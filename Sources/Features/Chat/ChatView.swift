import SwiftUI
import PhotosUI

//  ChatView.swift
//  Yumurta — premium iOS-клиент. Экран 7 — Чаты (list) и Переписка (chat).
//
//  Init-сигнатуры:
//    ChatView(list)              — экран списка чатов «Чаты».
//    ChatView(orderId: Int)      — переписка по конкретному заказу.
//
//  ВАЖНО: чат в этом API привязан к заказу (как в старом TrackView):
//    GET  api/v1/orders/{id}/chat[?after_id=N]  → [ChatMessage]  (инкрементально)
//    POST api/v1/orders/{id}/chat  body ["message": text]
//  Отдельного «списка всех чатов» сервер пока не отдаёт → список строим из активных заказов
//  (GET api/v1/orders) — 1:1 по данным, без выдуманных полей. TODO(API) помечены ниже.
//
//  Signature-язык: золото сквозное — бейдж непрочитанных, мои пузыри, кнопка отправки,
//  плашка привязки к заказу «№… · В пути» со статусной точкой.

// MARK: - Точка входа

extension ChatView {
    /// Экран списка чатов.
    static var list: ChatView { ChatView(mode: .list) }
}

struct ChatView: View {
    enum Mode: Equatable { case list; case chat(orderId: Int) }
    let mode: Mode

    /// Список чатов: ChatView(list) через static, либо ChatView(mode: .list).
    init(mode: Mode) { self.mode = mode }
    /// Переписка по заказу: ChatView(orderId:).
    init(orderId: Int) { self.mode = .chat(orderId: orderId) }

    var body: some View {
        switch mode {
        case .list:                 ChatListScreen()
        case .chat(let orderId):    ChatThreadScreen(orderId: orderId)
        }
    }
}

// MARK: - Список чатов (screen: list)

@MainActor
private final class ChatListViewModel: ObservableObject {
    @Published var dialogs: [ChatDialog] = []
    @Published var loading = true
    private var didLoad = false

    func firstLoad() async { guard !didLoad else { return }; didLoad = true; await load() }
    func load() async {
        loading = true
        // Реальный список диалогов: заказы с перепиской + последнее сообщение + непрочитанные.
        dialogs = (try? await API.shared.list("api/v1/chats")) ?? []
        loading = false
    }
}

private struct ChatListScreen: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = ChatListViewModel()
    @State private var query = ""

    private var filtered: [ChatDialog] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return vm.dialogs }
        let q = query.lowercased()
        return vm.dialogs.filter { ($0.shopName ?? "").lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: YMSpace.md) {
                    SearchField(placeholder: "Поиск по чатам", text: $query, active: !query.isEmpty)
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, YMSpace.xs)

                    content
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Чаты")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await vm.load() }
            .task { if session.isLoggedIn { await vm.firstLoad() } }
            .navigationDestination(for: Int.self) { ChatThreadScreen(orderId: $0) }
        }
    }

    @ViewBuilder private var content: some View {
        if !session.isLoggedIn {
            emptyState(icon: "person.crop.circle.badge.questionmark",
                       title: "Войдите в аккаунт",
                       hint: "Чтобы переписываться с заведениями по заказам.")
        } else if vm.loading && vm.dialogs.isEmpty {
            VStack(spacing: YMSpace.sm) {
                ForEach(0..<4, id: \.self) { _ in SkeletonBox().frame(height: 72) }
            }
            .padding(.horizontal, YMSpace.xl)
        } else if filtered.isEmpty {
            emptyState(icon: "bubble.left.and.bubble.right",
                       title: query.isEmpty ? "Чатов пока нет" : "Ничего не найдено",
                       hint: query.isEmpty
                            ? "Оформите заказ — здесь появится переписка с заведением."
                            : "Попробуйте другой запрос.")
        } else {
            VStack(spacing: 0) {
                ForEach(filtered) { dialog in
                    NavigationLink(value: dialog.orderId ?? 0) {
                        ChatListRow(dialog: dialog)
                    }
                    .buttonStyle(.plain)
                    if dialog.id != filtered.last?.id {
                        Divider().overlay(YMColor.hairline).padding(.leading, 82)
                    }
                }
            }
            .padding(.vertical, YMSpace.xs)
            .ymCard(radius: YMRadius.card)
            .padding(.horizontal, YMSpace.xl)
        }
    }

    private func emptyState(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: YMSpace.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .fill(YMColor.surface2).frame(width: 96, height: 96)
                Image(systemName: icon).font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
            }
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(hint).font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center).padding(.horizontal, YMSpace.xxxl)
        }
        .frame(maxWidth: .infinity).padding(.top, 64)
    }
}

