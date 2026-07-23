//
//  PlusView.swift — Yumurta Plus (подписка клиента), премиум-клиент (iOS, SwiftUI)
//
//  Поток 1:1 со старым клиентом (3 IOS-client · Features/Plus/PlusView.swift) и
//  Android-аналогом (9 Android-client-new · loyalty/PlusScreen.kt):
//    • GET  api/v1/plus            → PlusInfo (active/until/priceMonth/cashbackBonus/benefits)
//    • POST api/v1/plus/subscribe  → PayOnlineResp (confirmationUrl/paymentId) — разовый платёж YooKassa
//    • POST api/v1/plus/activate   ← {payment_id} → PlusActivateResp (active/until)
//
//  Оплата: открываем confirmationUrl во внешнем браузере (openURL). При возврате в
//  приложение (scenePhase → .active) пробуем активировать подписку по payment_id —
//  та же логика, что ON_RESUME на Android.
//
//  Деньги — ТОЛЬКО Money (Decimal). Токены YM.*, light+dark, Dynamic Type, Reduce Motion.
//  Состояния: загрузка (skeleton) / ошибка + «Повторить» / контент.
//

import SwiftUI

// MARK: - Модели (локально: в общих Models.swift отсутствуют)

/// Ответ GET api/v1/plus. Ключи snake_case → camelCase через .convertFromSnakeCase.
/// Деньги — @LenientDecimal (сервер может отдать "199.00" строкой).
struct PlusInfo: Decodable {
    let active: Bool?
    let until: String?
    @LenientDecimal var priceMonth: Decimal?
    @LenientDouble var cashbackBonus: Double?
    let benefits: [String]?
}
/// Ответ POST api/v1/plus/activate.
struct PlusActivateResp: Decodable {
    let active: Bool?
    let until: String?
}
/// Тело активации (camelCase → snake_case: payment_id).
private struct PlusActivateBody: Encodable { let paymentId: String }

struct PlusView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var info: PlusInfo?
    @State private var loading = true
    @State private var error: String?
    @State private var busy = false
    @State private var message: String?
    @State private var pendingPaymentId: String?

    var body: some View {
        Group {
            if loading {
                skeleton
            } else if let e = error {
                ErrorRetryView(message: e) { Task { await load() } }
            } else if let i = info {
                content(i)
            } else {
                ErrorRetryView(message: "Нет данных") { Task { await load() } }
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Yumurta Plus")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // Возврат из браузера оплаты → пробуем активировать подписку.
        .onChange(of: scenePhase) { phase in
            if phase == .active, pendingPaymentId != nil { Task { await tryActivate() } }
        }
    }

    // MARK: Контент

    private func content(_ i: PlusInfo) -> some View {
        ScrollView {
            VStack(spacing: YMSpace.lg) {
                heroCard(i)
                if let benefits = i.benefits, !benefits.isEmpty { benefitsCard(benefits) }
                if let m = message, !m.isEmpty {
                    Text(m)
                        .font(YMFont.subhead)
                        .foregroundStyle(YMColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                subscribeButton(i)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
    }

    /// Hero-карта статуса: золотой градиент.
    private func heroCard(_ i: PlusInfo) -> some View {
        let active = i.active ?? false
        return VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text(active ? "✨ Plus активна" : "✨ Yumurta Plus")
                .font(YMFont.title2)
                .foregroundStyle(YMColor.onAccent)
            Text(active
                 ? "Действует до \(String(i.until?.prefix(10) ?? "—"))"
                 : "Подписка для тех, кто заказывает часто")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.onAccent.opacity(0.85))
            if let cb = i.cashbackBonus, cb > 0 {
                Text("Повышенный кэшбэк +\(formatCashback(cb))%")
                    .font(YMFont.subhead)
                    .foregroundStyle(YMColor.onAccent)
                    .padding(.top, YMSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .background(
            LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
        )
    }

    /// Список бенефитов.
    private func benefitsCard(_ benefits: [String]) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            Text("Что даёт Plus")
                .font(YMFont.headline)
                .foregroundStyle(YMColor.text)
            ForEach(Array(benefits.enumerated()), id: \.offset) { _, b in
                HStack(spacing: YMSpace.sm) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(YMColor.accent)
                        .frame(width: 22, height: 22)
                        .background(YMColor.accent.opacity(0.16), in: Circle())
                    Text(b)
                        .font(YMFont.body)
                        .foregroundStyle(YMColor.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard()
    }

    private func subscribeButton(_ i: PlusInfo) -> some View {
        let active = i.active ?? false
        let price = Money.format(i.priceMonth ?? 0)
        return Button(action: subscribe) {
            HStack {
                if busy { ProgressView().tint(YMColor.onAccent) }
                else { Text((active ? "Продлить за " : "Оформить за ") + price + "/мес") }
            }
        }
        .buttonStyle(YMPrimaryButtonStyle())
        .disabled(busy)
    }

    // MARK: Скелетон

    private var skeleton: some View {
        VStack(spacing: YMSpace.lg) {
            SkeletonBox(radius: YMRadius.card).frame(height: 120)
            SkeletonBox(radius: YMRadius.card).frame(height: 200)
            SkeletonBox().frame(height: 54)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Данные

    private func load() async {
        loading = true; error = nil
        do {
            info = try await API.shared.get("api/v1/plus")
        } catch is CancellationError {
            // отмена задачи — не показываем ошибку
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
    }

    private func subscribe() {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                let r: PayOnlineResp = try await API.shared.post("api/v1/plus/subscribe")
                pendingPaymentId = r.paymentId
                if let link = r.confirmationUrl, let url = URL(string: link) {
                    Haptics.light()
                    openURL(url)
                } else {
                    message = "Не удалось создать платёж — попробуйте позже"
                }
            } catch {
                message = (error as? APIError)?.errorDescription ?? "Ошибка оплаты"
            }
        }
    }

    private func tryActivate() async {
        guard let pid = pendingPaymentId else { return }
        do {
            let r: PlusActivateResp = try await API.shared.post("api/v1/plus/activate",
                                                                body: PlusActivateBody(paymentId: pid))
            if r.active == true {
                pendingPaymentId = nil
                message = "Yumurta Plus активна ✨"
                Haptics.success()
                await load()
            } else {
                message = "Оплата ещё не подтверждена — проверим при следующем открытии"
            }
        } catch {
            // оплата ещё не прошла — оставляем pendingPaymentId, проверим при следующем возврате
        }
    }

    private func formatCashback(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - Общий блок ошибки + «Повторить»

/// Единый экран ошибки для премиум-детальных экранов лояльности.
struct ErrorRetryView: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: YMSpace.md) {
            Text("😕").font(.system(size: 44))
            Text(message)
                .font(YMFont.body)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Text("Повторить")
                    .font(YMFont.headline)
                    .foregroundStyle(YMColor.accent)
                    .padding(.horizontal, YMSpace.xl)
                    .frame(height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .strokeBorder(YMColor.accent.opacity(0.55), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(YMSpace.xl)
    }
}
