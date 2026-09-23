import Foundation

enum APIError: LocalizedError {
    case server(String)   // ошибка уровня приложения (success=false) — не повторяем
    case http(Int)        // HTTP-статус ошибки — повторяем при >= 500
    case network          // нет соединения — повторяем
    case timeout          // истёк таймаут — повторяем
    case unauthorized     // 401 — нужен повторный вход
    case decoding
    /// 409 «не хватает денег на кошельке». Сервер присылает суммы, и экран
    /// показывает «Пополните на 269 ₽» с кнопкой, а не «Ошибка сервера (409)».
    /// Так отвечают создание заказа с оплатой кошельком и публикация объявления.
    case walletShortage(need: Decimal, balance: Decimal, missing: Decimal, message: String)
    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .http(let c):   return "Ошибка сервера (\(c))"
        case .network:       return "Нет соединения с интернетом"
        case .timeout:       return "Превышено время ожидания. Попробуйте ещё раз"
        case .unauthorized:  return "Сессия истекла, войдите снова"
        case .decoding:      return "Не удалось обработать ответ"
        case .walletShortage(_, _, _, let m): return m
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

    /// Абсолютный адрес картинки.
    ///
    /// Сервер отдаёт пути в двух видах, и это не оплошность, а история разделов:
    ///   • товары, логотипы, баннеры — голый путь внутри хранилища
    ///     ("products/2026/06/x.webp"), к нему нужно дописать /assets/uploads/;
    ///   • объявления — уже готовый путь от корня сайта
    ///     ("/assets/uploads/ads/2026/09/x.webp", см. adsPhotoUrl в routes/ads.php),
    ///     к нему нужно дописать ТОЛЬКО адрес сайта.
    ///
    /// Второй случай раньше не обрабатывался: URL(string:) отдавал относительный
    /// адрес без схемы, AsyncImage такой не грузит — фото объявлений было видно на
    /// сайте и не видно в приложении.
    static func imageURL(_ path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        if p.hasPrefix("http") { return URL(string: p) }
        if p.hasPrefix("/") { return URL(string: base + p) }
        return URL(string: base + "/assets/uploads/" + p)
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String] = [:], body: Encodable? = nil) throws -> URLRequest {
        // Без «!»: путь может содержать данные извне (слаг из ссылки), и кривой
        // адрес должен давать ошибку запроса, а не падение приложения.
        guard var comps = URLComponents(string: API.base + "/" + path) else { throw APIError.network }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let reqURL = comps.url else { throw APIError.network }
        var req = URLRequest(url: reqURL)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.access { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
            if !isRetryAfterRefresh, !(req.url?.path.hasSuffix("/auth/refresh") ?? false) {
                switch await refreshAccessToken() {
                case .token(let newToken):
                    var retry = req
                    retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    return try await perform(retry, as: type, isRetryAfterRefresh: true)
                case .unavailable:
                    // Продлить не удалось из-за СЕТИ (таймаут, нет связи, 5xx).
                    // Раньше это считалось отказом, и человека разлогинивало со
                    // стиранием ещё живого refresh-токена. Теперь — «нет связи».
                    throw APIError.network
                case .rejected:
                    break
                }
            }
            if let handler = onUnauthorized { await MainActor.run { handler() } }
            throw APIError.unauthorized
        }

        do {
            let env = try decoder.decode(APIEnvelope<T>.self, from: data)
            // 409 с суммами need/balance/missing — это «не хватает на кошельке».
            // Разбираем ДО общей ветки success == false, иначе экран получил бы
            // только текст и не смог бы дать кнопку «Пополнить».
            if status == 409, let d = env.error?.details,
               let missing = d["missing"].flatMap({ Decimal(string: $0) }) {
                throw APIError.walletShortage(
                    need: d["need"].flatMap { Decimal(string: $0) } ?? 0,
                    balance: d["balance"].flatMap { Decimal(string: $0) } ?? 0,
                    missing: missing,
                    message: env.error?.message ?? "Не хватает денег на кошельке"
                )
            }
            if env.success == false {
                // Ошибки полей (details: {"title": "Слишком короткий заголовок"}) —
                // добавляем первую к общему «Проверьте поля объявления», иначе
                // человек не понимал, что именно исправить.
                var msg = env.error?.message ?? "Ошибка сервера"
                if status == 422, let first = env.error?.details?.values.sorted().first, !first.isEmpty, !msg.contains(first) {
                    msg += ": " + first
                }
                throw APIError.server(msg)
            }
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
    /// Итог продления: новый токен, отказ сервера (refresh недействителен →
    /// выход) или «сервер недоступен» (сеть/5xx → токены НЕ трогаем).
    enum RefreshOutcome { case token(String), rejected, unavailable }
    private var refreshTask: Task<RefreshOutcome, Never>?

    private func refreshAccessToken() async -> RefreshOutcome {
        if let running = refreshTask { return await running.value }
        let task = Task<RefreshOutcome, Never> { [weak self] () -> RefreshOutcome in
            guard let self = self,
                  let refresh = TokenStore.refresh,
                  !refresh.isEmpty,
                  let url = URL(string: API.base + "/api/v1/auth/refresh") else { return .rejected }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
            struct RefreshResp: Decodable { let token: String? }
            guard let (data, resp) = try? await self.session.data(for: req) else { return .unavailable }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code >= 500 || code == 0 || code == 429 { return .unavailable }
            guard code == 200,
                  let env = try? self.decoder.decode(APIEnvelope<RefreshResp>.self, from: data),
                  let token = env.data?.token, !token.isEmpty else { return .rejected }
            TokenStore.access = token
            return .token(token)
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
        guard let url = URLComponents(string: API.base + "/" + path)?.url else { throw APIError.network }
        // percent-кодирование значений (пробелы, кириллица, '+', '&', '=' и т.п.)
        var enc = CharacterSet.urlQueryAllowed
        enc.remove(charactersIn: "+&=")
        let bodyStr = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: enc) ?? value)"
        }.joined(separator: "&")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.access { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = bodyStr.data(using: .utf8)
        return try await send(req, as: T.self)
    }
    func postFormVoid(_ path: String, form: [String: String]) async throws { _ = try await postForm(path, form: form) as EmptyResp }

    /// Multipart-загрузка фото в чат заказа: POST api/v1/orders/{id}/chat/photo (field "photo").
    /// Возвращает относительный путь вложения. Проходит через send() (конверт/401/ретрай).
    func uploadChatPhoto(orderId: Int, jpeg: Data, caption: String = "") async throws -> String? {
        struct PhotoResp: Decodable { let attachment: String? }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: API.base + "/api/v1/orders/\(orderId)/chat/photo")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.access { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        if !caption.isEmpty { field("caption", caption) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let r: PhotoResp = try await send(req, as: PhotoResp.self)
        return r.attachment
    }
    // ── Доска объявлений (routes/ads.php) ──────────────────────────────────
    //
    // Загрузка фото лежит ЗДЕСЬ, а не в отдельном файле: send() приватный и
    // виден только внутри этого файла, а именно он разбирает конверт ответа,
    // обновляет токен по 401 и повторяет запрос.
    func adCategories() async throws -> AdCategoriesResponse {
        try await get("api/v1/ads/categories")
    }
    func ads(categoryId: Int = 0, q: String = "", cityId: Int = 0,
             priceMin: String = "", priceMax: String = "",
             sort: String = "new", withPhoto: Bool = false, page: Int = 1) async throws -> AdsFeedResponse {
        var query: [String: String] = ["sort": sort, "page": String(page)]
        if categoryId > 0 { query["category_id"] = String(categoryId) }
        if !q.isEmpty { query["q"] = q }
        if cityId > 0 { query["city_id"] = String(cityId) }
        if !priceMin.isEmpty { query["price_min"] = priceMin }
        if !priceMax.isEmpty { query["price_max"] = priceMax }
        if withPhoto { query["with_photo"] = "1" }
        return try await get("api/v1/ads", query: query)
    }
    func ad(_ id: Int) async throws -> AdDetailResponse { try await get("api/v1/ads/\(id)") }
    func myAds() async throws -> MyAdsResponse { try await get("api/v1/ads/my") }
    /// Избранные объявления. Постранично — как обычная лента.
    func adFavorites(page: Int = 1) async throws -> AdsFeedResponse {
        try await get("api/v1/ads/favorites", query: ["page": String(page)])
    }
    func adCreate(_ body: AdSaveBody) async throws -> AdCreatedResponse { try await post("api/v1/ads", body: body) }
    func adUpdate(_ id: Int, _ body: AdSaveBody) async throws { try await putVoid("api/v1/ads/\(id)", body: body) }
    func adPublish(_ id: Int) async throws -> AdPublishResponse { try await post("api/v1/ads/\(id)/publish") }
    /// Продлить действующее объявление заранее (последние 3 дня срока). Сервер продлевает только по явному renew=true.
    func adRenew(_ id: Int) async throws -> AdPublishResponse { try await post("api/v1/ads/\(id)/publish", body: ["renew": true]) }
    func adArchive(_ id: Int) async throws { _ = try await post("api/v1/ads/\(id)/archive", body: [String: String]()) as EmptyResp }
    func adDelete(_ id: Int) async throws { try await deleteVoid("api/v1/ads/\(id)") }
    func adPhotoDelete(adId: Int, photoId: Int) async throws { try await deleteVoid("api/v1/ads/\(adId)/photos/\(photoId)") }
    func adFavorite(_ id: Int) async throws -> AdFavoriteResponse { try await post("api/v1/ads/\(id)/favorite") }
    func adContact(_ id: Int) async throws -> AdContactResponse { try await post("api/v1/ads/\(id)/contact") }
    func adReport(_ id: Int, reason: String, comment: String?) async throws {
        _ = try await post("api/v1/ads/\(id)/report", body: AdReportBody(reason: reason, comment: comment)) as EmptyResp
    }

    /// Одна фотография объявления: POST api/v1/ads/{id}/photos, поле "photo".
    func uploadAdPhoto(adId: Int, jpeg: Data) async throws -> AdPhoto? {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: API.base + "/api/v1/ads/\(adId)/photos")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.access { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let r: AdPhotoUploadedResponse = try await send(req, as: AdPhotoUploadedResponse.self)
        return r.photo
    }

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
    /// Город, выбранный в приложении. Сервер иначе не знает, где клиент, и не
    /// может прислать «новое заведение в вашем городе». Поле аддитивное:
    /// nil не кодируется, старый сервер его игнорирует.
    var cityId: Int? = nil
}
