import SwiftUI

/// Типы организаций для чипов на Главной.
enum OrgKind: String, CaseIterable, Identifiable {
    case all = "Все"
    case restaurants = "Рестораны"
    case shops = "Магазины"
    case services = "Услуги"
    var id: String { rawValue }
}

/// Ряд чипов-фильтров (Все/Рестораны/Магазины/Услуги). Активный — золото.
struct ChipRow: View {
    @Binding var selected: OrgKind
    var onChange: ((OrgKind) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: YMSpace.sm) {
                ForEach(OrgKind.allCases) { kind in
                    Chip(label: kind.rawValue, active: kind == selected) {
                        Haptics.selection()
                        withAnimation(YMMotion.snappy) { selected = kind }
                        onChange?(kind)
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
        }
    }
}

/// Одиночный чип.
struct Chip: View {
    let label: String
    let active: Bool
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(active ? YMColor.onAccent : YMColor.text)
                .padding(.horizontal, 15).padding(.vertical, 8)
                .background(active ? YMColor.accent : YMColor.surface,
                            in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                        .strokeBorder(active ? Color.clear : YMColor.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Сегмент-контрол (control radius 14, surface2). Способы получения и т.п.
struct YMSegmentedControl: View {
    let options: [String]
    @Binding var index: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let active = i == index
                Button {
                    Haptics.selection()
                    withAnimation(YMMotion.snappy) { index = i }
                } label: {
                    Text(options[i])
                        .font(YMFont.subhead)
                        .foregroundStyle(active ? YMColor.text : YMColor.muted)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: YMRadius.control - 3, style: .continuous)
                                    .fill(YMColor.surface)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
    }
}
