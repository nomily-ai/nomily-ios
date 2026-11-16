import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "webdav-bg")

final class WebDAVBackgroundUploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    static let shared = WebDAVBackgroundUploader()
    static let sessionIdentifier = "com.nomily.app.webdav.upload"
    static let didFinishNotification = Notification.Name("webdavBackgroundUploadDidFinish")

    private var session: URLSession!
    /// Held between `handleEvents` and `urlSessionDidFinishEvents`.
    private var backgroundCompletionHandler: (() -> Void)?
    /// ★ 2026-10-30：跟最近一次 enqueue 的配置走——「允许自签」的 HTTPS 服务器
    /// 在后台会话里同样会发 server-trust 质询，不放行就传不上去。
    private var allowSelfSigned = false

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 15 * 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit {
        session?.finishTasksAndInvalidate()
    }

    /// Queue a file for upload. Directories must already exist (`ensureDirectories`
    /// is done by the caller in the foreground).
    func enqueue(fileAt localURL: URL, to remotePath: String, client: WebDAVClient) {
        guard let url = client.url(forPath: remotePath) else {
            log.error("bad remote path \(remotePath, privacy: .public)")
            return
        }
        allowSelfSigned = client.allowSelfSigned
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let credential = Data("\(client.username):\(client.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        let task = session.uploadTask(with: request, fromFile: localURL)
        task.taskDescription = remotePath
        task.resume()
        log.notice("queued upload \(remotePath, privacy: .public) (task \(task.currentRequest?.url?.absoluteString ?? "?", privacy: .public))")
    }

    // MARK: - Lifecycle (called from AppDelegate)

    /// iOS woke the process for this session's events; store the completion
    /// handler until `urlSessionDidFinishEvents` fires.
    func handleEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error {
            log.error("background session invalid: \(error.localizedDescription, privacy: .public)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    // MARK: - URLSessionTaskDelegate

    /// ★ 2026-10-30：自签证书放行——仅当该次上传的配置开了「允许自签」时，
    /// 对 server-trust 质询直接采信；其余质询/开关关闭时一律默认处理。
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowSelfSigned,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let path = task.taskDescription ?? "?"
        if let error {
            log.error("upload \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            log.notice("upload \(path, privacy: .public) done (HTTP \(status))")
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didFinishNotification, object: nil)
        }
    }
}
