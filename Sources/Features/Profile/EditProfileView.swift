//
//  EditProfileView.swift — Редактирование профиля (premium-клиент)
//
//  Имя и Email редактируются, телефон — только чтение (это логин).
//  Токены YM, light+dark, Dynamic Type, состояния загрузка/ошибка/сохранение.
//
//  ТОЧКА ВХОДА (для навигации из ProfileView):
//    EditProfileView()   — самодостаточный экран (внутренний ScrollView),
//                          навешивается через .navigationDestination.
//
//  ПРИВЯЗКА К API (как в старом EditProfileView):
//    • GET api/v1/profile   → Profile (name/phone/email)
//    • PUT api/v1/profile   ← {name, email}  (email опционален)  через putVoid
//

import SwiftUI

/// Тело обновления профиля (PUT api/v1/profile). camelCase → snake_case автоматически.
/// email/phone/password опциональны: nil-поля сервер пропускает (isset() == false для null).
private struct EditProfileBody: Encodable {
    let name: String
    let email: String?
    let phone: String?
    let password: String?
}

/// Подтверждаемая смена данных. changes — только изменённые поля; method: "call" | "email".
private struct ChangeRequestBody: Encodable {
    let changes: [String: String]
    let method: String
}
/// Ответ на запрос подтверждения (data-нагрузка). debug_code → debugCode (convertFromSnakeCase).
private struct ChangeRequestResult: Decodable {
    let method: String?
    let ttl: Int?
    let target: String?
    let debugCode: String?
}
private struct ChangeConfirmBody: Encodable { let code: String }

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var password = ""
    @State private var loading = true
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?

    // Исходные значения — чтобы понять, что реально изменилось.
    @State private var origName = ""
    @State private var origEmail = ""
    @State private var origPhone = ""
    // Поток подтверждения.
    @State private var showCodeSheet = false
    @State private var showSupportSheet = false
    @State private var pendingChanges: [String: String] = [:]
    @State private var confirmTarget: String?
    @State private var code = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return true }  // email опционален
        return e.contains("@") && e.contains(".") && !e.hasSuffix("@")
    }
    private var phoneValid: Bool { (10...11).contains(phone.filter(\.isNumber).count) }
    private var passwordValid: Bool { password.isEmpty || password.count >= 6 }  // пустой = не меняем
    private var canSave: Bool { !trimmedName.isEmpty && emailValid && phoneValid && passwordValid && !saving }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.lg) {
                if loading {
                    ForEach(0..<3, id: \.self) { _ in SkeletonBox(radius: 16).frame(height: 74) }
                } else if let loadError {
                    EditProfileErrorState(message: loadError) { Task { await load() } }
                } else {
                    field(title: "Имя", placeholder: "Ваше имя", text: $name,
                          contentType: .name, keyboard: .default, autocap: .words)

                    field(title: "Email", placeholder: "email@example.com", text: $email,
                          contentType: .emailAddress, keyboard: .emailAddress, autocap: .never)
                    if !emailValid {
                        Text("Проверьте адрес электронной почты")
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            .padding(.top, -8).padding(.leading, 4)
                    }

                    field(title: "Телефон", placeholder: "+7 900 000-00-00", text: $phone,
                          contentType: .telephoneNumber, keyboard: .phonePad, autocap: .never)
                    if !phoneValid {
                        Text("Проверьте номер телефона")
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            .padding(.top, -8).padding(.leading, 4)
                    }

                    passwordField

                    if let saveError {
                        Text(saveError)
                            .font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: save) {
                        if saving { ProgressView().tint(YMColor.onAccent) }
                        else { Text("Сохранить") }
                    }
                    .buttonStyle(YMPrimaryButtonStyle())
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
                    .padding(.top, YMSpace.sm)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.lg)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Редактировать профиль")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showCodeSheet) { codeSheet }
        .sheet(isPresented: $showSupportSheet) { supportSheet }
    }

    // ── Поле ввода ──
    private func field(title: String, placeholder: String, text: Binding<String>,
                       contentType: UITextContentType, keyboard: UIKeyboardType,
                       autocap: TextInputAutocapitalization) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.muted)
            TextField(placeholder, text: text)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocap)
                .autocorrectionDisabled(contentType == .emailAddress)
                .font(.system(size: 15))
                .foregroundStyle(YMColor.text)
                .padding(.horizontal, 14).padding(.vertical, 14)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
        }
    }

    // ── Новый пароль (опционально) ──
    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Новый пароль")
                .font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.muted)
            SecureField("Оставьте пустым, чтобы не менять", text: $password)
                .textContentType(.newPassword)
                .font(.system(size: 15))
                .foregroundStyle(YMColor.text)
                .padding(.horizontal, 14).padding(.vertical, 14)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            if !passwordValid {
                Text("Пароль минимум 6 символов")
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
            } else {
                Text("Смена телефона, почты или пароля требует подтверждения (звонок или код на почту).")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
        }
    }

    // ── Лист ввода кода подтверждения ──
    private var codeSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: YMSpace.lg) {
                Text(confirmTarget != nil ? "Мы отправили код на \(confirmTarget!)" : "Введите код подтверждения из письма")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                TextField("Код", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 14)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .onChange(of: code) { new in code = String(new.filter(\.isNumber).prefix(6)) }
                if let saveError {
                    Text(saveError).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                }
                Button(action: confirmCode) {
                    if saving { ProgressView().tint(YMColor.onAccent) } else { Text("Подтвердить") }
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(code.isEmpty || saving)
                .opacity((code.isEmpty || saving) ? 0.5 : 1)

                Button("Код не приходит? Написать в поддержку") {
                    showCodeSheet = false; code = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showSupportSheet = true }
                }
                .font(YMFont.subhead).foregroundStyle(YMColor.accent)
                .frame(maxWidth: .infinity)
                .disabled(saving)

                Spacer()
            }
            .padding(YMSpace.xl)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Подтверждение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showCodeSheet = false; code = "" }
                }
            }
        }
    }

    // ── Лист «Написать в поддержку» ──
    private var supportSheet: some View {
        SupportComposeSheet(
            onCancel: { showSupportSheet = false },
            onSent: { showSupportSheet = false; saveError = nil }
        )
    }

    // ── Data ──
    private func load() async {
        loading = true
        loadError = nil
        do {
            let p: Profile = try await API.shared.get("api/v1/profile")
            await MainActor.run {
                name = p.name ?? ""; email = p.email ?? ""; phone = p.phone ?? ""
                origName = name; origEmail = email; origPhone = phone
                loading = false
            }
        } catch is CancellationError {
        } catch {
            await MainActor.run {
                loadError = (error as? APIError)?.errorDescription ?? "Не удалось загрузить профиль"
                loading = false
            }
        }
    }

    // Что реально изменилось относительно загруженного профиля.
    private func buildChanges() -> [String: String] {
        var m: [String: String] = [:]
        let n = trimmedName
        if !n.isEmpty && n != origName { m["name"] = n }
        let e = email.trimmingCharacters(in: .whitespaces)
        if e != origEmail { m["email"] = e }
        let p = phone.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && p != origPhone { m["phone"] = p }
        if !password.isEmpty { m["password"] = password }
        return m
    }

    private func save() {
        guard canSave else { return }
        saveError = nil
        let m = buildChanges()
        if m.isEmpty { saveError = "Нет изменений"; return }
        let sensitive = m["email"] != nil || m["phone"] != nil || m["password"] != nil
        if sensitive {
            pendingChanges = m
            requestConfirm("email")         // → код на почту
        } else {
            // Только имя — сохраняем сразу, без подтверждения.
            saving = true
            Task {
                do {
                    try await API.shared.putVoid("api/v1/profile",
                        body: EditProfileBody(name: trimmedName, email: nil, phone: nil, password: nil))
                    await MainActor.run { Haptics.success(); saving = false; dismiss() }
                } catch {
                    await MainActor.run {
                        Haptics.error()
                        saveError = (error as? APIError)?.errorDescription ?? "Не удалось сохранить изменения"
                        saving = false
                    }
                }
            }
        }
    }

    // Запросить подтверждение выбранным способом (call | email).
    private func requestConfirm(_ method: String) {
        saving = true; saveError = nil
        Task {
            do {
                let r: ChangeRequestResult = try await API.shared.post(
                    "api/v1/profile/change/request",
                    body: ChangeRequestBody(changes: pendingChanges, method: method))
                await MainActor.run {
                    saving = false
                    confirmTarget = r.target
                    code = r.debugCode ?? ""
                    showCodeSheet = true
                }
            } catch {
                await MainActor.run {
                    Haptics.error()
                    saving = false
                    saveError = (error as? APIError)?.errorDescription ?? "Не удалось отправить код"
                }
            }
        }
    }

    // Подтвердить код → сервер применяет изменения.
    private func confirmCode() {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !saving else { return }
        saving = true; saveError = nil
        Task {
            do {
                try await API.shared.postVoid("api/v1/profile/change/confirm", body: ChangeConfirmBody(code: c))
                await MainActor.run {
                    Haptics.success(); saving = false
                    showCodeSheet = false; password = ""; code = ""
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    Haptics.error(); saving = false
                    saveError = (error as? APIError)?.errorDescription ?? "Неверный код"
                }
            }
        }
    }

}

