import Foundation

final class ShareRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private(set) var shareDestination: URL?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url,
           (LinkTools.noteID(in: url) != nil && LinkTools.isSignedXiaohongshuLink(url))
                || LinkTools.isProfileURL(url) {
            // 展开短链只需取得分享目标。继续请求笔记可能被网页端导向 /explore，
            // 不能因此丢掉已取得的正确笔记地址；主页目标仍交给调用方拒绝。
            shareDestination = url
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }
}

enum ShareURLResolver {
    static func remainingInterval(since copiedAt: TimeInterval, now: TimeInterval, minimum: TimeInterval) -> TimeInterval {
        max(0, minimum - (now - copiedAt))
    }

    /// 在后台执行。网络展开立即启动，返回首页与网络等待重叠；两者完成后仅通知一次。
    static func resolveWhileReturningHome(
        from copiedURL: URL,
        resolve: (URL, @escaping (URL, Bool) -> Void) -> Void = browserReadyURL,
        returnHome: () -> Bool,
        completion: @escaping (URL, Bool, Bool) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var resolved = (copiedURL, false)
        group.enter()
        resolve(copiedURL) { url, expanded in
            lock.lock()
            resolved = (url, expanded)
            lock.unlock()
            group.leave()
        }
        guard returnHome() else {
            completion(copiedURL, false, false)
            return
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            lock.lock()
            let result = resolved
            lock.unlock()
            completion(result.0, result.1, true)
        }
    }

    static func browserReadyURL(from copiedURL: URL, completion: @escaping (URL, Bool) -> Void) {
        guard LinkTools.isOfficialShortLink(copiedURL) else {
            completion(copiedURL, LinkTools.isSignedXiaohongshuLink(copiedURL))
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.httpShouldSetCookies = false

        let redirectDelegate = ShareRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        var request = URLRequest(url: copiedURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let task = session.dataTask(with: request) { _, response, _ in
            defer { session.finishTasksAndInvalidate() }
            let destination = redirectDelegate.shareDestination ?? response?.url
            if let finalURL = destination,
               LinkTools.isSignedXiaohongshuLink(finalURL) {
                completion(finalURL, true)
            } else if let finalURL = destination, LinkTools.isProfileURL(finalURL) {
                // 保留已观察到的错误目标，交给调用方拒绝，不能退回短链掩盖主页跳转。
                completion(finalURL, false)
            } else {
                // 官方短链本身可以由浏览器打开；展开失败时不丢弃它。
                completion(copiedURL, false)
            }
        }
        task.resume()
    }
}
