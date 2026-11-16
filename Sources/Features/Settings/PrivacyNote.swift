import SwiftUI

struct PrivacyNote: View {
    enum Flavor {
        /// Where recordings and transcripts live.
        case storage
        /// Cloud ASR/LLM — what leaves the device and when.
        case cloud
        /// Backup/export destinations.
        case backup

        var text: String {
            switch self {
            case .storage: return L10n.Privacy.storageNote
            case .cloud: return L10n.Privacy.cloudNote
            case .backup: return L10n.Privacy.backupNote
            }
        }
    }

    let flavor: Flavor

    var body: some View {
        Label {
            Text(flavor.text)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
