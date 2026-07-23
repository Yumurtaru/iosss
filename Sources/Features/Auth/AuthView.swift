//
//  AuthView.swift
//  Yumurta — маркетплейс (iOS, SwiftUI)
//
//  Экран входа премиум-клиента. Два способа (без соцсетей, паритет с Android AuthScreen):
//
//   1) Вход по ЗВОНКУ (Plusofon flashcall):
//        POST api/v1/auth/otp-request  {phone, channel:"call"}   → {sent, ttl, method, debug_code}
//        затем ввод последних 4 цифр номера, с которого позвонил робот →
//        POST api/v1/auth/otp-verify   {phone, code, name?}       → {user, token, refresh, redirect}
//
//   2) Вход по логину/паролю:
//        POST api/v1/auth/login        {login, password}          → {user, token, refresh, redirect}
//
//  Токены сохраняются через Session.signIn(token, refresh:) — как в старом iOS AuthView:
//  access кладётся в UserDefaults "token" (→ Authorization: Bearer подставляется в API),
//  refresh — в "refresh_token" (тихое продление при 401). isLoggedIn = (token != nil)
//  флипается реактивно, так что весь UI (Профиль/Заказы/Чат) сам обновляется.
//
//  Контракт API: server возвращает эти поля ВНУТРИ конверта {success,data,error}.
//  API.post<T> декодирует уже env.data, поэтому DTO ниже описывают именно data-полезную
//  нагрузку. Ключи snake_case (debug_code) маппятся авто-конвертером .convertFromSnakeCase.
//

import SwiftUI

// MARK: - DTO (полезная нагрузка `data` конверта v1)

/// Ответ otp-request: подтверждение отправки + метод/ttl + dev-код (если бэкенд его отдал).
private struct OtpRequestPayload: Decodable {
    let sent: Bool?
    let ttl: Int?
    let method: String?     // "call" — flashcall (Plusofon), либо "sms"
    let debugCode: String?  // dev-режим: сервер может подставить код (debug_code → debugCode)
}

/// Ответ login / otp-verify: токены доступа и продления.
private struct AuthTokens: Decodable {
    let token: String?
    let refresh: String?
}

// MARK: - AuthView

/// Экран входа. Драйвит Session напрямую (isLoggedIn флипается сам), плюс опциональный
/// колбэк onAuthed — вызывается ПОСЛЕ успешного сохранения токенов (для навигации/закрытия
/// шита главным процессом). Готов и к вызову как `AuthView(onAuthed: { … })`, и как `AuthView()`.
struct AuthView: View {
    var onAuthed: (() -> Void)? = nil

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Шаги как в Android: ввод телефона → код из звонка; отдельно — вход по паролю.
    private enum Step { case phone, code, password }
    @State private var step: Step = .phone

    @State private var phone = ""
    @State private var code = ""
    @State private var loginField = ""
    @State private var password = ""
    @State private var name = ""

    @State private var busy = false
    @State private var error: String?

    @FocusState private var focused: Field?
    private enum Field { case phone, code, login, password }

    // MARK: Нормализация / валидация

    /// Нормализует ввод в +7XXXXXXXXXX (толерантно: 8XXXXXXXXXX, 7XXXXXXXXXX, 10 цифр).
    private func normalizedPhone() -> String {
        let digits = phone.filter(\.isNumber)
        let d: String
        switch true {
        case digits.count == 11 && digits.hasPrefix("8"): d = "7" + digits.dropFirst()
        case digits.count == 11 && digits.hasPrefix("7"): d = digits
        case digits.count == 10:                          d = "7" + digits
        default:                                          d = digits
        }
        return "+" + d
    }

    private var phoneValid: Bool { (10...11).contains(phone.filter(\.isNumber).count) }
    private var codeValid: Bool  { code.filter(\.isNumber).count == 4 }
    private var passwordValid: Bool { !loginField.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }

    private var actionEnabled: Bool {
        guard !busy else { return false }
        switch step {
        case .phone:    return phoneValid
        case .code:     return codeValid
        case .password: return passwordValid
        }
    }

