import Foundation

struct AppResult: Codable, Identifiable, Hashable {
    let trackId: UInt64
    let trackName: String
    let bundleId: String
    let version: String?
    let artworkUrl60: URL?
    let price: Double?
    var artworkUrl512: URL? = nil
    var artworkUrl100: URL? = nil
    var primaryGenreName: String? = nil
    var artistName: String? = nil
    var sellerName: String? = nil
    var appDescription: String? = nil
    var releaseNotes: String? = nil
    var averageUserRating: Double? = nil
    var userRatingCount: Int? = nil
    var fileSizeBytes: String? = nil
    var minimumOsVersion: String? = nil
    var contentAdvisoryRating: String? = nil
    var formattedPrice: String? = nil
    var currency: String? = nil
    var screenshotUrls: [String]? = nil
    var ipadScreenshotUrls: [String]? = nil
    var languageCodesISO2A: [String]? = nil
    var supportedDevices: [String]? = nil
    var currentVersionReleaseDate: String? = nil
    var id: UInt64 { trackId }
    var iconURL: URL? { [artworkUrl512, artworkUrl100, artworkUrl60].compactMap { $0 }.first { $0.scheme == "https" } }
    var thumbnailURL: URL? { [artworkUrl100, artworkUrl60, artworkUrl512].compactMap { $0 }.first { $0.scheme == "https" } }
    var sizeText: String? {
        guard let raw = fileSizeBytes, let bytes = Int64(raw), bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    var ratingText: String? {
        guard let rating = averageUserRating, rating.isFinite, rating > 0, rating <= 5 else { return nil }
        return String(format: "%.1f", rating)
    }
    var ratingCountText: String? {
        guard let count = userRatingCount, count >= 0 else { return nil }
        return count.formatted(.number.notation(.compactName)) + " 个评分"
    }
    var categoryText: String? {
        guard let category = primaryGenreName, !category.isEmpty else { return nil }
        let labels = ["Entertainment":"娱乐", "Photo & Video":"摄影与录像", "Finance":"财务", "Business":"商务", "Games":"游戏", "Social Networking":"社交", "Productivity":"效率", "Utilities":"工具", "Music":"音乐", "Lifestyle":"生活", "Health & Fitness":"健康与健身", "Education":"教育", "Books":"图书", "Reference":"参考", "Travel":"旅游", "Weather":"天气", "Navigation":"导航", "Sports":"体育", "Shopping":"购物", "News":"新闻", "Medical":"医疗", "Food & Drink":"美食佳饮", "Developer Tools":"开发工具", "Graphics & Design":"图形与设计"]
        return labels[category] ?? category
    }
    var priceText: String {
        if price == 0 { return "免费" }
        if let label = formattedPrice, !label.isEmpty { return label }
        return price.map { String(format: "%.2f", $0) + (currency.map { " " + $0 } ?? "") } ?? "价格未提供"
    }
    var previews: [URL] {
        var seen = Set<URL>()
        return ((screenshotUrls ?? []) + (ipadScreenshotUrls ?? [])).compactMap {
            guard let url = URL(string: $0), url.scheme == "https", url.host != nil, seen.insert(url).inserted else { return nil }
            return url
        }
    }
    var storeDate: String? {
        guard let raw = currentVersionReleaseDate, let date = ISO8601DateFormatter().date(from: raw) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    enum CodingKeys: String, CodingKey {
        case trackId, trackName, bundleId, version, artworkUrl60, price, artworkUrl512, artworkUrl100
        case primaryGenreName, artistName, sellerName, releaseNotes, averageUserRating, userRatingCount
        case fileSizeBytes, minimumOsVersion, contentAdvisoryRating, formattedPrice, currency
        case screenshotUrls, ipadScreenshotUrls, languageCodesISO2A, supportedDevices, currentVersionReleaseDate
        case appDescription = "description"
    }
}

extension AppResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(trackId: try c.decode(UInt64.self, forKey: .trackId), trackName: try c.decode(String.self, forKey: .trackName),
                  bundleId: try c.decode(String.self, forKey: .bundleId), version: try? c.decode(String.self, forKey: .version),
                  artworkUrl60: try? c.decode(URL.self, forKey: .artworkUrl60), price: try? c.decode(Double.self, forKey: .price))
        artworkUrl512 = try? c.decode(URL.self, forKey: .artworkUrl512)
        artworkUrl100 = try? c.decode(URL.self, forKey: .artworkUrl100)
        primaryGenreName = try? c.decode(String.self, forKey: .primaryGenreName)
        artistName = try? c.decode(String.self, forKey: .artistName)
        sellerName = try? c.decode(String.self, forKey: .sellerName)
        appDescription = try? c.decode(String.self, forKey: .appDescription)
        releaseNotes = try? c.decode(String.self, forKey: .releaseNotes)
        averageUserRating = try? c.decode(Double.self, forKey: .averageUserRating)
        userRatingCount = try? c.decode(Int.self, forKey: .userRatingCount)
        fileSizeBytes = (try? c.decode(String.self, forKey: .fileSizeBytes)) ?? (try? c.decode(Int64.self, forKey: .fileSizeBytes)).map(String.init)
        minimumOsVersion = try? c.decode(String.self, forKey: .minimumOsVersion)
        contentAdvisoryRating = try? c.decode(String.self, forKey: .contentAdvisoryRating)
        formattedPrice = try? c.decode(String.self, forKey: .formattedPrice)
        currency = try? c.decode(String.self, forKey: .currency)
        screenshotUrls = try? c.decode([String].self, forKey: .screenshotUrls)
        ipadScreenshotUrls = try? c.decode([String].self, forKey: .ipadScreenshotUrls)
        languageCodesISO2A = try? c.decode([String].self, forKey: .languageCodesISO2A)
        supportedDevices = try? c.decode([String].self, forKey: .supportedDevices)
        currentVersionReleaseDate = try? c.decode(String.self, forKey: .currentVersionReleaseDate)
    }
}

