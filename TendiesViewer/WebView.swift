import SwiftUI
import UIKit
import WebKit
import Combine

// 全屏 WKWebView：只加载 Bundle 里的 index.html，编辑器完全离线跑。
// （JSZip 已换成本地 TendiesViewer/jszip.min.js，不走 CDN，断网也能导出。）
//
// 关键点，缺一不可：
// 1. 选图：网页里的 <input type="file" accept="image/*"> 由 WKWebView 原生接管，
//    iPad 上会弹出系统相册选图框（PHPicker），不需要 App 自己再写一个选图器，
//    前提是 Info.plist 里有 NSPhotoLibraryUsageDescription（已加，全中文文案）。
//    不要用自定义 JS 弹框代替系统选图框，那样拿不到相册原图。
// 2. 导出下载（旧路径，保留）：WKWebView 默认不支持 blob 下载，不拦截就会悄悄失败。
//    下面用 WKNavigationDelegate + WKDownloadDelegate 接管：未知 MIME 类型走
//    .download，下载完成存到临时目录，再弹系统分享单（UIActivityViewController），
//    用户可存到“文件”、隔空投送、或直接用 Pocket Poster / Nugget 打开。
//    网页内原有导出逻辑（JSZip 打包 .tendies、生成 blob、触发下载）原样保留，
//    这里只是把浏览器做不了的那一步在原生层补上，不是假按钮。
// 3. 导出消息桥（新路径，tendiesExport）：网页侧导出后会尝试
//    webkit.messageHandlers.tendiesExport.postMessage，分块发 base64 编码的
//    .tendies 数据；如果 App 没注册这个桥，网页会退回“分享 / 保存到文件”和
//    “重新下载”按钮那条路。本文件注册了这个桥，两种导出路径都要能走，
//    互不冲突：走桥的导出不再经过 WKDownloadDelegate，走下载的导出不受桥影响。
//    注意：网页侧分块字段的精确约定（见下面“桥接约定（假设）”）在本机无法
//    向网页侧最新版核对，因为网页版本身由另一个系统负责、这里不碰它。
//    下面实现按宽容解析写，兼容几种合理字段名，但真机上仍需与网页侧逐项对齐。
// 4. 手势：编辑器画布的拖动、双指捏合由网页内 pointer 事件处理，
//    WKWebView 的滚动视图不拦截画布手势；UIRequiresFullScreen = true
//    已在 Info.plist 里打开，避免 iPad 分屏 / Slide Over 把三栏压窄，
//    也避免系统边缘手势和编辑器拖动抢手势。右侧检查器自身的滚动仍正常。
struct WebView: UIViewRepresentable {
    @ObservedObject var incomingFile: IncomingFileStore

    func makeUIView(context: Context) -> WKWebView {
        // 装好 App 先在本地文件夹里生成储存结构：Projects 目录 + meta/projects.json（空数组），
        // 后面项目、图层、图片都往这里写，不用等第一次保存时再现建目录。
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            if let docs = docs {
                let base = docs.appendingPathComponent("Projects")
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let metaDir = base.appendingPathComponent("meta")
                try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
                let projectsFile = metaDir.appendingPathComponent("projects.json")
                if !FileManager.default.fileExists(atPath: projectsFile.path) {
                    try Data("[]".utf8).write(to: projectsFile, options: .atomic)
                }
            }
        } catch {}

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // JavaScript 默认就是开的，这里显式写明，免得以后 SDK 默认变了。
        config.preferences.javaScriptEnabled = true
        // 本地文件访问：index.html 在 Bundle 里，JSZip 也是本地文件，
        // 导出 .tendies 时 JS 要读写内存里的图片数据，不走网络。
        // 本地文件访问靠下面 loadFileURL 的 allowingReadAccessTo（Bundle 目录）实现，
        // 不再用 setValue 私有键：WKWebViewConfiguration 在新系统上对这两个键不是 KVC 兼容，
        // 启动时直接抛异常闪退，之前 iPhone 点开闪退最可能就是这两行。
        // 原生消息桥必须在 loadFileURL 之前注册，否则网页加载时发的第一条
        // 消息会因为桥还没注册而丢掉。名字必须 exactly 是 tendiesExport，
        // 网页侧按这个名字找，拼写差一个字母网页就会判定桥不存在而走回退路。
        config.userContentController.add(context.coordinator, name: "tendiesExport")
        config.userContentController.add(context.coordinator, name: "tendiesLocal")
        config.userContentController.add(context.coordinator, name: "tendiesShare")

