import Foundation
import CryptoKit
import os.log

@MainActor
final class WebDAVSyncService: ObservableObject {

    static let shared = WebDAVSyncService()
    private init() {}

    @Published var isRunning = false
    /// Last pass's outcome for the settings page ("已同步 12 · 失败 1：HTTP 413").
    @Published var lastReport: String?
    /// Last per-clip sync result for the post-transcription path (banner-less;
    /// surfaced only in the settings page log).
    @Published private(set) var uploadedCount = 0

    struct SyncOutcome {
        var uploaded = 0
        var skipped = 0
        var failures: [String] = []
    }

    /// Sync one clip's artefacts (called after transcription).
    func sync(clipName: String, config: AppConfig) async {
        guard let client = Self.client(from: config) else { return }
        _ = try? await syncClip(clipName, client: client,
                                syncAudio: config.webdav?.syncAudio ?? false,
                                content: config.webdav?.uploadContent ?? UploadContent())
    }

    /// Sweep every clip in the library that has a transcript.
    func syncAll(config: AppConfig) async {
        guard let cfg = config.webdav, cfg.isConfigured,
              let client = Self.client(from: config) else {
            lastReport = L10n.WebDAV.notConfigured
            return
        }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let audioExtensions: Set<String> = ["m4a", "aac", "wav", "caf", "mp3", "aif", "aiff", "flac", "opus"]
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        // Only clips with a transcript — text is the thing being backed up.
        let clips = names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .filter { name in
                let base = (name as NSString).deletingPathExtension
                return fm.fileExists(atPath: dir.appendingPathComponent("\(base).txt").path)
            }
            .sorted()

        var outcome = SyncOutcome()
        Self.trace("syncAll start · \(clips.count) clips · base \(cfg.basePath)")
        for clip in clips {
            do {
                if try await syncClip(clip, client: client, syncAudio: cfg.syncAudio,
                                      content: cfg.uploadContent) {
                    outcome.uploaded += 1
                } else {
                    outcome.skipped += 1
                }
            } catch {
                Self.trace("FAIL \(clip): \(error.localizedDescription)")
                outcome.failures.append("\(clip): \(error.localizedDescription)")
            }
        }
        uploadedCount = outcome.uploaded
        lastReport = Self.report(outcome)
        Self.trace("syncAll done · \(lastReport ?? "")")
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    // MARK: - Per-clip

    private func syncClip(_ clipName: String, client: WebDAVClient, syncAudio: Bool,
                          content: UploadContent) async throws -> Bool {
        var uploaded = false
        let urls = StorageLocations.transcriptURLs(for: clipName)
        let base = (clipName as NSString).deletingPathExtension
        let dir = StorageLocations.decryptedDir
        let folder = Self.clipFolderName(base: base, in: dir)

        // ★ 2026-11-02：每条录音一个「日期 主题」文件夹，文件名给人看。总结/
        //   章节有就顺带传——在网盘网页端不用下载就能读，这才叫备份。
        var artefacts: [(local: URL, remote: String)] = []
        if content.transcript {
            artefacts.append((urls.txt, L10n.WebDAV.remoteTranscript))
        }
        if content.asrJSON {
            artefacts.append((urls.json, L10n.WebDAV.remoteASR))
        }
        let chapters = dir.appendingPathComponent("\(base).chapters.json")
        if content.chapters, FileManager.default.fileExists(atPath: chapters.path) {
            artefacts.append((chapters, L10n.WebDAV.remoteChapters))
        }
        var confirmed = Set<String>()   // 新名字里确认已在服务器上的（本次传过或 HEAD 200）
        for (local, remote) in artefacts {
            guard FileManager.default.fileExists(atPath: local.path) else { continue }
            if try await needsUpload(local: local, remote: "\(folder)/\(remote)", client: client) {
                try await client.upload(fileAt: local, to: "\(client.basePath)/\(folder)/\(remote)")
                Self.trace("PUT  \(folder)/\(remote)")
                uploaded = true
            } else {
                Self.trace("SKIP \(folder)/\(remote)")
            }
            confirmed.insert(remote)
        }

        // 摘要.md：总结原文 + 元信息行 + 章节时间轴，**Markdown 明文**——
        // ★ 2026-11-03 用户明确要求"是 MD 文档好点而不是 pdf，pdf 不可编辑"：
        // 改回可编辑文本。PDF（`NotePDFRenderer`）留作以后"导出/分享"用，不再上传。
        // SHA256 没变且服务器已有就不重传——HEAD 只知道"有没有"，不知道
        // "内容变没变"，所以本地哈希是对"改过总结"的兜底。
        if content.summary, let note = Self.readableNote(base: base, in: dir) {
            let hash = Self.sha256Hex(Data(note.markdown.utf8))
            let stored = UserDefaults.standard.string(forKey: Self.noteHashKey(base))
            let remoteNote = "\(folder)/\(L10n.WebDAV.remoteNote)"
            let serverHasIt = try await Self.remoteExists(path: remoteNote, client: client)
            if !serverHasIt || stored != hash {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nomily-note-\(base).md")
                try Data(note.markdown.utf8).write(to: tmp, options: .atomic)
                try await client.upload(fileAt: tmp, to: "\(client.basePath)/\(remoteNote)")
                try? FileManager.default.removeItem(at: tmp)
                UserDefaults.standard.set(hash, forKey: Self.noteHashKey(base))
                Self.trace("PUT  \(remoteNote) (\(Data(note.markdown.utf8).count / 1024) KB)")
                uploaded = true
            } else {
                Self.trace("SKIP \(remoteNote)")
            }
            confirmed.insert(L10n.WebDAV.remoteNote)
        }

        // 待办.md：★ 2026-11-09（用户的目标布局：每条录音文件夹里躺一份独立
        // 的待办清单，和摘要、导图并列）。内容与分享包里的待办完全同源
        // （ShareBundle.todoMarkdown：AI 抓的行动项 + 手动添加，复选框、
        // 已完成的排后面）。没有待办就不放空文件。
        if content.todos,
           let todos = ShareBundle.todoMarkdown(base: base, title: Self.readableTitle(base: base, in: dir), in: dir) {
            let hash = Self.sha256Hex(Data(todos.utf8))
            let key = Self.noteHashKey(base).replacingOccurrences(of: "note", with: "todos")
            let stored = UserDefaults.standard.string(forKey: key)
            let remoteTodos = "\(folder)/\(L10n.WebDAV.remoteTodos)"
            let serverHasIt = try await Self.remoteExists(path: remoteTodos, client: client)
            if !serverHasIt || stored != hash {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nomily-todos-\(base).md")
                try Data(todos.utf8).write(to: tmp, options: .atomic)
                try await client.upload(fileAt: tmp, to: "\(client.basePath)/\(remoteTodos)")
                try? FileManager.default.removeItem(at: tmp)
                UserDefaults.standard.set(hash, forKey: key)
                Self.trace("PUT  \(remoteTodos) (\(Data(todos.utf8).count / 1024) KB)")
                uploaded = true
            } else {
                Self.trace("SKIP \(remoteTodos)")
            }
            confirmed.insert(L10n.WebDAV.remoteTodos)
        }

        let summaryText = Self.summaryText(base: base, in: dir)
        let mapPNG: Data? = content.mindMap ? summaryText.flatMap { text in
            MindMapSnapshot.pngData(markdown: text, title: Self.readableTitle(base: base, in: dir))
        } : nil
        if let png = mapPNG, !png.isEmpty {
            let hash = Self.sha256Hex(png)
            let key = Self.noteHashKey(base).replacingOccurrences(of: "note", with: "mindmap")
            let stored = UserDefaults.standard.string(forKey: key)
            let remoteMap = "\(folder)/\(L10n.WebDAV.remoteMindMap)"
            let serverHasIt = try await Self.remoteExists(path: remoteMap, client: client)
            if !serverHasIt || stored != hash {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nomily-map-\(base).png")
                try png.write(to: tmp, options: .atomic)
                try await client.upload(fileAt: tmp, to: "\(client.basePath)/\(remoteMap)")
                try? FileManager.default.removeItem(at: tmp)
                UserDefaults.standard.set(hash, forKey: key)
                Self.trace("PUT  \(remoteMap) (\(png.count / 1024) KB)")
                uploaded = true
            } else {
                Self.trace("SKIP \(remoteMap)")
            }
            confirmed.insert(L10n.WebDAV.remoteMindMap)
        }

        let bundleOptions = ShareBundle.Options(
            includeAudio: false,
            modified: Self.recordedDate(base: base, in: dir),
            mindMapPNG: mapPNG
        )
        if content.bundle, summaryText != nil,
           let zipURL = try? await ShareBundle.makeZip(for: clipName, options: bundleOptions) {
            let data = FileManager.default.contents(atPath: zipURL.path)
            try? FileManager.default.removeItem(at: zipURL)
            if let data, !data.isEmpty {
                let hash = Self.sha256Hex(data)
                let key = Self.noteHashKey(base).replacingOccurrences(of: "note", with: "bundle")
                let stored = UserDefaults.standard.string(forKey: key)
                let remoteBundle = "\(folder)/\(L10n.WebDAV.remoteBundle)"
                let serverHasIt = try await Self.remoteExists(path: remoteBundle, client: client)
                if !serverHasIt || stored != hash {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nomily-bundle-\(base).zip")
                    try data.write(to: tmp, options: .atomic)
                    try await client.upload(fileAt: tmp, to: "\(client.basePath)/\(remoteBundle)")
                    try? FileManager.default.removeItem(at: tmp)
                    UserDefaults.standard.set(hash, forKey: key)
                    Self.trace("PUT  \(remoteBundle) (\(data.count / 1024) KB)")
                    uploaded = true
                } else {
                    Self.trace("SKIP \(remoteBundle)")
                }
                confirmed.insert(L10n.WebDAV.remoteBundle)
            }
        }

        let legacyNames: [(old: String, new: String)] = [
            ("\(base).txt", L10n.WebDAV.remoteTranscript),
            ("\(base).asr.json", L10n.WebDAV.remoteASR),
            ("\(base).summary.md", L10n.WebDAV.remoteNote),
            ("\(base).chapters.json", L10n.WebDAV.remoteChapters),
            ("笔记.md", L10n.WebDAV.remoteNote),
            ("摘要.pdf", L10n.WebDAV.remoteNote),
            // 2026-11-04：音频从"机器名 .opus"改成"录音.m4a"，把老的那份删掉。
            (clipName, L10n.WebDAV.remoteAudio),
        ]
        // ★ 2026-11-02：迁移只做一次。每轮都对 80 条录音发 4 个 404 的 DELETE
        // 没必要——服务器目录名 + 录音名打过标就不再试（换了目录或服务器会自然
        // 生成新键，重新走一遍）。v3（2026-11-03）：摘要改回 .md，把上一版的
        // 摘要.pdf 也清掉。
        let legacyKey = "webdav.legacy.cleaned.v4.\(client.basePath)/\(folder)/\(base)"
        if !UserDefaults.standard.bool(forKey: legacyKey) {
            var legacyFailed = false
            for pair in legacyNames where confirmed.contains(pair.new) {
                do {
                    try await client.deleteFile(at: "\(client.basePath)/\(folder)/\(pair.old)")
                    Self.trace("DEL  \(folder)/\(pair.old)")
                } catch {
                    legacyFailed = true
                    Self.trace("DEL! \(folder)/\(pair.old) — \(error.localizedDescription)")
                }
            }
            if !legacyFailed { UserDefaults.standard.set(true, forKey: legacyKey) }
        }

        if syncAudio {
            let local = StorageLocations.decryptedDir.appendingPathComponent(clipName)
            let playable = StorageLocations.decryptedDir.appendingPathComponent("\(base).m4a")
            var audioLocal = local
            if !FileManager.default.fileExists(atPath: playable.path),
               let converted = try? await AudioExporter.exportAsM4A(source: local, suggestedName: base) {
                try? FileManager.default.removeItem(at: playable)
                try? FileManager.default.moveItem(at: converted, to: playable)
            }
            if FileManager.default.fileExists(atPath: playable.path) { audioLocal = playable }
            let remoteName = audioLocal == playable ? L10n.WebDAV.remoteAudio : clipName
            let remote = "\(folder)/\(remoteName)"
            if FileManager.default.fileExists(atPath: audioLocal.path),
               try await needsUpload(local: audioLocal, remote: remote, client: client) {
                try await client.ensureDirectories(forPath: "\(client.basePath)/\(folder)")
                WebDAVBackgroundUploader.shared.enqueue(fileAt: audioLocal, to: "\(client.basePath)/\(remote)", client: client)
                uploaded = true
            }
        }
        return uploaded
    }

    /// 一条录音的「摘要.md」成品（标题 + 元信息 + 摘要 + 章节），供打包分享复用。
    /// ★ 2026-11-04：和上传到 Nextcloud 的那份**完全同源**，避免"分享出去的"
    /// 和"网盘里躺着的"两份格式悄悄分叉。
    static func noteMarkdown(base: String) -> String? {
        readableNote(base: base, in: StorageLocations.decryptedDir)?.markdown
    }

    // MARK: - 每录音文件夹名（★ 2026-11-02）

    /// `20261014161945` 这样的录音文件名时间戳 → `2026-10-14`。
    private static let clipStampParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    private static let folderDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let embeddedStampRegex = try! NSRegularExpression(pattern: "(\\d{8}-?\\d{6})")

    private static func recordedDate(base: String, in dir: URL) -> Date {
        let range = NSRange(base.startIndex..., in: base)
        if let match = embeddedStampRegex.firstMatch(in: base, range: range),
           let matchRange = Range(match.range(at: 1), in: base) {
            let digits = base[matchRange].replacingOccurrences(of: "-", with: "")
            if let recorded = clipStampParser.date(from: digits) {
                return recorded
            }
        }
        if let attr = try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("\(base).txt").path),
           let mtime = attr[.modificationDate] as? Date {
            return mtime
        }
        return Date()
    }

