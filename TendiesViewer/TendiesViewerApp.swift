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
