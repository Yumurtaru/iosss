import SwiftUI

//
//  ReviewsScreen.swift — отдельный экран всех отзывов организации.
//  Открывается пушем из сводки «Отзывы (N) ›» на карточке организации (OrgView).
//
//  API: GET api/v1/shops/{slug}/reviews -> [Review].
//  Состояния: загрузка (скелет) / ошибка (повтор) / пусто / список.
//  Стиль — YMColor/YMFont, обе темы. Деньги здесь не участвуют. NULL-безопасность всюду.
//  Карточка отзыва — переиспользуем OrgReviewCard из OrgReviews.swift.
//

@MainActor
final class ReviewsScreenModel: ObservableObject {
    @Published var reviews: [Review] = []
    @Published var loading = true
    @Published var error: String?

    let slug: String
    /// Опорные значения сводки (чтобы шапка показала рейтинг/кол-во сразу).
    let avgRating: Double?
    let reviewsCount: Int?

    init(slug: String, avgRating: Double?, reviewsCount: Int?) {
        self.slug = slug
        self.avgRating = avgRating
        self.reviewsCount = reviewsCount
    }

    func load() async {
        guard !slug.isEmpty else { loading = false; error = "Нет данных заведения"; return }
        loading = true; error = nil
        do {
            reviews = try await API.shared.list("api/v1/shops/\(slug)/reviews")
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct ReviewsScreen: View {
    @StateObject private var vm: ReviewsScreenModel
    @Environment(\.dismiss) private var dismiss

    init(slug: String, avgRating: Double? = nil, reviewsCount: Int? = nil) {
        _vm = StateObject(wrappedValue: ReviewsScreenModel(
            slug: slug, avgRating: avgRating, reviewsCount: reviewsCount))
    }

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryHeader

                    if vm.loading {
                        VStack(spacing: 10) {
                            ForEach(0..<4, id: \.self) { _ in
                                SkeletonBox(radius: 16).frame(height: 96)
                            }
                        }
                    } else if let e = vm.error, !e.isEmpty {
                        errorBox(e)
                    } else if vm.reviews.isEmpty {
                        emptyBox
                    } else {
                        VStack(spacing: 10) {
                            ForEach(vm.reviews) { r in OrgReviewCard(review: r) }
                        }
                    }

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Отзывы")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    // Сводка: крупный рейтинг · кол-во отзывов.
    private var summaryHeader: some View {
        let cnt = vm.reviewsCount ?? (vm.reviews.isEmpty ? 0 : vm.reviews.count)
        let avg = vm.avgRating ?? 0
        return Group {
            if cnt > 0 || avg > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(YMColor.accent)
                    Text(fmtRatingHeader(avg))
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    if cnt > 0 {
                        Text(pluralReviewsHeader(cnt))
                            .font(.system(size: 14))
                            .foregroundStyle(YMColor.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)
            }
        }
    }

    private var emptyBox: some View {
        VStack(spacing: 8) {
            Text("⭐️").font(.system(size: 40))
            Text("Пока нет отзывов")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(YMColor.text)
            Text("Будьте первым, кто оставит отзыв")
                .font(.system(size: 13.5))
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorBox(_ message: String) -> some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(YMColor.muted)
            Text(message.isEmpty ? "Не удалось загрузить отзывы" : message)
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button("Повторить") { Task { await vm.load() } }
                .buttonStyle(YMSecondaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Хелперы шапки (локальные, чтобы не тянуть private из OrgReviews.swift)

private func fmtRatingHeader(_ r: Double) -> String {
    if r == r.rounded(.towardZero) { return "\(Int(r)).0" }
    return String(format: "%.1f", r)
}

private func pluralReviewsHeader(_ n: Int) -> String {
    let mod10 = n % 10, mod100 = n % 100
    let word: String
    if mod10 == 1 && mod100 != 11 { word = "отзыв" }
    else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "отзыва" }
    else { word = "отзывов" }
    return "\(n) \(word)"
}
