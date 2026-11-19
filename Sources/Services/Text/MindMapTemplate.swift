import Foundation

enum MindMapTemplate: String, CaseIterable {
    case topic
    case minutes
    case people
    case timeline
    case actions

    var label: String {
        switch self {
        case .topic:    return L10n.ClipDetail.mapTemplateTopic
        case .minutes:  return L10n.ClipDetail.mapTemplateMinutes
        case .people:   return L10n.ClipDetail.mapTemplatePeople
        case .timeline: return L10n.ClipDetail.mapTemplateTimeline
        case .actions:  return L10n.ClipDetail.mapTemplateActions
        }
    }

    var symbol: String {
        switch self {
        case .topic:    return "circle.hexagongrid"
        case .minutes:  return "person.2"
        case .people:   return "person.crop.circle"
        case .timeline: return "arrow.right.to.line"
        case .actions:  return "checklist"
        }
    }

    // MARK: 识别

    private static let minutesRank: [String] = [
        "总结", "结论", "概要", "摘要", "summary", "conclusion",
        "要点", "关键", "highlight", "key point",
        "讨论", "议题", "详情", "discussion", "topic",
        "待办", "行动", "跟进", "todo", "action", "next step",
        "风险", "问题", "未决", "risk", "open question",
    ]

    static func detect(_ root: OutlineNode) -> MindMapTemplate {
        let branches = root.children
        guard !branches.isEmpty else { return .topic }
        let titles = branches.map { $0.title.lowercased() }
        let joined = titles.joined(separator: "|")

        func any(_ needles: [String]) -> Bool { needles.contains { joined.contains($0) } }

        // 组织图：至少两个人名、至少三条 `姓名：事项` 形式的条目。
        // ⚠️ 阈值不能低：一句"张伟：下周三给方案"只是待办写法，不是会议组织图。
        let owners = OwnerScan.group(root)
        let ownerTotal = owners.byOwner.values.reduce(0) { $0 + $1.count }
        if owners.byOwner.count >= 2 && ownerTotal >= 3 { return .people }

        if any(["阶段", "流程", "步骤", "时间轴", "复盘", "process", "phase", "timeline", "step"]) {
            return .timeline
        }
        if any(["待办", "行动项", "action item", "to-do", "todo", "next step"]) { return .actions }
        if any(["参会", "议程", "决议", "出席", "会议", "attendee", "agenda", "decision", "minutes"]) {
            return .minutes
        }
        return .topic
    }

    // MARK: 应用

    /// 只改**根的直接子分支**与它们的顺序：那是"这张图长什么样"的全部。
    /// 深层的父子关系保持摘要自己的结构，不为了模板去编造层级。
    func apply(to root: OutlineNode) -> OutlineNode {
        switch self {
        case .topic:
            return root

        case .minutes:
            let sorted = root.children.enumerated().sorted { lhs, rhs in
                let l = Self.rank(lhs.element.title), r = Self.rank(rhs.element.title)
                return l == r ? lhs.offset < rhs.offset : l < r
            }.map(\.element)
            return Self.rebuild(root, children: sorted)

        case .actions:
            let todo = root.children.filter { Self.isTodoBranch($0.title) }
            let rest = root.children.filter { !Self.isTodoBranch($0.title) }
            return Self.rebuild(root, children: todo + rest)

        case .timeline:
            let glyphs = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]
            let numbered = root.children.enumerated().map { index, node -> OutlineNode in
                // 摘要自己已经写成 "1. 需求确认" 的段落不再叠加序号。
                guard index < glyphs.count, !Self.hasLeadingNumber(node.title) else { return node }
                return Self.retitled(node, title: glyphs[index] + " " + node.title)
            }
            return Self.rebuild(root, children: numbered)

        case .people:
            let (grouped, remaining) = OwnerScan.group(root)
            guard !grouped.isEmpty else { return root }
            var branches: [OutlineNode] = grouped
                .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
                .map { owner, items in
                    OutlineNode(id: 0, title: owner, depth: 1, kind: .heading,
                                children: items.map { node in
                                    // 去掉"张伟："这个前缀——父节点已经是人了，重复一遍是噪音。
                                    Self.retitled(node, title: OwnerScan.stripPrefix(node.title),
                                                  depth: 2, children: nil)
                                })
                }
            if !remaining.isEmpty {
                branches.append(OutlineNode(id: 0, title: L10n.ClipDetail.mapTemplateOthers,
                                            depth: 1, kind: .heading, children: remaining))
            }
            return Self.rebuild(root, children: branches)
        }
    }

    // MARK: 工具

    private static func rank(_ title: String) -> Int {
        let t = title.lowercased()
        for (index, needle) in minutesRank.enumerated() where t.contains(needle) { return index }
        return minutesRank.count
    }

    private static func isTodoBranch(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("待办") || t.contains("行动") || t.contains("跟进")
            || t.contains("todo") || t.contains("to-do") || t.contains("action")
    }

    private static func hasLeadingNumber(_ title: String) -> Bool {
        title.range(of: #"^\s*(\d{1,2}[.)、]|[①-⑩])"#, options: .regularExpression) != nil
    }

    /// 换标题 / 换深度 / 换子节点，`id` 由 `rebuild` 统一重发。
    private static func retitled(_ node: OutlineNode,
                                 title: String? = nil,
                                 depth: Int? = nil,
                                 children: [OutlineNode]? = nil) -> OutlineNode {
        OutlineNode(id: node.id,
                    title: title ?? node.title,
                    depth: depth ?? node.depth,
                    kind: node.kind,
                    children: children ?? node.children)
    }

    /// 重建整棵树并**按深度优先重发 id**。
    ///
    /// ⚠️ 必须重发：折叠状态（`collapsed: Set<Int>`）是按 id 存的，重组之后的
    ///    树如果沿用旧 id，"折起来的那个分支"会在模板切换后指到另一个节点上。
    private static func rebuild(_ node: OutlineNode, children: [OutlineNode]) -> OutlineNode {
        var next = 0
        func walk(_ n: OutlineNode, depth: Int) -> OutlineNode {
            let me = next
            next += 1
            return OutlineNode(id: me, title: n.title, depth: depth, kind: n.kind,
                               children: n.children.map { walk($0, depth: depth + 1) })
        }
        // 先把换过的子分支按新层级整理，再整体发号。
        let regrounded = children.map { child -> OutlineNode in
            func depth(_ n: OutlineNode, _ d: Int) -> OutlineNode {
                OutlineNode(id: n.id, title: n.title, depth: d, kind: n.kind,
                            children: n.children.map { depth($0, d + 1) })
            }
            return depth(child, 2)
        }
        return walk(OutlineNode(id: node.id, title: node.title, depth: 0,
                                kind: node.kind, children: regrounded), depth: 0)
    }
}

