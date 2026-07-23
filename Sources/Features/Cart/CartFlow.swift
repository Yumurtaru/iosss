import SwiftUI

//
//  CartFlow.swift — контейнер флоу корзины (Корзина → Оформление → Успех).
//
//  Собирает три самодостаточных экрана в один NavigationStack и связывает их
//  готовыми колбэками (onCheckout / onSuccess / onBack / onTrack / onHome):
//
//    CartView(onCheckout:onClose:)
//      → CheckoutView(onSuccess: (OrderCreateResult) -> Void, onBack:)
//        → SuccessView(order:, onTrack:, onHome:)
//
//  Показывается ГЛОБАЛЬНО из RootTabView как fullScreenCover (доступ к корзине
//  из любого места: StickyCartBar в Org, badge и т.п.). Контракт API не трогаем —
//  создание заказа делает CheckoutView сам.
//
//  Навигация наружу:
//    onClose          — закрыть весь флоу (‹ / «На главную» из пусто-состояния).
//    onTrackOrder(id) — «Следить за заказом»: родитель откроет таб «Заказы» + деталь.
//
struct CartFlow: View {
    /// Закрыть весь флоу корзины.
    var onClose: () -> Void
    /// Открыть трекинг заказа после успешного оформления.
    var onTrackOrder: (Int) -> Void

    private enum Step: Hashable { case checkout, success }

    @State private var path: [Step] = []
    // Результат создания заказа — источник данных для SuccessView.
    @State private var result: OrderCreateResult?

    var body: some View {
        NavigationStack(path: $path) {
            CartView(
                onCheckout: { path.append(.checkout) },
                onClose: { onClose() }
            )
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .checkout:
                    CheckoutView(
                        onSuccess: { r in
                            result = r
                            path.append(.success)
                        },
                        onBack: { if !path.isEmpty { path.removeLast() } }
                    )
                case .success:
                    successScreen
                        .navigationBarBackButtonHidden(true)
                }
            }
        }
    }

    @ViewBuilder private var successScreen: some View {
        if let r = result {
            SuccessView(
                order: r,
                onTrack: {
                    let id = r.resolvedId ?? 0
                    onClose()
                    onTrackOrder(id)
                },
                onHome: { onClose() }
            )
        } else {
            // Теоретически недостижимо: success пушится только после onSuccess.
            Color.clear.onAppear { onClose() }
        }
    }
}
