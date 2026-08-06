//
//  BecomeSellerView.swift — регистрация своей организации ПРЯМО В ПРИЛОЖЕНИИ (без сайта).
//
//  Flow:
//    Промо-карточка в списках заведений (после каждых 3-х) → BecomeSellerView (описание)
//    → кнопка «Подать заявку» → .sheet с формой (название, ФИО, телефон, тип) → «ждите модерацию».
//
//  API: POST api/v1/organizations/apply  body {org_name, full_name, phone, type, city_id}
//       → OrgApplyResult {registration_id, status:"pending"}. Заявка падает в shop_registrations
//       (pending) → модерация в админке. Тип — канон API: store | restaurant | service.
//
//  Токены — только YM. Light + dark. Русские литералы.
//

import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Промо-карточка (вставляется в списки заведений после каждых 3-х)
// ─────────────────────────────────────────────────────────────────────────────

struct BecomeSellerPromoCard: View {
    var onTap: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                Text("YUMURTA ДЛЯ БИЗНЕСА")
                    .font(YMFont.caption2).fontWeight(.semibold)
                    .foregroundStyle(YMColor.accent)
                Text("Добавьте свою организацию")
                    .font(YMFont.title3).foregroundStyle(YMColor.text)
                Text("Продавайте товары, блюда и услуги на Yumurta. Заявка — прямо в приложении.")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("Подать заявку").font(YMFont.headline).foregroundStyle(YMColor.accent)
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.lg)
            .background(YMColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .strokeBorder(YMColor.accent.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Экран описания «Стать продавцом»
// ─────────────────────────────────────────────────────────────────────────────

struct BecomeSellerView: View {
    @State private var showForm = false
    @State private var submitted = false

    private let benefits: [(String, String)] = [
        ("Витрина в приложении", "Ваши товары и услуги видят клиенты вашего города."),
        ("Заказы и оплата", "Приём заказов, онлайн-оплата и доставка — всё внутри Yumurta."),
        ("Без вложений на старте", "Подключение бесплатно. Оставьте заявку — мы поможем настроить."),
    ]

    var body: some View {
        ScrollView {
            if submitted {
                doneContent
            } else {
                introContent
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Стать продавцом")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showForm) {
            ApplyOrgFormView { ok in
                if ok { withAnimation { submitted = true } }
            }
        }
    }

    private var introContent: some View {
        VStack(alignment: .leading, spacing: YMSpace.lg) {
            Text("Продавайте на Yumurta")
                .font(YMFont.title).foregroundStyle(YMColor.text)
            Text("Магазин, ресторан или услуги — разместите свою организацию в приложении и получайте заказы от клиентов вашего города.")
                .font(YMFont.body).foregroundStyle(YMColor.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: YMSpace.md) {
                ForEach(benefits, id: \.0) { title, sub in
                    HStack(alignment: .top, spacing: YMSpace.md) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(YMColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(YMFont.headline).foregroundStyle(YMColor.text)
                            Text(sub).font(YMFont.callout).foregroundStyle(YMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, YMSpace.xs)

            Button {
                Haptics.light()
                showForm = true
            } label: { Text("Подать заявку") }
                .buttonStyle(YMPrimaryButtonStyle())
                .padding(.top, YMSpace.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.md)
        .padding(.bottom, YMSpace.xxxl)
    }

    private var doneContent: some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64)).foregroundStyle(YMColor.accent)
                .padding(.top, YMSpace.xxxl)
            Text("Заявка отправлена!").font(YMFont.title2).foregroundStyle(YMColor.text)
            Text("Мы проверим данные и свяжемся с вами по указанному телефону. Обычно это занимает до 24 часов.")
                .font(YMFont.body).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Форма заявки (sheet): название, ФИО, телефон, тип
// ─────────────────────────────────────────────────────────────────────────────

private struct ApplyOrgFormView: View {
    /// success — родитель показывает экран «ждите модерацию».
    let onResult: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var orgName = ""
    @State private var fullName = ""
    @State private var phone = ""
    @State private var type = "store"          // store | restaurant | service
    @State private var sending = false
    @State private var error: String?

    private var valid: Bool {
        orgName.trimmingCharacters(in: .whitespaces).count >= 2
            && fullName.trimmingCharacters(in: .whitespaces).count >= 2
            && phone.filter({ $0.isNumber }).count >= 10
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Организация") {
                    TextField("Название организации", text: $orgName)
                        .textInputAutocapitalization(.words)
                    Picker("Тип", selection: $type) {
                        Text("Магазин").tag("store")
                        Text("Ресторан").tag("restaurant")
                        Text("Услуги").tag("service")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Контакты") {
                    TextField("Ваше ФИО", text: $fullName)
                        .textContentType(.name)
                    TextField("Телефон", text: $phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                }
                if let error {
                    Text(error).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if sending { ProgressView() } else { Text("Отправить заявку").fontWeight(.bold) }
                            Spacer()
                        }
                    }
                    .disabled(!valid || sending)
                } footer: {
                    Text("Заявка уйдёт на модерацию. После одобрения мы свяжемся с вами по телефону.")
                }
            }
            .navigationTitle("Заявка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .task { await prefill() }
        }
        .tint(YMColor.accent)
    }

    /// Автоподстановка ФИО/телефона из профиля (если вошёл) — клиент правит.
    private func prefill() async {
        guard Session.shared.isLoggedIn else { return }
        if let p: Profile = try? await API.shared.get("api/v1/profile") {
            await MainActor.run {
                if fullName.isEmpty, let n = p.name, !n.isEmpty { fullName = n }
                if phone.isEmpty, let ph = p.phone, !ph.isEmpty { phone = ph }
            }
        }
    }

    private func submit() {
        error = nil
        sending = true
        let body = OrgApplyBody(
            orgName: orgName.trimmingCharacters(in: .whitespaces),
            fullName: fullName.trimmingCharacters(in: .whitespaces),
            phone: phone.trimmingCharacters(in: .whitespaces),
            type: type,
            cityId: Session.shared.cityId
        )
        Task {
            do {
                let _: OrgApplyResult = try await API.shared.post("api/v1/organizations/apply", body: body)
                await MainActor.run {
                    Haptics.success()
                    sending = false
                    onResult(true)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    sending = false
                    self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить заявку"
                }
            }
        }
    }
}