/// Строка чата: лого 52, название, время последнего сообщения, превью, золотой бейдж непрочитанных.
private struct ChatListRow: View {
    let dialog: ChatDialog

    private var unread: Int { dialog.unreadCount ?? 0 }
    /// Превью: последнее сообщение, либо «📷 Фото» для вложения, либо заглушка.
    private var preview: String {
        if let m = dialog.lastMessage, !m.isEmpty { return m }
        if !((dialog.lastAttachment ?? "").isEmpty) { return "📷 Фото" }
        return "Нет сообщений"
    }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            LogoBadge(url: API.imageURL(dialog.shopLogo),
                      letter: (dialog.shopName ?? "?").prefix(1).uppercased(),
                      size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(dialog.shopName ?? "Заведение")
                        .font(.system(size: 15.5, weight: .bold)).foregroundStyle(YMColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(DateFmt.time(dialog.lastAt))
                        .font(YMFont.caption).foregroundStyle(unread > 0 ? YMColor.accent : YMColor.muted)
                }
                HStack(spacing: YMSpace.sm) {
                    Text(preview)
                        .font(.system(size: 13, weight: unread > 0 ? .semibold : .regular))
                        .foregroundStyle(unread > 0 ? YMColor.text : YMColor.muted)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 11, weight: .heavy)).foregroundStyle(YMColor.onAccent)
                            .frame(minWidth: 20, minHeight: 20).padding(.horizontal, 5)
                            .background(YMColor.accent, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.vertical, YMSpace.md)
        .contentShape(Rectangle())
    }
}

// MARK: - Переписка (screen: chat)

@MainActor
private final class ChatThreadViewModel: ObservableObject {
    let orderId: Int
    @Published var order: OrderDetail?
    @Published var track: TrackData?
    @Published var messages: [ChatMessage] = []
    @Published var loading = true
    @Published var sending = false

    private var lastChatId = 0
    private var pollTimer: Timer?

    init(orderId: Int) { self.orderId = orderId }

    func initialLoad() async {
        loading = true
        async let o: OrderDetail? = try? await API.shared.get("api/v1/orders/\(orderId)")
        async let t: TrackData?   = try? await API.shared.get("api/v1/orders/\(orderId)/track")
        order = await o
        track = await t
        await fetchNew()
        loading = false
    }

    /// Инкрементальная подгрузка: первый запрос — вся история, дальше только after_id=N.
    func fetchNew() async {
        let path = lastChatId > 0
            ? "api/v1/orders/\(orderId)/chat?after_id=\(lastChatId)"
            : "api/v1/orders/\(orderId)/chat"
        guard let batch: [ChatMessage] = try? await API.shared.list(path), !batch.isEmpty else { return }
        if lastChatId == 0 { messages = batch } else { messages.append(contentsOf: batch) }
        lastChatId = max(lastChatId, batch.compactMap { $0.id }.max() ?? 0)
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetchNew() }
        }
    }
    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sending = true; defer { sending = false }
        try? await API.shared.postVoid("api/v1/orders/\(orderId)/chat", body: ["message": trimmed])
        await fetchNew()
    }

    /// Отправка фото с оптимистичным превью (localImage) + статусом «отправляется/ошибка».
    func sendPhoto(_ data: Data) async {
        let tempStamp = "local-\(UUID().uuidString)"
        let temp = ChatMessage(id: nil, message: nil, sender: "client", createdAt: tempStamp,
                               mine: true, attachment: nil, read: false, senderName: nil,
                               localState: "sending", localImage: data)
        messages.append(temp)
        sending = true; defer { sending = false }
        do {
            _ = try await API.shared.uploadChatPhoto(orderId: orderId, jpeg: data)
            messages.removeAll { $0.stableId == temp.stableId }
            await fetchNew()
        } catch {
            if let i = messages.firstIndex(where: { $0.stableId == temp.stableId }) {
                messages[i].localState = "failed"
            }
        }
    }
}

