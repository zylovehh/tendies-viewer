// UpdateChecker.swift
// 检查更新：打开 App 时拉一下下载页上的 version.json，比版本号，
// 有新版就弹提示框，点“去下载”跳到下载页（https://zytendies.cc.cd/）。
// 侧载 App 自己装不了更新，只能跳网页让用户手动下新包再装。

import SwiftUI

/// 远端 version.json 的结构（放在下载页 docs/version.json 里）。
/// 顶层是壁纸匣那份，各 App 的号分节放：viewer / installer / editor。
/// 提示框要的就三个值：版本号、数字、下载页地址。
struct RemoteVersion: Decodable {
    let tag: String
    let number: Double
    let url: String
}

/// version.json 整份的结构，只取 viewer 这一节和顶层的 url。
private struct VersionFile: Decodable {
    struct Section: Decodable {
        let tag: String
        let number: Double
    }
    let viewer: Section?
    let url: String?
}

enum UpdateChecker {
    /// 本版的对外版本号（下载页/version.json 里 viewer 那节的号）。
    /// 发新版时这里和 version.json 一起 +0.1，不然新版装上还会弹“有新版本”。
    static let localTag = "V1.1"
    static let localNumber = 1.1

    /// 下载页上的 version.json 地址。
    static let versionURL = URL(string: "https://zylovehh.github.io/wallive-clone/version.json")!
    /// 点“去下载”跳去的下载页。
    static let downloadPageURL = URL(string: "https://zytendies.cc.cd/")!

    /// 拉 version.json，比版本号。有新版就回传远端信息，没有新版回传 nil。
    /// 拉不到（没网、文件没了）就当没新版，不报错、不打扰。
    static func checkForUpdate() async -> RemoteVersion? {
        do {
            let (data, _) = try await URLSession.shared.data(from: versionURL)
            let file = try JSONDecoder().decode(VersionFile.self, from: data)
            guard let section = file.viewer else { return nil }
            if section.number > localNumber {
                return RemoteVersion(tag: section.tag, number: section.number, url: file.url ?? downloadPageURL.absoluteString)
            }
            return nil
        } catch {
            return nil
        }
    }
}

/// 更新提示框：有新版时弹出来，点“去下载”跳下载页，点“以后再说”关掉。
struct UpdateAlertModifier: ViewModifier {
    @Binding var remote: RemoteVersion?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .alert("有新版本", isPresented: Binding(
                get: { remote != nil },
                set: { if !$0 { remote = nil } }
            )) {
                Button("去下载") {
                    if let url = URL(string: remote?.url ?? UpdateChecker.downloadPageURL.absoluteString) {
                        openURL(url)
                    }
                    remote = nil
                }
                Button("以后再说", role: .cancel) {
                    remote = nil
                }
            } message: {
                Text("新版本 \(remote?.tag ?? "") 已发布，点“去下载”到下载页拿新包，再用 AltStore / SideStore 装一次。")
            }
    }
}

extension View {
    func updateAlert(remote: Binding<RemoteVersion?>) -> some View {
        modifier(UpdateAlertModifier(remote: remote))
    }
}
