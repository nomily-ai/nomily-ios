import Foundation
import UIKit

enum MindMapSnapshot {

    @MainActor
    static func pngData(markdown: String, title: String, dark: Bool = false) -> Data? {
        guard let parsed = MarkdownOutline.parse(markdown) else { return nil }
        let template = MindMapTemplate.detect(parsed)
        let tree = template.apply(to: parsed)
        let level = min(3, max(1, tree.maxDepth))
        let folded = MindMapLayout.foldPoints(in: tree, showingLevels: level)

        // 和 `MindMapScreen.exportPNG` 同一套缩放规则：大图降 scale，免得
        // 一张 3x 的长图吃掉几十 MB 内存。
        let size = MindMapLayout.build(tree: tree, collapsed: folded, rootLabel: title).size
        let points = size.width * size.height
        let scale: CGFloat = points > 8_000_000 ? 1 : (points > 2_000_000 ? 2 : 3)

        let layout = MindMapLayout.build(tree: tree, collapsed: folded, rootLabel: title)
        guard let image = MindMapExporter.image(
            layout: layout, rootLabel: title, dark: dark, scale: scale
        ) else { return nil }
        return image.pngData()
    }
}
