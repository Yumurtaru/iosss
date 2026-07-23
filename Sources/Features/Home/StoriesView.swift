//
//  StoriesView.swift — «Сторис»-лента для Главной (премиум iOS-клиент Yumurta)
//
//  Горизонтальная лента кружков (Instagram-style) для вставки на Главную.
//  ВСТАВКУ на Главную делает главный процесс — здесь только сам компонент.
//
//  Сигнатура: StoriesView(cityId: Int?)   // по умолчанию берёт Session.shared.cityId
//
//  ДАННЫЕ (реальный путь, сверено по core/api_v1.php):
//    • GET api/v1/banners?city_id={id}  → [Banner]
//        поля: id, position, title, link, image_webp  (Banner.image == imageWebp)
//    Грузит сам в .task. Пусто/ошибка → НИЧЕГО не рисует (graceful, без краша).
//
//  Тап по кружку → полноэкранный просмотр (fullScreenCover):
//    прогресс-полоски, авто-продвижение 5с, тап слева/справа — назад/вперёд,
//    свайп вниз / крестик — закрыть. Уважает Reduce Motion (без авто-таймера).
//
//  Картинки — только через API.imageURL (как везде в новом клиенте).
//  Токены YM.*, light+dark. Русские строки.
//

import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Лента кружков
// ─────────────────────────────────────────────────────────────────────────────

struct StoriesView: View {
    /// Город для выборки баннеров. По умолчанию — текущий город сессии.
    var cityId: Int? = Session.shared.cityId

    @State private var banners: [Banner] = []
    @State private var openIndex: Int?
    @State private var loaded = false

    var body: some View {
        Group {
            // Пусто → ничего не рисуем (без пустого места и без краша).
            if banners.isEmpty {
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.md) {
                        ForEach(Array(banners.enumerated()), id: \.element.id) { idx, b in
                            StoryCircle(banner: b, tone: idx) {
                                Haptics.light(); openIndex = idx
                            }
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.vertical, YMSpace.sm)
                }
            }
        }
        .task(id: cityId) { await load() }
        .fullScreenCover(item: Binding(
            get: { openIndex.map { StoryStart(index: $0) } },
            set: { if $0 == nil { openIndex = nil } }
        )) { start in
            StoriesPlayer(banners: banners, startIndex: start.index) { openIndex = nil }
        }
    }

    private func load() async {
        // При смене города перезагружаем; повторно на тот же город — один раз.
        var query: [String: String] = [:]
        if let c = cityId, c > 0 { query["city_id"] = String(c) }
        let result: [Banner] = (try? await API.shared.list("api/v1/banners", query: query)) ?? []
        await MainActor.run { banners = result; loaded = true }
    }
}

/// Обёртка индекса для item-based fullScreenCover.
private struct StoryStart: Identifiable { let index: Int; var id: Int { index } }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Кружок сторис
// ─────────────────────────────────────────────────────────────────────────────

/// Кружок 64pt с золотой градиентной рамкой + фото внутри + подпись под ним.
private struct StoryCircle: View {
    let banner: Banner
    var tone: Int = 0
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: YMSpace.xs) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 66, height: 66)
                    Circle().fill(YMColor.bg).frame(width: 60, height: 60)
                    PhotoPlaceholder(url: API.imageURL(banner.image), label: "", radius: 27, tone: tone)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }
                Text(banner.title ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(YMColor.muted)
                    .lineLimit(1)
                    .frame(width: 66)
            }
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(banner.title.map { "История: \($0)" } ?? "История")
        .accessibilityAddTraits(.isButton)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Полноэкранный просмотр
// ─────────────────────────────────────────────────────────────────────────────

/// Просмотр сторис: прогресс-полоски, авто-продвижение 5с, тап-зоны, свайп-вниз/крестик.
private struct StoriesPlayer: View {
    let banners: [Banner]
    let startIndex: Int
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var index: Int
    @State private var progress: CGFloat = 0
    @State private var timer: Timer?
    private let perStory: Double = 5

    init(banners: [Banner], startIndex: Int, onClose: @escaping () -> Void) {
        self.banners = banners
        self.startIndex = startIndex
        self.onClose = onClose
        _index = State(initialValue: max(0, min(startIndex, banners.count - 1)))
    }

    private var current: Banner? { banners.indices.contains(index) ? banners[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let b = current {
                AsyncImage(url: API.imageURL(b.image)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.system(size: 40)).foregroundStyle(.white.opacity(0.35))
                    default:
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Тап-зоны: слева — назад, справа — вперёд.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { back() }
                Color.clear.contentShape(Rectangle()).onTapGesture { advance() }
            }
            .ignoresSafeArea()

            VStack(spacing: YMSpace.sm) {
                // Прогресс-полоски по одной на кадр.
                HStack(spacing: 4) {
                    ForEach(banners.indices, id: \.self) { i in
                        GeometryReader { geo in
                            Capsule().fill(Color.white.opacity(0.3))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color.white)
                                        .frame(width: geo.size.width * fill(for: i))
                                }
                        }
                        .frame(height: 3)
                    }
                }

                HStack(alignment: .top) {
                    if let t = current?.title, !t.isEmpty {
                        Text(t).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.black.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                // Кнопка «Подробнее» — если у баннера есть ссылка.
                if let link = current?.link, let url = URL(string: link) {
                    Button {
                        close(); openURL(url)
                    } label: {
                        Text("Подробнее")
                            .font(.system(size: 15, weight: .heavy)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, YMSpace.lg)
                }
            }
            .padding(.horizontal, YMSpace.lg)
            .padding(.top, YMSpace.sm)
        }
        .gesture(DragGesture().onEnded { if $0.translation.height > 100 { close() } })
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
        .statusBarHidden(true)
    }

    /// Заполнение полоски i относительно текущего кадра.
    private func fill(for i: Int) -> CGFloat {
        if i < index { return 1 }
        if i == index { return progress }
        return 0
    }

    private func startTimer() {
        timer?.invalidate(); progress = 0
        // Reduce Motion: не крутим авто-прогресс (полоска заполнена, листаем тапом).
        guard !reduceMotion else { progress = 1; return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            progress += 0.02 / perStory
            if progress >= 1 { advance() }
        }
    }
    private func advance() {
        if index < banners.count - 1 { index += 1; startTimer() } else { close() }
    }
    private func back() {
        if index > 0 { index -= 1 }
        startTimer()
    }
    private func close() { timer?.invalidate(); onClose() }
}
