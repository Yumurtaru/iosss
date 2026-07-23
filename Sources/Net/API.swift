import Foundation

enum APIError: LocalizedError {
    case server(String)   // ошибка уровня приложения (success=false) — не повторяем
    case http(Int)        // HTTP-статус ошибки — повторяем при >= 500
    case network          // нет соединения — повторяем
    case timeout          // истёк таймаут — повторяем
    case unauthorized     // 401 — нужен повторный вход
    case decoding
    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .http(let c):   return "Ошибка сервера (\(c))"
        case .network:       return "Нет соединения с интернетом"
        case .timeout:       return "Превышено время ожидания. Попробуйте ещё раз"
        case .unauthorized:  return "Сессия истекла, войдите снова"
        case .decoding:      return "Не удалось обработать ответ"
        }
    }
    /// Стоит ли повторять запрос при этой ошибке (для идемпотентных GET).
    var isRetryable: Bool {
        switch self {
        case .network, .timeout: return true
        case .http(let c):       return c >= 500
        default:                 return false
        }
    }
}

final class API {
    static let shared = API()
    static let base = "https://yumurta.ru"

    /// Вызывается при 401 (истёкший токен). Session подписывается, чтобы выйти из аккаунта.
    var onUnauthorized: (() -> Void)?

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()

    /// Свой URLSession: таймауты и ожидание появления сети.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20       // ожидание ответа на запрос
        cfg.timeoutIntervalForResource = 40      // суммарный лимит на ресурс
        cfg.waitsForConnectivity = true          // подождать сеть вместо мгновенной ошибки
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private let maxRetries = 2                    // доп. попытки (итого до 3) для GET