    private var actionTitle: String {
        if busy { return "Подождите…" }
        return step == .phone ? "Позвонить мне" : "Войти"
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            YMColor.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    logo
                        .padding(.top, YMSpace.xxl)
                    heading
                        .padding(.top, YMSpace.lg)
                    fields
                        .padding(.top, YMSpace.xxl)

                    if let error, !error.isEmpty {
                        Text(error)
                            .font(YMFont.subhead)
                            .foregroundStyle(YMColor.statusCancel)
                            .padding(.top, YMSpace.sm)
                    }

                    Button(action: act) {
                        HStack(spacing: YMSpace.sm) {
                            if busy { ProgressView().tint(YMColor.onAccent) }
                            Text(actionTitle)
                        }
                    }
                    .buttonStyle(YMPrimaryButtonStyle())
                    .disabled(!actionEnabled)
                    .opacity(actionEnabled ? 1 : 0.55)
                    .padding(.top, YMSpace.xl)

                    footerLinks
                        .padding(.top, YMSpace.md)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.bottom, YMSpace.xxxl)
            }
        }
        .animation(YMMotion.adaptive(YMMotion.spring, reduceMotion: reduceMotion), value: step)
    }

    // MARK: Шапка «← Назад»

    private var topBar: some View {
        HStack {
            Button {
                Haptics.light()
                if step != .phone { back(to: .phone) } else { dismiss() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(YMColor.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, YMSpace.md)
    }

    // MARK: Логотип

    private var logo: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 64, height: 64)
            .overlay(
                Text("Y").font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(YMPalette.goldInk)
            )
            .shadow(color: YMPalette.gold.opacity(0.45), radius: 20, y: 10)
    }

    // MARK: Заголовок + подзаголовок

    private var heading: some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text(titleText)
                .font(.system(size: 30, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(YMColor.text)
            Text(subtitleText)
                .font(YMFont.body)
                .foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: String {
        switch step {
        case .phone:    return "Вход по номеру"
        case .code:     return "Код из звонка"
        case .password: return "Вход по паролю"
        }
    }

    private var subtitleText: String {
        switch step {
        case .phone:    return "Вам позвонит робот — подтверждение по звонку"
        case .code:     return "Введите последние 4 цифры номера, с которого поступил звонок на \(normalizedPhone())"
        case .password: return "Введите телефон/email и пароль"
        }
    }

    // MARK: Поля ввода

    @ViewBuilder
    private var fields: some View {
        switch step {
        case .phone:
            AuthField(placeholder: "+7 900 000-00-00", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focused, equals: .phone)
                .onAppear { focused = .phone }

        case .code:
            VStack(alignment: .leading, spacing: YMSpace.md) {
                AuthField(placeholder: "Последние 4 цифры звонка", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(YMFont.title2)
                    .multilineTextAlignment(.center)
                    .focused($focused, equals: .code)
                    .onAppear { focused = .code }
                    .onChange(of: code) { new in
                        code = String(new.filter(\.isNumber).prefix(4))
                    }
                AuthField(placeholder: "Ваше имя (если впервые)", text: $name)
                    .textContentType(.name)
            }

        case .password:
            VStack(alignment: .leading, spacing: YMSpace.md) {
                AuthField(placeholder: "Телефон или email", text: $loginField)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focused, equals: .login)
                    .onAppear { focused = .login }
                AuthField(placeholder: "Пароль", text: $password, secure: true)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
            }
        }
    }

    // MARK: Нижние ссылки (повтор звонка / переключатель способа)

    @ViewBuilder
    private var footerLinks: some View {
        if step == .code {
            linkButton("Позвонить повторно") { requestCall() }
        }
        if step == .phone || step == .password {
            linkButton(step == .phone ? "Войти по паролю" : "Войти по звонку") {
                back(to: step == .phone ? .password : .phone)
            }
        }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.light(); action() }) {
            Text(title)
                .font(YMFont.subhead)
                .foregroundStyle(YMColor.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, YMSpace.sm)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: Переходы между шагами

    private func back(to step: Step) {
        self.step = step
        error = nil
    }

    // MARK: Действия

    private func act() {
        switch step {
        case .phone:    requestCall()
        case .code:     verify()
        case .password: loginByPassword()
        }
    }

    /// Шаг 1: запросить звонок (Plusofon flashcall). channel:"call".
    private func requestCall() {
        guard phoneValid, !busy else { return }
        busy = true; error = nil
        Task {
            do {
                let r: OtpRequestPayload = try await API.shared.post(
                    "api/v1/auth/otp-request",
                    body: ["phone": normalizedPhone(), "channel": "call"]
                )
                await MainActor.run {
                    if let dc = r.debugCode, !dc.isEmpty { code = dc } // dev-режим: автоподстановка
                    busy = false
                    Haptics.success()
                    back(to: .code)
                }
            } catch {
                fail(error, fallback: "Не удалось позвонить")
            }
        }
    }

    /// Шаг 2: подтвердить код из звонка → токены.
    private func verify() {
        guard codeValid, !busy else { return }
        busy = true; error = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                var body: [String: String] = ["phone": normalizedPhone(), "code": code.trimmingCharacters(in: .whitespaces)]
                if !trimmedName.isEmpty { body["name"] = trimmedName }
                let t: AuthTokens = try await API.shared.post("api/v1/auth/otp-verify", body: body)
                finish(t)
            } catch {
                fail(error, fallback: "Неверный код")
            }
        }
    }

    /// Альтернатива: вход логин + пароль → токены.
    private func loginByPassword() {
        guard passwordValid, !busy else { return }
        busy = true; error = nil
        Task {
            do {
                let t: AuthTokens = try await API.shared.post(
                    "api/v1/auth/login",
                    body: ["login": loginField.trimmingCharacters(in: .whitespaces), "password": password]
                )
                finish(t)
            } catch {
                fail(error, fallback: "Неверный логин или пароль")
            }
        }
    }

    /// Сохранение токенов + колбэк. Session.signIn кладёт access в "token",
    /// refresh — в "refresh_token"; isLoggedIn становится true реактивно.
    @MainActor
    private func finish(_ tokens: AuthTokens) {
        busy = false
        guard let token = tokens.token, !token.isEmpty else {
            error = "Не получили токен"
            Haptics.error()
            return
        }
        session.signIn(token, refresh: tokens.refresh)
        Haptics.success()
        if let onAuthed { onAuthed() } else { dismiss() }
    }

    @MainActor
    private func fail(_ error: Error, fallback: String) {
        busy = false
        if error is CancellationError { return }
        let msg = error.localizedDescription
        self.error = msg.isEmpty ? fallback : msg
        Haptics.error()
    }
}

// MARK: - AuthField (стилизованное поле под премиум-токены)

/// Поле ввода в surface-боксе с hairline (паритет с Android AuthField).
/// secure=true → SecureField (маскированный пароль).
private struct AuthField: View {
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(YMFont.body)
        .foregroundStyle(YMColor.text)
        .tint(YMColor.accent)
        .padding(.horizontal, YMSpace.lg)
        .frame(height: 54)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1)
        )
    }
}
