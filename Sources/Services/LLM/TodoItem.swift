import Foundation

struct TodoItem: Equatable {
    var title: String
    var owner: String?
    var due: String?
    /// 来源秒数（摘要里的 `[mm:ss]`）。
    var stamp: TimeInterval?

    /// 拼回一行。分隔符用 ` · `：中英文都不撞，且用户一眼能看出这是三段。
    var composed: String {
        var pieces = [title]
        if let owner, !owner.isEmpty { pieces.append("@\(owner)") }
        if let due, !due.isEmpty { pieces.append(due) }
        if let stamp { pieces.append("[\(StampRef.format(stamp))]") }
        return pieces.joined(separator: " · ")
    }

    /// 从一行文本还原。容错优先：认不出来就当标题，绝不返回 nil——
    /// 待办行丢一条比显示得糙一点严重得多。
    static func parse(_ raw: String) -> TodoItem {
        let stripped = StampRef.stripping(raw).trimmingCharacters(in: .whitespaces)
        var parts = stripped.components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let title = parts.isEmpty ? stripped : parts.removeFirst()
        var owner: String?
        var due: String?
        for part in parts where !part.isEmpty {
            if part.hasPrefix("@") {
                owner = String(part.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if due == nil {
                due = part
            }
        }
        return TodoItem(title: title, owner: owner, due: due, stamp: StampRef.parse(raw))
    }

    /// 解析一行 Markdown 表格。表头、分隔行、空行都返回 nil（它们不是待办）。
    static func fromTableRow(_ line: String) -> TodoItem? {
        guard line.contains("|") else { return nil }
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        guard cells.count >= 2 else { return nil }
        // `|---|---|`
        if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }) { return nil }

        let title = cells[0]
        guard !title.isEmpty else { return nil }
        // 表头行：第一格就是列名。
        let headerWords = ["事项", "任务", "内容", "待办", "item", "action", "task", "to-do", "todo", "no.", "#"]
        if headerWords.contains(where: { title.lowercased() == $0 }) { return nil }

        func cell(_ index: Int) -> String? {
            guard index < cells.count else { return nil }
            let value = cells[index]
            // 模型仍可能写 "TBD" 之类——空着比写假话好。
            guard !value.isEmpty, !isPlaceholder(value) else { return nil }
            return value
        }
        return TodoItem(
            title: title,
            owner: cell(1),
            due: cell(2),
            stamp: cells.count > 3 ? StampRef.parseLoose(cells[3]) : StampRef.parse(line)
        )
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        let markers = ["tbd", "tbc", "na", "n/a", "none", "unknown", "待确认", "未提及", "未知", "无", "—", "-"]
        return markers.contains(trimmed.lowercased())
    }
}

// MARK: - 表格折叠（显示用）
//
// 成文层被要求用表格写待办，因为**表格才有列**：责任人和截止是字段，不是句子里的
// 一串字。但原生渲染器（`MarkdownBlocks.parse`）只认标题/要点/引用/段落，管道行
// 会原样显示成 `| 事项 | 责任人 | 截止 | 来源 |`——比不排版的纯文本还难看。
//
// 所以渲染前折一道：表格数据行 → 一条要点（`事项 · @张伟 · 11-08 · [12:24]`），
// 表头与分隔行直接扔掉。**只动显示，不动存储**：`TodoExtract` 仍然从原表格读出
// 结构，源文件也仍然是那张表。
enum MarkdownTable {

    static func fold(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        var output: [MarkdownBlock] = []
        for block in blocks {
            // 只处理"整行以 | 开头"的块：正文明文里偶尔出现一个竖线不该被当成表格。
            let isTableLine: Bool
            switch block.kind {
            case .paragraph, .bullet:
                isTableLine = block.text.trimmingCharacters(in: .whitespaces).hasPrefix("|")
            default:
                isTableLine = false
            }
            guard isTableLine else {
                output.append(block)
                continue
            }
            guard let item = TodoItem.fromTableRow(block.text) else { continue }
            output.append(MarkdownBlock(kind: .bullet, text: item.composed))
        }
        return output
    }
}
