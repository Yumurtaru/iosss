import SwiftUI

/*
 Плашка «Карта клиента» в профиле: штрихкод EAN-13 (см. Core/EAN13.swift) и
 номер под ним. Показывается кассиру в магазине.

 Фон штрихкода белый даже в тёмной теме — инверсию кассовые сканеры не читают.
 На время показа поднимаем яркость экрана: на приглушённом экране скан обычно
 не проходит. Прежняя яркость возвращается, когда экран уходит.
*/

struct ClientCardBlock: View {
    let code: String

    @State private var savedBrightness: CGFloat?

    var body: some View {
        if let modules = EAN13.modules(code) {
            VStack(spacing: 8) {
                Text("Карта клиента")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        // Ширину модуля округляем вниз до целого пикселя, а остаток
                        // делим поровну по краям: дробная ширина размывает границы
                        // полос антиалиасингом, и камерные сканеры читают хуже.
                        let scale = UIScreen.main.scale
                        let raw = geo.size.width / CGFloat(modules.count)
                        let mw = max(1 / scale, (raw * scale).rounded(.down) / scale)
                        let pad = (geo.size.width - mw * CGFloat(modules.count)) / 2
                        Path { path in
                            for (i, on) in modules.enumerated() where on {
                                path.addRect(CGRect(x: pad + CGFloat(i) * mw, y: 0,
                                                    width: mw, height: geo.size.height))
                            }
                        }
                        .fill(Color.black)
                    }
                    .frame(height: 76)
                    Text(EAN13.pretty(code))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.black)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Покажите этот код кассиру — покупка учтётся в бонусах")
                    .font(.system(size: 12))
                    .foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(YMSpace.lg)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.lg)
            .onAppear {
                if savedBrightness == nil {
                    savedBrightness = UIScreen.main.brightness
                    UIScreen.main.brightness = 1.0
                }
            }
            .onDisappear {
                if let b = savedBrightness {
                    UIScreen.main.brightness = b
                    savedBrightness = nil
                }
            }
        }
    }
}
