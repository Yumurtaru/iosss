//
//  WalletView.swift — «Кошелёк» клиента (баланс, пополнение через ЮKassa, история)
//
//  Контракт (routes/wallet.php), 1:1 с Android (9 Android-client-new · ui/screens/wallet/WalletScreen.kt):
//    • GET  api/v1/wallet              → WalletInfo(balance, enabled, minTopup, maxTopup, transactions)
//    • POST api/v1/wallet/topup        → WalletTopupCreated(topupId, amount, confirmationUrl)
//    • GET  api/v1/wallet/topup/{id}   → WalletTopupStatus(status, amount, balance)
//
//  Важное про деньги: баланс поднимает ТОЛЬКО сервер и только после того, как
//  ЮKassa подтвердила платёж. Экран открывает страницу оплаты в SFSafariViewController
//  и опрашивает статус — сам он ничего не зачисляет.
//
//  Деньги — Decimal через @LenientDecimal и Money.format, никогда не Double.
//  Токены YM.*, light+dark, Dynamic Type. Состояния: скелетон / ошибка + «Повторить» / контент.
//

import SwiftUI

@MainActor
final class WalletViewModel: ObservableObject {
    @Published var info: WalletInfo?
    @Published var loading = true
    @Published var error: String?
    @Published var notice: String?
    @Published var payLink: PayLink?
    /// Ждём подтверждения оплаты по этому пополнению (nil — не ждём).
    @Published var awaitingTopupId: Int?

    /// Опрос статуса. Держит self слабо, поэтому при уходе экрана прекращается сам.
    private var watchTask: Task<Void, Never>?

    var minTopup: Decimal { info?.minTopup ?? 100 }
    var maxTopup: Decimal { info?.maxTopup ?? 300_000 }

    func load() async {
        do {
            info = try await API.shared.get("api/v1/wallet")
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
    }

    func topup(amount: Decimal, method: String) async {
        notice = nil
        do {
            let body = WalletTopupBody(amount: Money.wire(amount), method: method)
            let created: WalletTopupCreated = try await API.shared.post("api/v1/wallet/topup", body: body)
            guard let link = created.confirmationUrl, let url = URL(string: link) else {
                notice = "Сервер не вернул ссылку на оплату. Попробуйте позже."
                return
            }
            payLink = PayLink(url: url)
            if let id = created.topupId, id > 0 {
                awaitingTopupId = id
                notice = "Ожидаем оплату. Баланс обновится сам, как только ЮKassa подтвердит платёж."
                watch(id: id)
            }
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Не удалось создать платёж"
        }
    }

    /// Ждём ответа ЮKassa примерно 5 минут. Обрыв связи отказом не считаем —
    /// запрос просто повторяется, платёж от этого не пропадает.
    private func watch(id: Int) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.awaitingTopupId == id else { return }
                guard let st: WalletTopupStatus = try? await API.shared.get("api/v1/wallet/topup/\(id)") else { continue }
                if Task.isCancelled { return }
                switch st.status {
                case "confirmed":
                    self.awaitingTopupId = nil
                    self.notice = "Кошелёк пополнен на \(Money.format(st.amount ?? 0))"
                    await self.load()
                    return
                case "rejected":
                    self.awaitingTopupId = nil
                    self.notice = "Платёж не прошёл. Деньги не списаны, можно попробовать ещё раз."
                    await self.load()
                    return
                default:
                    continue
                }
            }
            guard let self, self.awaitingTopupId == id else { return }
            self.awaitingTopupId = nil
            self.notice = "Платёж обрабатывается. Баланс обновится сам — деньги не потеряются."
            await self.load()
        }
    }

    /// Человек закрыл страницу оплаты — проверяем статус сразу, не дожидаясь
    /// следующего тика опроса.
    func checkNow() async {
        guard let id = awaitingTopupId else { await load(); return }
        if let st: WalletTopupStatus = try? await API.shared.get("api/v1/wallet/topup/\(id)") {
            if st.status == "confirmed" {
                awaitingTopupId = nil
                notice = "Кошелёк пополнен на \(Money.format(st.amount ?? 0))"
            } else if st.status == "rejected" {
                awaitingTopupId = nil
                notice = "Платёж не прошёл. Деньги не списаны, можно попробовать ещё раз."
            }
        }
        await load()
    }
}

struct WalletView: View {
    @StateObject private var vm = WalletViewModel()
    @State private var showTopup = false

