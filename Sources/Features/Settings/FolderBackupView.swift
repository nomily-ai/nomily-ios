import SwiftUI
import UniformTypeIdentifiers

struct FolderBackupView: View {
    @ObservedObject private var exporter = FolderExportService.shared
    @EnvironmentObject private var configService: ConfigService

    @State private var showPicker = false
    /// ★ 2026-11-02：首次使用（没选过文件夹）进页自动弹选择器——iOS 文件
    /// 浏览器根目录默认就是 iCloud 云盘，选一次即成默认云备份路径。
    @State private var autoOpenedPicker = false

    var body: some View {
        Form {
            Section {
                Button {
                    showPicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.blue.gradient)
                        Text(L10n.FolderExport.pickFolder)
                        Spacer()
                        if let name = exporter.folderName {
                            Text(name).foregroundStyle(.secondary)
                        } else {
                            Text(L10n.FolderExport.noFolder).foregroundStyle(.secondary)
                        }
                    }
                }
                if exporter.hasFolder {
                    if let usage = exporter.usageText {
                        LabeledContent(L10n.FolderExport.usage) {
                            Text(usage)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        exporter.clear()
                    } label: {
                        Text(L10n.FolderExport.clearFolder)
                    }
                }
            } header: {
                Text(L10n.FolderExport.destination)
            } footer: {
                // ★ 2026-11-02：iCloud 引导（免签名方案——文件浏览器的根目录
                // 默认就是 iCloud 云盘，选一次即可全自动云同步）。
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.FolderExport.icloudHint)
                    Text(L10n.FolderExport.pickFooter)
                }
            }

            // ★ 2026-10-30：自动备份。放在目的地之后、手动导出之前——这是
            // 主路径（打开就全自动），手动导出只是补跑历史。
            Section {
                Toggle(L10n.FolderExport.auto, isOn: $exporter.autoEnabled)
            } footer: {
                Text(L10n.FolderExport.autoFooter)
            }

            Section {
                Toggle(L10n.FolderExport.syncAudio, isOn: $exporter.syncAudio)
            } footer: {
                Text(L10n.FolderExport.syncAudioFooter)
            }

            Section {
                Toggle(L10nUploadContent.transcript, isOn: $exporter.uploadContent.transcript)
                Toggle(L10nUploadContent.asr, isOn: $exporter.uploadContent.asrJSON)
                Toggle(L10nUploadContent.summary, isOn: $exporter.uploadContent.summary)
                Toggle(L10nUploadContent.todos, isOn: $exporter.uploadContent.todos)
                Toggle(L10nUploadContent.mindMap, isOn: $exporter.uploadContent.mindMap)
                Toggle(L10nUploadContent.chapters, isOn: $exporter.uploadContent.chapters)
                Toggle(L10nUploadContent.bundle, isOn: $exporter.uploadContent.bundle)
            } header: {
                Text(L10nUploadContent.section)
            } footer: {
                Text(L10nUploadContent.footer)
            }

            Section {
                Button {
                    Task { await exporter.exportAll() }
                } label: {
                    HStack {
                        Text(L10n.FolderExport.exportNow)
                        if exporter.isRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(exporter.isRunning || !exporter.hasFolder)
                if let report = exporter.lastReport {
                    Text(report)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.FolderExport.exportFooter)
            }

            Section {
                PrivacyNote(flavor: .backup)
            }
        }
        .navigationTitle(L10n.FolderExport.title)
        .navigationBarTitleDisplayMode(.inline)
        // ★ 2026-11-02：进页统计占用；首次使用自动弹选择器。
        .task {
            exporter.refreshUsage()
            if !exporter.hasFolder, !autoOpenedPicker {
                autoOpenedPicker = true
                showPicker = true
            }
        }
        .refreshable { exporter.refreshUsage() }
        .onChange(of: exporter.lastReport) { _ in
            // 手动导出跑完顺手刷新占用。
            exporter.refreshUsage()
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                exporter.store(from: url)
            }
        }
    }
}
