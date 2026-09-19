//
//  AdFormView.swift — подача и правка объявления
//
//  Порядок ровно как на сайте и в Android:
//    1. черновик с полями (денег не списываем)
//    2. фотографии — по одной, лимит берём из категории
//    3. «Оплатить и опубликовать» — списание из кошелька
//
//  Правка (editAdId != 0) ничего не стоит и не сбрасывает срок размещения.
//  Цена на провод уходит строкой "0.00" через Money.wire: под русской локалью
//  запятая сломала бы сумму на сервере.
//

import PhotosUI
import SwiftUI

@MainActor
final class AdFormViewModel: ObservableObject {
    @Published var cats: [(cat: AdCategory, label: String)] = []
    @Published var chosen: AdCategory?
    @Published var title = ""
    @Published var desc = ""
    @Published var price = ""
    @Published var negotiable = false
    @Published var condition = -1          // -1 не указано, 1 новое, 0 б/у
    @Published var phone = ""
    @Published var hidePhone = false
    @Published var address = ""
    @Published var photos: [AdPhoto] = []
    @Published var balance: Decimal = 0
    @Published var adId = 0
    @Published var canChangeCategory = true
    @Published var loading = true
    @Published var busy = false
    @Published var toast: String?
    @Published var shortage: String?

    /// Плоский список выбираемых категорий: листья, а у корней без детей — сам корень.
    private func leaves(_ list: [AdCategory]) -> [(AdCategory, String)] {
        var out: [(AdCategory, String)] = []
        for root in list {
            let kids = root.children ?? []
            if kids.isEmpty { out.append((root, root.name ?? "")) }
            else { for k in kids { out.append((k, "\(root.name ?? "") · \(k.name ?? "")")) } }
        }
        return out
    }

    func start(editAdId: Int) async {
        if let r = try? await API.shared.adCategories() {
            cats = leaves(r.categories ?? []).map { (cat: $0.0, label: $0.1) }
        }
        if let w: WalletInfo = try? await API.shared.get("api/v1/wallet") { balance = w.balance ?? 0 }
        if editAdId > 0, let r = try? await API.shared.ad(editAdId), let a = r.ad {
            adId = editAdId
            title = a.title ?? ""
            desc = a.description ?? ""
            price = a.price.map { Money.wire($0) } ?? ""
            negotiable = a.isNegotiable ?? false
            condition = a.conditionNew == nil ? -1 : ((a.conditionNew ?? false) ? 1 : 0)
            phone = a.contactPhone ?? ""
            hidePhone = a.phoneHidden ?? false
            address = a.address ?? ""
            photos = a.photos ?? []
            canChangeCategory = (a.status ?? "draft") == "draft"
            chosen = cats.first { $0.cat.stableId == (a.categoryId ?? 0) }?.cat
        }
        loading = false
    }

    private func body(for cat: AdCategory) -> AdSaveBody {
        AdSaveBody(
            categoryId: cat.stableId,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: desc.trimmingCharacters(in: .whitespacesAndNewlines),
            // Цену нормализуем: запятую в точку, и только если категория её просит.
            price: cat.priceAllowed
                ? (Decimal(string: price.replacingOccurrences(of: ",", with: ".")).map { Money.wire($0) } ?? "")
                : "",
            isNegotiable: negotiable,
            conditionNew: condition == 1 ? true : (condition == 0 ? false : nil),
            address: address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : address,
            contactPhone: phone.trimmingCharacters(in: .whitespaces),
            hidePhone: hidePhone
        )
    }

    /// Создать черновик или сохранить правку. Возвращает id или 0.
    @discardableResult
    func save(silent: Bool) async -> Int {
        guard let cat = chosen else { toast = "Выберите категорию"; return 0 }
        do {
            if adId > 0 {
                try await API.shared.adUpdate(adId, body(for: cat))
            } else {
                let r = try await API.shared.adCreate(body(for: cat))
                guard let newId = r.adId, newId > 0 else {
                    toast = "Сервер не вернул номер объявления"
                    return 0
                }
                adId = newId
            }
            if !silent { toast = "Сохранено" }
            return adId
        } catch {
            toast = (error as? LocalizedError)?.errorDescription ?? "Проверьте поля объявления"
            return 0
        }
    }

    func addPhotos(_ items: [PhotosPickerItem]) async {
        guard let cat = chosen else { toast = "Сначала выберите категорию"; return }
        // Фото цепляются к объявлению, поэтому черновик должен существовать.
        if adId == 0, await save(silent: true) == 0 { return }
        for item in items {
            if photos.count >= cat.photosLimit { toast = "Больше \(cat.photosLimit) фотографий нельзя"; break }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let p = try? await API.shared.uploadAdPhoto(adId: adId, jpeg: data) { photos.append(p) }
            else { toast = "Не удалось загрузить фото"; break }
        }
    }

    func deletePhoto(_ p: AdPhoto) async {
        guard adId > 0 else { return }
        do { try await API.shared.adPhotoDelete(adId: adId, photoId: p.stableId)
             photos.removeAll { $0.stableId == p.stableId } }
        catch { toast = "Не удалось удалить фото" }
    }

    /// Оплатить и опубликовать. onDone получает id опубликованного объявления.
    func publish(onDone: @escaping (Int) -> Void) async {
        busy = true
        defer { busy = false }
        let id = await save(silent: true)
        guard id > 0 else { return }
        do {
            let r = try await API.shared.adPublish(id)
            let charged = r.charged ?? 0
            toast = charged > 0 ? "Опубликовано, списано \(Money.format(charged))" : "Опубликовано"
            onDone(id)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "Не удалось опубликовать"
            if msg.contains("хватает") { shortage = msg } else { toast = msg }
        }
    }
}