// MARK: - `姓名：事项` 扫描

/// 从全树里找 `张伟：下周三给方案` 这种"有人名在前"的叶子。
///
/// 只认**标题开头**的人名，且名字长度 1–6 个字符（中文名 2–4、英文名可能带空格），
/// 中文冒号与英文冒号都算。这样"成本：上涨 15%"这种以名词开头的行会被当成
/// 普通事项——它本来就不是一个人。
private enum OwnerScan {
    /// 以人为父节点重组：返回 (人名 → 该人的事项) 与"没有主人"的**整支**分支。
    ///
    /// ⚠️ 没被认领的分支必须**整支**留下来（连它的子节点一起）。早期版本只收
    ///    没有子节点的叶子当"其他"，结果"讨论详情"这类有下级的章节会整个消失——
    ///    模板不该以丢内容为代价。
    static func group(_ root: OutlineNode) -> (byOwner: [String: [OutlineNode]], remaining: [OutlineNode]) {
        var byOwner: [String: [OutlineNode]] = [:]
        var remaining: [OutlineNode] = []

        for branch in root.children {
            if let owner = ownerPrefix(branch.title) {
                byOwner[owner, default: []].append(branch)
                continue
            }
            // 整支都是"人：事"的清单（典型是「待办事项」）——拆到各人名下。
            let kids = branch.children
            if !kids.isEmpty, kids.allSatisfy({ ownerPrefix($0.title) != nil }) {
                for kid in kids {
                    if let owner = ownerPrefix(kid.title) {
                        byOwner[owner, default: []].append(kid)
                    }
                }
                continue
            }
            remaining.append(branch)
        }
        return (byOwner, remaining)
    }

    static func stripPrefix(_ title: String) -> String {
        guard let range = title.range(of: #"^[^：:]{1,6}[：:]\s*"#, options: .regularExpression) else {
            return title
        }
        return String(title[range.upperBound...])
    }

    private static func ownerPrefix(_ title: String) -> String? {
        guard let range = title.range(of: #"^[^：:]{1,6}[：:]\s*"#, options: .regularExpression) else {
            return nil
        }
        let name = title[range].trimmingCharacters(in: CharacterSet(charactersIn: "：: ").union(.whitespaces))
        // 纯数字/纯符号开头的不是人名（"15%：成本"）。
        guard name.contains(where: { $0.isLetter }), !name.contains(" ") || name.count <= 5 else { return nil }
        // 常见"不是人"的名词前缀，挡掉误判。
        let blocked = ["时间", "地点", "成本", "预算", "风险", "问题", "结论", "备注", "目标"]
        guard !blocked.contains(name) else { return nil }
        return name
    }
}
