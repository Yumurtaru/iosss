import SwiftUI

/// Дизайнерская заглушка фото: градиентный прямоугольник с монопометкой «ФОТО»/«ОБЛОЖКА».
/// Реальные изображения приходят из API (см. API.imageURL). Если url есть — грузим через
/// AsyncImage поверх плейсхолдера; placeholder виден во время загрузки и при ошибке.
struct PhotoPlaceholder: View {
    var url: URL? = nil
    var label: String = "ФОТО"
    var radius: CGFloat = YMRadius.card
    /// Индекс для детерминированного выбора тона градиента (карусель выглядит разнообразно).
    var tone: Int = 0

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            gradient
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(10)
        }
        .overlay {
            if let url {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var gradient: LinearGradient {
        let darkTones: [[Color]] = [
            [Color(hex: "#33302B"), Color(hex: "#2E322E")],
            [Color(hex: "#3A342A"), Color(hex: "#342E30")],
            [Color(hex: "#2E322E"), Color(hex: "#302F36")],
            [Color(hex: "#342E30"), Color(hex: "#33302B")]
        ]
        let lightTones: [[Color]] = [
            [Color(hex: "#EBE3D2"), Color(hex: "#E4E8DE")],
            [Color(hex: "#E9DFC9"), Color(hex: "#EFE6DC")],
            [Color(hex: "#E4E8DE"), Color(hex: "#E6E7EE")],
            [Color(hex: "#EFE6DC"), Color(hex: "#EBE3D2")]
        ]
        let pool = scheme == .dark ? darkTones : lightTones
        let pair = pool[tone % pool.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