    static func imageURL(_ path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        if p.hasPrefix("http") { return URL(string: p) }
        return URL(string: base + "/assets/uploads/" + p)
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String] = [:], body: Encodable? = nil) throws -> URLRequest {
        var comps = URLComponents(string: API.base + "/" + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = UserDefaults.standard.string(forKey: "token") { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = body { req.httpBody = try Self.encoder.encode(AnyEncodable(body)) }
        return req
    }

    /// Повтор только для идемпотентных запросов (GET): POST/PUT/DELETE не повторяем,
    /// чтобы не задвоить заказ или платёж.
    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let idempotent = (req.httpMethod ?? "GET") == "GET"
        let attempts = idempotent ? maxRetries + 1 : 1
        var lastError: Error = APIError.network
        for attempt in 0..<attempts {
            do {
                return try await perform(req, as: type)
            } catch let e as APIError where e.isRetryable && attempt < attempts - 1 {
                lastError = e
                let delay = pow(2.0, Double(attempt)) * 0.5 + Double.random(in: 0...0.3) // 0.5s, 1.5s + джиттер
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
        }
        throw lastError
    }

    private func perform<T: Decodable>(_ req: URLRequest, as type: T.Type, isRetryAfterRefresh: Bool = false) async throws -> T {
        let data: Data; let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }   // отмена (дебаунс) — не повторяем
            throw urlError.code == .timedOut ? APIError.timeout : APIError.network
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.network
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // Тихое продление access-токена (security-аудит): refresh → один повтор запроса.
            // Позволяет серверу сократить JWT_EXPIRES до часов без массовых разлогинов.
            if !isRetryAfterRefresh,
               !(req.url?.path.hasSuffix("/auth/refresh") ?? false),
               let newToken = await refreshAccessToken() {
                var retry = req
                retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                return try await perform(retry, as: type, isRetryAfterRefresh: true)
            }
            if let handler = onUnauthorized { await MainActor.run { handler() } }
            throw APIError.unauthorized
        }

        do {
            let env = try decoder.decode(APIEnvelope<T>.self, from: data)
            if env.success == false { throw APIError.server(env.error?.message ?? "Ошибка сервера") }
            // Ошибочный статус с телом {ok:false,error:"..."} (Response::error): success отсутствует,
            // но текст есть — показываем его (иначе терялось «Минимальная сумма заказа…» → «Ошибка 422»).
            if status >= 400, let msg = env.error?.message, !msg.isEmpty { throw APIError.server(msg) }
            guard let payload = env.data else { throw APIError.decoding }
            return payload
        } catch let e as APIError {
            throw e
        } catch {
            if status >= 500 { throw APIError.http(status) }
            if status >= 400 { throw APIError.server("Ошибка \(status)") }
            throw APIError.decoding
        }
    }

    // ── Тихое продление access-токена (security-аудит) ──────────────────────
    // Single-flight: параллельные 401 ждут один общий refresh-вызов.
    private var refreshTask: Task<String?, Never>?

    private func refreshAccessToken() async -> String? {
        if let running = refreshTask { return await running.value }
        let task = Task<String?, Never> { [weak self] () -> String? in
            guard let self = self,
                  let refresh = UserDefaults.standard.string(forKey: "refresh_token"),
                  !refresh.isEmpty,
                  let url = URL(string: API.base + "/api/v1/auth/refresh") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
            struct RefreshResp: Decodable { let token: String? }
            guard let (data, resp) = try? await self.session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let env = try? self.decoder.decode(APIEnvelope<RefreshResp>.self, from: data),
                  let token = env.data?.token, !token.isEmpty else { return nil }
            UserDefaults.standard.set(token, forKey: "token")
            return token
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(try makeRequest("GET", path, query: query), as: T.self)
    }
    func post<T: Decodable>(_ path: String, body: Encodable? = nil) async throws -> T {
        try await send(try makeRequest("POST", path, body: body), as: T.self)
    }
    func put<T: Decodable>(_ path: String, body: Encodable? = nil) async throws -> T {
        try await send(try makeRequest("PUT", path, body: body), as: T.self)
    }
    func list<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> [T] {
        let p: ListPayload<T> = try await send(try makeRequest("GET", path, query: query), as: ListPayload<T>.self)
        return p.items
    }
    func postVoid(_ path: String, body: Encodable? = nil) async throws { _ = try await send(try makeRequest("POST", path, body: body), as: EmptyResp.self) }

    /// POST с телом application/x-www-form-urlencoded.
    /// Нужен там, где сервер читает поля из `$_POST` (PHP не наполняет $_POST из JSON-тела),
    /// например отклик на вакансию: POST api/v1/jobs/{id}/apply {name, phone}.
    /// Совпадает с Android @FormUrlEncoded — контракт 1:1.
    func postForm<T: Decodable>(_ path: String, form: [String: String]) async throws -> T {
        let url = URLComponents(string: API.base + "/" + path)!.url!
        // percent-кодирование значений (пробелы, кириллица, '+', '&', '=' и т.п.)
        var enc = CharacterSet.urlQueryAllowed
        enc.remove(charactersIn: "+&=")
        let bodyStr = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: enc) ?? value)"
        }.joined(separator: "&")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token = UserDefaults.standard.string(forKey: "token") { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = bodyStr.data(using: .utf8)
        return try await send(req, as: T.self)
    }
    func postFormVoid(_ path: String, form: [String: String]) async throws { _ = try await postForm(path, form: form) as EmptyResp }
    func deleteVoid(_ path: String) async throws { _ = try await send(try makeRequest("DELETE", path), as: EmptyResp.self) }
    func putVoid(_ path: String, body: Encodable? = nil) async throws { _ = try await send(try makeRequest("PUT", path, body: body), as: EmptyResp.self) }
}

// MARK: - Вспомогательные типы транспорта
// (восстановлено: в исходном моторе жили в хвосте API.swift, который был обрезан)

/// Стирание типа для Encodable-тела запроса — чтобы принимать любой Encodable
/// и корректно прогонять через JSONEncoder с .convertToSnakeCase.
struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { self.encodeFunc = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}

/// Пустой ответ для запросов без полезной нагрузки (postVoid/putVoid/deleteVoid).
/// Толерантен к пустому data / отсутствию тела.
struct EmptyResp: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}

/// Тело регистрации push-токена: POST /api/v1/push/register.
/// camelCase → snake_case автоматически через .convertToSnakeCase.
struct PushBody: Encodable {
    let token: String
    let platform: String
}
