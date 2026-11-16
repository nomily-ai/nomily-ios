import SwiftUI

struct StorageLocationsView: View {
    @EnvironmentObject private var configService: ConfigService
    // 文件夹备份状态（自动备份徽标要实时反映开关）。
    @ObservedObject private var folderExport = FolderExportService.shared
    // ★ 2026-10-30：WebDAV 入口是类型选择弹层（与录音与转写页共用）。
    @State private var showWebDAVSetup = false

    var body: some View {
        Form {
            Section {
                Picker(L10n.StorageLocations.uploadScope, selection: Binding(
                    get: { configService.config.autoUploadScope ?? "all" },
                    set: { newValue in
                        configService.config.autoUploadScope = newValue == "all" ? nil : newValue
                        configService.saveNow()
                    }
                )) {
                    Text(L10n.StorageLocations.scopeAll).tag("all")
                    Text(L10n.StorageLocations.scopeWithSummary).tag("with_summary")
                    Text(L10n.StorageLocations.scopeManual).tag("manual")
                }
            } header: {
                Text(L10n.StorageLocations.uploadScope)
            } footer: {
                Text(L10n.StorageLocations.uploadScopeFooter)
            }

            Section {
                // 1. 这台 iPhone —— 主存储。转写后的音频/文本都在 decryptedDir，
                //    点进去看占用明细。
                NavigationLink {
                    StorageUsageView()
                } label: {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(L10n.StorageLocations.iphone, systemImage: "iphone")
                            Text(L10n.StorageLocations.iphoneDesc)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 2. iCloud 云盘 —— 自动云备份的首选落点。FolderBackupView 首次
                //    进入会自动打开选择器，起点就是 iCloud 云盘根目录。
                NavigationLink {
                    FolderBackupView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(L10n.StorageLocations.icloud, systemImage: "icloud")
                            Spacer()
                            if folderExport.autoEnabled {
                                Text(L10n.FolderExport.autoOn)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if let name = folderExport.folderName {
                                Text(name)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(L10n.StorageLocations.icloudDesc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // 3. NAS —— WebDAV 类型选择弹层，选完进对应预设的配置页。
                Button {
                    showWebDAVSetup = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(L10n.StorageLocations.nas, systemImage: "server.rack")
                                .foregroundStyle(.primary)
                            Spacer()
                            // ★ 2026-11-09 多账户：右侧显示「当前使用」的那台；
                            //   存了多台时补「共 N 台」，提示还有别的账户可切。
                            if let webdav = configService.config.webdav, webdav.isConfigured {
                                let count = configService.config.webdavAccounts?.count ?? 1
                                Text(count > 1
                                     ? "\(webdav.preset ?? webdav.host) · \(L10n.WebDAV.serverCount(count))"
                                     : webdav.preset ?? webdav.host)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(L10n.WebDAV.unconfigured)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(L10n.StorageLocations.nasDesc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // 4. 文件夹 App —— 任意位置导出（第三方网盘、外接盘等）。
                NavigationLink {
                    FolderBackupView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(L10n.StorageLocations.folder, systemImage: "folder")
                            Spacer()
                            if let name = folderExport.folderName, !folderExport.autoEnabled {
                                Text(name)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(L10n.StorageLocations.folderDesc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.StorageLocations.sectionHeader)
            } footer: {
                Text(L10n.StorageLocations.footer)
            }
        }
        .navigationTitle(L10n.StorageLocations.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWebDAVSetup) {
            WebDAVSetupSheet()
        }
    }
}
