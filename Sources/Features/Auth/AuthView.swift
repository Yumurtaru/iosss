//
//  AuthView.swift
//  Yumurta — маркетплейс (iOS, SwiftUI)
//
//  Экран входа/регистрации премиум-клиента (flash call убран — дорого).
//
//   Вход:  POST api/v1/auth/login  {login, password}  → {user, token, refresh, redirect}
//          login — email ИЛИ телефон.
//   Регистрация (2 шага, подтверждение почты):
//     1) POST api/v1/auth/register/request {name, phone, email, password} → {sent, ttl, email, debug_code}
//        (сервер шлёт 6-значный код на почту)
//     2) POST api/v1/auth/register/confirm {email, code} → {user, token, refresh, redirect}
//
//  Токены сохраняются через Session.signIn(token, refresh:): access → "token"
//  (Authorization: Bearer), refresh → "refresh_token". isLoggedIn флипается реактивно.
//
//  API.post<T> декодирует уже env.data. Ключи snake_case (debug_code) маппятся
//  авто-конвертером .convertFromSnakeCase.
//

import SwiftUI

// MARK: - DTO (полезная нагрузка `data` конверта v1)

/// Ответ register/request: подтверждение отправки + замаскированный email + dev-код.
private struct RegRequestResult: Decodable {
    let sent: Bool?
    let ttl: Int?
    let email: String?      // замаскированный адрес для UI
    let debugCode: String?  // dev-режим (debug_code → debugCode)
}

/// Ответ login / register/confirm: токены доступа и продления.
private struct AuthTokens: Decodable {
    let token: String?
    let refresh: String?
}

// MARK: - AuthView

struct AuthView: View {
    var onAuthed: (() -> Void)? = nil

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Вход по паролю; регистрация — форма → код с почты.
    private enum Step { case password, register, registerCode }
    @State private var step: Step = .password

    // Вход
    @State private var loginField = ""
    @State private var password = ""
    // Регистрация
    @State private var name = ""
    @State private var phone = ""
    @State private var regEmail = ""
    // Подтверждение почты
    @State private var code = ""
    @State private var sentMask: String?

    @State private var busy = false
    @State private var error: String?

    @FocusState private var focused: Field?
    private enum Field { case login, password, name, code }

    // MARK: Нормализация / валидация

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
    private var emailValid: Bool {
        let e = regEmail.trimmingCharacters(in: .whitespaces)
        return e.contains("@") && (e.split(separator: "@").last?.contains(".") ?? false) && !e.hasSuffix("@")
    }
    private var passwordValid: Bool { !loginField.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }
    private var registerValid: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2 && phoneValid && emailValid && password.count >= 6
    }
    private var codeValid: Bool { code.filter(\.isNumber).count == 6 }

    private var actionEnabled: Bool {
        guard !busy else { return false }
        switch step {
        case .password:     return passwordValid
        case .register:     return registerValid
        case .registerCode: return codeValid
        }
    }

    private var actionTitle: String {
        if busy { return "Подождите…" }
        switch step {
        case .password:     return "Войти"
        case .register:     return "Получить код"
        case .registerCode: return "Подтвердить"
        }
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            YMColor.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    logo.padding(.top, YMSpace.xxl)
                    heading.padding(.top, YMSpace.lg)
                    fields.padding(.top, YMSpace.xxl)

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

                    footerLinks.padding(.top, YMSpace.md)
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
                back()
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
        case .password:     return "Вход"
        case .register:     return "Регистрация"
        case .registerCode: return "Подтвердите почту"
        }
    }

    private var subtitleText: String {
        switch step {
        case .password:     return "Введите email или телефон и пароль"
        case .register:     return "Заполните данные — на почту придёт код подтверждения"
        case .registerCode: return "Мы отправили 6-значный код на \(sentMask ?? regEmail.trimmingCharacters(in: .whitespaces))"
        }
    }

    // MARK: Поля ввода

    @ViewBuilder
    private var fields: some View {
        switch step {
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

        case .register:
            VStack(alignment: .leading, spacing: YMSpace.md) {
                AuthField(placeholder: "Ваше имя", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .focused($focused, equals: .name)
                    .onAppear { focused = .name }
                AuthField(placeholder: "+7 900 000-00-00", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                AuthField(placeholder: "Email", text: $regEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                AuthField(placeholder: "Пароль (минимум 6 символов)", text: $password, secure: true)
                    .textContentType(.newPassword)
            }

        case .registerCode:
            AuthField(placeholder: "Код из письма", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(YMFont.title2)
                .multilineTextAlignment(.center)
                .focused($focused, equals: .code)
                .onAppear { focused = .code }
                .onChange(of: code) { new in
                    code = String(new.filter(\.isNumber).prefix(6))
                }
        }
    }

    // MARK: Нижние ссылки

    @ViewBuilder
    private var footerLinks: some View {
        if step == .registerCode {
            linkButton("Отправить код повторно") { registerRequest() }
        }
        if step == .password || step == .register {
            linkButton(step == .register ? "Уже есть аккаунт? Войти" : "Регистрация") {
                back(to: step == .register ? .password : .register)
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

    // MARK: Переходы

    private func back(to step: Step) {
        self.step = step
        error = nil
    }

    /// Кнопка «назад» в шапке: registerCode → register → password → закрыть.
    private func back() {
        switch step {
        case .password:     dismiss()
        case .register:     back(to: .password)
        case .registerCode: code = ""; back(to: .register)
        }
    }

    // MARK: Действия

    private func act() {
        switch step {
        case .password:     loginByPassword()
        case .register:     registerRequest()
        case .registerCode: registerConfirm()
        }
    }

    /// Вход логин(email/телефон) + пароль → токены.
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

    /// Шаг 1 регистрации: отправить код на почту.
    private func registerRequest() {
        guard registerValid, !busy else { return }
        busy = true; error = nil
        let body: [String: String] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "phone": normalizedPhone(),
            "email": regEmail.trimmingCharacters(in: .whitespaces),
            "password": password,
        ]
        Task {
            do {
                let r: RegRequestResult = try await API.shared.post("api/v1/auth/register/request", body: body)
                await MainActor.run {
                    busy = false
                    sentMask = r.email
                    if let dc = r.debugCode, !dc.isEmpty { code = dc } // dev-режим
                    Haptics.success()
                    back(to: .registerCode)
                }
            } catch {
                fail(error, fallback: "Не удалось отправить код")
            }
        }
    }

    /// Шаг 2 регистрации: подтвердить код → аккаунт создан, входим.
    private func registerConfirm() {
        guard codeValid, !busy else { return }
        busy = true; error = nil
        let email = regEmail.trimmingCharacters(in: .whitespaces).lowercased()
        Task {
            do {
                let t: AuthTokens = try await API.shared.post(
                    "api/v1/auth/register/confirm",
                    body: ["email": email, "code": code.trimmingCharacters(in: .whitespaces)]
                )
                finish(t)
            } catch {
                fail(error, fallback: "Неверный код")
            }
        }
    }

    /// Сохранение токенов + колбэк.
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

/// Поле ввода в surface-боксе с hairline. secure=true → SecureField.
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
