import SwiftUI

// Выбор машины для посылки (волна А80) — двойник assets/js/cargo-picker.js сайта:
// «По городу / Межгород», кузов «Авто S M L XL XXL» с рисунком и размерами,
// «Максимум N кг», грузчики «Нет 1 2», вес; межгород — город назначения и
// водители с ценой по их тарифу. Рисунок кузова рисуем сами (Canvas).

// MARK: - Рисунок кузова

/// Схема машины: у легковой — силуэт, у грузовой — коробка в перспективе с
/// кабиной, колёсами и подписями Д×Ш×В. Геометрия — та же, что bodySvg на сайте
/// (поле 300×150), масштабируется под ширину.
struct ParcelVehicleDrawing: View {
    let vehicle: ParcelVehicle

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / 300, size.height / 150)
            let ox = (size.width - 300 * k) / 2, oy = (size.height - 150 * k) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }
            let line = YMColor.accent
            let soft = YMColor.accent.opacity(0.16)
            let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ anchor: UnitPoint = .center) {
                ctx.draw(Text(s).font(.system(size: 12 * k, weight: .semibold)).foregroundColor(line), at: p(x, y), anchor: anchor)
            }
            func wheel(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
                let c = Path(ellipseIn: CGRect(origin: p(x - r, y - r), size: CGSize(width: 2 * r * k, height: 2 * r * k)))
                ctx.fill(c, with: .color(YMColor.surface))
                ctx.stroke(c, with: .color(line), style: stroke)
            }

            if vehicle.code == "car" {
                // Легковая: силуэт, окна, колёса и подпись «багажник и салон».
                var car = Path()
                car.move(to: p(60, 112)); car.addLine(to: p(240, 112))
                car.addQuadCurve(to: p(248, 100), control: p(250, 112))
                car.addLine(to: p(242, 84))
                car.addQuadCurve(to: p(232, 76), control: p(240, 76))
                car.addLine(to: p(198, 76)); car.addLine(to: p(172, 52))
                car.addQuadCurve(to: p(162, 48), control: p(168, 48))
                car.addLine(to: p(110, 48))
                car.addQuadCurve(to: p(99, 53), control: p(103, 48))
                car.addLine(to: p(77, 76)); car.addLine(to: p(65, 76))
                car.addQuadCurve(to: p(55, 86), control: p(55, 76))
                car.addLine(to: p(55, 102))
                car.addQuadCurve(to: p(65, 112), control: p(55, 112))
                car.closeSubpath()
                ctx.fill(car, with: .color(soft))
                ctx.stroke(car, with: .color(line), style: stroke)
                var win = Path()
                win.addLines([p(100, 76), p(116, 59), p(156, 59), p(156, 76)]); win.closeSubpath()
                win.addLines([p(164, 59), p(174, 59), p(193, 76), p(164, 76)]); win.closeSubpath()
                ctx.stroke(win, with: .color(line), style: stroke)
                wheel(95, 114, 12); wheel(210, 114, 12)
                label("багажник и салон · до \(vehicle.maxKg ?? 50) кг", 150, 140)
                return
            }

            // Грузовая: коробка кузова в перспективе + кабина справа.
            let b = vehicle.body
            let L = CGFloat(b?.l ?? 100), W = CGFloat(b?.w ?? 80), H = CGFloat(b?.h ?? 50)
            let base: CGFloat = 120, x0: CGFloat = 34
            let l = max(60, min(190, L * 0.36)), h = max(30, min(78, H * 0.38)), d = max(12, min(20, W * 0.09))
            let y0 = base - h, xe = x0 + l
            let front = Path(CGRect(origin: p(x0, y0), size: CGSize(width: l * k, height: h * k)))
            ctx.fill(front, with: .color(soft))
            ctx.stroke(front, with: .color(line), style: stroke)
            var top = Path()
            top.addLines([p(x0, y0), p(x0 + d, y0 - d), p(xe + d, y0 - d), p(xe, y0)]); top.closeSubpath()
            ctx.fill(top, with: .color(YMColor.accent.opacity(0.26)))
            ctx.stroke(top, with: .color(line), style: stroke)
            var side = Path()
            side.addLines([p(xe, y0), p(xe + d, y0 - d), p(xe + d, base - d), p(xe, base)]); side.closeSubpath()
            ctx.fill(side, with: .color(YMColor.accent.opacity(0.36)))
            ctx.stroke(side, with: .color(line), style: stroke)
            var cab = Path()
            cab.addLines([p(xe + d + 2, base), p(xe + d + 2, base - 44), p(xe + d + 28, base - 44),
                          p(xe + d + 44, base - 20), p(xe + d + 44, base)]); cab.closeSubpath()
            ctx.fill(cab, with: .color(YMColor.surface))
            ctx.stroke(cab, with: .color(line), style: stroke)
            var cabWin = Path()
            cabWin.addLines([p(xe + d + 8, base - 38), p(xe + d + 26, base - 38), p(xe + d + 37, base - 22), p(xe + d + 8, base - 22)])
            cabWin.closeSubpath()
            ctx.stroke(cabWin, with: .color(line), style: stroke)
            var ground = Path()
            ground.move(to: p(x0 - 6, base)); ground.addLine(to: p(xe + d + 50, base))
            ctx.stroke(ground, with: .color(line), style: stroke)
            wheel(x0 + 24, base + 6, 10); wheel(xe + d + 26, base + 6, 10)
            if b?.known == true {
                label("\(Int(L)) см", x0 + l / 2 + d / 2, y0 - d - 8)
                label("\(Int(H))", x0 - 6, y0 + h / 2, .trailing)
                label("\(Int(W))", xe + d + 6, y0 - d + 2, .leading)
            }
        }
        .accessibilityLabel(vehicle.label + (vehicle.body.map { ", кузов " + $0.text } ?? ""))
    }
}