private struct ChatThreadScreen: View {
    let orderId: Int
    @StateObject private var vm: ChatThreadViewModel
    @State private var draft = ""
    @State private var photoItems: [PhotosPickerItem] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(orderId: Int) {
        self.orderId = orderId
        _vm = StateObject(wrappedValue: ChatThreadViewModel(orderId: orderId))
    }

    var body: some View {
        VStack(spacing: 0) {
            orderLinkPlate
            Divider().overlay(YMColor.hairline)
            messagesList
            inputBar
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { headerTitle } }
        .task { await vm.initialLoad(); vm.startPolling() }
        .onDisappear { vm.stopPolling() }
    }

    // Шапка: лого + «● онлайн · обычно отвечает за 2 мин»
    private var headerTitle: some View {
        HStack(spacing: YMSpace.sm) {
            LogoBadge(url: API.imageURL(vm.order?.shopName == nil ? nil : nil),
                      letter: (vm.order?.shopName ?? "?").prefix(1).uppercased(),
                      size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.order?.shopName ?? "Чат")
                    .font(.system(size: 15.5, weight: .bold)).foregroundStyle(YMColor.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("●").font(.system(size: 9)).foregroundStyle(YMColor.statusDone)
                    Text("онлайн · обычно отвечает за 2 мин")
                        .font(.system(size: 11)).foregroundStyle(YMColor.muted)
                }
            }
        }
    }

    // Плашка привязки к заказу «№… · В пути» + состав·сумма
    private var orderLinkPlate: some View {
        HStack(spacing: YMSpace.sm) {
            StatusDot(color: OrderFlow.color(vm.order?.status),
                      pulsing: OrderFlow.isEnRoute(vm.order?.status), size: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("Заказ №\(vm.order?.dailyNumber ?? orderId) · \(OrderStatus.label(vm.order?.status))")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.text)
                if let o = vm.order {
                    Text("\(o.items?.count ?? 0) поз. · \(Money.format(Money.parse(o.total)))")
                        .font(.system(size: 11.5)).foregroundStyle(YMColor.muted)
                }
            }
            Spacer()
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.vertical, YMSpace.md)
        .background(YMColor.surface)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: YMSpace.sm) {
                    if vm.loading && vm.messages.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in SkeletonBox().frame(height: 40) }
                            .padding(.horizontal, YMSpace.lg)
                    } else if vm.messages.isEmpty {
                        Text("Напишите первое сообщение заведению")
                            .font(YMFont.callout).foregroundStyle(YMColor.muted)
                            .padding(.top, 48)
                    } else {
                        ForEach(Array(vm.messages.enumerated()), id: \.element.stableId) { idx, m in
                            if let sep = daySeparator(before: idx) { dateChip(sep) }
                            ChatBubble(message: m).id(m.stableId)
                        }
                    }
                }
                .padding(.horizontal, YMSpace.lg)
                .padding(.vertical, YMSpace.md)
            }
            .onChange(of: vm.messages.count) { _ in
                guard let last = vm.messages.last else { return }
                withAnimation(YMMotion.adaptive(YMMotion.spring, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(last.stableId, anchor: .bottom)
                }
            }
        }
    }

    // Поле ввода + вложение (+фото) + золотая кнопка отправки
    private var inputBar: some View {
        HStack(spacing: YMSpace.sm) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 1, matching: .images) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(YMColor.muted)
                    .frame(width: 40, height: 40)
                    .background(YMColor.surface2, in: Circle())
            }
            .accessibilityLabel("Прикрепить фото")

            HStack {
                TextField("Сообщение…", text: $draft, axis: .vertical)
                    .font(YMFont.body).foregroundStyle(YMColor.text)
                    .lineLimit(1...4)
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))

            Button {
                let text = draft; draft = ""
                Task { await vm.send(text) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .heavy)).foregroundStyle(YMColor.onAccent)
                    .frame(width: 40, height: 40)
                    .background(YMColor.accent, in: Circle())
                    .shadow(color: YMPalette.gold.opacity(0.5), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.sending)
            .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            .accessibilityLabel("Отправить")
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.vertical, YMSpace.sm)
        .background(.ultraThinMaterial)
        .onChange(of: photoItems) { _ in
            guard let item = photoItems.first else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await vm.sendPhoto(data)
                }
                photoItems = []
            }
        }
    }

    // MARK: Разделители дат

    /// Метка-разделитель перед сообщением idx, если день отличается от предыдущего.
    private func daySeparator(before idx: Int) -> String? {
        guard idx < vm.messages.count, let d = chatDate(vm.messages[idx].createdAt) else { return nil }
        if idx == 0 { return dayLabel(d) }
        guard let prev = chatDate(vm.messages[idx - 1].createdAt) else { return dayLabel(d) }
        return Calendar.current.isDate(d, inSameDayAs: prev) ? nil : dayLabel(d)
    }

    private func dateChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(YMColor.muted)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(YMColor.surface2, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    /// Парсинг серверного времени: MySQL datetime "yyyy-MM-dd HH:mm:ss" или ISO8601.
    private func chatDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, !s.hasPrefix("local-") else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        return f.string(from: date)
    }
}

