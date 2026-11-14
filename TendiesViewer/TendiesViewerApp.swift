import SwiftUI

// App 入口：整个界面就是一个全屏 WKWebView，见 WebView.swift。
// 之前用 GeometryReader + .frame(geo) 会在启动时按竖屏尺寸定住，导致横屏后右侧留黑条。
// 现在直接让 WebView 铺满窗口并忽略安全区，尺寸由系统窗口决定，不再用启动时的 UIScreen 尺寸。

// 分享进来的 zip / .tendies / .tendiesx / .tendiex 文件：用户在“文件”或别处分享壁纸包到查看器时，
// 系统经 onOpenURL 把文件 URL 交给 App；这里读出数据交给 WebView，
// 由 WebView 转给网页里的 __nativeImportZip 导入成项目。
// zip 里装满 .tendies / .tendiesx / .tendiex，单个 .tendies / .tendiesx / .tendiex 也能直接分享进来。
final class IncomingFileStore: ObservableObject {
    struct PendingImport {
        let data: Data
        let filename: String
    }
    @Published var pending: PendingImport?

    func handleIncomingURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "zip" || ext == "tendies" || ext == "tendiesx" || ext == "tendiex" else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let filename = url.lastPathComponent.isEmpty ? "wallpapers.zip" : url.lastPathComponent
        // 主线程改 @Published，避免后台线程改 UI 状态。
        DispatchQueue.main.async { [weak self] in
            self?.pending = PendingImport(data: data, filename: filename)
        }
    }
}

@main
struct TendiesViewerApp: App {
    @StateObject private var incomingFile = IncomingFileStore()
    // 检查更新用的远端版本号：打开 App 就拉 version.json 比一次，有新版弹提示框。
    @State private var remoteVersion: RemoteVersion?

    var body: some Scene {
        WindowGroup {
            WebView(incomingFile: incomingFile)
                .ignoresSafeArea(.all, edges: .all)
                .onOpenURL { url in
                    incomingFile.handleIncomingURL(url)
                }
                .task {
                    remoteVersion = await UpdateChecker.checkForUpdate()
                }
                .updateAlert(remote: $remoteVersion)
        }
    }
}

// ---- 检查更新（原 UpdateChecker.swift 并进来：新文件不进工程会编不到） ----
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
    static let localTag = "V1.2"
    static let localNumber = 1.2

    /// 下载页上的 version.json 地址。
    static let versionURL = URL(string: "https://zylovehh.github.io/wallive-clone/version.json")!
    /// 点“去下载”跳去的下载页。
    static let downloadPageURL = URL(string: "https://zylovehh.github.io/wallive-clone/")!

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
