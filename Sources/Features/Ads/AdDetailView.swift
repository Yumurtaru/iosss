//
//  AdDetailView.swift — карточка объявления
//
//  Телефон показывается ПО НАЖАТИЮ (POST api/v1/ads/{id}/contact): владелец
//  видит реальное число обращений, а номер не достаётся тем, кто просто листал.
//  Если владелец спрятал номер, в карточке его нет вовсе — только кнопка.
//

import SwiftUI

private let adReportReasons: [(String, String)] = [
    ("fraud", "Мошенничество"),
    ("prohibited", "Запрещённый товар"),
    ("spam", "Спам или реклама"),
    ("wrong_category", "Не та категория"),
    ("sold", "Уже продано"),
    ("other", "Другое"),
]

@MainActor
final class AdDetailViewModel: ObservableObject {
    @Published var ad: AdDetail?
    @Published var loading = true
    @Published var error: String?
    @Published var phone: String?
    @Published var favorite = false
    @Published var toast: String?

    func load(_ id: Int) async {
        do {
            let r = try await API.shared.ad(id)
            ad = r.ad
            favorite = r.ad?.favorite ?? false
            phone = r.ad?.contactPhone?.isEmpty == false ? r.ad?.contactPhone : nil
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Объявление не найдено"
        }
        loading = false
    }

    func showPhone(_ id: Int) async {
        if let r = try? await API.shared.adContact(id), let p = r.phone, !p.isEmpty { phone = p }
        else { toast = "Телефон недоступен" }
    }

    func toggleFavorite(_ id: Int) async {
        if let r = try? await API.shared.adFavorite(id) { favorite = r.favorite ?? favorite }
        else { toast = "Не удалось изменить избранное" }
    }

    func report(_ id: Int, reason: String) async {
        do { try await API.shared.adReport(id, reason: reason, comment: nil); toast = "Жалоба отправлена, спасибо" }
        catch { toast = "Не удалось отправить жалобу" }
    }
}

struct AdDetailView: View {
    let adId: Int
    @StateObject private var vm = AdDetailViewModel()
    @State private var bigPhoto: String?
    @State private var showReport = false
    @State private var reason = adReportReasons[0].0
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if vm.loading {
                AdsSkeletonView()
            } else if let a = vm.ad {
                content(a)
            } else {
                ErrorRetryView(message: vm.error ?? "Объявление не найдено") {
                    Task { vm.loading = true; await vm.load(adId) }
                }
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Объявление")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(adId) }
        .overlay(alignment: .bottom) {
            if let t = vm.toast {
                Text(t)
                    .font(YMFont.caption).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(YMColor.text.opacity(0.9), in: Capsule())
                    .padding(.bottom, YMSpace.lg)
                    .task { try? await Task.sleep(nanoseconds: 2_500_000_000); vm.toast = nil }
            }
        }
        .confirmationDialog("Пожаловаться", isPresented: $showReport, titleVisibility: .visible) {
            ForEach(adReportReasons, id: \.0) { value, label in
                Button(label) { Task { await vm.report(adId, reason: value) } }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func content(_ a: AdDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                if (a.status ?? "active") != "active" {
                    Text("Это объявление сейчас не показывается в общей ленте.")
                        .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        .padding(YMSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
                }

                let photos = a.photos ?? []
                ZStack {
                    Rectangle().fill(YMColor.surface2)
                    let shown = bigPhoto ?? photos.first?.full ?? photos.first?.card
                    if let s = shown, let u = URL(string: s) {
                        AsyncImage(url: u) { phase in
                            if let img = phase.image { img.resizable().aspectRatio(contentMode: .fit) }
                            else { ProgressView() }
                        }
                    } else {
                        Image(systemName: "photo").font(.system(size: 44)).foregroundStyle(YMColor.muted)
                    }
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))

                if photos.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: YMSpace.sm) {
                            ForEach(photos) { p in
                                if let s = p.thumb ?? p.card, let u = URL(string: s) {
                                    AsyncImage(url: u) { phase in
                                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                                        else { Rectangle().fill(YMColor.surface2) }
                                    }
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                                    .onTapGesture { bigPhoto = p.full ?? p.card }
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(a.priceText ?? "").font(YMFont.largeTitle).foregroundStyle(YMColor.text)
                    Text(a.title ?? "").font(YMFont.title3).foregroundStyle(YMColor.text)
                    Text([
                        a.categoryName, a.city, "\(a.viewsCount ?? 0) просмотров",
                    ].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }

                if let p = vm.phone {
                    Button {
                        let digits = p.filter { $0.isNumber || $0 == "+" }
                        if let u = URL(string: "tel://\(digits)") { openURL(u) }
                    } label: {
                        Label("Позвонить: \(p)", systemImage: "phone.fill")
                            .font(YMFont.headline).foregroundStyle(YMColor.onAccent)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(YMColor.accent, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    }
                } else {
                    Button {
                        Task { await vm.showPhone(adId) }
                    } label: {
                        Label("Показать телефон", systemImage: "phone.fill")
                            .font(YMFont.headline).foregroundStyle(YMColor.onAccent)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(YMColor.accent, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    }
                }

                HStack(spacing: YMSpace.md) {
                    Button {
                        Task { await vm.toggleFavorite(adId) }
                    } label: {
                        Label(vm.favorite ? "В избранном" : "В избранное",
                              systemImage: vm.favorite ? "heart.fill" : "heart")
                            .font(YMFont.callout).foregroundStyle(YMColor.accent)
                    }
                    Button { showReport = true } label: {
                        Label("Пожаловаться", systemImage: "flag")
                            .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    }
                    Spacer()
                }

                if let cond = a.conditionNew {
                    Text("Состояние: \(cond ? "новое" : "б/у")").font(YMFont.body).foregroundStyle(YMColor.text)
                }
                if let addr = a.address, !addr.isEmpty {
                    Text("Адрес: \(addr)").font(YMFont.body).foregroundStyle(YMColor.text)
                }

                Text("Описание").font(YMFont.title3).foregroundStyle(YMColor.text).padding(.top, YMSpace.sm)
                Text(a.description ?? "").font(YMFont.body).foregroundStyle(YMColor.text)

                Text("Продавец: \(a.author?.name?.isEmpty == false ? (a.author?.name ?? "") : "частное лицо")")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .padding(.top, YMSpace.sm)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
    }
}
