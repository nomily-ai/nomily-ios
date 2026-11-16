import SwiftUI

struct WelcomeSheet: View {
    /// 「开始使用」：关闭本页，进入 App。
    var start: () -> Void

    /// 三条示例：图标 / 颜色 / 标题 / 一句话说明。
    /// 标题与 `DemoContent` 的中英文示例标题保持一致。
    private var samples: [(icon: String, tint: Color, title: String, body: String)] {
        [
            ("book.fill", .orange, L10n.Welcome.sampleGuideTitle, L10n.Welcome.sampleGuideBody),
            ("envelope.open.fill", .blue, L10n.Welcome.sampleWelcomeTitle, L10n.Welcome.sampleWelcomeBody),
            ("waveform", .red, L10n.Welcome.sampleMeetingTitle, L10n.Welcome.sampleMeetingBody),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    samplesCard
                }
                .padding(.horizontal, 22)
                .padding(.top, 44)
                .padding(.bottom, 12)
            }

            footer
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.appAccent.gradient)
                )
                .shadow(color: Color.appAccent.opacity(0.28), radius: 12, y: 6)
                .accessibilityHidden(true)

            Text(L10n.Welcome.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(L10n.Welcome.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - the three samples

    private var samplesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.Welcome.samplesHeader)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: sample.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(sample.tint)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(sample.title)
                            .font(.subheadline.weight(.semibold))
                        Text(sample.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if index < samples.count - 1 {
                    Divider().padding(.leading, 57)
                }
            }
            .padding(.bottom, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - footer

    private var footer: some View {
        VStack(spacing: 12) {
            Text(L10n.Welcome.footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: start) {
                Text(L10n.Welcome.start)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}