// MARK: - Выбор машины

struct ParcelCargoPicker: View {
    @ObservedObject var m: ParcelFormModel
    @State private var showDest = false

    var body: some View {
        if let q = m.quote, !q.vehicles.isEmpty {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                if q.intercityEnabled {
                    YMSegmented(options: ["city", "intercity"],
                                selection: Binding(get: { m.trip }, set: { m.selectTrip($0) }),
                                title: { $0 == "city" ? "По городу" : "Межгород" })
                }
                if let v = m.selectedVehicle {
                    VStack(spacing: 4) {
                        ParcelVehicleDrawing(vehicle: v).frame(height: 128)
                        if !v.hint.isEmpty {
                            Text(v.hint).font(YMFont.caption).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                        }
                        Text(maxLine(v)).font(YMFont.subhead).foregroundStyle(YMColor.text).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, YMSpace.sm).padding(.horizontal, YMSpace.md)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Кузов").font(YMFont.subhead).foregroundStyle(YMColor.text)
                    YMSegmented(options: q.vehicles.map(\.code),
                                selection: Binding(get: { m.vehicleClass }, set: { m.selectVehicle($0) }),
                                title: { code in q.vehicles.first { $0.code == code }?.short ?? code })
                }
                HStack(alignment: .center, spacing: YMSpace.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Грузчики").font(YMFont.subhead).foregroundStyle(YMColor.text)
                        Text(m.loaders > 0 ? "по \(ParcelFmt.rub(q.loaderPrice)) за грузчика" : "Помощь не нужна")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    Spacer(minLength: 8)
                    YMSegmented(options: [0, 1, 2],
                                selection: Binding(get: { m.loaders }, set: { m.selectLoaders($0) }),
                                title: { $0 == 0 ? "Нет" : "\($0)" })
                        .frame(width: 170)
                }
                HStack(spacing: YMSpace.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Вес груза, кг").font(YMFont.subhead).foregroundStyle(YMColor.text)
                        Text("если знаете").font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    Spacer(minLength: 8)
                    TextField("—", text: Binding(get: { m.cargoKg }, set: { m.setCargoKg($0) }))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(YMFont.body)
                        .padding(.horizontal, 12).frame(width: 110, height: 40)
                        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                }
                if let e = q.cargo?.errors["cargo_kg"] { ParcelErrorLine(text: e) }
                if q.cargo?.available == false, m.vehicleClass != "car" || m.trip != "city" || m.loaders > 0 {
                    ParcelErrorLine(text: "Грузовые машины и межгород временно недоступны")
                }
                if m.trip == "intercity" { intercity(q) }
            }
            .sheet(isPresented: $showDest) {
                ParcelCitySheet(title: "Куда — город", options: m.destOptions, selected: m.destCityId) { id in
                    m.selectDest(id)
                }
            }
        }
    }

    private func maxLine(_ v: ParcelVehicle) -> String {
        var s = "Максимум \(v.maxKg ?? 0) кг"
        if let b = v.body, b.known { s += " · кузов " + b.text }
        return s
    }

    @ViewBuilder
    private func intercity(_ q: ParcelQuote) -> some View {
        let errs = q.cargo?.errors ?? ParcelTextMap()
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Куда — город").font(YMFont.subhead).foregroundStyle(YMColor.text)
            Button { showDest = true } label: {
                HStack {
                    Text(m.destName.isEmpty ? "Выберите город" : m.destName)
                        .font(YMFont.body)
                        .foregroundStyle(m.destName.isEmpty ? YMColor.muted : YMColor.text)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(YMColor.muted)
                }
                .padding(.horizontal, 14).frame(height: 46)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            if m.destCityId > 0, let e = errs["dest_city_id"] { ParcelErrorLine(text: e) }
            if m.destCityId > 0, let km = q.cargo?.distanceKm, km > 0 {
                Text("≈ \(Int(km.rounded())) км по дороге").font(YMFont.callout).foregroundStyle(YMColor.text)
            }
            if m.destCityId > 0, errs["dest_city_id"] == nil, errs["cargo_kg"] == nil {
                Text("Водители — цена по их тарифу").font(YMFont.subhead).foregroundStyle(YMColor.text).padding(.top, 4)
                driverRow(selected: m.courierId == 0, action: { m.selectDriver(0) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Любой водитель").font(YMFont.headline).foregroundStyle(YMColor.text)
                        Text("Разошлём всем, кто ездит по межгороду, — по вашей цене")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                } price: {
                    q.cargo?.suggestedFee.map { ParcelFmt.rub($0) } ?? ""
                }
                if q.drivers.isEmpty {
                    Text("Водителей межгорода с подходящей машиной в вашем городе пока нет — отправьте «Любому водителю».")
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
                ForEach(q.drivers) { d in
                    driverRow(selected: m.courierId == d.courierId, action: { m.selectDriver(d.courierId) }) {
                        driverInfo(d)
                    } price: {
                        ParcelFmt.rub(d.total)
                    }
                }
            }
        }
    }

    private func driverInfo(_ d: ParcelDriver) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(d.name).font(YMFont.headline).foregroundStyle(YMColor.text)
                if let r = d.rating { Text("★ " + ParcelFmt.rating(r)).font(YMFont.caption).foregroundStyle(YMColor.accent) }
                if d.busy { ParcelBadge(text: "сейчас в рейсе", color: YMColor.statusPending) }
                else if d.online { ParcelBadge(text: "на линии", color: YMColor.statusDone) }
            }
            Text(vehicleText(d)).font(YMFont.caption).foregroundStyle(YMColor.text)
            Text(tariffText(d)).font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
    }

    private func vehicleText(_ d: ParcelDriver) -> String {
        var s = d.vehicleLabel
        if let kg = d.maxKg { s += (s.isEmpty ? "" : " · ") + "до \(kg) кг" }
        if let b = d.body, b.known { s += " · " + b.text }
        if let n = d.loaders, n > 0 { s += " · грузчиков до \(n)" }
        return s
    }
    private func tariffText(_ d: ParcelDriver) -> String {
        var parts: [String] = []
        if !d.car.isEmpty { parts.append(d.car) }
        var t = ParcelFmt.rub(d.kmPrice) + "/км"
        if let mn = d.intercityMin, mn > 0 { t += ", от " + ParcelFmt.rub(mn) }
        parts.append(t)
        parts.append("доставок \(d.deliveriesCount ?? 0)")
        return parts.joined(separator: " · ")
    }

    private func driverRow<C: View>(selected: Bool, action: @escaping () -> Void,
                                    @ViewBuilder content: () -> C, price: () -> String) -> some View {
        let priceText = price()
        return Button { Haptics.selection(); action() } label: {
            HStack(alignment: .center, spacing: YMSpace.md) {
                content()
                Spacer(minLength: 6)
                Text(priceText).font(.system(size: 18, weight: .heavy)).foregroundStyle(YMColor.text).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? YMColor.accent.opacity(0.10) : YMColor.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Мелкие общие элементы раздела

struct ParcelErrorLine: View {
    let text: String
    var body: some View {
        Text(text).font(YMFont.caption).foregroundStyle(YMColor.statusCancel).fixedSize(horizontal: false, vertical: true)
    }
}

struct ParcelBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(YMFont.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

enum ParcelFmt {
    /// Целые рубли («7 750 ₽»): копейки в цене поездки только мешают (как на сайте).
    static func rub(_ v: Decimal?) -> String {
        guard let v else { return "" }
        return Money.format(whole(v))
    }
    static func whole(_ v: Decimal) -> Decimal {
        var r = Decimal(), x = v
        NSDecimalRound(&r, &x, 0, .plain)
        return r
    }
    static func rating(_ r: Double) -> String {
        String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
    }
    /// Время сервера (ISO 8601, date('c')): сегодня — «17:33», иначе «21.10, 17:33».
    static func time(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        return (Calendar.current.isDateInToday(d) ? timeOut : dayTimeOut).string(from: d)
    }
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = isoIn.date(from: s) { return d }
        // Запасной путь — «2026-10-20 17:33:00» (время Москвы).
        return plainIn.date(from: s)
    }
    // Форматтеры — один раз: время печатается в каждой строке списка.
    private static let isoIn = ISO8601DateFormatter()
    private static let plainIn: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let timeOut: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.timeZone = .autoupdatingCurrent
        f.dateFormat = "HH:mm"; return f
    }()
    private static let dayTimeOut: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.timeZone = .autoupdatingCurrent
        f.dateFormat = "dd.MM, HH:mm"; return f
    }()
}

// MARK: - Выбор города (поиск по списку)

struct ParcelCitySheet: View {
    let title: String
    let options: [(id: Int, name: String)]
    let selected: Int
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [(id: Int, name: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return options }
        return options.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: YMSpace.md) {
                TextField("Поиск города", text: $query)
                    .autocorrectionDisabled()
                    .padding(.horizontal, YMSpace.lg).padding(.vertical, 12)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .padding(.horizontal, YMSpace.xl).padding(.top, YMSpace.md)
                if options.isEmpty {
                    Text("Список городов не загрузился. Проверьте интернет и откройте снова.")
                        .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                        .padding(YMSpace.xl)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered, id: \.id) { c in
                                Button {
                                    Haptics.selection(); onPick(c.id); dismiss()
                                } label: {
                                    HStack {
                                        Text(c.name).font(YMFont.body)
                                            .foregroundStyle(c.id == selected ? YMColor.accent : YMColor.text)
                                        Spacer()
                                        if c.id == selected { Image(systemName: "checkmark").foregroundStyle(YMColor.accent) }
                                    }
                                    .padding(.horizontal, YMSpace.xl).padding(.vertical, 13)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Rectangle().fill(YMColor.hairline).frame(height: 1).padding(.leading, YMSpace.xl)
                            }
                            if filtered.isEmpty {
                                Text("Город не найден").font(YMFont.callout).foregroundStyle(YMColor.muted).padding(YMSpace.xl)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
    }
}
