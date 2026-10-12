import Foundation

// SC-6 冻结语义修订记录 R1（2026-09-30）·网络语义：本文件是全工程唯一允许出现
// 网络 API 的文件（SC-5 冻结语义修订记录 R2 白名单口径）。
// 仅两个用户触发动作产生请求：①关于页点按「检查更新…」→ 对本频道清单 URL 一次 GET；
// ②用户点按「下载并安装」→ 对清单内 packageURL 一次 GET。
// 硬约束（任一不满足即拒绝）：仅 HTTPS；host 白名单唯一（blacstar7.github.io）；
// 清单与包同源；拒绝 file:／IP 字面量 host／user:pass@／显式端口号；
// 任何 HTTP 重定向一律拒绝（含同域）；请求空闲超时 30 秒；不重试、无静默重试。
// 本文件除把下载数据写到调用方给定的暂存路径外，不做任何其他文件系统写删操作。

enum UpdateNetworkError: Error, Equatable, Sendable {
    case manifestURLMissing
    case manifestTooLarge(Int)
    case schemeNotHTTPS(String)
    case hostNotWhitelisted(String)
    case explicitPort(Int)
    case userInfoPresent
    case manifestOriginUnknown
    case packageOriginMismatch(manifestHost: String, packageHost: String)
    case redirectRejected(original: String, target: String)
    case serverStatus(Int)
    case transport(String)
    case emptyBody
    case writeFailed(String)
}

/// 拒绝任何 HTTP 重定向的会话代理（冻结语义 R1：重定向一律拒绝，含同域）。
private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onRedirect: @Sendable (_ original: String, _ target: String) -> Void

    init(onRedirect: @escaping @Sendable (_ original: String, _ target: String) -> Void) {
        self.onRedirect = onRedirect
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let original = response.url?.absoluteString ?? task.originalRequest?.url?.absoluteString ?? "(unknown)"
        let target = request.url?.absoluteString ?? "(unknown)"
        onRedirect(original, target)
        completionHandler(nil)
    }
}

enum UpdateDownloader: Sendable {
    /// 冻结语义 R1：host 白名单＝唯一 host。
    static let allowedHost = "blacstar7.github.io"
    /// 冻结语义 R1：请求空闲超时 30 秒，不重试。
    static let requestIdleTimeout: TimeInterval = 30
    /// 清单请求整体硬上限（清单为小文件，与空闲超时一致）。
    static let manifestResourceTimeout: TimeInterval = 30
    /// 清单大小硬上限（R1 附注二第 7 条：64 KiB，与解析侧 65,536 字节一致）。
    static let manifestMaxBytes = 65_536
    /// 更新包整体硬上限（大文件的次要安全阀；空闲超时仍为 30 秒）。
    static let packageResourceTimeout: TimeInterval = 600

    /// 构建期经 Info.plist 注入的本频道清单 URL（与频道同机制，应用内无切换 UI）。
    static func manifestURL(bundle: Bundle = .main) -> Result<URL, UpdateNetworkError> {
        guard let raw = bundle.infoDictionary?["SinCleanUpdateManifestURL"] as? String,
              !raw.isEmpty
        else { return .failure(.manifestURLMissing) }
        guard let url = URL(string: raw) else { return .failure(.manifestURLMissing) }
        return validateRequestURL(url)
    }

    /// 静态 URL 边界校验（发起请求前必须全部通过）。
    static func validateRequestURL(_ url: URL) -> Result<URL, UpdateNetworkError> {
        guard url.scheme?.lowercased() == "https" else {
            return .failure(.schemeNotHTTPS(url.scheme ?? "(nil)"))
        }
        guard url.user == nil, url.password == nil else {
            return .failure(.userInfoPresent)
        }
        guard url.port == nil else {
            return .failure(.explicitPort(url.port!))
        }
        guard let host = url.host, host == allowedHost else {
            return .failure(.hostNotWhitelisted(url.host ?? "(nil)"))
        }
        guard !url.path.isEmpty, url.path != "/" else {
            return .failure(.hostNotWhitelisted(host))
        }
        return .success(url)
    }

    /// 同源校验（清单请求与更新包必须同 scheme＋host＋port；冻结语义 R1）。
    static func validateSameOrigin(packageURL: URL, manifestURL origin: URL) -> Result<URL, UpdateNetworkError> {
        let checked: URL
        switch validateRequestURL(packageURL) {
        case .failure(let error): return .failure(error)
        case .success(let url): checked = url
        }
        guard let originHost = origin.host else { return .failure(.manifestOriginUnknown) }
        guard let packageHost = checked.host, packageHost == originHost,
              checked.port == nil, origin.port == nil
        else {
            return .failure(.packageOriginMismatch(manifestHost: originHost, packageHost: checked.host ?? "(nil)"))
        }
        return .success(checked)
    }