struct AdFormView: View {
    let editAdId: Int
    let onPublished: (Int) -> Void

    @StateObject private var vm = AdFormViewModel()
    @State private var picked: [PhotosPickerItem] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.loading { AdsSkeletonView() } else { form }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle(editAdId > 0 ? "Правка объявления" : "Новое объявление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Закрыть") { dismiss() } }
            }
            .task { await vm.start(editAdId: editAdId) }
            // Один параметр: двухпараметрический onChange — это iOS 17, а цель
            // развёртывания проекта 16.0 (project.yml), и сборка на нём падает.
            .onChange(of: picked) { items in
                guard !items.isEmpty else { return }
                Task { await vm.addPhotos(items); picked = [] }
            }
            .alert("Не хватает денег", isPresented: Binding(
                get: { vm.shortage != nil }, set: { if !$0 { vm.shortage = nil } }
            )) {
                Button("Понятно", role: .cancel) { vm.shortage = nil }
            } message: {
                Text((vm.shortage ?? "") + "\n\nОбъявление сохранено в черновиках — пополните кошелёк в профиле и опубликуйте его из «Моих объявлений».")
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
    }

    private var form: some View {
        Form {
            Section("Категория") {
                Picker("Категория", selection: Binding(
                    get: { vm.chosen?.stableId ?? 0 },
                    set: { id in vm.chosen = vm.cats.first { $0.cat.stableId == id }?.cat }
                )) {
                    Text("— выберите —").tag(0)
                    ForEach(vm.cats, id: \.cat.stableId) { row in
                        Text(row.label + " — " + (row.cat.priceValue > 0 ? Money.format(row.cat.priceValue) : "бесплатно"))
                            .tag(row.cat.stableId)
                    }
                }
                .disabled(!vm.canChangeCategory)
                if !vm.canChangeCategory {
                    Text("Категорию можно выбрать только до публикации.")
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }

            Section("Объявление") {
                TextField("Заголовок", text: $vm.title)
                TextField("Описание", text: $vm.desc, axis: .vertical).lineLimit(4...10)
            }

            if vm.chosen?.priceAllowed != false {
                Section("Цена") {
                    TextField("Цена, ₽ (можно не указывать)", text: $vm.price).keyboardType(.decimalPad)
                    Toggle("Возможен торг", isOn: $vm.negotiable)
                }
            }

            Section("Состояние") {
                Picker("Состояние", selection: $vm.condition) {
                    Text("Не указано").tag(-1)
                    Text("Новое").tag(1)
                    Text("Б/у").tag(0)
                }
                .pickerStyle(.segmented)
            }

            Section("Контакты") {
                TextField("Телефон для связи", text: $vm.phone).keyboardType(.phonePad)
                Toggle("Показывать телефон только по кнопке", isOn: $vm.hidePhone)
                TextField("Адрес или район (необязательно)", text: $vm.address)
            }

            Section("Фотографии") {
                if !vm.photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: YMSpace.sm) {
                            ForEach(vm.photos) { p in
                                ZStack(alignment: .topTrailing) {
                                    if let u = API.imageURL(p.thumb ?? p.card) {
                                        AsyncImage(url: u) { phase in
                                            if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                                            else { Rectangle().fill(YMColor.surface2) }
                                        }
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                                    }
                                    Button {
                                        Task { await vm.deletePhoto(p) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.white, YMColor.statusCancel)
                                    }
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                PhotosPicker(selection: $picked, maxSelectionCount: vm.chosen?.photosLimit ?? 8, matching: .images) {
                    Label("Добавить фото", systemImage: "camera")
                }
                Text("До \(vm.chosen?.photosLimit ?? 8) фотографий. Первая станет главной.")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }

            Section {
                if let cat = vm.chosen {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Размещение в «\(cat.name ?? "")»").font(YMFont.caption).foregroundStyle(YMColor.muted)
                        Text(cat.priceValue > 0 ? Money.format(cat.priceValue) : "Бесплатно")
                            .font(YMFont.title3).foregroundStyle(YMColor.text)
                        Text("на \(cat.daysValue) дней").font(YMFont.caption).foregroundStyle(YMColor.muted)
                        if cat.priceValue > 0 {
                            let enough = vm.balance >= cat.priceValue
                            Text("Кошелёк: \(Money.format(vm.balance))" + (enough ? "" : " — не хватает"))
                                .font(YMFont.caption)
                                .foregroundStyle(enough ? YMColor.muted : YMColor.statusCancel)
                        }
                    }
                } else {
                    Text("Выберите категорию — рядом покажем стоимость размещения.")
                        .font(YMFont.body).foregroundStyle(YMColor.muted)
                }
            }

            Section {
                Button {
                    Task { await vm.save(silent: false) }
                } label: {
                    HStack { Spacer(); Text("Сохранить"); Spacer() }
                }
                .disabled(vm.busy || vm.chosen == nil)

                Button {
                    Task { await vm.publish { id in onPublished(id); dismiss() } }
                } label: {
                    HStack {
                        Spacer()
                        if vm.busy { ProgressView() }
                        else {
                            Text((vm.chosen?.priceValue ?? 0) > 0 ? "Оплатить и опубликовать" : "Опубликовать").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(vm.busy || vm.chosen == nil)
            } footer: {
                Text("Объявление публикуется сразу после оплаты. За нарушение правил площадки объявление может быть заблокировано.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(YMColor.bg.ignoresSafeArea())
    }
}