    /// 服务器上的每录音文件夹名：`2026-10-14 产品评审会`。
    ///
    /// 日期：录音名里嵌的时间戳（见 `recordedDate`）；取不到退回转写文件的
    /// mtime。主题：`<base>.title`——转写完成时生成的那份；没有就用录音文件名
    /// 兜底。服务器路径不能有 `/` 等捣乱字符，统一清洗；超长截到 60 字符
    /// （中文标题足够，且不吃 URL 长度限制）。
    ///
    /// ★ 2026-11-09：从实例方法放开为 static `clipFolderName`——文件夹 App
    /// （FolderExportService）的每录音布局直接复用同一个命名，网盘和本机
    /// 文件夹里同一批录音的文件夹名一致，用户两边对照不用猜。
    static func clipFolderName(base: String, in dir: URL) -> String {
        let fm = FileManager.default
        let datePart = Self.folderDayFormatter.string(from: Self.recordedDate(base: base, in: dir))

        var title = ""
        if let data = fm.contents(atPath: dir.appendingPathComponent("\(base).title").path),
           let raw = String(data: data, encoding: .utf8) {
            title = Self.sanitizeFolderTitle(raw)
        }
        if title.isEmpty { title = Self.sanitizeFolderTitle(base) }
        if title.isEmpty { title = "未命名" }

        let folder = "\(datePart) \(title)"
        return Self.sanitizeFolderTitle(folder)
    }