    private static func makeSession(
        resourceTimeout: TimeInterval,
        onRedirect: @escaping @Sendable (_ original: String, _ target: String) -> Void
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestIdleTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(
            configuration: configuration,
            delegate: RedirectRejectingDelegate(onRedirect: onRedirect),
            delegateQueue: nil
        )
    }

    /// 检查更新：获取本频道清单（一次 GET）。仅由用户点按「检查更新…」触发。
    /// 流式接收并在 64 KiB 处截断（R1 附注二第 7 条：超大清单不进入解析即拒绝）。
    static func fetchManifest(
        from url: URL,
        onRedirect: @escaping @Sendable (_ original: String, _ target: String) -> Void = { _, _ in }
    ) async -> Result<Data, UpdateNetworkError> {
        let validated: URL
        switch validateRequestURL(url) {
        case .failure(let error): return .failure(error)
        case .success(let u): validated = u
        }
        let session = makeSession(resourceTimeout: manifestResourceTimeout, onRedirect: onRedirect)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: validated)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode) {
                return .failure(.redirectRejected(
                    original: validated.absoluteString,
                    target: http.value(forHTTPHeaderField: "Location") ?? "(no location header)"
                ))
            }
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("non-HTTP response"))
            }
            guard http.statusCode == 200 else { return .failure(.serverStatus(http.statusCode)) }
            var data = Data()
            for try await chunk in bytes {
                data.append(chunk)
                if data.count > manifestMaxBytes {
                    return .failure(.manifestTooLarge(data.count))
                }
            }
            guard !data.isEmpty else { return .failure(.emptyBody) }
            return .success(data)
        } catch let error as NSError where error.code == NSURLErrorCancelled {
            return .failure(.redirectRejected(original: validated.absoluteString, target: "(cancelled at delegate)"))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// 下载更新包到调用方给定的暂存路径。仅由用户点按「下载并安装」触发；
    /// manifestOrigin 为本次清单请求 URL（同源校验）；expectedBytes 为清单声明的包字节数，
    /// 累计超过即中止并删除半成品（R1 附注二第 7 条）。流式直写暂存文件，不整包驻内存；
    /// progress 回调按累计已写字节数汇报。
    static func downloadPackage(
        from packageURL: URL,
        manifestOrigin: URL,
        expectedBytes: Int64,
        to destination: URL,
        progress: @escaping @Sendable (_ receivedBytes: Int64) -> Void
    ) async -> Result<URL, UpdateNetworkError> {
        let validated: URL
        switch validateSameOrigin(packageURL: packageURL, manifestURL: manifestOrigin) {
        case .failure(let error): return .failure(error)
        case .success(let url): validated = url
        }
        let session = makeSession(resourceTimeout: packageResourceTimeout, onRedirect: { _, _ in })
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: validated)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // 目标已存在则先移除（暂存目录内、由本函数独占管理）。
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            return .failure(.writeFailed("open staging file"))
        }
        defer { try? handle.close() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode) {
                return .failure(.redirectRejected(
                    original: validated.absoluteString,
                    target: http.value(forHTTPHeaderField: "Location") ?? "(no location header)"
                ))
            }
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("non-HTTP response"))
            }
            guard http.statusCode == 200 else { return .failure(.serverStatus(http.statusCode)) }
            var written: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(1 << 16)
            for try await byte in bytes {
                written += 1
                if written > expectedBytes {
                    try? FileManager.default.removeItem(at: destination)
                    return .failure(.transport("body exceeds manifest packageBytes (\(expectedBytes))"))
                }
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    progress(written)
                }
            }
            try? handle.close()
            if !buffer.isEmpty {
                guard let handle2 = try? FileHandle(forWritingTo: destination) else {
                    return .failure(.writeFailed("reopen staging file"))
                }
                defer { try? handle2.close() }
                try handle2.seekToEnd()
                try handle2.write(contentsOf: buffer)
            }
            guard written > 0 else {
                try? FileManager.default.removeItem(at: destination)
                return .failure(.emptyBody)
            }
            guard written == expectedBytes else {
                try? FileManager.default.removeItem(at: destination)
                return .failure(.transport("body shorter than manifest packageBytes (\(written)/\(expectedBytes))"))
            }
            return .success(destination)
        } catch let error as NSError where error.code == NSURLErrorCancelled {
            try? FileManager.default.removeItem(at: destination)
            return .failure(.redirectRejected(original: validated.absoluteString, target: "(cancelled at delegate)"))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return .failure(.transport(error.localizedDescription))
        }
    }
}
