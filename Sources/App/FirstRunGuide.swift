import SwiftUI

enum GuideStep: Int, CaseIterable {
    case connectDevice = 0
    case liveTranscribe
    case configureASR
    case configureLLM
    case cloudBackup

    var title: String {
        switch self {
        case .connectDevice:  return L10n.Guide.titleConnect
        case .liveTranscribe: return L10n.Guide.titleLive
        case .configureASR:   return L10n.Guide.titleASR
        case .configureLLM:   return L10n.Guide.titleLLM
        case .cloudBackup:    return L10n.Guide.titleBackup
        }
    }

    var body: String {
        switch self {
        case .connectDevice:  return L10n.Guide.bodyConnect
        case .liveTranscribe: return L10n.Guide.bodyLive
        case .configureASR:   return L10n.Guide.bodyASR
        case .configureLLM:   return L10n.Guide.bodyLLM
        case .cloudBackup:    return L10n.Guide.bodyBackup
        }
    }

    /// 主按钮文案；nil = 该步只有「下一步」。
    var primaryButton: String? {
        switch self {
        case .connectDevice:  return L10n.Guide.actionConnect
        case .liveTranscribe: return nil
        case .configureASR:   return L10n.Guide.actionGo
        case .configureLLM:   return L10n.Guide.actionGo
        case .cloudBackup:    return L10n.Guide.actionGo
        }
    }

    var icon: String {
        switch self {
        case .connectDevice:  return "dot.radiowaves.left.and.right"
        case .liveTranscribe: return "waveform.badge.mic"
        case .configureASR:   return "text.bubble"
        case .configureLLM:   return "sparkles"
        case .cloudBackup:    return "icloud.and.arrow.up"
        }
    }

    var tint: Color {
        switch self {
        case .connectDevice:  return .blue
        case .liveTranscribe: return .teal
        case .configureASR:   return .indigo
        case .configureLLM:   return .purple
        case .cloudBackup:    return .orange
        }
    }

    /// 「第 N 步 · 共 5 步」。
    var progressText: String {
        String(format: L10n.Guide.stepOf, index + 1, GuideStep.allCases.count)
    }

    var index: Int { rawValue }
}

struct GuideCardView: View {
    let step: GuideStep
    /// 主按钮（去连接 / 前往）：RootView 提供深链与扫描拉起。
    var primaryAction: () -> Void = {}
    /// 下一步。
    var advance: () -> Void
    /// 跳过整条引导。
    var skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: step.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(step.tint.gradient)
                Text(step.progressText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(L10n.Guide.skip, action: skip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(step.title)
                .font(.headline)
            Text(step.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if let primary = step.primaryButton {
                    // ★ 主按钮只触发动作（扫描/深链）；是否推进到下一步由 RootView
                    // 决定——主按钮已经导航时，推进逻辑不该再切 tab。
                    Button(action: primaryAction) {
                        Text(primary)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(step.tint)
                }
                Button {
                    advance()
                } label: {
                    Text(step.primaryButton == nil ? L10n.Guide.next : L10n.Guide.later)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(step.tint.gradient.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
