//
//  MyAdsView.swift — «Мои объявления»: продление, снятие, правка, удаление
//
//  Сумма продления приходит с сервера в renew_price: она нулевая, если
//  объявление снято владельцем, а оплаченный срок ещё идёт. Поэтому на кнопке
//  показываем именно её, а не цену категории.
//

import SwiftUI

private func adStatusLabel(_ s: String?) -> String {
    switch s {
    case "draft": return "Черновик"
    case "active": return "Активно"
    case "expired": return "Срок вышел"
    case "archived": return "Снято с публикации"
    case "blocked": return "Заблокировано"
    default: return s ?? "—"
    }
}

@MainActor
final class MyAdsViewModel: ObservableObject {
    @Published var items: [AdCard] = []
    @Published var active = 0
    @Published var maxActive = 0
    @Published var balance: Decimal = 0
    @Published var loading = true
    @Published var error: String?
    @Published var toast: String?
    @Published var shortage: String?

    func load() async {
        do {
            let r = try await API.shared.myAds()
            items = r.items ?? []
            active = r.active ?? 0
            maxActive = r.maxActive ?? 0
            balance = r.balance ?? 0
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
    }

    func publish(_ ad: AdCard) async {
        do {
            let r = try await API.shared.adPublish(ad.stableId)
            let charged = r.charged ?? 0
            toast = charged > 0 ? "Опубликовано, списано \(Money.format(charged))" : "Опубликовано"
            await load()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "Не удалось опубликовать"
            // 409 «не хватает денег» сервер отдаёт с суммами, но до экрана
            // доходит текст — показываем его и предлагаем пополнить кошелёк.
            if msg.contains("хватает") { shortage = msg } else { toast = msg }
        }
    }

    func archive(_ ad: AdCard) async {
        do { try await API.shared.adArchive(ad.stableId); toast = "Снято. Оплаченный срок сохранён"; await load() }
        catch { toast = "Не удалось снять с публикации" }
    }

    func remove(_ ad: AdCard) async {
        do { try await API.shared.adDelete(ad.stableId); toast = "Удалено"; await load() }
        catch { toast = "Не удалось удалить" }
    }
}

struct MyAdsView: View {
    @StateObject private var vm = MyAdsViewModel()
    @State private var editId: Int?
    @State private var showNew = false
    @State private var confirmDelete: AdCard?

    var body: some View {
        Group {
            if vm.loading {
                AdsSkeletonView()
            } else if let e = vm.error, vm.items.isEmpty {
                ErrorRetryView(message: e) { Task { vm.loading = true; await vm.load() } }
            } else if vm.items.isEmpty {
                AdsEmptyView(title: "Объявлений пока нет", subtitle: "Подайте первое — это займёт пару минут.")
            } else {
                list
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои объявления")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await vm.load() }
        .sheet(isPresented: $showNew) {
            AdFormView(editAdId: 0) { _ in showNew = false; Task { await vm.load() } }
        }
        .sheet(item: Binding(get: { editId.map { AdEditTarget(id: $0) } },
                             set: { editId = $0?.id })) { target in
            AdFormView(editAdId: target.id) { _ in editId = nil; Task { await vm.load() } }
        }
        .alert("Удалить объявление?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let ad = confirmDelete { Task { await vm.remove(ad) } }
                confirmDelete = nil
            }
            Button("Отмена", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("«\(confirmDelete?.title ?? "")» и его фотографии будут удалены безвозвратно.")
        }
        .alert("Не хватает денег", isPresented: Binding(
            get: { vm.shortage != nil },
            set: { if !$0 { vm.shortage = nil } }
        )) {
            Button("Понятно", role: .cancel) { vm.shortage = nil }
        } message: {
            Text((vm.shortage ?? "") + "\n\nПополните кошелёк в профиле — объявление сохранено и никуда не денется.")
        }
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
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                Text("Активных: \(vm.active) из \(vm.maxActive) · на кошельке \(Money.format(vm.balance))")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)

                ForEach(vm.items) { ad in
                    VStack(alignment: .leading, spacing: YMSpace.sm) {
                        HStack(alignment: .top, spacing: YMSpace.md) {
                            ZStack {
                                Rectangle().fill(YMColor.surface2)
                                if let s = ad.photoURL, let u = URL(string: s) {
                                    AsyncImage(url: u) { phase in
                                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                                        else { Image(systemName: "photo").foregroundStyle(YMColor.muted) }
                                    }
                                } else {
                                    Image(systemName: "photo").foregroundStyle(YMColor.muted)
                                }
                            }
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(adStatusLabel(ad.status))
                                    .font(YMFont.caption2)
                                    .foregroundStyle(ad.status == "active" ? YMColor.statusDone
                                                     : (ad.status == "blocked" ? YMColor.statusCancel : YMColor.muted))
                                Text(ad.title ?? "").font(YMFont.headline).foregroundStyle(YMColor.text).lineLimit(2)
                                Text(ad.priceText ?? "").font(YMFont.body).foregroundStyle(YMColor.text)
                                Text("Просмотров: \(ad.viewsCount ?? 0)"
                                     + (ad.expiresAt?.isEmpty == false
                                        ? " · " + ((ad.status == "active") ? "до " : "срок вышел ") + String((ad.expiresAt ?? "").prefix(10))
                                        : ""))
                                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                                if let br = ad.blockReason, !br.isEmpty {
                                    Text(br).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                                }
                            }
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: YMSpace.md) {
                            if ad.status == "active" {
                                NavigationLink(value: AdsRoute.detail(ad.stableId)) {
                                    Text("Открыть").font(YMFont.callout).foregroundStyle(YMColor.accent)
                                }
                                Button("Снять") { Task { await vm.archive(ad) } }
                                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                            } else if ad.status == "blocked" {
                                Text("Обратитесь в поддержку").font(YMFont.caption).foregroundStyle(YMColor.muted)
                            } else {
                                Button {
                                    Task { await vm.publish(ad) }
                                } label: {
                                    Text((ad.renewPrice ?? 0) > 0
                                         ? "Оплатить \(Money.format(ad.renewPrice ?? 0))"
                                         : "Опубликовать")
                                        .font(YMFont.callout).fontWeight(.semibold)
                                        .foregroundStyle(YMColor.accent)
                                }
                            }
                            Spacer()
                            Button("Изменить") { editId = ad.stableId }
                                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                            Button("Удалить") { confirmDelete = ad }
                                .font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                        }
                    }
                    .padding(YMSpace.md)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                            .strokeBorder(YMColor.hairline, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .refreshable { await vm.load() }
    }
}

/// Обёртка для .sheet(item:) — Int сам по себе не Identifiable.
struct AdEditTarget: Identifiable { let id: Int }
