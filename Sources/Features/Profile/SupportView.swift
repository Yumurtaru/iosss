//
//  SupportView.swift — Поддержка + форма жалобы (premium-клиент)
//
//  Быстрые контакты (mailto/tel через openURL), FAQ (раскрывающиеся строки),
//  форма жалобы (тема + описание). Токены YM, light+dark, Dynamic Type.
//
//  ТОЧКА ВХОДА (для навигации из ProfileView):
//    SupportView()   — самодостаточный экран (внутренний ScrollView),
//                      навешивается через .navigationDestination.
//
//  ПРИВЯЗКА К API (как в старом клиенте и Android SupportScreen):
//    • POST api/v1/complaints  ← {target_type, target_id, reason, text}
//        target_type="platform", target_id=0 — общая жалоба в поддержку маркетплейса.
//        reason = выбранная тема, text = описание (опционально на сервере).
//

import SwiftUI

/// Тело жалобы (POST api/v1/complaints). camelCase → snake_case автоматически.
/// Совпадает 1:1 со старым iOS `ComplaintFullBody` и Android `ComplaintReq`.
private struct SupportComplaintBody: Encodable {
    let targetType: String
    let targetId: Int
    let reason: String
    let text: String?
}

/// Темы жалобы = reason. Пара (значение для API, подпись в UI). 1:1 с Android COMPLAINT_REASONS.
private struct SupportReason: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

private let supportReasons: [SupportReason] = [
    .init(value: "order",    label: "Проблема с заказом"),
    .init(value: "payment",  label: "Оплата и возврат"),
    .init(value: "shop",     label: "Магазин или продавец"),
    .init(value: "product",  label: "Товар или услуга"),
    .init(value: "delivery", label: "Доставка"),
    .init(value: "app",      label: "Работа приложения"),
    .init(value: "other",    label: "Другое"),
]

private struct SupportFaqItem: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

private let supportFaq: [SupportFaqItem] = [
    .init(question: "Как отследить заказ?",
          answer: "Откройте «Профиль → Мои заказы», выберите нужный заказ — там доступен статус и трекинг доставки в реальном времени."),
    .init(question: "Как вернуть товар?",
          answer: "В карточке заказа нажмите «Оформить возврат», укажите причину и дождитесь подтверждения от магазина. Деньги вернутся тем же способом оплаты."),
    .init(question: "Почему в корзине только один магазин?",
          answer: "Одна корзина рассчитана на один магазин — так доставка и оплата собираются корректно. Чтобы заказать из другого магазина, оформите текущую корзину или очистите её."),
    .init(question: "Как изменить город?",
          answer: "Город меняется на главном экране в шапке. От него зависят доступные магазины и условия доставки."),
]

private let supportEmail = "support@yumurta.ru"
private let supportPhone = "+7 800 000 00 00"

struct SupportView: View {
    @Environment(\.openURL) private var openURL

    @State private var reason: SupportReason = supportReasons.first!
    @State private var reasonMenuOpen = false
    @State private var text = ""
    @State private var sending = false
    /// Сообщение под кнопкой: nil — нет; иначе (текст, успех?).
    @State private var status: (message: String, ok: Bool)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.xl) {
                contactsSection
                faqSection
                complaintSection
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.lg)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Поддержка")
        .navigationBarTitleDisplayMode(.inline)
    }

    // ── Контакты ──
    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Связаться с нами")
            HStack(spacing: YMSpace.md) {
                contactCard(icon: "envelope.fill", title: "Написать", subtitle: supportEmail) {
                    if let url = URL(string: "mailto:\(supportEmail)?subject=Обращение%20в%20поддержку%20Yumurta") {
                        openURL(url)
                    }
                }
                contactCard(icon: "phone.fill", title: "Позвонить", subtitle: supportPhone) {
                    let digits = supportPhone.filter { $0.isNumber || $0 == "+" }
                    if let url = URL(string: "tel:\(digits)") { openURL(url) }
                }
            }
        }
    }

    private func contactCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.light(); action() }) {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                Image(systemName: icon)
                    .font(.system(size: 18)).foregroundStyle(YMColor.accent)
                    .frame(width: 40, height: 40)
                    .background(YMColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                Text(title).font(.system(size: 15, weight: .heavy)).foregroundStyle(YMColor.text)
                Text(subtitle).font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(1)
            }
            .padding(YMSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ── FAQ ──
    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Частые вопросы")
            VStack(spacing: 0) {
                ForEach(Array(supportFaq.enumerated()), id: \.element.id) { idx, item in
                    SupportFaqRow(item: item)
                    if idx < supportFaq.count - 1 {
                        Rectangle().fill(YMColor.hairline).frame(height: 1).padding(.leading, 16)
                    }
                }
            }
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        }
    }

    // ── Жалоба ──
    private var complaintSection: some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            sectionTitle("Пожаловаться")
            Text("Опишите проблему — мы разберёмся и вернёмся с решением.")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)

            // Тема (reason)
            VStack(alignment: .leading, spacing: 8) {
                Text("Тема").font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.muted)
                Menu {
                    ForEach(supportReasons) { r in
                        Button {
                            reason = r
                            if status?.ok == false { status = nil }
                        } label: {
                            if r == reason { Label(r.label, systemImage: "checkmark") }
                            else { Text(r.label) }
                        }
                    }
                } label: {
                    HStack {
                        Text(reason.label).font(.system(size: 15)).foregroundStyle(YMColor.text)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(YMColor.muted)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 14)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                }
            }

            // Описание (text)
            VStack(alignment: .leading, spacing: 8) {
                Text("Описание").font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.muted)
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .foregroundStyle(YMColor.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Опишите проблему подробно…")
                                .font(.system(size: 15)).foregroundStyle(YMColor.muted)
                                .padding(.horizontal, 15).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: text) { _ in if status?.ok == false { status = nil } }
            }

            Button(action: submit) {
                if sending { ProgressView().tint(YMColor.onAccent) }
                else { Text("Отправить") }
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(sending)
            .opacity(sending ? 0.6 : 1)

            if let status {
                Text(status.message)
                    .font(YMFont.callout)
                    .foregroundStyle(status.ok ? YMColor.accent : YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.muted)
    }

    // ── Отправка жалобы ──
    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            status = ("Опишите проблему — поле пустое", false); Haptics.warning(); return
        }
        guard !sending else { return }
        sending = true; status = nil
        Task {
            do {
                try await API.shared.postVoid("api/v1/complaints",
                    body: SupportComplaintBody(targetType: "platform", targetId: 0, reason: reason.value, text: t))
                await MainActor.run {
                    Haptics.success()
                    status = ("Жалоба отправлена. Мы свяжемся с вами.", true)
                    text = ""
                    sending = false
                }
            } catch {
                await MainActor.run {
                    Haptics.error()
                    let msg = (error as? APIError)?.errorDescription ?? "Не удалось отправить жалобу"
                    status = (msg, false)
                    sending = false
                }
            }
        }
    }
}

/// Раскрывающаяся строка FAQ: вопрос + шеврон → ответ.
private struct SupportFaqRow: View {
    let item: SupportFaqItem
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(item.question)
                        .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(YMColor.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(expanded ? YMColor.accent : YMColor.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(item.answer)
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}
