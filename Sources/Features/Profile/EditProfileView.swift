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
/// email опционален: пустая строка не отправляется (nil), совпадает со старым клиентом.
private struct EditProfileBody: Encodable {
    let name: String
    let email: String?
}

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var loading = true
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return true }  // email опционален
        return e.contains("@") && e.contains(".") && !e.hasSuffix("@")
    }
    private var canSave: Bool { !trimmedName.isEmpty && emailValid && !saving }

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

                    phoneField

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

    // ── Телефон (только чтение) ──
    private var phoneField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Телефон")
                .font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.muted)
            HStack {
                Text(phone.isEmpty ? "—" : phone)
                    .font(.system(size: 15)).foregroundStyle(YMColor.muted)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 12)).foregroundStyle(YMColor.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            Text("Телефон — это логин, изменить его здесь нельзя.")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
    }

    // ── Data ──
    private func load() async {
        loading = true
        loadError = nil
        do {
            let p: Profile = try await API.shared.get("api/v1/profile")
            await MainActor.run {
                name = p.name ?? ""; email = p.email ?? ""; phone = p.phone ?? ""
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

    private func save() {
        guard canSave else { return }
        saving = true; saveError = nil
        let e = email.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await API.shared.putVoid("api/v1/profile",
                    body: EditProfileBody(name: trimmedName, email: e.isEmpty ? nil : e))
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
