import SwiftUI

//
//  SuccessView.swift — экран успеха (screen: success). Дизайн 1:1 с CheckoutPhone.dc.html.
//
//  ПУБЛИЧНАЯ INIT-СИГНАТУРА (для централизованной навигации):
//    SuccessView(order: OrderCreateResult, onTrack: () -> Void, onHome: () -> Void)
//      order   — результат создания заказа (номер для показа).
//      onTrack — «Следить за заказом» (родитель открывает трекинг).
//      onHome  — «На главную».
//
//  Конфетти — падающие частицы (золото/зелёный/белый) через TimelineView + Canvas,
//  с учётом Reduce Motion (при включённом — статичный экран без анимации).
//  Золотой круг 110×110 с ✓ и pop-анимацией. Токены — YM*.
//
//  API: экран ничего не запрашивает — принимает готовый OrderCreateResult.
//  ETA берётся из TODO(API): в OrderCreateResult нет поля eta — показываем
//  типовой диапазон-плейсхолдер (реальный ETA приходит на экране трекинга).
//

struct SuccessView: View {
    let order: OrderCreateResult
    var onTrack: () -> Void = {}
    var onHome: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkPopped = false

    // Номер заказа: dailyNumber (виден клиенту) → id → 0.
    private var orderNumber: Int { order.dailyNumber ?? order.id ?? 0 }

    // TODO(API): OrderCreateResult не содержит ETA. Показываем типовой диапазон;
    // точное время доставки приходит на экране трекинга (TrackData.etaMinutes).
    private let etaText = "25–35 мин"

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()

            if !reduceMotion {
                ConfettiView().ignoresSafeArea().allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                Spacer()

                // Золотой круг 110×110 с pop-анимацией.
                ZStack {
                    Circle()
                        .fill(YMColor.accent)
                        .frame(width: 110, height: 110)
                        .shadow(color: YMPalette.gold.opacity(0.6), radius: 50, y: 20)
                    Image(systemName: "checkmark")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(YMColor.onAccent)
                }
                .scaleEffect(checkPopped ? 1 : (reduceMotion ? 1 : 0.4))
                .opacity(checkPopped || reduceMotion ? 1 : 0)

                Text("Заказ оформлен!")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(YMColor.text)
                    .padding(.top, YMSpace.xxl)

                Text("Заведение уже приняло заказ №\(orderNumber).\nМы уведомим, когда курьер будет в пути.")
                    .font(YMFont.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(YMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, YMSpace.sm)
                    .padding(.horizontal, YMSpace.xxl)

                // ETA-плашка.
                HStack(spacing: YMSpace.xs) {
                    Text("Ожидаемая доставка ·")
                        .font(.system(size: 14))
                        .foregroundStyle(YMColor.text)
                    Text(etaText)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(YMColor.text)
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
                .padding(.top, YMSpace.xl)

                Spacer()

                VStack(spacing: YMSpace.md) {
                    Button(action: { Haptics.light(); onTrack() }) {
                        Text("Следить за заказом")
                    }
                    .buttonStyle(YMPrimaryButtonStyle())

                    Button(action: { Haptics.light(); onHome() }) {
                        Text("На главную")
                    }
                    .buttonStyle(YMGhostButtonStyle())
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.bottom, YMSpace.xxl)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            Haptics.success()
            if reduceMotion {
                checkPopped = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { checkPopped = true }
            }
        }
    }
}

// MARK: - Конфетти (падающие частицы, TimelineView + Canvas)

/// Частицы золото/зелёный/белый падают сверху с вращением. Рендер — Canvas в
/// TimelineView (эффективно, без per-particle View). Вызывается только при
/// выключенном Reduce Motion (родитель это проверяет).
private struct ConfettiView: View {
    private struct Particle {
        let x: CGFloat          // 0..1 по ширине
        let size: CGFloat
        let color: Color
        let delay: Double
        let duration: Double
        let spin: Double        // оборотов за падение
    }

    private let particles: [Particle]

    init() {
        let colors: [Color] = [
            YMPalette.gold, YMPalette.goldBright,
            YMColor.statusDone, YMPalette.inkLight, YMPalette.goldDeep
        ]
        self.particles = (0..<24).map { i in
            Particle(
                x: CGFloat(Double.random(in: 0.04...0.96)),
                size: CGFloat.random(in: 6...11),
                color: colors[i % colors.count],
                delay: Double.random(in: 0...1.4),
                duration: Double.random(in: 2.2...3.6),
                spin: Double.random(in: 1.2...3.0)
            )
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for p in particles {
                    // Прогресс падения в цикле (учёт задержки).
                    let t = (now - p.delay).truncatingRemainder(dividingBy: p.duration)
                    guard t >= 0 else { continue }
                    let progress = t / p.duration
                    let y = -20 + CGFloat(progress) * (size.height + 40)
                    let x = p.x * size.width
                    // Плавный fade-in / fade-out.
                    let alpha: Double = progress < 0.2 ? progress / 0.2
                                       : progress > 0.85 ? max(0, (1 - progress) / 0.15) : 1
                    let angle = Angle(degrees: progress * 360 * p.spin)

                    var rect = Path(roundedRect: CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size * 0.6),
                                    cornerRadius: 1.5)
                    rect = rect.applying(CGAffineTransform(rotationAngle: CGFloat(angle.radians)))
                    rect = rect.applying(CGAffineTransform(translationX: x, y: y))
                    ctx.fill(rect, with: .color(p.color.opacity(alpha)))
                }
            }
        }
    }
}