        // cap 协议必须在 WKWebView 创建前注册：WKWebView 创建时拷贝配置，
        // 创建后再往 config 里加 handler 对已建好的 webView 不生效，cap:// 请求
        // 就会直接失败、屏幕一直白，这就是上一版白屏的直接原因。
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "cap")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // 画布手势不被滚动视图抢走：编辑器面板自身的滚动不受影响，
        // 画布元素在网页里已用 touch-action: none 接管拖动和捏合。
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        // 原版 CAPlayground 静态导出：用 cap:// 本地协议跑，不用 file://。
        // file:// 下 /_next/ 这种绝对路径读不到包里文件，cap:// 全部走下面的
        // WKURLSchemeHandler，按路径从 Bundle 的 caplayground/ 目录取文件，
        // /editor/任何新项目号都回落到 editor/demo.html，客户端再按 URL 里的
        // 真实项目号从 localStorage 取项目，路由才不会 404。
        // 查看器版：优先走 cap://app/viewer.html（壁纸查看器入口）。
        if let url = URL(string: "cap://app/viewer.html") {
            webView.load(URLRequest(url: url))
        } else if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // 分享进来的文件由 Coordinator 转给网页：先记下 webView，再开始监听。
        context.coordinator.hostWebView = webView
        context.coordinator.startObservingIncomingFile()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 横屏全屏关键：不要用启动时的 UIScreen 尺寸，始终铺满父视图（窗口）。
        // SwiftUI 的 UIViewRepresentable 在旋转时不会自动改 frame，这里强制跟父视图走。
        if let parent = uiView.superview, uiView.frame != parent.bounds {
            uiView.frame = parent.bounds
            uiView.scrollView.frame = uiView.bounds
        }
        uiView.scrollView.contentInset = .zero
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(incomingFile: incomingFile)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        // MARK: - 分享导入（native → web）：用户分享 zip / .tendies 到 App 时走这里
        //
        // 流程：系统 onOpenURL → IncomingFileStore.pending → 这里收到后，
        // 先回到查看器页（cap://app/viewer.html，__nativeImportZip 只在
        // 查看器页定义），等页面加载完再把文件 base64 发给网页导入。
        // 网页侧导入成功会刷新图库，失败会弹中文提示。
        weak var hostWebView: WKWebView?
        let incomingFile: IncomingFileStore
        private var cancellables = Set<AnyCancellable>()
        private var observingIncomingFile = false

        init(incomingFile: IncomingFileStore) {
            self.incomingFile = incomingFile
            super.init()
        }

        func startObservingIncomingFile() {
            guard !observingIncomingFile else { return }
            observingIncomingFile = true
            incomingFile.$pending
                .receive(on: DispatchQueue.main)
                .sink { [weak self] pending in
                    guard pending != nil else { return }
                    self?.requestDeliverPendingImport()
                }
                .store(in: &cancellables)
        }

        // 收到分享文件：回到查看器页再导入。查看器页的 useEffect 会定义
        // window.__nativeImportZip；如果已经在查看器页，重载一次也无害
        // （只是重新渲染图库，不丢数据）。
        private func requestDeliverPendingImport() {
            guard let hostWebView = hostWebView else { return }
            if let url = URL(string: "cap://app/viewer.html") {
                hostWebView.load(URLRequest(url: url))
            }
            // 真正的发送在 webView(_:didFinish:) 里做（页面加载完才有桥）。
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 页面加载完：如果有待导入的分享文件，现在发给网页。
            guard incomingFile.pending != nil else { return }
            deliverPendingImport()
        }

        // 发给网页前先确认桥已定义（React 还没挂载完时桥不存在）。
        // 没定义就隔 0.5 秒重试，最多约 5 秒；超时则清掉待导入并提示用户
        // 去查看器里手动导入，避免文件悄悄丢了用户却不知道。
        private func deliverPendingImport(attempt: Int = 0) {
            guard let hostWebView = hostWebView, let pending = incomingFile.pending else { return }
            hostWebView.evaluateJavaScript("typeof window.__nativeImportZip === 'function'") { [weak self] result, _ in
                guard let self = self else { return }
                let isReady = (result as? Bool) == true
                if isReady {
                    // 先清掉 pending，免得重试时重复导入出两个项目。
                    self.incomingFile.pending = nil
                    let base64 = pending.data.base64EncodedString()
                    // base64 只含 A-Za-z0-9+/=，单引号里是安全的；文件名要转义。
                    let safeFilename = pending.filename
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    let js = "window.__nativeImportZip('\(base64)', '\(safeFilename)')"
                    hostWebView.evaluateJavaScript(js, completionHandler: nil)
                } else if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard self?.incomingFile.pending != nil else { return }
                        self?.deliverPendingImport(attempt: attempt + 1)
                    }
                } else {
                    self.incomingFile.pending = nil
                    self.showBridgeError("没有收到分享的文件，请在查看器里点“导入壁纸包 ZIP”重新选一次。")
                }
            }
        }

        // MARK: - cap:// 本地协议：把静态导出文件从 Bundle 里喂给 WKWebView
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(NSError(domain: "cap", code: -1, userInfo: nil))
                return
            }
            // 新存储（请求式）：cap://app/storage/{save,load,list,delete}，JS 用 fetch 发请求，
            // 不再走 WKScriptMessage + evaluateJavaScript 回话。写文件先写临时文件再改名（原子写），
            // 写完读回大小回给 JS 校验；读不到回 404（JS 据此区分“文件缺失”和“存储不可用”）。
            if url.path.hasPrefix("/storage/") {
                handleNativeStorage(urlSchemeTask: urlSchemeTask)
                return
            }
            // App 本地储存直供图：cap://app/local/<项目号>/<文件路径>
            // 从 Documents/Projects 取文件、按扩展名给正确类型，不走浏览器存储和 blob。
            if url.path.hasPrefix("/local/") {
                let rel = String(url.path.dropFirst("/local/".count))
                let parts = rel.split(separator: "/").map { String($0) }
                if parts.count >= 2 {
                    let projectId = parts[0]
                    let fileRel = parts.dropFirst().joined(separator: "/")
                    let safeProject = projectId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                    let safeRel = fileRel.split(separator: "/").filter { $0 != "" && $0 != "." && $0 != ".." }.joined(separator: "/")
                    if !safeProject.isEmpty && !safeRel.isEmpty,
                       let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        let file = docs.appendingPathComponent("Projects").appendingPathComponent(safeProject).appendingPathComponent(safeRel)
                        if let data = try? Data(contentsOf: file) {
                            let ext = (safeRel as NSString).pathExtension.lowercased()
                            let mime: String
                            switch ext {
                            case "png": mime = "image/png"
                            case "jpg", "jpeg": mime = "image/jpeg"
                            case "webp": mime = "image/webp"
                            case "gif": mime = "image/gif"
                            case "svg": mime = "image/svg+xml"
                            case "bmp": mime = "image/bmp"
                            case "mp4": mime = "video/mp4"
                            case "mov": mime = "video/quicktime"
                            default: mime = "application/octet-stream"
                            }
                            if let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count)]) {
                                urlSchemeTask.didReceive(resp); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish(); return
                            }
                        }
                    }
                }
                if let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) {
                    urlSchemeTask.didReceive(resp); urlSchemeTask.didFinish()
                }
                return
            }
            // Next 客户端路由取 RSC 数据：静态包里只有 demo 页的 RSC。
            // /editor/ 新项目号先回 demo.txt（同页 RSC），让客户端路由能渲染编辑器页，
            // 编辑器页再按 URL 里的真实项目号从本机存储取项目；其他路径有对应 txt
            // 就回对应 txt，实在没有才 404 退回整页导航。
            if let q = url.query, q.contains("_rsc") {
                if url.path.hasPrefix("/editor/") {
                    let demoTxt = Bundle.main.resourceURL?.appendingPathComponent("caplayground/editor/demo.txt")
                    if let d = demoTxt, let data = try? Data(contentsOf: d),
                       let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/x-component", "Content-Length": String(data.count)]) {
                        urlSchemeTask.didReceive(resp); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish(); return
                    }
                }
                let txtPath = String(url.path.dropFirst()) + ".txt"
                if let b = Bundle.main.resourceURL?.appendingPathComponent("caplayground"),
                   let data = try? Data(contentsOf: b.appendingPathComponent(txtPath)),
                   let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/x-component", "Content-Length": String(data.count)]) {
                    urlSchemeTask.didReceive(resp); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish(); return
                }
                if let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) {
                    urlSchemeTask.didReceive(resp); urlSchemeTask.didFinish()
                }
                return
            }
            var path = url.path
            if path.isEmpty || path == "/" { path = "/projects.html" }
            // 文件夹引用在包里是一个目录，url(forResource:) 找不到目录会返回 nil，
            // 原版 serve 在 base 为 nil 时直接 return、不回 404，请求就永远挂起、
            // 屏幕一直白。改走 resourceURL 拼目录，找不到时也要回 404，别静默挂起。
            let base = Bundle.main.resourceURL?.appendingPathComponent("caplayground")
                ?? Bundle.main.url(forResource: "caplayground", withExtension: nil)
            func serve(_ rel: String, status: Int = 200) {
                guard let b = base else {
                    if let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) {
                        urlSchemeTask.didReceive(resp); urlSchemeTask.didFinish()
                    }
                    return
                }
                let file = b.appendingPathComponent(rel)
                guard let data = try? Data(contentsOf: file) else {
                    if let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) {
                        urlSchemeTask.didReceive(resp); urlSchemeTask.didFinish()
                    }
                    return
                }
                let ext = (rel as NSString).pathExtension.lowercased()
                let mime: String
                switch ext {
                case "html": mime = "text/html"
                case "js": mime = "text/javascript"
                case "css": mime = "text/css"
                case "json": mime = "application/json"
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "svg": mime = "image/svg+xml"
                case "woff2": mime = "font/woff2"
                case "woff": mime = "font/woff"
                case "txt": mime = "text/plain"
                case "ico": mime = "image/x-icon"
                case "mp4": mime = "video/mp4"
                case "webp": mime = "image/webp"
                default: mime = "application/octet-stream"
                }
                if let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count)]) {
                    urlSchemeTask.didReceive(resp); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                }
            }
            let rel = String(path.dropFirst())
            if rel.hasSuffix(".html") || rel.contains(".") {
                // 有扩展名的直接取文件；/editor/demo.html、/_next/...、图片、字体都走这里
                serve(rel); return
            }
            if path.hasPrefix("/editor/") { serve("editor/demo.html"); return }
            if let b = base, FileManager.default.fileExists(atPath: b.appendingPathComponent(rel + ".html").path) { serve(rel + ".html"); return }
            serve("index.html")
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
        // decideDestinationUsing 里记下的下载目标，downloadDidFinish 时用它弹分享单。
        // WKDownload 本身不对外暴露目标路径，所以必须自己记一份。
        private var pendingDownloadURL: URL?

        // MARK: - 新存储（请求式 cap://app/storage/）
        private func storageRespond(_ task: WKURLSchemeTask, status: Int, json: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data("{\"ok\":false}".utf8)
            if let resp = HTTPURLResponse(url: task.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)]) {
                task.didReceive(resp); task.didReceive(data); task.didFinish()
            } else {
                task.didFailWithError(NSError(domain: "cap", code: -1, userInfo: nil))
            }
        }
        private func storageSafePath(_ raw: String) -> String? {
            let parts = raw.split(separator: "/").filter { $0 != "" && $0 != "." && $0 != ".." }
            if parts.isEmpty { return nil }
            return parts.joined(separator: "/")
        }
        private func storageProjectURL(projectId: String) -> URL? {
            let safeProject = projectId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !safeProject.isEmpty, let base = localBaseDir() else { return nil }
            return base.appendingPathComponent(safeProject)
        }
        private func storageReadBody(_ task: WKURLSchemeTask) -> Data? {
            if let body = task.request.httpBody, !body.isEmpty { return body }
            // 大请求体可能走 httpBodyStream：同步读完它（fetch POST 的 JSON 体一般不大到需要分块，但这里兜底）。
            guard let stream = task.request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            return out.isEmpty ? nil : out
        }
        private func handleNativeStorage(urlSchemeTask task: WKURLSchemeTask) {
            guard let url = task.request.url else {
                task.didFailWithError(NSError(domain: "cap", code: -1, userInfo: nil)); return
            }
            let route = url.path // /storage/save | /storage/load | /storage/list | /storage/delete
            let query: [String: String] = {
                var d: [String: String] = [:]
                if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    for it in items { if let v = it.value { d[it.name] = v } }
                }
                return d
            }()
            if route == "/storage/save" || route == "/storage/delete" {
                guard let body = storageReadBody(task),
                      let obj = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
                      let projectId = obj["projectId"] as? String,
                      let projDir = storageProjectURL(projectId: projectId) else {
                    storageRespond(task, status: 400, json: ["ok": false, "error": "bad_request"]); return
                }
                if route == "/storage/delete" {
                    let rawPath = (obj["path"] as? String) ?? ""
                    do {
                        if rawPath.isEmpty {
                            if FileManager.default.fileExists(atPath: projDir.path) { try FileManager.default.removeItem(at: projDir) }
                        } else if let safe = storageSafePath(rawPath) {
                            let target = projDir.appendingPathComponent(safe)
                            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                        } else {
                            storageRespond(task, status: 400, json: ["ok": false, "error": "bad_path"]); return
                        }
                        storageRespond(task, status: 200, json: ["ok": true]); return
                    } catch {
                        storageRespond(task, status: 500, json: ["ok": false, "error": "delete_failed"]); return
                    }
                }
                // save：先写临时文件再改名，原子替换；写完读回大小回给 JS 校验。
                guard let path = obj["path"] as? String, let safe = storageSafePath(path),
                      let b64 = obj["dataBase64"] as? String,
                      let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                    storageRespond(task, status: 400, json: ["ok": false, "error": "bad_request"]); return
                }
                let fileURL = projDir.appendingPathComponent(safe)
                let tmpURL = projDir.appendingPathComponent(".tmp-" + UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: tmpURL, options: .atomic)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
                    } else {
                        try FileManager.default.moveItem(at: tmpURL, to: fileURL)
                    }
                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
                    storageRespond(task, status: 200, json: ["ok": true, "size": size]); return
                } catch {
                    try? FileManager.default.removeItem(at: tmpURL)
                    storageRespond(task, status: 500, json: ["ok": false, "error": "save_failed"]); return
                }
            }
            if route == "/storage/load" {
                guard let projectId = query["projectId"], let rawPath = query["path"],
                      let safe = storageSafePath(rawPath), let projDir = storageProjectURL(projectId: projectId) else {
                    storageRespond(task, status: 400, json: ["ok": false, "error": "bad_request"]); return
                }
                let fileURL = projDir.appendingPathComponent(safe)
                guard let data = try? Data(contentsOf: fileURL) else {
                    storageRespond(task, status: 404, json: ["ok": false, "error": "not_found"]); return
                }
                if let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream", "Content-Length": String(data.count)]) {
                    task.didReceive(resp); task.didReceive(data); task.didFinish()
                } else {
                    task.didFailWithError(NSError(domain: "cap", code: -1, userInfo: nil))
                }
                return
            }
            if route == "/storage/list" {
                guard let projectId = query["projectId"], let projDir = storageProjectURL(projectId: projectId) else {
                    storageRespond(task, status: 400, json: ["ok": false, "error": "bad_request"]); return
                }
                var relPaths: [String] = []
                if let enumerator = FileManager.default.enumerator(at: projDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                            let rel = fileURL.path.replacingOccurrences(of: projDir.path + "/", with: "")
                            if !rel.isEmpty { relPaths.append(rel) }
                        }
                    }
                }
                relPaths.sort()
                storageRespond(task, status: 200, json: ["ok": true, "files": relPaths]); return
            }
            storageRespond(task, status: 404, json: ["ok": false, "error": "unknown_route"])
        }

        // MARK: - tendiesExport 桥接约定（假设，需真机对齐）
        //
        // 以下约定是 App 侧的假设，不是已与网页侧核对过的事实：
        // 假设 A：每条 postMessage 的 body 是一个字典（或 JSON 字符串），字段为：
        //   type: "start" | "chunk" | "end" | "error" | "complete"（缺 type 时按 chunk 处理）
        //   id / exportId: 本次导出的标识，缺省为 "default"，用于区分连续两次导出
        //   index: 本块序号，从 0 开始；total: 总块数（可选，end 块为准）
        //   isLast / last: true 表示这是最后一块，收到后即拼包
        //   filename: 建议文件名，如 "wallpaper.tendies"，缺省为 "wallpaper.tendies"
        //   data / chunk / base64: 本块的 base64 字符串（可含换行，解码时忽略空白）
        // 假设 B：块按 index 排序拼包，同一 index 重复发只保留第一次收到的（去重），
        //   拼包时 index 必须连续（0..<total 或 0...lastIndex），缺块即报错不拼包。
        // 假设 C：拼好的数据就是 .tendies 文件本身，可能是 zip 格式（文件头 PK\x03\x04），
        //   也可能是 WALLIVE1 加密包（文件头 "WALLIVE1"，网页侧导出时加密）；两种都放行，
        //   不是这两种头的数据会被当作导出失败处理，不会直接拿去分享。
        // 假设 D："start" 表示一次新导出开始，会丢弃同 id 未完成旧传输；"error" 带
        //   message 字段时直接弹中文提示并丢弃该传输；"complete" 且 data 为完整
        //   base64 时直接按单块拼包分享。
        // 宽容处理：字段名、type 缺省、字符串 body（先按 JSON 解析）都做了兼容，
        //   但如果网页侧实际约定与上面不同（例如字段叫 part/partIndex、或用
        //   二进制 ArrayBuffer 而不是 base64 字符串），真机上就会对不上，
        //   需要按网页侧实际代码把下面解析处逐项改对，不要在交付里说成已对齐。
        private struct ExportTransfer {
            var id: String = "default"
            var filename: String
            var chunks: [Int: Data] = [:]
            var lastIndex: Int?
            var total: Int?
            var type: String = "chunk"
            // 预览视频的保存目录（Documents 下的子文件夹名，用户在网页设置里填）：
            // 有值就直接存到 Documents/<saveDir>/，不弹分享单；空着走老路（临时目录 + 分享单）。
            var saveDir: String = ""
        }

        private var exportTransfers: [String: ExportTransfer] = [:]

        // 导出结果回写给网页：window.__tendiesExportResult(id, ok, message)。
        // 网页侧等这个回调再显示“已保存”，不再凭“发出去了”就报已保存。
        private func replyExportResult(id: String, ok: Bool, message: String) {
            guard let webView = hostWebView else { return }
            let safeId = id.replacingOccurrences(of: "'", with: "")
            let safeMsg = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: " ")
            webView.evaluateJavaScript("window.__tendiesExportResult && window.__tendiesExportResult('\(safeId)', \(ok ? "true" : "false"), '\(safeMsg)')", completionHandler: nil)
        }

        // 目录名只留安全字符，防止网页给的路径写到别处。
        private func sanitizedDirName(_ raw: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ .·、"))
            let cleaned = raw.unicodeScalars.filter { allowed.contains($0) }.map { String($0) }.joined()
            let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "预览视频" : trimmed
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // 消息回调可能不在主线程，状态读写和弹框统一回主线程，避免竞态。
            DispatchQueue.main.async { [weak self] in
                if message.name == "tendiesLocal" {
                    self?.handleTendiesLocal(message.body, webView: message.webView)
                } else if message.name == "tendiesShare" {
                    self?.handleTendiesShare(message.body)
                } else {
                    self?.handleTendiesExport(message.body)
                }
            }
        }

        // MARK: - App 本地储存（tendiesLocal）：iPad 老 WebKit 下浏览器存储不可靠时用
        // 网页侧导入时分块发 base64 到这里，存到 Documents/Projects/<项目号>/<路径>；
        // 画布改从 cap://app/local/... 直接取图，不走 OPFS/IndexedDB/blob。
        private struct LocalTransfer {
            var projectId: String
            var path: String
            var chunks: [Int: String] = [:]
        }
        private var localTransfers: [String: LocalTransfer] = [:]
        private func localBaseDir() -> URL? {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Projects")
        }
        private func localFileURL(projectId: String, path: String) -> URL? {
            let safeProject = projectId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            let safeRel = path.split(separator: "/").filter { $0 != "" && $0 != "." && $0 != ".." }.joined(separator: "/")
            guard !safeProject.isEmpty, !safeRel.isEmpty, let base = localBaseDir() else { return nil }
            return base.appendingPathComponent(safeProject).appendingPathComponent(safeRel)
        }
        private func replyLocal(webView: WKWebView?, id: String, ok: Bool) {
            guard let webView = webView else { return }
            let safeId = id.replacingOccurrences(of: "'", with: "")
            webView.evaluateJavaScript("window.__tendiesLocalResolve && window.__tendiesLocalResolve('\(safeId)', \(ok ? "true" : "false"))", completionHandler: nil)
        }
        // list 回复：把 JSON 字符串塞进单引号 JS 字符串字面量，必须先转义反斜杠、单引号、换行，
        // 否则路径里一旦出现这些字符就会把 JS 语句截断、JS 侧收不到列表。
        private func jsStringEscaped(_ raw: String) -> String {
            var out = ""
            for ch in raw {
                switch ch {
                case "\\": out += "\\\\"
                case "'": out += "\\'"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(ch)
                }
            }
            return out
        }
        private func replyLocalList(webView: WKWebView?, id: String, json: String) {
            guard let webView = webView else { return }
            let safeId = id.replacingOccurrences(of: "'", with: "")
            webView.evaluateJavaScript("window.__tendiesLocalListResolve && window.__tendiesLocalListResolve('\(safeId)', '\(jsStringEscaped(json))')", completionHandler: nil)
        }
        private func handleTendiesLocal(_ body: Any, webView: WKWebView?) {
            guard let dict = body as? [String: Any],
                  let id = dict["id"] as? String,
                  let action = dict["action"] as? String,
                  let projectId = dict["projectId"] as? String,
                  let path = dict["path"] as? String else { return }
            if action == "has" {
                let exists = localFileURL(projectId: projectId, path: path).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                replyLocal(webView: webView, id: id, ok: exists)
                return
            }
            if action == "list" {
                // 列出 Documents/Projects/<projectId>/ 下所有文件（相对路径，排序后返回）。
                // 目录不存在时返回空数组，不报错，让 JS 侧当作空项目处理。
                var relPaths: [String] = []
                if let base = localBaseDir() {
                    let safeProject = projectId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                    let dir = base.appendingPathComponent(safeProject)
                    if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                        for case let fileURL as URL in enumerator {
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                                let rel = fileURL.path.replacingOccurrences(of: dir.path + "/", with: "")
                                if !rel.isEmpty { relPaths.append(rel) }
                            }
                        }
                    }
                }
                relPaths.sort()
                let jsonData = (try? JSONSerialization.data(withJSONObject: relPaths, options: [])) ?? Data("[]".utf8)
                replyLocalList(webView: webView, id: id, json: String(data: jsonData, encoding: .utf8) ?? "[]")
                return
            }
            if action == "delete" {
                // path 为空 = 删整个项目目录；否则删单个文件（或目录，递归）。
                // 文件已不存在也回 true（幂等），让 JS 侧孤儿清理不因缺文件而报错。
                var ok = true
                if path.isEmpty {
                    if let base = localBaseDir() {
                        let safeProject = projectId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                        let dir = base.appendingPathComponent(safeProject)
                        if FileManager.default.fileExists(atPath: dir.path) {
                            do { try FileManager.default.removeItem(at: dir) } catch { ok = false }
                        }
                    }
                } else if let fileURL = localFileURL(projectId: projectId, path: path) {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        do { try FileManager.default.removeItem(at: fileURL) } catch { ok = false }
                    }
                }
                replyLocal(webView: webView, id: id, ok: ok)
                return
            }
            guard action == "saveChunk" else { return }
            // WKScriptMessage 的 JS 数字/布尔到 Swift 是 NSNumber，直接 as? Int / as? Bool 会失败；
            // 必须走 NSNumber 的 intValue / boolValue，否则 isLast 永远 false、文件永远不写盘。
            let index = (dict["index"] as? NSNumber)?.intValue ?? 0
            let isLast = (dict["isLast"] as? NSNumber)?.boolValue ?? false
            let chunk = dict["data"] as? String ?? ""
            var t = localTransfers[id] ?? LocalTransfer(projectId: projectId, path: path)
            t.chunks[index] = chunk
            localTransfers[id] = t
            if !isLast {
                replyLocal(webView: webView, id: id, ok: true)
                return
            }
            // 最后一块到了，按序号拼包、写文件
            let keys = t.chunks.keys.sorted()
            var b64 = ""
            for k in keys { b64 += t.chunks[k] ?? "" }
            localTransfers.removeValue(forKey: id)
            guard let fileURL = localFileURL(projectId: projectId, path: path),
                  let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                replyLocal(webView: webView, id: id, ok: false)
                return
            }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                replyLocal(webView: webView, id: id, ok: true)
            } catch {
                replyLocal(webView: webView, id: id, ok: false)
            }
        }

        // WKWebView 默认不弹 JS 的 alert/confirm/prompt，必须实现 UIDelegate 否则网页弹框静默无显示，
        // 上一版“返回项目列表”保存失败时只 alert 了一句，用户看到的就是按钮点了没反应。
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default) { _ in completionHandler() })
            // 找到最上层 ViewController 弹框
            var vc = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
            while let presented = vc?.presentedViewController { vc = presented }
            vc?.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            var vc = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
            while let presented = vc?.presentedViewController { vc = presented }
            vc?.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            var vc = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
            while let presented = vc?.presentedViewController { vc = presented }
            vc?.present(alert, animated: true)
        }
        private func handleTendiesExport(_ body: Any) {
            // 1) 字符串 body：先尝试按 JSON 解析，解析失败则当作整包 base64 单块处理。
            if let text = body as? String {
                if let jsonData = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData),
                   let dict = json as? [String: Any] {
                    handleTendiesExportDict(dict)
                } else {
                    // 整包 base64，没有分块元数据，只能按单次完整文件处理。
                    finalizeBridgeExport(id: "default", filename: "wallpaper.tendies", chunks: [0: text])
                }
                return
            }
            guard let dict = body as? [String: Any] else {
                showBridgeError("导出数据格式不对，请再点一次“导出 .tendies”。")
                return
            }
            handleTendiesExportDict(dict)
        }

        private func handleTendiesExportDict(_ dict: [String: Any]) {
            let id = (dict["id"] as? String) ?? (dict["exportId"] as? String) ?? "default"
            let type = (dict["type"] as? String)?.lowercased() ?? "chunk"

            if type == "error" {
                exportTransfers.removeValue(forKey: id)
                let detail = (dict["message"] as? String) ?? ""
                showBridgeError(detail.isEmpty
                    ? "导出失败，请再点一次“导出 .tendies”。"
                    : "导出失败：\(detail)")
                return
            }

            if type == "start" {
                // 新导出开始，丢弃同 id 未完成的旧传输，避免旧块混进新包。
                exportTransfers.removeValue(forKey: id)
                return
            }

            let filename = sanitizedFilename(
                (dict["filename"] as? String) ?? (dict["name"] as? String)
            )
            // 网页侧导出用 "data"（编辑器 ExportDialog），查看器保存视频曾用 "dataBase64"，
            // 这里两种都认，否则视频块会被当成“没有数据”直接报“数据不完整”。
            let base64 = (dict["data"] as? String)
                ?? (dict["chunk"] as? String)
                ?? (dict["base64"] as? String)
                ?? (dict["dataBase64"] as? String)
            // 预览视频的保存目录（网页设置里填的文件夹名），跟块一起带过来。
            let saveDir = (dict["saveDir"] as? String) ?? ""

            // complete：data 即整包，直接拼包分享，不走分块。
            if type == "complete" {
                guard let base64 = base64 else {
                    showBridgeError("导出数据不完整，请再点一次“导出 .tendies”。")
                    return
                }
                finalizeBridgeExport(id: id, filename: filename, chunks: [0: base64])
                return
            }

            // chunk / end：需要 data 和 index（end 块若缺 index，视为最后一块，
            // 但仍需 data；若连 data 都没有且已有块，则按“结束信号”处理）。
            // 同 tendiesLocal：JS 数字/布尔到 Swift 是 NSNumber，直接 as? 会失败
            let index = (dict["index"] as? NSNumber)?.intValue
                ?? (dict["part"] as? NSNumber)?.intValue
                ?? (dict["partIndex"] as? NSNumber)?.intValue
            let total = (dict["total"] as? NSNumber)?.intValue ?? (dict["totalChunks"] as? NSNumber)?.intValue
            let isLast = (dict["isLast"] as? NSNumber)?.boolValue ?? (dict["last"] as? NSNumber)?.boolValue ?? false

            if base64 == nil, !(type == "end" && !exportTransfers[id].isNil) {
                showBridgeError("导出数据不完整，请再点一次“导出 .tendies”。")
                exportTransfers.removeValue(forKey: id)
                return
            }

            // 分块必须带序号才能排序：有数据、无序号、又不是最后一块时，
            // 无法放进顺序里，宁可报错丢弃，也不要悄悄丢块拼出坏包。
            if base64 != nil, index == nil, !isLast {
                exportTransfers.removeValue(forKey: id)
                showBridgeError("导出数据不完整，缺少分块序号，请再点一次“导出 .tendies”。")
                return
            }

            var transfer = exportTransfers[id] ?? ExportTransfer(id: id, filename: filename)
            transfer.id = id
            transfer.filename = filename
            transfer.type = type
            if !saveDir.isEmpty { transfer.saveDir = saveDir }
            if let total = total { transfer.total = total }
            if let base64 = base64, let index = index {
                // 去重：同一 index 只保留第一次收到的块，重复块直接忽略。
                if transfer.chunks[index] == nil,
                   let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                    transfer.chunks[index] = data
                } else if transfer.chunks[index] == nil {
                    // base64 解码失败：这块数据本身坏了，整包不能拼，直接报错丢弃。
                    exportTransfers.removeValue(forKey: id)
                    showBridgeError("导出数据解码失败，请再点一次“导出 .tendies”。")
                    return
                }
                if isLast { transfer.lastIndex = index }
            } else if isLast {
                // end 信号无 index：最后一块序号即当前已收最大序号。
                transfer.lastIndex = transfer.chunks.keys.max()
            }
            exportTransfers[id] = transfer

            let shouldFinalize = isLast || type == "end"
            if shouldFinalize {
                exportTransfers.removeValue(forKey: id)
                finalizeBridgeChunks(transfer)
            }
        }

        private func finalizeBridgeExport(id: String, filename: String, chunks: [Int: String]) {
            var decoded: [Int: Data] = [:]
            for (index, base64) in chunks {
                guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                    showBridgeError("导出数据解码失败，请再点一次“导出 .tendies”。")
                    return
                }
                decoded[index] = data
            }
            finalizeBridgeChunks(ExportTransfer(id: id, filename: filename, chunks: decoded, lastIndex: 0, total: 1))
        }

        private func finalizeBridgeChunks(_ transfer: ExportTransfer) {
            // 确定应有块数：total 优先，其次 lastIndex+1，否则按已收块数推断。
            let expectedCount: Int
            if let total = transfer.total {
                expectedCount = total
            } else if let last = transfer.lastIndex {
                expectedCount = last + 1
            } else {
                expectedCount = transfer.chunks.count
            }
            guard expectedCount > 0 else {
                showBridgeError("导出数据为空，请再点一次“导出 .tendies”。")
                return
            }
            // 连续性检查：0..<expectedCount 必须每块都有，缺任何一块都不拼包。
            var assembled = Data()
            for index in 0..<expectedCount {
                guard let chunk = transfer.chunks[index] else {
                    showBridgeError("导出数据不完整，缺少第 \(index + 1) 块，请再点一次“导出 .tendies”。")
                    return
                }
                assembled.append(chunk)
            }
            // .tendies 可以是 zip 包（文件头 PK\x03\x04），也可以是 WALLIVE1 加密包
            // （文件头 "WALLIVE1"，网页侧导出时加密）；两种都放行，不是这两种
            // 才当失败处理，不要把一包坏数据拿去分享给用户装机。
            // 预览视频是 MP4（第 4-8 字节是 "ftyp"），也放行。
            let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
            let wallive1Magic: [UInt8] = [0x57, 0x41, 0x4C, 0x4C, 0x49, 0x56, 0x45, 0x31]
            let ftypMagic: [UInt8] = [0x66, 0x74, 0x79, 0x70]
            let isZip = assembled.count >= 4 && Array(assembled.prefix(4)) == zipMagic
            let isWallive1 = assembled.count >= 8 && Array(assembled.prefix(8)) == wallive1Magic
            let isMp4 = assembled.count >= 8 && Array(assembled[4..<8]) == ftypMagic
            guard isZip || isWallive1 || isMp4 else {
                showBridgeError("导出的数据不是有效的壁纸包或视频，请再点一次。")
                replyExportResult(id: transfer.id, ok: false, message: "数据不是有效的壁纸包或视频")
                return
            }
            // 预览视频 + 用户设了保存目录：直接存到 Documents/<目录>/ 文件名，
            // 不弹分享单。Documents 在“文件”里看得到（已开 UIFileSharingEnabled）。
            if transfer.type == "preview-video", !transfer.saveDir.isEmpty,
               let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let dirName = sanitizedDirName(transfer.saveDir)
                let dir = docs.appendingPathComponent(dirName)
                let dest = dir.appendingPathComponent(transfer.filename)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try assembled.write(to: dest, options: .atomic)
                    replyExportResult(id: transfer.id, ok: true, message: "\(dirName)/\(transfer.filename)")
                    return
                } catch {
                    showBridgeError("视频保存失败，请再点一次。")
                    replyExportResult(id: transfer.id, ok: false, message: "视频保存失败")
                    return
                }
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(transfer.filename)
            do {
                try? FileManager.default.removeItem(at: dest)
                try assembled.write(to: dest, options: .atomic)
            } catch {
                showBridgeError("壁纸文件保存失败，请再点一次“导出 .tendies”。")
                replyExportResult(id: transfer.id, ok: false, message: "文件保存失败")
                return
            }
            replyExportResult(id: transfer.id, ok: true, message: transfer.filename)
            presentShareSheet(for: dest, deleteAfterSharing: true)
        }

        private func sanitizedFilename(_ raw: String?) -> String {
            guard let raw = raw, !raw.isEmpty else { return "wallpaper.tendies" }
            // 只取最后一段，去掉路径分隔符，防止网页给的路径写到别处。
            let name = raw.split(separator: "/").last.map(String.init) ?? raw
            let clean = name.split(separator: "\\").last.map(String.init) ?? name
            return clean.isEmpty ? "wallpaper.tendies" : clean
        }

        // blob 下载（导出 .ca/.tendies 用的 <a download>）：不走导航，改走下载委托，
        // 下载完成再弹分享单，否则 WKWebView 会悄悄吞掉 blob 下载、导出什么都不出。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.request.url?.scheme == "blob" {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        // MARK: - WKDownloadDelegate（旧下载路径，保留不动）

        // 未知 MIME 类型（.tendies、zip、blob 下载）不直接打开，改走下载流程。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        // 响应变成下载后，把下载代理交给自己，后续走 decideDestination / didFinish。
        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        // 下载目标：系统临时目录 + 建议文件名（编辑器给的就是 xxx.tendies）。
        // 先删同名旧文件，避免“文件已存在”导致下载失败。
        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let name = suggestedFilename.isEmpty ? "wallpaper.tendies" : suggestedFilename
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            pendingDownloadURL = dest
            completionHandler(dest)
        }

        // 下载完成：弹系统分享单。iPad 上分享单必须是 popover，
        // 必须给 sourceView / sourceRect，否则会直接闪退。
        func downloadDidFinish(_ download: WKDownload) {
            guard let url = pendingDownloadURL else { return }
            pendingDownloadURL = nil
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            presentShareSheet(for: url, deleteAfterSharing: true)
        }

        // 下载失败：弹中文提示，不要悄悄失败让用户以为导出成功了。
        func download(
            _ download: WKDownload,
            didFailWithError error: Error,
            resumeData: Data?
        ) {
            pendingDownloadURL = nil
            let alert = UIAlertController(
                title: "导出失败",
                message: "壁纸文件没有下载下来，请再点一次“导出 .tendies”。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert)
        }

        // MARK: - 分享单与提示（桥和下载两条路共用）

        private func presentShareSheet(for url: URL, deleteAfterSharing: Bool) {
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.excludedActivityTypes = [.assignToContact]
            if deleteAfterSharing {
                // 分享完成（或取消）后再删临时文件：分享单回调时系统已完成复制 /
                // 隔空投送交接，删临时文件不会打断分享；不删则临时目录会越积越多。
                sheet.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: url)
                }
            }
            present(sheet)
        }

        // MARK: - 分享到壁纸匣（tendiesShare）：网页点“分享”时发项目号和文件名过来，
        // 原生直接从沙盒 Projects/<项目号>/ 里读原包和预览视频，弹系统分享单。
        // 文件名用壁纸名 + 后缀，分享单里看着清楚；临时文件分享完就删。
        private func handleTendiesShare(_ body: Any) {
            guard let dict = body as? [String: Any],
                  let projectId = dict["projectId"] as? String,
                  let tendiesFile = dict["tendiesFile"] as? String,
                  let name = dict["name"] as? String
            else { return }
            guard let base = localBaseDir() else { return }
            let safeProject = projectId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !safeProject.isEmpty else { return }
            let projectDir = base.appendingPathComponent(safeProject)
            let tendiesURL = projectDir.appendingPathComponent(tendiesFile)
            guard FileManager.default.fileExists(atPath: tendiesURL.path) else { return }

            let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
            let tmpDir = FileManager.default.temporaryDirectory
            var items: [URL] = []
            var tmpFiles: [URL] = []
            let tendiesTmp = tmpDir.appendingPathComponent("\(safeName).tendies")
            try? FileManager.default.removeItem(at: tendiesTmp)
            if (try? FileManager.default.copyItem(at: tendiesURL, to: tendiesTmp)) != nil {
                items.append(tendiesTmp)
                tmpFiles.append(tendiesTmp)
            } else {
                return
            }
            if let videoFile = dict["videoFile"] as? String {
                let videoURL = projectDir.appendingPathComponent(videoFile)
                if FileManager.default.fileExists(atPath: videoURL.path) {
                    let videoTmp = tmpDir.appendingPathComponent("\(safeName).mp4")
                    try? FileManager.default.removeItem(at: videoTmp)
                    if (try? FileManager.default.copyItem(at: videoURL, to: videoTmp)) != nil {
                        items.append(videoTmp)
                        tmpFiles.append(videoTmp)
                    }
                }
            }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            sheet.excludedActivityTypes = [.assignToContact]
            sheet.completionWithItemsHandler = { _, _, _, _ in
                for f in tmpFiles { try? FileManager.default.removeItem(at: f) }
            }
            present(sheet)
        }

        private func showBridgeError(_ message: String) {
            let alert = UIAlertController(
                title: "导出失败",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert)
        }

        // 从当前 key window 的根控制器往上找到最顶层控制器再 present，
        // 分享单和提示框都走这一路，避免 SwiftUI 里拿不到 presenter。
        private func present(_ controller: UIViewController) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            else { return }
            while let presented = top.presentedViewController {
                top = presented
            }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = top.view
                popover.sourceRect = CGRect(
                    x: top.view.bounds.midX, y: top.view.bounds.midY,
                    width: 0, height: 0
                )
                popover.permittedArrowDirections = []
            }
            top.present(controller, animated: true)
        }
    }
}

// Swift 可选链在 Dictionary 上没有 isNil 成员，这里补一个小工具，
// 仅供上面 end 信号无 data 时判断“该传输是否已存在”。
private extension Optional {
    var isNil: Bool { self == nil }
}
