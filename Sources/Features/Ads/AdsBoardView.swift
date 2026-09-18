//
//  AdsBoardView.swift — доска объявлений: лента (нижняя вкладка «Объявления»)
//
//  Контракт (routes/ads.php), 1:1 с сайтом и Android:
//    • GET api/v1/ads/categories → категории с ЦЕНОЙ размещения (наследование
//      «подкатегория → родитель → настройки» сервер уже применил)
//    • GET api/v1/ads            → лента с фильтрами и постраничной подгрузкой
//
//  Деньги — Decimal через @LenientDecimal и Money.format, никогда не Double.
//  Токены YM.*, light+dark, Dynamic Type.
//

import SwiftUI

@MainActor
final class AdsBoardViewModel: ObservableObject {
    @Published var cats: [AdCategory] = []
    @Published var items: [AdCard] = []
    @Published var loading = true
    @Published var loadingMore = false
    @Published var error: String?
    @Published var enabled = true
    @Published var total = 0
    @Published var query = ""
    @Published var categoryId = 0

    private var page = 1
    private var pages = 1
    private var searchTask: Task<Void, Never>?

    /// Выбранная корневая категория — чтобы показать её подкатегории.
    var activeRoot: AdCategory? {
        cats.first { $0.stableId == categoryId }
            ?? cats.first { root in (root.children ?? []).contains { $0.stableId == categoryId } }
    }

    func start() async {
        if let r = try? await API.shared.adCategories() {
            cats = r.categories ?? []
            enabled = r.enabled ?? true
        }
        await load(reset: true)
    }

    func load(reset: Bool) async {
        if reset { loading = items.isEmpty; page = 1 } else { loadingMore = true }
        do {
            let r = try await API.shared.ads(categoryId: categoryId, q: query, page: reset ? 1 : page + 1)
            enabled = r.enabled ?? true
            total = r.total ?? 0
            pages = max(1, r.pages ?? 1)
            let fresh = r.items ?? []
            items = reset ? fresh : items + fresh
            if !reset { page += 1 }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
        loadingMore = false
    }

    var canLoadMore: Bool { page < pages }

    /// Поиск с задержкой: печатают быстро, а запрос нужен один.
    func searchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            await self?.load(reset: true)
        }
    }

    func pick(_ id: Int) {
        categoryId = id
        Task { await load(reset: true) }
    }
}

struct AdsBoardView: View {
    @StateObject private var vm = AdsBoardViewModel()
    @State private var path = NavigationPath()
    @State private var showForm = false