    /// 文件夹名清洗：服务器路径的非法字符换空格、压平连续空格、去首尾、限长。
    static func sanitizeFolderTitle(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 60 {
            cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    // MARK: - 摘要 PDF 组装（★ 2026-11-03 可读性优化）

    /// 没有总结（`.summary.md` 缺失或为空）返回 nil——这条录音就没有摘要可传。
    /// 摘要正文（不含标题/章节），给思维导图渲染用。
    private static func summaryText(base: String, in dir: URL) -> String? {
        let path = dir.appendingPathComponent("\(base).summary.md").path
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 显示标题：用户改过的 `<base>.title` 优先，否则用录音名。
    static func readableTitle(base: String, in dir: URL) -> String {
        if let data = FileManager.default.contents(atPath: dir.appendingPathComponent("\(base).title").path),
           let raw = String(data: data, encoding: .utf8) {
            let cleaned = sanitizeFolderTitle(raw)
            if !cleaned.isEmpty { return cleaned }
        }
        return base
    }

    static func readableNote(base: String, in dir: URL) -> NotePDFRenderer.Note? {
        let fm = FileManager.default
        let summaryPath = dir.appendingPathComponent("\(base).summary.md").path
        guard let summaryData = fm.contents(atPath: summaryPath),
              let summary = String(data: summaryData, encoding: .utf8),
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var chapters: [ClipChapter] = []
        if let chapterData = fm.contents(atPath: dir.appendingPathComponent("\(base).chapters.json").path),
           let decoded = try? JSONDecoder().decode([ClipChapter].self, from: chapterData) {
            chapters = decoded.sorted { $0.start < $1.start }
        }

        var title = ""
        if let titleData = fm.contents(atPath: dir.appendingPathComponent("\(base).title").path),
           let raw = String(data: titleData, encoding: .utf8) {
            title = Self.sanitizeFolderTitle(raw)
        }
        if title.isEmpty { title = base }

        let dateText = Self.folderDayFormatter.string(from: Self.recordedDate(base: base, in: dir))
        let meta = dateText + " · " + L10n.WebDAV.noteMeta

        let body = summary
            .components(separatedBy: "\n")
            .map { line -> String in
                guard line.hasPrefix("#") else { return line }
                let hashes = line.prefix { $0 == "#" }.count
                guard hashes >= 1, hashes <= 5 else { return line }
                return String(repeating: "#", count: hashes + 1) + line.dropFirst(hashes)
            }
            .joined(separator: "\n")
        var markdown = "# \(title)\n\n\(meta)\n\n## \(L10n.WebDAV.noteSummaryHeading)\n\n\(body)"
        if !chapters.isEmpty {
            markdown += "\n\n---\n\n## \(L10n.WebDAV.noteChaptersHeading)\n\n"
            for chapter in chapters {
                markdown += "- \(NotePDFRenderer.chapterStamp(chapter.start)) \(chapter.title)\n"
            }
        }
        return NotePDFRenderer.Note(
            title: title,
            dateText: dateText,
            meta: meta,
            summaryMarkdown: summary,
            chapters: chapters,
            chaptersHeading: L10n.WebDAV.noteChaptersHeading,
            markdown: markdown
        )
    }

    /// 调试/预览用：把一条录音的摘要 PDF 渲染出来（真机验证排版，或写进
    /// Documents 后用 devicectl 拉回 Mac 检查）。不影响同步流程。
    func notePDFData(base: String) -> Data? {
        let dir = StorageLocations.decryptedDir
        guard let note = Self.readableNote(base: base, in: dir) else { return nil }
        return NotePDFRenderer.render(note)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// v3（2026-11-03）：上一版把摘要存成 PDF 用过 v2 键，改回 .md 后必须换键，
    /// 否则服务器上那份 PDF 时代的哈希会对上，导致 .md 传不上去。
    private static func noteHashKey(_ base: String) -> String {
        "webdav.note.sha256.v3.\(base)"
    }

    /// HEAD probe without a local file (the note is assembled in memory).
    private static func remoteExists(path: String, client: WebDAVClient) async throws -> Bool {
        guard let req = client.request(publicMethod: "HEAD", path: "\(client.basePath)/\(path)") else {
            return false
        }
        let result = try? await client.session.data(for: req)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
        return status == 200
    }

    /// HEAD check: 200 = server already has it, anything else = upload.
    private func needsUpload(local: URL, remote: String, client: WebDAVClient) async throws -> Bool {
        guard let req = client.request(publicMethod: "HEAD", path: "\(client.basePath)/\(remote)") else {
            return true
        }
        // `try?` on a throwing tuple-returning call yields an optional tuple —
        // unwrap via `result?.1`; any failure (network, TLS, non-2xx) means upload.
        // ★ 2026-10-30：走 client.session —— 「允许自签」的配置这里是放行版会话。
        let result = try? await client.session.data(for: req)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
        return status != 200
    }

    // MARK: - Helpers

    /// Build a client from config + the Keychain-held password.
    static func client(from config: AppConfig) -> WebDAVClient? {
        guard let cfg = config.webdav, cfg.isConfigured else { return nil }
        return WebDAVClient(
            host: cfg.host,
            port: cfg.port,
            useHTTPS: cfg.useHTTPS,
            username: cfg.username,
            password: cfg.password ?? "",
            basePath: cfg.basePath,
            allowSelfSigned: cfg.allowSelfSigned
        )
    }

    private static func report(_ outcome: SyncOutcome) -> String {
        if outcome.failures.isEmpty {
            return L10n.WebDAV.reportAll(outcome.uploaded, outcome.skipped)
        }
        let first = outcome.failures.first ?? ""
        return L10n.WebDAV.reportFailures(outcome.uploaded, outcome.skipped, outcome.failures.count, first)
    }

    /// 逐文件结果打到控制台（`devicectl … --console` 可见）。仅 DEBUG；
    /// Release 里是空实现，用于真机核对「到底传了哪个名字、旧名删掉没有」。
    private static func trace(_ text: String) {
        #if DEBUG
        NSLog("[WEBDAV-TEST] %@", text)
        #endif
    }
}

extension WebDAVClient {
    /// Exposed for the sync service's HEAD probe (the base `request` is private).
    func request(publicMethod method: String, path: String) -> URLRequest? {
        guard let url = url(forPath: path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return req
    }
}