struct AppSelection: Identifiable, Hashable {
    let app: AppResult
    let country: String
    var id: String { "\(country)-\(app.id)" }
}

enum CatalogFailure: LocalizedError {
    case empty, country, link, response, unavailable
    var errorDescription: String? {
        switch self {
        case .empty: return "请输入名称、App ID、Bundle ID 或 App Store 链接。"
        case .country: return "请选择有效的商店地区。"
        case .link: return "请输入有效的 App Store 应用链接。"
        case .response: return "暂时无法读取 App Store，请稍后重试。"
        case .unavailable: return "此应用在所选地区暂未提供公开详情。"
        }
    }
}

enum AppCatalog {
    static func endpoint(_ input: String, country: String) throws -> URL {
        guard country.utf8.count == 2, country.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw CatalogFailure.country }
        var term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw CatalogFailure.empty }
        if term.contains("://") {
            guard let link = URLComponents(string: term), ["https", "http"].contains(link.scheme?.lowercased() ?? ""),
                  ["apps.apple.com", "itunes.apple.com"].contains(link.host?.lowercased() ?? ""),
                  let part = link.path.split(separator: "/").last, part.hasPrefix("id"),
                  UInt64(part.dropFirst(2)).map({ $0 > 0 }) == true else { throw CatalogFailure.link }
            term = String(part.dropFirst(2))
        }
        let identifier = UInt64(term).flatMap { $0 > 0 ? $0 : nil }
        let bundle = term.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
        var url = URLComponents()
        url.scheme = "https"; url.host = "itunes.apple.com"
        url.path = identifier != nil || bundle ? "/lookup" : "/search"
        url.queryItems = [.init(name: "country", value: country.lowercased()), .init(name: "entity", value: "software"),
                          .init(name: "limit", value: "25"),
                          .init(name: identifier != nil ? "id" : bundle ? "bundleId" : "term", value: term)]
        guard let endpoint = url.url else { throw CatalogFailure.link }
        return endpoint
    }
    static func search(_ input: String, country: String) async throws -> [AppResult] {
        let url = try endpoint(input, country: country)
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 25))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw CatalogFailure.response }
        try Task.checkCancellation()
        struct Listing: Decodable { let results: [AppResult] }
        return try JSONDecoder().decode(Listing.self, from: data).results
    }
    static func detail(_ id: UInt64, country: String) async throws -> AppResult {
        guard let app = try await search(String(id), country: country).first(where: { $0.id == id }) else { throw CatalogFailure.unavailable }
        return app
    }
}