    private let columns = [GridItem(.flexible(), spacing: YMSpace.md), GridItem(.flexible(), spacing: YMSpace.md)]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                content
                if vm.enabled {
                    Button {
                        showForm = true
                    } label: {
                        Label("Подать объявление", systemImage: "plus")
                            .font(YMFont.headline)
                            .foregroundStyle(YMColor.onAccent)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 22)
                            .background(
                                LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                               startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                    }
                    .padding(.bottom, YMSpace.lg)
                }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Объявления")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(value: AdsRoute.my) { Text("Мои") }
                }
            }
            .navigationDestination(for: AdsRoute.self) { route in
                switch route {
                case .my: MyAdsView()
                case .detail(let id): AdDetailView(adId: id)
                }
            }
            .sheet(isPresented: $showForm) {
                AdFormView(editAdId: 0) { newId in
                    showForm = false
                    path.append(AdsRoute.detail(newId))
                }
            }
            .task { await vm.start() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !vm.enabled {
            AdsEmptyView(title: "Доска объявлений пока не включена",
                         subtitle: "Заходите позже — раздел скоро откроется.")
        } else if vm.loading {
            AdsSkeletonView()
        } else if let e = vm.error, vm.items.isEmpty {
            ErrorRetryView(message: e) { Task { await vm.load(reset: true) } }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: YMSpace.md) {
                    searchField
                    categoryRow
                    if vm.items.isEmpty {
                        AdsEmptyView(title: "Ничего не нашлось",
                                     subtitle: "Измените запрос или подайте своё объявление.")
                            .frame(height: 260)
                    } else {
                        if vm.total > 0 {
                            Text("Найдено: \(vm.total)")
                                .font(YMFont.caption).foregroundStyle(YMColor.muted)
                        }
                        LazyVGrid(columns: columns, spacing: YMSpace.md) {
                            ForEach(vm.items) { ad in
                                NavigationLink(value: AdsRoute.detail(ad.stableId)) {
                                    AdGridCard(ad: ad)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if vm.canLoadMore {
                            Button {
                                Task { await vm.load(reset: false) }
                            } label: {
                                HStack { Spacer()
                                    if vm.loadingMore { ProgressView() } else { Text("Показать ещё") }
                                    Spacer() }
                            }
                            .padding(.top, YMSpace.sm)
                        }
                    }
                }
                .padding(.horizontal, YMSpace.lg)
                .padding(.top, YMSpace.sm)
                .padding(.bottom, 96)   // место под кнопку «Подать объявление»
            }
            .refreshable { await vm.load(reset: true) }
        }
    }

    private var searchField: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(YMColor.muted)
            TextField("Что ищете?", text: $vm.query)
                .textInputAutocapitalization(.never)
                // Один параметр: двухпараметровая форма — iOS 17, а цель iOS 16.
                .onChange(of: vm.query) { _ in vm.searchChanged() }
            if !vm.query.isEmpty {
                Button { vm.query = ""; vm.searchChanged() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(YMColor.muted)
                }
            }
        }
        .padding(.horizontal, YMSpace.md)
        .padding(.vertical, 12)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
    }

    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: YMSpace.sm) {
                    AdCatChip(title: "Все", price: nil, selected: vm.categoryId == 0) { vm.pick(0) }
                    ForEach(vm.cats) { cat in
                        AdCatChip(
                            title: cat.name ?? "",
                            price: cat.priceValue,
                            selected: vm.activeRoot?.stableId == cat.stableId
                        ) { vm.pick(cat.stableId) }
                    }
                }
            }
            if let kids = vm.activeRoot?.children, !kids.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.sm) {
                        ForEach(kids) { k in
                            AdCatChip(title: k.name ?? "", price: nil, selected: vm.categoryId == k.stableId) {
                                vm.pick(k.stableId)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Куда ходим из ленты. Отдельный тип, чтобы NavigationPath был типизированным.
enum AdsRoute: Hashable {
    case my
    case detail(Int)
}

struct AdCatChip: View {
    let title: String
    let price: Decimal?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(YMFont.callout)
                if let p = price {
                    Text(p > 0 ? Money.format(p) : "бесплатно")
                        .font(YMFont.caption2)
                        .foregroundStyle(selected ? YMColor.accent.opacity(0.8) : YMColor.muted)
                }
            }
            .padding(.horizontal, YMSpace.md)
            .padding(.vertical, YMSpace.sm)
            .foregroundStyle(selected ? YMColor.accent : YMColor.text)
            .background(
                (selected ? YMColor.accent.opacity(0.16) : YMColor.surface),
                in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                    .strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct AdGridCard: View {
    let ad: AdCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(YMColor.surface2)
                if let url = ad.photoURL, let u = URL(string: url) {
                    AsyncImage(url: u) { phase in
                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                        else { Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(YMColor.muted) }
                    }
                } else {
                    Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(YMColor.muted)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fill)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if (ad.photosCount ?? 0) > 1 {
                    Text("\(ad.photosCount ?? 0)")
                        .font(YMFont.caption2).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(ad.priceText ?? "").font(YMFont.headline).foregroundStyle(YMColor.text)
                Text(ad.title ?? "").font(YMFont.body).foregroundStyle(YMColor.text).lineLimit(2)
                Text([ad.categoryName, ad.city].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.md)
        }
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1)
        )
    }
}

struct AdsSkeletonView: View {
    var body: some View {
        VStack(spacing: YMSpace.md) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: YMSpace.md) {
                    SkeletonBox(radius: YMRadius.card).frame(height: 190)
                    SkeletonBox(radius: YMRadius.card).frame(height: 190)
                }
            }
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.top, YMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct AdsEmptyView: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: YMSpace.sm) {
            Image(systemName: "megaphone").font(.system(size: 42)).foregroundStyle(YMColor.muted)
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(subtitle).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(YMSpace.xl)
    }
}
