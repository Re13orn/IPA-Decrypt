import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct AppArtwork: View {
    let app: AppResult
    var size: CGFloat = 56
    var body: some View {
        AsyncImage(url: size > 80 ? app.iconURL : app.thumbnailURL) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { ZStack { Color.secondary.opacity(0.08); Image(systemName: "app.dashed").font(.system(size: size * 0.4)).foregroundStyle(.secondary) } }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

struct AppListingLabel: View {
    let app: AppResult
    private var metadata: String {
        var parts: [String] = []
        if let version = app.version { parts.append("v" + version) }
        if let size = app.sizeText { parts.append(size) }
        if let rating = app.ratingText { parts.append("★ " + rating) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 12) {
            AppArtwork(app: app)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.trackName).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(app.categoryText ?? app.bundleId).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(metadata)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScreenshotSelection: Identifiable { let url: URL; var id: URL { url } }

@MainActor struct AppDetailView: View {
    @ObservedObject var model: LocalLab
    let selection: AppSelection
    let onDownload: (AppResult) -> Void
    let onVersions: (AppResult) -> Void
    let onAcquire: (AppResult) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var details: AppResult?
    @State private var loading = false
    @State private var problem: String?
    @State private var expandedDescription = false
    @State private var expandedNotes = false
    @State private var viewing: ScreenshotSelection?
    @State private var tabletPreviews = false
    private var transferBusy: Bool {
        #if os(macOS)
        false
        #else
        model.action != nil
        #endif
    }
    private var app: AppResult { details ?? selection.app }
    private var storeURL: URL { URL(string: "https://apps.apple.com/\(selection.country.lowercased())/app/id\(app.id)")! }
    private var previewURLs: [URL] {
        let raw = tabletPreviews || (app.screenshotUrls ?? []).isEmpty ? app.ipadScreenshotUrls ?? [] : app.screenshotUrls ?? []
        var seen = Set<URL>()
        return raw.compactMap { URL(string: $0) }.filter { $0.scheme == "https" && $0.host != nil && seen.insert($0).inserted }
    }
    private var surface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
    private var background: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if loading { ProgressView("正在读取应用详情…").frame(maxWidth: .infinity) }
                if let problem {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        Button("重新加载") { Task { await load() } }
                    }.font(.callout)
                }
                if !app.previews.isEmpty { previews }
                if let notes = app.releaseNotes, !notes.isEmpty { update(notes) }
                if let text = app.appDescription, !text.isEmpty { description(text) }
                information
                Text("详情来自 \(Storefronts.name(selection.country)) App Store。商店标示大小与实际下载 IPA 大小可能不同，下载权限由登录账户决定。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .background(background)
        .navigationTitle("应用详情")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: selection.id) { await load() }
        .sheet(item: $viewing) { item in
            VStack(spacing: 12) {
                HStack { Spacer(); Button("关闭") { viewing = nil } }.padding()
                AsyncImage(url: item.url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else if phase.error != nil { Label("截图暂不可用", systemImage: "photo") }
                    else { ProgressView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.bottom)
            #if os(macOS)
            .frame(width: 700, height: 740)
            #endif
        }
    }
    private var header: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                AppArtwork(app: app, size: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.trackName).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    if let developer = app.artistName ?? app.sellerName { Text(developer).font(.subheadline).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        if let version = app.version { Text("版本 " + version) }
                        Text(app.priceText)
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("下载 IPA") { onDownload(app) }.buttonStyle(.borderedProminent)
                        Menu {
                            if app.price == 0 { Button("获取免费授权") { onAcquire(app) }.disabled(model.action != nil) }
                            Button("复制 App ID") { copy(String(app.id)) }
                            Button("复制 Bundle ID") { copy(app.bundleId) }
                            ShareLink(item: storeURL) { Label("分享商店链接", systemImage: "square.and.arrow.up") }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 32, minHeight: 32) }
                    }.disabled(transferBusy)
                }
                Spacer(minLength: 0)
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 16) {
                metric("评分", app.ratingText ?? "未评分", app.ratingCountText ?? "")
                metric("商店大小", app.sizeText ?? "未提供", "")
                metric("兼容性", app.minimumOsVersion.map { $0 + "+" } ?? "未提供", "iOS")
                metric("类别", app.categoryText ?? "未提供", "")
            }
            Divider()
            HStack {
                Label("历史版本", systemImage: "clock.arrow.circlepath").font(.subheadline.weight(.medium))
                Spacer()
                Button("选择版本", systemImage: "chevron.right") { onVersions(app) }.font(.subheadline)
            }.disabled(model.action != nil)
            HStack {
                Text("下载账户")
                Spacer()
                Text(model.activeProfile(beta: false)?.email ?? "尚未登录").lineLimit(1).truncationMode(.middle)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private func metric(_ title: String, _ value: String, _ footnote: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            if !footnote.isEmpty { Text(footnote).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .top)
    }
    private var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预览").font(.title3.bold())
                Spacer()
                if !(app.screenshotUrls ?? []).isEmpty && !(app.ipadScreenshotUrls ?? []).isEmpty {
                    Picker("截图设备", selection: $tabletPreviews) { Text("iPhone").tag(false); Text("iPad").tag(true) }
                        .pickerStyle(.segmented).frame(maxWidth: 160)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(previewURLs.enumerated()), id: \.offset) { index, url in
                        Button { viewing = ScreenshotSelection(url: url) } label: {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image { image.resizable().scaledToFit() }
                                else if phase.error != nil { Image(systemName: "photo").foregroundStyle(.secondary) }
                                else { ProgressView() }
                            }.frame(width: tabletPreviews ? 300 : 176, height: 365)
                                .background(surface, in: RoundedRectangle(cornerRadius: 14))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).accessibilityLabel("查看第 \(index + 1) 张截图")
                    }
                }
            }
        }
    }
    private func update(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("本次更新").font(.title3.bold()); Spacer(); if let date = app.storeDate { Text(date).font(.caption).foregroundStyle(.secondary) } }
            if let version = app.version { Text("版本 " + version).font(.subheadline).foregroundStyle(.secondary) }
            Text(notes).font(.body).lineLimit(expandedNotes ? nil : 5).textSelection(.enabled)
            Button(expandedNotes ? "收起" : "展开更新说明") { expandedNotes.toggle() }.font(.subheadline)
        }
    }
    private func description(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关于此应用").font(.title3.bold())
            Text(text).font(.body).lineLimit(expandedDescription ? nil : 6).textSelection(.enabled)
            Button(expandedDescription ? "收起" : "展开应用介绍") { expandedDescription.toggle() }.font(.subheadline)
        }
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("信息").font(.title3.bold())
            VStack(spacing: 12) {
                info("App ID", String(app.id))
                info("Bundle ID", app.bundleId)
                if let seller = app.sellerName { Divider(); info("提供者", seller) }
                if let age = app.contentAdvisoryRating { Divider(); info("年龄分级", age) }
                if let languages = app.languageCodesISO2A, !languages.isEmpty {
                    Divider(); info("语言", Array(NSOrderedSet(array: languages.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 })) .compactMap { $0 as? String }.joined(separator: "、"))
                }
                Divider(); Link(destination: storeURL) { Label("在 App Store 查看", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(16).background(surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private func info(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 20) { Text(key).foregroundStyle(.secondary); Spacer(minLength: 0); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.subheadline)
    }
    private func load() async {
        loading = true; problem = nil
        defer { loading = false }
        do { let value = try await AppCatalog.detail(selection.app.id, country: selection.country); if !Task.isCancelled { details = value } }
        catch { if !Task.isCancelled { problem = model.friendly(error) } }
    }
    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
