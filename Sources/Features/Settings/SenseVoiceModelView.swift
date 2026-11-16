import SwiftUI
import UniformTypeIdentifiers

struct SenseVoiceModelView: View {
    @ObservedObject private var store = SenseVoiceModelStore.shared
    /// ★ 2026-11-02：手工导入（隔空投送 / 文件 App）。所有镜像都被挡时的最后一条路。
    @State private var showImporter = false
    @State private var importMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.SenseVoice.name, systemImage: "waveform.badge.mic")
                        .font(.headline)
                    Text(L10n.SenseVoice.desc)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.SenseVoice.footer)
            }

            Section {
                switch store.phase {
                case .idle:
                    Button {
                        store.download()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(L10n.SenseVoice.download)
                            Spacer()
                            Text(L10n.SenseVoice.sizeHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .downloading(let fraction):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L10n.SenseVoice.downloading)
                            Spacer()
                            Text("\(Int(fraction * 100))%")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: fraction)
                        Text(L10n.SenseVoice.downloadingHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .ready:
                    LabeledContent(L10n.SenseVoice.statusRow) {
                        Text(L10n.SenseVoice.ready(
                            SenseVoiceModelStore.downloadedSizeText ?? "—"))
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                    Button(role: .destructive) {
                        store.delete()
                    } label: {
                        Label(L10n.SenseVoice.deleteModel, systemImage: "trash")
                    }
                case .failed(let message):
                    Label(L10n.SenseVoice.failed, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        store.download()
                    } label: {
                        Label(L10n.SenseVoice.retry, systemImage: "arrow.clockwise")
                    }
                }
            } header: {
                Text(L10n.SenseVoice.manageHeader)
            }

            if !store.isDownloaded {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label(L10n.SenseVoice.importModel, systemImage: "folder.badge.plus")
                    }
                } footer: {
                    Text(L10n.SenseVoice.importHint)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data, .plainText, .item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if !store.importModels(from: urls) {
                    importMessage = L10n.SenseVoice.importIncomplete
                }
            case .failure(let error):
                importMessage = error.localizedDescription
            }
        }
        .alert(L10n.SenseVoice.importModel, isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button(L10n.Common.ok) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .navigationTitle(L10n.SenseVoice.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
    }
}