private struct EditProfileErrorState: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: YMSpace.md) {
            Text("😕").font(.system(size: 44))
            Text(message)
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button("Повторить") { Haptics.light(); onRetry() }
                .buttonStyle(YMPrimaryButtonStyle())
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

/// Лист «Написать в поддержку» — создаёт тикет через POST api/v1/support.
/// Самодостаточный: свой стейт, свой сетевой вызов. onSent вызывается при успехе.
private struct SupportComposeSheet: View {
    let onCancel: () -> Void
    let onSent: () -> Void

    @State private var message = ""
    @State private var sending = false
    @State private var error: String?

    private struct Payload: Encodable { let subject: String?; let message: String }

    private var canSend: Bool { message.trimmingCharacters(in: .whitespaces).count >= 5 && !sending }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: YMSpace.lg) {
                Text("Опишите проблему — мы ответим прямо в приложении.")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                ZStack(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Ваше сообщение…")
                            .font(.system(size: 15)).foregroundStyle(YMColor.muted)
                            .padding(.horizontal, 14).padding(.vertical, 16)
                    }
                    TextEditor(text: $message)
                        .frame(minHeight: 140)
                        .padding(6)
                        .scrollContentBackground(.hidden)
                        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                }
                if let error {
                    Text(error).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                }
                Button(action: send) {
                    if sending { ProgressView().tint(YMColor.onAccent) } else { Text("Отправить") }
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.5)
                Spacer()
            }
            .padding(YMSpace.xl)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Поддержка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена", action: onCancel) }
            }
        }
    }

    private func send() {
        let msg = message.trimmingCharacters(in: .whitespaces)
        guard msg.count >= 5, !sending else { return }
        sending = true; error = nil
        Task {
            do {
                try await API.shared.postVoid("api/v1/support",
                    body: Payload(subject: "Не могу подтвердить смену данных", message: msg))
                await MainActor.run { sending = false; Haptics.success(); onSent() }
            } catch {
                await MainActor.run {
                    sending = false; Haptics.error()
                    self.error = (error as? APIError)?.errorDescription ?? "Не удалось отправить обращение"
                }
            }
        }
    }
}
