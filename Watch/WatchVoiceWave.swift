import SwiftUI

struct WatchVoiceWave: View {
    /// The current level. `level` decides how tall this slot is; `tick` drives the advance —
    /// see the block at the top of `WatchAudioMeter` (when quiet `level` is constantly 0,
    /// `onChange(of: level)` never fires once, and `tick` is how we know to move).
    let meter: WatchAudioMeter
    /// The nominal side length of this face, sharing one set of proportions with the eyes.
    let size: CGFloat
    /// The wave's colour. It follows the colour chosen on the "Appearance" page (the same source as the eyes).
    let tint: Color

    /// The level history inside the scrolling window, with the newest slot on the right.
    @State private var samples: [CGFloat]
    /// When the last slot came in. Used to work out how far it has slid between two samples.
    @State private var lastTickAt = Date()
    /// Stops the whole timeline when dimmed (Always-On).
    @Environment(\.isLuminanceReduced) private var reduced

    /// How many slots fit on one screen. 34 slots ÷ 12.5Hz ≈ 2.7 seconds.
    private static let sampleCount = 34

    /// The interval between samples. Must match `WatchRecorderModel.meterInterval`.
    private static let tickInterval: TimeInterval = 0.08

    /// The redraw rate（省电模式下降到 2fps，见 `lowPower`）。
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    init(meter: WatchAudioMeter, size: CGFloat, tint: Color, lowPower: Bool = false, levelScale: CGFloat = 1) {
        self.meter = meter
        self.size = size
        self.tint = tint
        self.lowPower = lowPower
        self.levelScale = levelScale
        _samples = State(initialValue: Array(repeating: 0, count: Self.sampleCount))
    }

    /// ★ 2026-11-02（全天候录音 · 省电）：重绘从 30fps 降到 **2fps**——
    /// 采样本身已降到 2Hz，两次采样之间没有新信息，高帧率只是把同一条线画 15 遍。
    var lowPower: Bool

    /// ★ 2026-11-03（V4 原型）：振幅系数 0…1。**停止录音的收场动画**用：
    /// 原型 opening 段 0–320ms 先把振幅收平（`af=1-smooth(seg(el,0,320))`）、
    /// 340–820ms 线再从两端收回中心——两件事是叠着做的。
    /// 之前只有"收线"没有"收幅"，电平还没归零时线带着幅度往里缩，
    /// 看起来就是用户说的"半圆往内缩"，而不是"波形平掉、睁眼"。
    var levelScale: CGFloat = 1

    private var frameIntervalNow: TimeInterval { lowPower ? 0.5 : Self.frameInterval }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameIntervalNow, paused: reduced)) { timeline in
            Canvas { context, canvasSize in
                render(
                    into: &context,
                    canvas: canvasSize,
                    phase: scrollPhase(at: timeline.date)
                )
            }
        }
        .frame(width: size * 1.26, height: size * 0.80)
        // ★ 2026-11-03（V4）：两端渐隐改用**外挂 mask**——`Canvas` 里对每段 path 手算
        // 渐变既繁琐又慢，一个横向 LinearGradient 的 mask 一次搞定，且只渲染一次。
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.14),
                    .init(color: .white, location: 0.86),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .onChange(of: meter) { _, new in advance(using: new) }
        .accessibilityHidden(true)
    }

    /// How far it has slid between two samples, `0 ..< 1`.
    private func scrollPhase(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(lastTickAt)
        guard elapsed > 0 else { return 0 }
        return min(1, elapsed / Self.tickInterval)
    }

    /// Advance one slot. **Driven by `tick`**, not by `level` — see the `WatchAudioMeter` block.
    private func advance(using meter: WatchAudioMeter) {
        var next = samples
        next.append(CGFloat(meter.level))
        if next.count > Self.sampleCount {
            next.removeFirst(next.count - Self.sampleCount)
        }
        samples = next
        lastTickAt = Date()
    }

    // MARK: - Draw

    private func render(
        into context: inout GraphicsContext,
        canvas: CGSize,
        phase: Double
    ) {
        let lineWidth = Self.lineWidth(for: size)
        // ★ V4：中线在画布**正中**（原型 `MID = 136/2`），振幅约为半高的 0.62
        // （原型 `MAXA 44 / MID 68`）。安静时整条线贴着中线，本身就是轴。
        let mid = canvas.height / 2
        // ★ 2026-11-03：乘上 `levelScale`——停止录音时由 `WatchBotFace` 把它压到 0，
        // 复刻原型"先收幅、再收线"的叠层（见属性注释）。
        // ★ 七轮：0.62 → **0.74**，配合更高的画布把波纹立起来（原来太扁）。
        let amplitude = (canvas.height / 2 - lineWidth) * 0.74 * levelScale

        let count = samples.count
        guard count > 1 else { return }
        let step = canvas.width / CGFloat(count - 1)
        let shift = CGFloat(phase) * step

        var trace = Path()
        for (index, value) in samples.enumerated() {
            let x = CGFloat(index) * step - shift
            let clamped = min(1, max(0, value))
            let y = mid - clamped * amplitude
            if index == 0 {
                trace.move(to: CGPoint(x: x, y: y))
            } else {
                trace.addLine(to: CGPoint(x: x, y: y))
            }
        }
        // 头部补一段到右缘，滑动时右端不留缺口（revision 16 的做法，保留）。
        let headY = mid - min(1, max(0, samples[count - 1])) * amplitude
        trace.addLine(to: CGPoint(x: canvas.width, y: headY))

        // 主线：一根 2pt 的线，没了。
        context.stroke(
            trace,
            with: .color(tint),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )

        // 倒影：同一条路径垂直镜像（对中线翻转），1pt、0.16——原型 `echoG`。
        // `GraphicsContext` 是值类型，拷贝一份做仿射变换不影响外面那个。
        var reflection = context
        reflection.translateBy(x: 0, y: mid)
        reflection.scaleBy(x: 1, y: -1)
        reflection.translateBy(x: 0, y: -mid)
        reflection.stroke(
            trace,
            with: .color(tint.opacity(0.16)),
            style: StrokeStyle(lineWidth: lineWidth * 0.5, lineCap: .round, lineJoin: .round)
        )
    }

    private static func lineWidth(for size: CGFloat) -> CGFloat {
        max(2.2, size * 0.022)
    }
}
