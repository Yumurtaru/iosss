//
//  GiftCardView.swift — Подарочная карта (premium-клиент)
//
//  Экран «Подарочная карта»: ввод кода + «Проверить и активировать», показ баланса, статуса и срока.
//  Токены YM.*, light+dark, Dynamic Type, Reduce Motion. Состояния: idle / загрузка / результат / ошибка+Повторить.
//
//  ПРИВЯЗКА К API (как в старом GiftCardView + Android-аналог):
//    • GET api/v1/gift-cards/{code} → GiftCard { code, balance, status, expiresAt }
//
//  ДЕНЬГИ: GiftCard.balance форматируем ТОЛЬКО через Money.format(Decimal). Никогда не Double напрямую.
//  Пушится в NavigationStack профиля → системная кнопка «Назад» (как AddressesView/BookingsView).
//

import SwiftUI

struct GiftCardView: View {
    @State private var code = ""
    @State private var card: GiftCard?
    @State private var loading = false
    @State private var error: String?

    private var canCheck: Bool {
        code.trimmingCharacters(in: .whitespaces).count >= 4 && !loading
    }

    var body: some View {
        ScrollView {
            VStack(spacing: YMSpace.lg) {
                heroCard
                inputSection

                if loading {
                    loadingBlock
                } else if let c = card {
                    balanceCard(c)
                } else if let e = error {
                    errorBlock(e)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Подарочная карта")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero (золотой градиент)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Image(systemName: "giftcard.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(YMColor.onAccent)
            Text("Подарочная карта")
                .font(YMFont.title3).foregroundStyle(YMColor.onAccent)
            Text("Введите код с карты, чтобы проверить баланс и активировать её.")
                .font(YMFont.callout).foregroundStyle(YMColor.onAccent.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xxl)
        .background(
            LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
        )
    }

    // MARK: - Ввод кода

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Код карты").font(YMFont.title3).foregroundStyle(YMColor.text)
            TextField("Например, GIFT-XXXX-XXXX", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(YMFont.body)
                .foregroundStyle(YMColor.text)
                .padding(.horizontal, YMSpace.md)
                .frame(height: 54)
                .background(YMColor.surface2,
                            in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .onChange(of: code) { _ in error = nil; card = nil }

            Button { Haptics.light(); check() } label: {
                Group {
                    if loading {
                        ProgressView().tint(YMColor.onAccent)
                    } else {
                        Text("Проверить и активировать").font(YMFont.headline)
                    }
                }
                .foregroundStyle(canCheck ? YMColor.onAccent : YMColor.muted)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background {
                    if canCheck {
                        LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                       startPoint: .leading, endPoint: .trailing)
                            .clipShape(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .fill(YMColor.surface2)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!canCheck)
        }
    }

    // MARK: - Загрузка

    private var loadingBlock: some View {
        ProgressView().tint(YMColor.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, YMSpace.xxl)
    }

    // MARK: - Результат: баланс

    private func balanceCard(_ c: GiftCard) -> some View {
        let active = isActive(c.status)
        return VStack(alignment: .leading, spacing: YMSpace.md) {
            HStack(spacing: YMSpace.sm) {
                Text("✅").font(.system(size: 20))
                Text("Карта найдена").font(YMFont.headline).foregroundStyle(YMColor.text)
            }
            VStack(alignment: .leading, spacing: YMSpace.xs) {
                Text("Баланс").font(YMFont.caption).foregroundStyle(YMColor.muted)
                Text(Money.format(Money.dec(c.balance)))
                    .font(YMFont.largeTitle).foregroundStyle(YMColor.accent)
            }
            infoRow("Статус", statusLabel(c.status), valueColor: active ? YMColor.statusDone : YMColor.muted)
            if let e = c.expiresAt, !e.isEmpty {
                infoRow("Действует до", DateFmt.short(e))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.accent.opacity(0.4), lineWidth: 1)
        )
    }

    private func infoRow(_ label: String, _ value: String, valueColor: Color = YMColor.text) -> some View {
        HStack {
            Text(label).font(YMFont.callout).foregroundStyle(YMColor.muted)
            Spacer()
            Text(value).font(YMFont.subhead).foregroundStyle(valueColor)
        }
    }

    // MARK: - Ошибка + Повторить

    private func errorBlock(_ message: String) -> some View {
        VStack(spacing: YMSpace.md) {
            Text("😔").font(.system(size: 34))
            Text(message).font(YMFont.body).foregroundStyle(YMColor.text).multilineTextAlignment(.center)
            Button { Haptics.light(); check() } label: {
                Text("Повторить").font(YMFont.headline).foregroundStyle(YMColor.accent)
                    .padding(.horizontal, YMSpace.xl).padding(.vertical, YMSpace.sm)
                    .overlay(
                        RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .strokeBorder(YMColor.accent.opacity(0.55), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canCheck)
        }
        .frame(maxWidth: .infinity)
        .padding(YMSpace.xl)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.statusCancel.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Данные

    private func check() {
        let input = code.trimmingCharacters(in: .whitespaces)
        guard input.count >= 4, !loading else { return }
        loading = true; error = nil; card = nil
        Task {
            do {
                let path = "api/v1/gift-cards/\(input.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? input)"
                let c: GiftCard = try await API.shared.get(path)
                Haptics.success()
                card = c
            } catch {
                Haptics.error()
                self.error = (error as? APIError)?.errorDescription ?? "Сертификат не найден"
            }
            loading = false
        }
    }

    // MARK: - Хелперы статуса

    private func isActive(_ status: String?) -> Bool {
        guard let s = status?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return true }
        return ["active", "активна", "активный", "valid", "ok"].contains(s)
    }

    private func statusLabel(_ raw: String?) -> String {
        guard let r = raw?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return "Активна" }
        switch r.lowercased() {
        case "active", "активна", "активный", "valid", "ok": return "Активна"
        case "used", "spent", "использована":                return "Использована"
        case "expired", "истекла":                           return "Истёк срок"
        case "blocked", "disabled", "заблокирована":         return "Заблокирована"
        default:                                             return r
        }
    }
}
