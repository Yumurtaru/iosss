import SwiftUI

//
//  OrgReviews.swift — секция «Отзывы» карточки организации (премиум-стиль YM*).
//  1:1 с Android OrgReviews.kt.
//
//  Данные грузит OrgViewModel: GET api/v1/shops/{slug}/reviews -> [Review].
//  Review (Net/Models.swift): ratingOverall: Int?, text, author, isVerified: Int?,
//                             createdAt, photos: [String]?, reply, replyAt.
//
//  Состояния: загрузка (скелет) / ошибка (мягкая плашка) / пусто / список.
//  Средний рейтинг и кол-во оценок — из ShopDetail (rating + reviewsCount), крупно над списком.
//  Деньги здесь не участвуют. NULL-безопасность всюду.
//

// MARK: - Сводка отзывов (встраивается в sheet OrgView; тап → отдельный экран ReviewsScreen)

struct OrgReviewsSection: View {
    /// Slug организации — ключ загрузки полного экрана отзывов.
    let slug: String
    let reviews: [Review]
    let loading: Bool
    let error: String?
    let avgRating: Double?
    let reviewsCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Нажимаемая строка «Отзывы · ★N · N отзывов ›» — push на полный экран.
            NavigationLink {
                ReviewsScreen(slug: slug, avgRating: avgRating, reviewsCount: reviewsCount)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Text("Отзывы")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    Spacer(minLength: 8)
                    let cnt = reviewsCount ?? 0
                    if cnt > 0 || (avgRating ?? 0) > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(YMColor.accent)
                            Text(fmtRating1(avgRating))
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(YMColor.text)
                            if cnt > 0 {
                                Text("· \(pluralReviews(cnt))")
                                    .font(.system(size: 13))
                                    .foregroundStyle(YMColor.muted)
                            }
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(YMColor.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Краткое превью: первые 2 отзыва (или состояние загрузки/пусто).
            Group {
                if loading {
                    VStack(spacing: 10) {
                        ForEach(0..<2, id: \.self) { _ in
                            SkeletonBox(radius: 16).frame(height: 96)
                        }
                    }
                } else if let e = error, !e.isEmpty {
                    ReviewsNotice(text: "Не удалось загрузить отзывы")
                } else if reviews.isEmpty {
                    ReviewsNotice(text: "Пока нет отзывов. Будьте первым!")
                } else {
                    VStack(spacing: 10) {
                        ForEach(reviews.prefix(2)) { r in OrgReviewCard(review: r) }
                    }
                    if reviews.count > 2 {
                        NavigationLink {
                            ReviewsScreen(slug: slug, avgRating: avgRating, reviewsCount: reviewsCount)
                        } label: {
                            Text("Все отзывы ›")
                                .font(.system(size: 14.5, weight: .bold))
                                .foregroundStyle(YMColor.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(YMColor.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Карточка отзыва

struct OrgReviewCard: View {
    let review: Review

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Звёзды + «проверенный».
            HStack(spacing: 8) {
                StarRow(rating: review.ratingOverall ?? 0)
                if (review.isVerified ?? 0) == 1 {
                    VerifiedBadge()
                }
            }

            if let t = review.text, !t.isEmpty {
                Text(t)
                    .font(.system(size: 14.5))
                    .foregroundStyle(YMColor.text)
                    .padding(.top, 8)
            }

            // Фото отзыва (горизонтальная лента).
            let photos = (review.photos ?? []).filter { !$0.isEmpty }
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { idx, ph in
                            PhotoPlaceholder(url: API.imageURL(ph),
                                             label: "ФОТО", radius: 12, tone: idx)
                                .frame(width: 84, height: 84)
                        }
                    }
                }
                .padding(.top, 10)
            }

            // Автор + дата.
            HStack {
                Text((review.author?.isEmpty == false ? review.author! : "Гость"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(YMColor.muted)
                Spacer(minLength: 8)
                if let d = review.createdAt, !d.isEmpty {
                    Text(fmtReviewDate(d))
                        .font(.system(size: 11.5))
                        .foregroundStyle(YMColor.muted)
                }
            }
            .padding(.top, 10)

            // Ответ организации (аддитивно): показываем, если продавец ответил.
            if let reply = review.reply, !reply.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ответ организации")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(YMColor.accent)
                    Text(reply)
                        .font(.system(size: 12))
                        .foregroundStyle(YMColor.text)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 10)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}

// MARK: - Ряд из 5 звёзд

struct StarRow: View {
    let rating: Int
    var size: CGFloat = 15

    var body: some View {
        let r = min(max(rating, 0), 5)
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < r ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i < r ? YMColor.accent : YMColor.muted)
            }
        }
    }
}

// MARK: - Бейдж «ПРОВЕРЕННЫЙ»

private struct VerifiedBadge: View {
    var body: some View {
        Text("ПРОВЕРЕННЫЙ")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(YMColor.statusDone)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(YMColor.statusDone.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Мягкая инфо-плашка (пусто / ошибка)

private struct ReviewsNotice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14.5))
            .foregroundStyle(YMColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22).padding(.horizontal, 16)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}

// MARK: - Хелперы

/// Средний рейтинг с одним знаком: 4 -> "4.0", 4.5 -> "4.5".
private func fmtRating1(_ r: Double?) -> String {
    let v = r ?? 0
    if v == v.rounded(.towardZero) { return "\(Int(v)).0" }
    return String(format: "%.1f", v)
}

/// Склонение «отзыв / отзыва / отзывов».
private func pluralReviews(_ n: Int) -> String {
    let mod10 = n % 10, mod100 = n % 100
    let word: String
    if mod10 == 1 && mod100 != 11 { word = "отзыв" }
    else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "отзыва" }
    else { word = "отзывов" }
    return "\(n) \(word)"
}

/// "2026-07-03 14:22:10" / "2026-07-03T14:22:10" -> "03.07.2026". Толерантно к формату.
private func fmtReviewDate(_ raw: String) -> String {
    let datePart = raw.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "T", with: " ")
        .split(separator: " ").first.map(String.init) ?? raw
    let p = datePart.split(separator: "-").map(String.init)
    if p.count == 3, p[0].count == 4 { return "\(p[2]).\(p[1]).\(p[0])" }
    return datePart
}
