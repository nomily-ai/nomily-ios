import SwiftUI

// `String.fullwidthNormalized` / `credentialNormalized` 见 AppConfig.swift ——
// 凭据归一化属于传输层，不放 UI 文件，免得只有这一条路记得清洗。


struct WebDAVSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var configService: ConfigService

    private var accounts: [WebDAVConfig] {
        configService.config.webdavAccounts ?? (configService.config.webdav.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack {
            List {
                if !accounts.isEmpty {
                    Section {
                        ForEach(accounts) { account in
                            NavigationLink {
                                WebDAVView(accountID: account.id)
                            } label: {
                                HStack(spacing: 12) {
                                    presetIcon(account.preset)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.preset ?? L10n.WebDAV.title)
                                        Text(account.host)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    if isActive(account) {
                                        Text(L10n.WebDAV.inUse)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                        .onDelete { indexSet in
                            let ids = indexSet.compactMap { accounts[safe: $0]?.id }
                            for id in ids {
                                configService.config.removeWebDAVAccount(id: id)
                                SecretStore.delete(key: ConfigService.webdavPasswordKey(accountID: id))
                            }
                            configService.saveNow()
                        }
                    } header: {
                        Text(L10n.WebDAV.savedServers)
                    }
                }

                Section {
                    ForEach(WebDAVPresets.all, id: \.label) { item in
                        NavigationLink {
                            WebDAVView(initialPreset: item.label)
                        } label: {
                            HStack(spacing: 12) {
                                // ★ 2026-10-30：有官方 App 图标就用真图标（App Store
                                //   抓的原 图，圆角由这里裁）；没品牌的回退 SF Symbol。
                                if let appIcon = item.appIcon {
                                    Image(appIcon)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                } else {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(item.tint.gradient)
                                        )
                                }
                                Text(item.label)
                                Spacer(minLength: 8)
                            }
                        }
                    }
                } header: {
                    Text(L10n.WebDAV.addServer)
                } footer: {
                    Text(accounts.isEmpty
                         ? L10n.WebDAV.setupFooter
                         : L10n.WebDAV.accountsFooter)
                }
            }
            .navigationTitle(L10n.WebDAV.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func isActive(_ account: WebDAVConfig) -> Bool {
        configService.config.activeWebDAVAccount?.id == account.id
    }

    @ViewBuilder
    private func presetIcon(_ label: String?) -> some View {
        if let item = WebDAVPresets.item(named: label ?? "") {
            if let appIcon = item.appIcon {
                Image(appIcon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(item.tint.gradient))
            }
        } else {
            Image(systemName: "server.rack")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.gray.gradient))
        }
    }
}

/// 数组安全下标（onDelete 的 IndexSet → 元素）。
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum WebDAVPresets {
    struct Item {
        let label: String
        let port: Int
        let https: Bool
        let hostPlaceholder: String
        let hint: String
        let symbol: String
        let tint: Color
        var appIcon: String? = nil
    }

    static let all: [Item] = [
        Item(label: "群晖", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "先在套件中心装好「WebDAV Server」，用 DSM 账号登录",
             symbol: "shippingbox.fill", tint: .blue, appIcon: "NASynology"),
        Item(label: "威联通", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "在 App Center 启用 WebDAV 后使用",
             symbol: "shippingbox.fill", tint: .indigo, appIcon: "NASQNAP"),
        Item(label: "绿联", port: 9443, https: true, hostPlaceholder: "192.168.1.10",
             hint: "在绿联云的设置里开启 WebDAV",
             symbol: "shippingbox.fill", tint: .green, appIcon: "NASUGREEN"),
        Item(label: "飞牛", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "fnOS 应用中心启用 WebDAV 后使用",
             symbol: "shippingbox.fill", tint: .teal, appIcon: "NASFeiniu"),
        // ★ 2026-10-30：极空间实测（Z4Pro，5005 HTTP 认证通过 + 个人空间可写）。
        //   关键规则：**WebDAV 根目录不可写**（MKCOL/PUT 一律 400/401），可写的根是
        //   用户的个人空间 `/sataXX-账号/`——目录必须填到个人空间下面。
        //   5006 HTTPS 是自签证书 → 必须开「允许自签」。目录填错时测试连接会
        //   自动扫描根目录定位个人空间并回填。
        Item(label: "极空间", port: 5005, https: false, hostPlaceholder: "192.168.1.10 或 100.x.y.z",
             hint: "系统设置 → 文件与共享服务 → WebDAV 打开。HTTP 默认 5005；用 HTTPS(5006) 需开「允许自签证书」。目录填个人空间下的路径（形如 /sata11-你的账号/nomily），填错也没关系——测试连接会自动定位",
             symbol: "externaldrive.fill", tint: .orange, appIcon: "NASZSpace"),
        // ★ 2026-10-30（Nextcloud 引导）：公网服务，和局域网 NAS 的填法完全
        //   不同——域名 + 应用密码 + 自动目录，不再要求用户手拼 remote.php 路径。
        Item(label: "Nextcloud", port: 443, https: true, hostPlaceholder: "cloud.example.com",
             hint: "① 主机填域名，例如 cloud.example.com（自建且证书自签就打开「允许自签证书」）；② 密码用「应用密码」：登录网页版 → 右上角头像 → 设置 → 安全 → 设备和会话 → 创建新应用密码，登录密码不行；③ 目录不用填，会自动用 /remote.php/dav/files/你的用户名/Nomily/",
             symbol: "cloud.fill", tint: .cyan, appIcon: "NASNextcloud"),
        Item(label: "坚果云", port: 443, https: true, hostPlaceholder: "dav.jianguoyun.com",
             hint: "路径填 /dav；密码要用「应用密码」（账户安全里生成），不是登录密码",
             symbol: "cloud.fill", tint: .blue, appIcon: "NASNutstore"),
        Item(label: "其他 WebDAV", port: 443, https: true, hostPlaceholder: "服务器地址",
             hint: "任意标准 WebDAV 服务",
             symbol: "server.rack", tint: .gray),
    ]

    static func item(named label: String) -> Item? {
        all.first { $0.label == label }
    }
}

struct WebDAVView: View {
    @EnvironmentObject private var configService: ConfigService
    @ObservedObject private var sync = WebDAVSyncService.shared
    @Environment(\.dismiss) private var dismiss

    var initialPreset: String? = nil

    /// ★ 2026-11-09 多账户：非 nil = 编辑已保存的某一条账户（按 id 从
    /// `webdavAccounts` 里读/写）；nil = 新建一条（保存后自动成为「使用中」）。
    var accountID: String? = nil

    /// ★ 2026-11-09：编辑已有账户时把它设为备份目标的确认提示（一次）。
    @State private var activeNote: String?
    /// ★ 2026-11-09：账户刚被本页删除——onDisappear 的 save() 不能把它复活。
    @State private var removed = false

    /// Form-local editable copy — committed to config on save, password lives
    /// in the Keychain via ConfigService's strip/restore.
    @State private var host = ""
    @State private var portText = "443"
    @State private var useHTTPS = true
    /// ★ 2026-10-30（极空间 HTTPS 5006 实测自签证书）：信任自签的开关。
    @State private var allowSelfSigned = false
    @State private var username = ""
    @State private var password = ""
    @State private var basePath = "/nomily"
    @State private var syncAudio = false
    @State private var upload = UploadContent()
    @State private var preset = ""

    @State private var probing = false
    @State private var probe: (ok: Bool, text: String)?
    /// ★ 2026-11-02（用户拿分享链接当 WebDAV 地址）：粘贴的是网页分享链接
    ///   （`/f/<id>`、`/s/<token>`）时给出纠正引导，而不是默默存一条必挂的配置。
    @State private var pasteNote: String?
    @State private var showingFolderPicker = false

    /// `portText` → 有效端口；非法（空/越界）返回 nil，由调用方报错。
    private var parsedPort: Int? {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(p) else { return nil }
        return p
    }

    /// 主机框占位符跟随预设（极空间提示"或 100.x.y.z"等）。
    private var hostPlaceholder: String {
        WebDAVPresets.item(named: preset)?.hostPlaceholder ?? L10n.WebDAV.host
    }

    private var isNextcloud: Bool { preset == "Nextcloud" }

    /// 实际生效的服务器目录：Nextcloud 自动推导，其余照旧。
    /// ★ 2026-11-02：推导到 `<用户名>/Nomily/` 子目录——files 根直接堆
    ///   transcripts/、audio/ 会把网盘根目录弄乱，与其他 NAS 的 /nomily 一致。
    private var effectiveBasePath: String {
        if isNextcloud {
            let user = username.trimmingCharacters(in: .whitespaces).credentialNormalized
            if !user.isEmpty, !basePath.contains("remote.php") {
                return "/remote.php/dav/files/\(user)/Nomily/"
            }
        }
        return basePathText()
    }

    var body: some View {
        Form {

            Section {
                TextField(hostPlaceholder, text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    // ★ 2026-10-30：极空间客户端里点「复制」拿到的是完整 URL
                    //   （http://192.168.15.102:5005）——回车/保存时自动拆出协议和端口。
                    .onSubmit { applyPastedEndpoint() }
                TextField(L10n.WebDAV.portField, text: $portText)
                    .keyboardType(.numberPad)
                    .onChange(of: portText) { newValue in
                        let digits = newValue.filter { $0.isNumber }.prefix(5)
                        if String(digits) != newValue { portText = String(digits) }
                    }
                Toggle(L10n.WebDAV.https, isOn: $useHTTPS)
                Toggle(L10n.WebDAV.allowSelfSigned, isOn: $allowSelfSigned)
                TextField(L10n.WebDAV.username, text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L10n.WebDAV.password, text: $password)
                if isNextcloud {
                    HStack {
                        Text(effectiveBasePath)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if basePath.contains("remote.php") {
                            Button(L10n.WebDAV.resetFolder) { basePath = "" }
                                .font(.footnote)
                        }
                    }
                } else {
                    TextField(L10n.WebDAV.basePath, text: $basePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button {
                    prepareFolderPicker()
                } label: {
                    Label(L10n.WebDAV.browseFolders, systemImage: "folder.badge.gearshape")
                }
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                          || username.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text(L10n.WebDAV.connection)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(L10n.WebDAV.credentialGuide)
                    } icon: {
                        Image(systemName: "person.text.rectangle")
                    }
                    if isNextcloud {
                        Text(L10n.WebDAV.nextcloudPathHint + L10n.WebDAV.basePathFooter)
                    } else if let hint = WebDAVPresets.item(named: preset)?.hint {
                        Text(hint + "\n\n" + L10n.WebDAV.basePathFooter)
                    } else {
                        Text(L10n.WebDAV.basePathFooter)
                    }
                }
            }

            if let note = pasteNote {
                Section {
                    Label {
                        Text(note)
                    } icon: {
                        Image(systemName: "link.badge.plus")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle(L10n.WebDAV.syncAudio, isOn: $syncAudio)
            } footer: {
                Text(L10n.WebDAV.syncAudioFooter)
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text(L10n.WebDAV.test)
                        if probing { Spacer(); ProgressView() }
                    }
                }
                .disabled(probing || host.isEmpty || username.isEmpty || password.isEmpty)
                if let probe {
                    Label {
                        Text(probe.text)
                    } icon: {
                        Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(probe.ok ? Color.green : Color.red)
                    }
                }
            }

            Section {
                Button {
                    Task { await syncNow() }
                } label: {
                    HStack {
                        Text(L10n.WebDAV.syncNow)
                        if sync.isRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(sync.isRunning)
                if let report = sync.lastReport {
                    Text(report)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.WebDAV.syncNowFooter)
            }

            Section {
                Toggle(L10nUploadContent.transcript, isOn: $upload.transcript)
                Toggle(L10nUploadContent.asr, isOn: $upload.asrJSON)
                Toggle(L10nUploadContent.summary, isOn: $upload.summary)
                Toggle(L10nUploadContent.todos, isOn: $upload.todos)
                Toggle(L10nUploadContent.mindMap, isOn: $upload.mindMap)
                Toggle(L10nUploadContent.chapters, isOn: $upload.chapters)
                Toggle(L10nUploadContent.bundle, isOn: $upload.bundle)
            } header: {
                Text(L10nUploadContent.section)
            } footer: {
                Text(L10nUploadContent.footer)
            }

            // ★ 2026-11-09 多账户：编辑已保存的账户时，切换备份目标 / 移除账户
            //   都在这里显式完成（旧的"主机清空 = 删除"已废）。
            if accountID != nil {
                Section {
                    if let activeNote {
                        Label {
                            Text(activeNote)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(.green)
                    }
                    Button {
                        setActive()
                    } label: {
                        Label(L10n.WebDAV.setActive, systemImage: "checkmark.seal")
                    }
                    Button(role: .destructive) {
                        removeAccount()
                    } label: {
                        Label(L10n.WebDAV.removeServer, systemImage: "trash")
                    }
                } footer: {
                    Text(L10n.WebDAV.accountsFooter)
                }
            }

            Section {
                PrivacyNote(flavor: .backup)
            }
        }
        .navigationTitle(L10n.WebDAV.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFolderPicker) {
            WebDAVFolderPicker(
                client: makeFormClient(),
                initialPath: effectiveBasePath
            ) { picked in
                basePath = picked
                probe = (true, "目录已设为 \(picked)")
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    /// 用表单当前值构建浏览用的 client（端口非法时兜底 443——入口已拦过）。
    private func makeFormClient() -> WebDAVClient {
        WebDAVClient(
            host: host.trimmingCharacters(in: .whitespaces),
            port: parsedPort ?? 443,
            useHTTPS: useHTTPS,
            username: username,
            password: password,
            basePath: basePathText(),
            allowSelfSigned: allowSelfSigned
        )
    }

    /// 进文件夹选择器前先把粘贴的整串端点拆掉（主机框里可能是完整 URL）。
    private func prepareFolderPicker() {
        applyPastedEndpoint()
        guard parsedPort != nil else {
            probe = (false, L10n.WebDAV.badPort)
            return
        }
        showingFolderPicker = true
    }

    // MARK: - Load / save

    private func load() {
        // ★ 2026-11-09 多账户：编辑模式从指定账户读，新建模式**从空白开始**
        //   （只按预设预填端口/HTTPS/目录）——不能再回落读 `config.webdav`，
        //   否则"添加极空间"进去看到的还是 NC 的主机和账号（用户实测反馈）。
        let cfg: WebDAVConfig?
        if let accountID,
           let account = configService.config.webdavAccounts?.first(where: { $0.id == accountID }) {
            cfg = account
        } else if accountID != nil {
            // 账户已被删除（左滑后返回）：不回填，也不该再落盘——save 里挡。
            cfg = nil
        } else {
            cfg = nil
        }
        host = cfg?.host ?? ""
        portText = String(cfg?.port ?? 443)
        useHTTPS = cfg?.useHTTPS ?? true
        allowSelfSigned = cfg?.allowSelfSigned ?? false
        username = cfg?.username ?? ""
        password = cfg?.password ?? ""
        basePath = cfg?.basePath ?? "/nomily"
        syncAudio = cfg?.syncAudio ?? false
        upload = cfg?.uploadContent ?? UploadContent()
        // ★ 2026-10-30：从类型选择弹层跳进来且还没有配置时，预选该类型并把
        //   端口/HTTPS/目录预填好（原来靠已删除的 Picker onChange 触发）。
        preset = cfg?.preset ?? initialPreset ?? ""
        if cfg == nil, let p = initialPreset {
            applyPresetDefaults(p)
        }
        pasteNote = nil
    }

    /// 弹层选完类型进来的一次性预填（端口 / HTTPS / 目录）。
    private func applyPresetDefaults(_ label: String) {
        guard let item = WebDAVPresets.item(named: label) else { return }
        portText = String(item.port)
        useHTTPS = item.https
        basePath = label == "坚果云" ? "/dav"
            : label == "Nextcloud" ? basePath
            : "/nomily"
    }

    private func save() {
        // 删除后离开页面：什么都不写，否则 upsert 会把刚删的账户加回来。
        guard !removed else { return }
        applyPastedEndpoint()
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard trimmedHost.isEmpty == false, let port = parsedPort else {
            // ★ 2026-11-09 多账户：旧版「主机清空 = 移除整个目的地」的隐式删除
            //   改为 no-op（删除走编辑页里的「移除这个服务器」按钮），只留
            //   端口非法的报错，避免半填的表单静默清掉配置。
            if !trimmedHost.isEmpty {
                probe = (false, L10n.WebDAV.badPort)
            }
            return
        }
        var cfg = WebDAVConfig(
            host: trimmedHost,
            port: port,
            useHTTPS: useHTTPS,
            username: username.trimmingCharacters(in: .whitespaces).credentialNormalized,
            // ★ 2026-10-30：Nextcloud 的目录由用户名推导（/remote.php/dav/files/<用户名>/），
            //   不能把表单里那格（本来就隐藏了）的默认 /nomily 存下去。
            basePath: effectiveBasePath,
            preset: preset.isEmpty ? nil : preset,
            // ★ 2026-10-30：进 Keychain 之前就清干净，别把不可见字符存下去。
            password: password.credentialNormalized.isEmpty ? nil : password.credentialNormalized,
            syncAudio: syncAudio,
            allowSelfSigned: allowSelfSigned,
            uploadContent: upload
        )
        if let accountID { cfg.id = accountID } // 编辑：保持原账户身份（密码槽跟着 id 走）
        // 新建自动成为「使用中」；编辑不动使用中标记（切换走显式按钮）。
        configService.config.upsertWebDAVAccount(cfg, makeActive: accountID == nil)
        configService.saveNow()
    }

    /// ★ 2026-11-09：把正在编辑的账户设为自动备份目标。
    private func setActive() {
        guard let accountID else { return }
        configService.config.webdavActiveID = accountID
        configService.config.syncWebDAVMirror()
        configService.saveNow()
        activeNote = L10n.WebDAV.setActiveDone
    }

    /// ★ 2026-11-09：移除正在编辑的账户（显式删除，替代旧的「主机清空」）。
    private func removeAccount() {
        guard let accountID else { return }
        removed = true
        configService.config.removeWebDAVAccount(id: accountID)
        SecretStore.delete(key: ConfigService.webdavPasswordKey(accountID: accountID))
        configService.saveNow()
        dismiss()
    }

    // MARK: - Endpoint parsing


    /// ★ 2026-10-30：把粘贴进主机框的完整 URL 拆开——`http://192.168.15.102:5005`
    /// → 主机 `192.168.15.102`、端口 `5005`、HTTPS 关。极空间/群晖客户端的「复制」
    /// 按钮给的都是这种串，逐字重抄是最容易错的一步。
    /// ★ 二稿：裸 `ip:端口`（没有 `://`）也拆——调用点都是"提交时刻"
    /// （回车/测试/保存），不存在打字打一半的问题；顺手把全角数字/冒号
    /// 归一成半角（中文键盘最容易埋的雷）。
    private func applyPastedEndpoint() {
        var text = host.trimmingCharacters(in: .whitespaces).fullwidthNormalized
        // 全角冒号＼数字先归一，再走同一条解析路径。
        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            if scheme == "https" {
                useHTTPS = true
            } else if scheme == "http" {
                useHTTPS = false
            }
            text = String(text[schemeRange.upperBound...])
            // ★ 2026-10-30（Nextcloud 引导）：末尾可能带着路径——
            //   `https://cloud.example.com/remote.php/dav/files/alice/` 整串粘进来
            //   时，主机后面的部分不能直接扔：Nextcloud 的路径里藏着用户名，
            //   其他 NAS 的路径就是目录。交给 applyPastedPath 处理。
            if let slash = text.firstIndex(of: "/") {
                let pathPart = String(text[slash...])
                text = String(text[..<slash])
                applyPastedPath(pathPart)
            }
        }
        if let colon = text.lastIndex(of: ":"),
           let p = Int(text[text.index(after: colon)...]),
           (1...65535).contains(p) {
            portText = String(p)
            text = String(text[..<colon])
        }
        host = text
    }

    /// ★ 2026-10-30（Nextcloud 引导）：粘贴的 URL 里主机后面的路径怎么用。
    ///   · `/remote.php/dav/files/<用户名>/` → 用户名直接回填（Nextcloud 客户端
    ///     复制的 WebDAV 地址就是这个形状），目录走自动推导，不用动；
    ///   · `/remote.php/webdav…`（旧版端点）→ 目录原样保留；
    /// Detect browser sharing URLs so they are not used as WebDAV endpoints.
    private static let sharePathRegex = try? NSRegularExpression(
        pattern: #"^/(f|s|d)/[A-Za-z0-9._-]+/?$"#)

    private func applyPastedPath(_ path: String) {
        if let re = Self.sharePathRegex,
           re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil {
            pasteNote = L10n.WebDAV.pastedShareLink
            return
        }
        pasteNote = nil
        let filesMarker = "/remote.php/dav/files/"
        if path.hasPrefix(filesMarker) {
            let user = path.dropFirst(filesMarker.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !user.isEmpty { username = String(user) }
            basePath = filesMarker + user + "/"
        } else if path.hasPrefix("/remote.php/webdav") {
            basePath = "/remote.php/webdav/"
        } else if !path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            basePath = path.hasSuffix("/") ? path : path + "/"
        }
        // 根路径（"/"）没有可提取的信息，忽略。
    }

    // MARK: - Actions

    private func test() async {
        applyPastedEndpoint()
        guard let port = parsedPort else {
            probe = (false, L10n.WebDAV.badPort)
            return
        }
        probing = true
        probe = nil
        defer { probing = false }

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces).fullwidthNormalized

        // ★ 2026-10-30：密码里混进看不见的字符（复制带来的零宽符、结尾换行、
        //   全角小数点）时，用户自己再怎么重打也是同样的结果。网络层已经统一
        //   清洗，这里把这件事说出来，并把清洗后的值写回输入框。
        let passwordCleaned = password != password.credentialNormalized
        if passwordCleaned { password = password.credentialNormalized }
        func annotate(_ text: String) -> String {
            passwordCleaned ? text + "（密码里的空格/不可见字符已自动清理）" : text
        }

        func make(_ path: String) -> WebDAVClient {
            WebDAVClient(
                host: trimmedHost,
                port: port,
                useHTTPS: useHTTPS,
                username: trimmedUser,
                password: password,
                basePath: path,
                allowSelfSigned: allowSelfSigned
            )
        }

        var basePath = effectiveBasePath
        if !isNextcloud, basePath == "/nomily",
           let space = await make("/").discoverPersonalSpace(username: trimmedUser) {
            basePath = space + "/nomily"
            self.basePath = basePath
        }

        do {
            let ms = try await make(basePath).testConnection()
            probe = (true, annotate(basePath == effectiveBasePath
                ? L10n.WebDAV.testOk(ms)
                : L10n.WebDAV.testOkDiscovered(ms, basePath)))
            return
        } catch {
            // ★ 自愈重试：目录填错时极空间报 401/404，话术再好也不如直接修好。
            //   扫根目录找个人空间，切过去再试一次；成功就把新目录回填表单。
            if let space = await make("/").discoverPersonalSpace(username: trimmedUser) {
                let retryPath = space + "/nomily"
                if retryPath != basePath,
                   let ms = try? await make(retryPath).testConnection() {
                    self.basePath = retryPath
                    probe = (true, annotate(L10n.WebDAV.testOkDiscovered(ms, retryPath)))
                    return
                }
            }
            probe = (false, annotate(error.localizedDescription))
        }
    }

    private func basePathText() -> String {
        basePath.trimmingCharacters(in: .whitespaces).isEmpty ? "/nomily" : basePath
    }

    private func syncNow() async {
        save() // commit the form first — sync reads config
        await sync.syncAll(config: configService.config)
    }
}

private struct WebDAVFolderPicker: View {
    let client: WebDAVClient
    let initialPath: String
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var dirs: [WebDAVClient.DirectoryEntry] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(WebDAVClient.normalizedDirPath(path))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L10n.WebDAV.useThisFolder, systemImage: "checkmark.circle.fill")
                                .font(.body.weight(.semibold))
                            Text(path.isEmpty ? initialPath : path)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .disabled(loading)
                    if path != "/" {
                        Button {
                            Task { await go(to: parentPath) }
                        } label: {
                            Label(L10n.WebDAV.parentFolder, systemImage: "arrow.uturn.backward")
                        }
                        .disabled(loading)
                    }
                }
                Section {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if dirs.isEmpty {
                        Text(L10n.WebDAV.noSubfolders)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dirs) { dir in
                            Button {
                                Task { await go(to: dir.path) }
                            } label: {
                                Label(dir.name, systemImage: "folder.fill")
                                    .foregroundStyle(.primary)
                            }
                            .disabled(loading)
                        }
                    }
                } header: {
                    Text(L10n.WebDAV.subfolders)
                } footer: {
                    Text(L10n.WebDAV.pickFolderFooter)
                }
            }
            .navigationTitle(L10n.WebDAV.pickFolder)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if path.isEmpty {
                path = WebDAVClient.normalizedDirPath(initialPath)
                await load()
            }
        }
    }

    private var parentPath: String {
        let trimmed = path.dropLast()              // 去掉结尾 /
        if let idx = trimmed.lastIndex(of: "/") {
            let parent = String(trimmed[...idx])
            return parent == "/" ? "/" : parent
        }
        return "/"
    }

    private func go(to newPath: String) async {
        path = WebDAVClient.normalizedDirPath(newPath)
        await load()
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            dirs = try await client.listDirectories(at: path)
        } catch {
            dirs = []
            errorText = error.localizedDescription
        }
    }
}
