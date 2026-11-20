import Foundation
@main struct AppCatalogTests {
    static func main() async throws {
        func query(_ input: String) throws -> [String:String] {
            let url = try AppCatalog.endpoint(input, country: "US")
            precondition(url.scheme == "https" && url.host == "itunes.apple.com")
            return Dictionary(uniqueKeysWithValues:URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.map { ($0.name,$0.value!) })
        }
        let q0 = try query("  Example App  "); precondition(q0["term"] == "Example App")
        let q1 = try query("123"); precondition(q1["id"] == "123")
        let q2 = try query("invalid.example.app"); precondition(q2["bundleId"] == "invalid.example.app")
        let q3 = try query("https://apps.apple.com/us/app/example/id123?mt=8"); precondition(q3["id"] == "123")
        let q4 = try query("https://itunes.apple.com/app/id123/"); precondition(q4["id"] == "123")
        for input in ["", "https://example.invalid/app/id123", "https://apps.apple.com.evil.invalid/app/id123", "https://apps.apple.com/app/idABC", "file:///app/id123"] {
            do { _ = try AppCatalog.endpoint(input,country:"us"); preconditionFailure("Unsafe or empty query accepted") }
            catch is CatalogFailure { }
        }
        do { _ = try AppCatalog.endpoint("App",country:"../"); preconditionFailure("Bad country accepted") } catch is CatalogFailure { }
        let old = Data(#"{"trackId":123,"trackName":"Fixture","bundleId":"invalid.example.fixture"}"#.utf8)
        let legacy = try JSONDecoder().decode(AppResult.self,from:old)
        precondition(legacy.appDescription == nil && legacy.sizeText == nil && legacy.priceText == "价格未提供")
        let sample = Data(#"{"trackId":123,"trackName":"Fixture","bundleId":"invalid.example.fixture","fileSizeBytes":1048576,"averageUserRating":4.7,"price":0,"description":"Example description","releaseNotes":"Example update","artworkUrl60":"http://example.invalid/a.png","artworkUrl512":"https://example.invalid/b.png","screenshotUrls":["file:///tmp/no.png","https://example.invalid/s.png","https://example.invalid/s.png"],"ipadScreenshotUrls":["https://example.invalid/t.png"],"minimumOsVersion":"16.0"}"#.utf8)
        let app = try JSONDecoder().decode(AppResult.self,from:sample)
        precondition(app.fileSizeBytes == "1048576" && app.sizeText != nil && app.priceText == "免费")
        precondition(app.ratingText == "4.7" && app.previews.count == 2 && app.iconURL?.scheme == "https")
        let roundtrip = try JSONDecoder().decode(AppResult.self,from:JSONEncoder().encode(app))
        precondition(roundtrip == app)
        let malformed = Data(#"{"trackId":123,"trackName":"Fixture","bundleId":"invalid.example.fixture","fileSizeBytes":{},"screenshotUrls":4,"averageUserRating":9}"#.utf8)
        let partial = try JSONDecoder().decode(AppResult.self,from:malformed)
        precondition(partial.ratingText == nil && partial.sizeText == nil && partial.previews.isEmpty)
        print("PASS catalog: query/link validation, fixed Apple endpoint, legacy records, optional metadata, byte counts, HTTPS artwork, screenshot deduplication and roundtrip")
        if CommandLine.arguments.contains("--live") {
            let results = try await AppCatalog.search("Netflix",country:"us")
            guard let first=results.first else { preconditionFailure("Public search empty") }
            let details = try await AppCatalog.detail(first.id,country:"us")
            precondition(details.id==first.id && !details.bundleId.isEmpty)
            print("PASS public lookup: results=\(results.count), screenshots=\(details.previews.count), description=\(details.appDescription != nil), size=\(details.sizeText != nil), rating=\(details.ratingText != nil)")
        }
    }
}
