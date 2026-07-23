import SwiftUI

//
//  CartView.swift — экран корзины (screen: cart). Дизайн 1:1 с CheckoutPhone.dc.html.
//
//  ПУБЛИЧНАЯ INIT-СИГНАТУРА (для централизованной навигации):
//    CartView(onCheckout: () -> Void, onClose: () -> Void)
//      onCheckout — «Перейти к оформлению» (родитель пушит CheckoutView).
//      onClose    — «‹ Корзина» назад / «На главную» из пусто-состояния.
//
//  Данные — из Core/Cart.shared (single-store: одна корзина = один магазин).
//  Деньги — только Decimal через Money.format(Money.parse(...)). Токены — YM*.
//
//  API: экран заказ не создаёт (это делает CheckoutView) — читает Cart.shared.
//  Плашка «Комментарий к заказу…» здесь — дизайнерская подсказка (по макету):
//  фактический ввод комментария выполняется на экране оформления (CheckoutView),
//  т.к. Core/Cart не хранит поле comment (инвариант single-store, без правок ядра).
//

struct CartView: View {
    @ObservedObject private var cart = Cart.shared
    var onCheckout: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()
            if cart.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Header «‹ Корзина»

    private var header: some View {
        HStack(spacing: YMSpace.md) {
            Button(action: { Haptics.light(); onClose() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text("Корзина")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)
            Spacer()
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.xs)
        .padding(.bottom, YMSpace.md)
    }

    // MARK: - Filled content

    private var content: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    storeBanner
                        .padding(.bottom, YMSpace.lg)

                    SectionKicker("Ваш заказ")
                        .padding(.bottom, YMSpace.md)

                    VStack(spacing: YMSpace.md) {
                        ForEach(cart.lines) { line in
                            CartRow(line: line)
                        }
                    }

                    commentHint
                        .padding(.top, YMSpace.lg)

                    totalsCard
                        .padding(.top, YMSpace.lg)

                    Color.clear.frame(height: YMSpace.lg)
                }
                .padding(.horizontal, YMSpace.xl)
            }
            bottomCTA
        }
    }

    // Баннер магазина: лого (или монограмма) + название из Cart.shopName.
    private var storeBanner: some View {
        HStack(spacing: YMSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(YMColor.surface2)
                Text(monogram)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(YMColor.accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(cart.shopName ?? "Магазин")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(YMColor.text)
                Text("В корзине \(cart.count) \(itemsWord(cart.count))")
                    .font(YMFont.caption)
                    .foregroundStyle(YMColor.muted)
            }
            Spacer()
            Button(action: { Haptics.light(); onClose() }) {
                Text("Меню")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(YMColor.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var monogram: String {
        let s = (cart.shopName ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "•" : String(s.prefix(1)).uppercased()
    }

    // Плашка-подсказка «Комментарий к заказу…» (dashed) — 1:1 с макетом.
    private var commentHint: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 15))
                .foregroundStyle(YMColor.muted)
            Text("Комментарий к заказу…")
                .font(.system(size: 13.5))
                .foregroundStyle(YMColor.muted)
            Spacer()
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(YMColor.hairline)
        )
    }

    // Блок итогов (на корзине — Товары + Доставка «рассчитается при оформлении»).
    private var totalsCard: some View {
        VStack(spacing: 9) {
            totalRow("Товары (\(cart.count))", Money.format(Money.parse(cart.total)), bold: true)
            totalRow("Доставка", "рассчитается при оформлении")
        }
        .padding(YMSpace.lg)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private func totalRow(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
            Spacer()
            Text(value)
                .font(.system(size: 13.5, weight: bold ? .heavy : .semibold))
                .foregroundStyle(bold ? YMColor.text : YMColor.muted)
        }
    }

    // Нижний CTA: «Перейти к оформлению» + сумма.
    private var bottomCTA: some View {
        VStack(spacing: YMSpace.md) {
            HStack {
                Text("Итого")
                    .font(.system(size: 13.5))
                    .foregroundStyle(YMColor.muted)
                Spacer()
                Text(Money.format(Money.parse(cart.total)))
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(YMColor.text)
            }
            Button(action: { Haptics.medium(); onCheckout() }) {
                Text("Перейти к оформлению")
            }
            .buttonStyle(YMPrimaryButtonStyle())
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.top, YMSpace.lg)
        .padding(.bottom, YMSpace.xxl)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) { YMColor.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Empty state (дизайнерское)

    private var emptyState: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            VStack(spacing: YMSpace.lg) {
                ZStack {
                    Circle()
                        .fill(YMColor.accent.opacity(0.12))
                        .frame(width: 120, height: 120)
                    Image(systemName: "bag")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(YMColor.accent)
                }
                VStack(spacing: YMSpace.sm) {
                    Text("Корзина пуста")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    Text("Загляните в каталог — выберите\nблюда любимого заведения")
                        .font(YMFont.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: { Haptics.light(); onClose() }) {
                    Text("На главную")
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .frame(maxWidth: 240)
                .padding(.top, YMSpace.sm)
            }
            .padding(.horizontal, YMSpace.xxxl)
            Spacer()
            Spacer()
        }
    }

    // Склонение «блюдо / блюда / блюд».
    private func itemsWord(_ count: Int) -> String {
        let n = abs(count) % 100, n1 = n % 10
        if n > 10 && n < 20 { return "блюд" }
        if n1 > 1 && n1 < 5 { return "блюда" }
        if n1 == 1 { return "блюдо" }
        return "блюд"
    }
}

// MARK: - Строка товара со степпером −/N/+

private struct CartRow: View {
    let line: CartLine
    @ObservedObject private var cart = Cart.shared

    private var lineTotal: Decimal {
        Money.parse(line.unitPrice) * Decimal(line.qty)
    }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            PhotoPlaceholder(url: API.imageURL(line.photo), label: "ФОТО", radius: 14, tone: line.productId)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(YMColor.text)
                    .lineLimit(1)
                if !line.modsLabel.isEmpty {
                    Text(line.modsLabel)
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                        .lineLimit(1)
                } else if let u = line.unit, !u.isEmpty {
                    Text(fmtQty(line.qty, u))
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                }
            }

            Spacer(minLength: YMSpace.sm)

            stepper

            Text(Money.format(lineTotal))
                .font(.system(size: 14.5, weight: .heavy))
                .foregroundStyle(YMColor.text)
                .fixedSize()
        }
    }

    // −/N/+ степпер: N — количество (дробное для весовых), минус удаляет при 0.
    private var stepper: some View {
        HStack(spacing: 8) {
            Button(action: { Haptics.light(); cart.dec(line.key) }) {
                Image(systemName: "minus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(line.isFractional ? fmtQty(line.qty) : "\(Int(line.qty.rounded()))")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(YMColor.text)
                .frame(minWidth: 20)

            Button(action: { Haptics.light(); cart.inc(line.key) }) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YMColor.onAccent)
                    .frame(width: 26, height: 26)
                    .background(YMColor.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - Секционный кикер (UPPERCASE подпись раздела)

struct SectionKicker: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(YMColor.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