    var body: some View {
        Group {
            if vm.loading {
                skeleton
            } else if let e = vm.error, vm.info == nil {
                ErrorRetryView(message: e) { Task { vm.loading = true; await vm.load() } }
            } else {
                content
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Кошелёк")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .sheet(item: $vm.payLink, onDismiss: { Task { await vm.checkNow() } }) { link in
            SafariSheet(url: link.url)
        }
        .sheet(isPresented: $showTopup) {
            TopupSheet(min: vm.minTopup, max: vm.maxTopup) { amount, method in
                showTopup = false
                Task { await vm.topup(amount: amount, method: method) }
            }
        }
    }

    // MARK: Контент

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                heroCard

                if let n = vm.notice {
                    HStack(spacing: YMSpace.sm) {
                        if vm.awaitingTopupId != nil { ProgressView().scaleEffect(0.8) }
                        Text(n)
                            .font(YMFont.callout)
                            .foregroundStyle(vm.awaitingTopupId != nil ? YMColor.muted : YMColor.text)
                    }
                }

                if vm.info?.enabled == true {
                    Button {
                        showTopup = true
                    } label: {
                        Text("Пополнить")
                            .font(YMFont.headline)
                            .foregroundStyle(YMColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                               startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                            )
                    }
                } else {
                    // enabled=false — онлайн-оплата на площадке не настроена.
                    // Кнопку не показываем: нажатие всё равно вернуло бы 503.
                    Text("Пополнение сейчас недоступно. Баланс можно тратить на заказы.")
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                }

                Text("История операций")
                    .font(YMFont.title3)
                    .foregroundStyle(YMColor.text)
                    .padding(.top, YMSpace.sm)

                let txs = vm.info?.transactions ?? []
                if txs.isEmpty {
                    Text("Операций пока нет")
                        .font(YMFont.body)
                        .foregroundStyle(YMColor.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(txs.enumerated()), id: \.offset) { idx, t in
                            WalletTxRow(tx: t)
                            if idx != txs.count - 1 { Divider().overlay(YMColor.hairline) }
                        }
                    }
                    .padding(.horizontal, YMSpace.md)
                    .padding(.vertical, YMSpace.xs)
                    .ymCard()
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .refreshable { await vm.load() }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text("Баланс кошелька")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.onAccent.opacity(0.9))
            Text(Money.format(vm.info?.balance ?? 0))
                .font(YMFont.largeTitle)
                .foregroundStyle(YMColor.onAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .background(
            LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
        )
    }

    private var skeleton: some View {
        VStack(spacing: YMSpace.md) {
            SkeletonBox(radius: YMRadius.card).frame(height: 110)
            ForEach(0..<4, id: \.self) { _ in SkeletonBox(radius: YMRadius.card).frame(height: 64) }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Строка истории

private struct WalletTxRow: View {
    let tx: WalletTx

    private var amount: Decimal { tx.amount ?? 0 }
    private var positive: Bool { amount >= 0 }
    private var label: String {
        if let l = tx.typeLabel, !l.isEmpty { return l }
        switch tx.type {
        case "topup":        return "Пополнение"
        case "order_pay":    return "Оплата заказа"
        case "order_refund": return "Возврат по заказу"
        case "correction":   return "Корректировка"
        default:
            let v = (tx.type ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? "Операция" : v
        }
    }
    private var subtitle: String {
        var parts: [String] = []
        if let d = tx.description, !d.isEmpty { parts.append(d) }
        let d = DateFmt.short(tx.createdAt)
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 18))
                .foregroundStyle(YMColor.accent)
                .frame(width: 44, height: 44)
                .background(YMColor.accent.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(YMFont.body).foregroundStyle(YMColor.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(positive ? "+" : "−")\(Money.format(positive ? amount : -amount))")
                    .font(YMFont.headline)
                    .foregroundStyle(positive ? YMColor.statusDone : YMColor.text)
                Text("= " + Money.format(tx.balanceAfter ?? 0))
                    .font(YMFont.caption)
                    .foregroundStyle(YMColor.muted)
            }
        }
        .padding(.vertical, YMSpace.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(positive ? "плюс" : "минус") \(Money.format(positive ? amount : -amount))")
    }
}

// MARK: - Пополнение

private struct TopupSheet: View {
    let min: Decimal
    let max: Decimal
    let onSubmit: (Decimal, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = "1000"
    @State private var method = "card"
    @State private var localError: String?

    private let presets: [Decimal] = [500, 1000, 3000, 5000]

    private var parsed: Decimal? {
        let t = amountText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Decimal(string: t)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сумма") {
                    TextField("Сумма, ₽", text: $amountText)
                        .keyboardType(.decimalPad)
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { p in
                            Button(Money.format(p)) { amountText = Money.wire(p) }
                                .font(YMFont.caption)
                                .buttonStyle(.bordered)
                        }
                    }
                    Text("От \(Money.format(min)) до \(Money.format(max)). Оплата откроется на защищённой странице ЮKassa.")
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                }
                Section("Способ") {
                    Picker("Способ", selection: $method) {
                        Text("Картой").tag("card")
                        Text("СБП").tag("sbp")
                    }
                    .pickerStyle(.segmented)
                }
                if let e = localError {
                    Section { Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel) }
                }
                Section {
                    Button {
                        guard let a = parsed, a >= min, a <= max else {
                            localError = "Сумма должна быть от \(Money.format(min)) до \(Money.format(max))"
                            return
                        }
                        onSubmit(a, method)
                    } label: {
                        HStack { Spacer(); Text("Пополнить").bold(); Spacer() }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Пополнение кошелька")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
        }
    }
}
