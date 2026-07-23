//
//  NotificationsView.swift — Уведомления (premium-клиент)
//
//  Список уведомлений с непрочитанной точкой (золото), иконкой по типу,
//  заголовком/текстом и датой. При открытии непрочитанные помечаются
//  прочитанными на сервере. Токены YM, light+dark, Dynamic Type, Reduce Motion.
//
//  ТОЧКА ВХОДА (для навигации из ProfileView):
//    NotificationsView()   — самодостаточный экран (внутренний ScrollView),
//                            навешивается через .navigationDestination.
//
//  ПРИВЯЗКА К API (как в старом NotificationsView):
//    • GET  api/v1/notifications        → [AppNotification] (поле is_read → .read)
//    • POST api/v1/notifications/read   ← NotifReadBody(ids:[Int])  (пометить прочитанными)
//

import SwiftUI

struct NotificationsView: View {
    @State private var items: [AppNotification] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                if loading {
                    ForEach(0..<5, id: \.self) { _ in SkeletonBox(radius: 18).frame(height: 74) }
                } else if let error {
                    NotifErrorState(message: error) { Task { await load() } }
                } else if items.isEmpty {
                    NotifEmptyState()
                } else {
                    ForEach(items) { n in NotifRow(item: n) }
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Уведомления")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let list: [AppNotification] = try await API.shared.list("api/v1/notifications")
            await MainActor.run { items = list; loading = false }
            // Отметить непрочитанные прочитанными (тихо, ошибки не показываем).
            let unread = list.filter { !$0.read }.map { $0.id }
            if !unread.isEmpty {
                try? await API.shared.postVoid("api/v1/notifications/read", body: NotifReadBody(ids: unread))
            }
        } catch is CancellationError {
            // экран закрыли во время загрузки — игнор
        } catch {
            await MainActor.run {
                self.error = (error as? APIError)?.errorDescription ?? "Не удалось загрузить уведомления"
                loading = false
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Строка уведомления
// ─────────────────────────────────────────────────────────────────────────────

private struct NotifRow: View {
    let item: AppNotification

    /// Эмодзи-иконка по типу уведомления (аддитивно; неизвестный тип → 🔔).
    private var icon: String {
        switch (item.type ?? "").lowercased() {
        case let t where t.contains("order"):    return "🧾"
        case let t where t.contains("delivery"): return "🚚"
        case let t where t.contains("promo"), let t where t.contains("discount"): return "🎁"
        case let t where t.contains("bonus"), let t where t.contains("point"):    return "💎"
        case let t where t.contains("chat"), let t where t.contains("message"):   return "💬"
        default: return "🔔"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(icon)
                .font(.system(size: 17))
                .frame(width: 40, height: 40)
                .background(item.read ? YMColor.surface2 : YMColor.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.title ?? "Уведомление")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !item.read {
                        Circle().fill(YMColor.accent).frame(width: 8, height: 8).padding(.top, 5)
                    }
                }
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(DateFmt.short(item.createdAt))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 1)
            }
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(item.read ? YMColor.hairline : YMColor.accent.opacity(0.35),
                              lineWidth: item.read ? 1 : 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.read ? "" : "Новое, ")\(item.title ?? "Уведомление"). \(item.body ?? "")")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Пусто / ошибка (локальные, уникальные имена)
// ─────────────────────────────────────────────────────────────────────────────

private struct NotifEmptyState: View {
    var body: some View {
        VStack(spacing: YMSpace.sm) {
            Text("🔔").font(.system(size: 44))
            Text("Уведомлений пока нет")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Здесь появятся статусы заказов, акции и важные события.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 60)
    }
}

private struct NotifErrorState: View {
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
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 60)
    }
}