// MARK: - ChatBubble (пузырь сообщения)

/// Пузырь сообщения. Мои — золотые (радиус 16/16/4/16, тики ✓✓), их — surface.
/// Появление — ym-in (fade + slide), деградирует при Reduce Motion.
private struct ChatBubble: View {
    let message: ChatMessage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// «Моё» сообщение — из серверного поля mine (fallback на строку sender для совместимости).
    private var mine: Bool {
        if let m = message.mine { return m }
        let s = (message.sender ?? "").lowercased()
        return s == "client" || s == "customer" || s == "me" || s == "user"
    }
    private var hasText: Bool { !((message.message ?? "").isEmpty) }
    private var hasImage: Bool { message.localImage != nil || !((message.attachment ?? "").isEmpty) }

    // Асимметричные углы: мои 16/16/4/16, их 16/16/16/4.
    private var corners: RoundedCorner {
        mine ? RoundedCorner(tl: 16, tr: 16, bl: 16, br: 4)
             : RoundedCorner(tl: 16, tr: 16, bl: 4, br: 16)
    }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 6) {
                    if hasImage { bubbleImage }
                    if hasText {
                        Text(message.message ?? "")
                            .font(YMFont.body)
                            .foregroundStyle(mine ? YMColor.onAccent : YMColor.text)
                    }
                }
                .padding(hasImage ? 4 : 9)
                .padding(.horizontal, hasImage ? 0 : 4)
                .background(mine ? YMColor.accent : YMColor.surface)
                .clipShape(corners)
                .overlay(mine ? nil : corners.strokeBorder(YMColor.hairline, lineWidth: 1))

                HStack(spacing: 4) {
                    if mine, message.localState == "failed" {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(YMColor.statusCancel)
                    }
                    Text(DateFmt.time(message.createdAt))
                        .font(.system(size: 10.5)).foregroundStyle(YMColor.muted)
                    if mine, message.localState == "sending" {
                        Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(YMColor.muted)
                    } else if mine, message.localState == nil {
                        Text(message.read == true ? "✓✓" : "✓")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(message.read == true ? YMColor.accent : YMColor.muted)
                    }
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.28)) { appeared = true }
        }
    }

    /// Фото в пузыре: локальное превью (при отправке) или загрузка по URL.
    @ViewBuilder private var bubbleImage: some View {
        Group {
            if let data = message.localImage, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if let url = API.imageURL(message.attachment) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .failure:          ZStack { Color(.secondarySystemBackground); Image(systemName: "photo").foregroundStyle(YMColor.muted) }
                    default:                ZStack { Color(.secondarySystemBackground); ProgressView() }
                    }
                }
            }
        }
        .frame(width: 220, height: 220)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - RoundedCorner (асимметричные скругления пузырей)

/// Прямоугольник с индивидуальными радиусами углов (для пузырей чата 16/16/4/16).
struct RoundedCorner: Shape, InsettableShape {
    var tl: CGFloat = 0, tr: CGFloat = 0, bl: CGFloat = 0, br: CGFloat = 0
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var p = Path()
        let (w, h) = (r.width, r.height)
        let tl = min(min(self.tl, h/2), w/2)
        let tr = min(min(self.tr, h/2), w/2)
        let bl = min(min(self.bl, h/2), w/2)
        let br = min(min(self.br, h/2), w/2)
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var c = self; c.insetAmount += amount; return c
    }
}
