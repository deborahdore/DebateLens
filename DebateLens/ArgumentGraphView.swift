import SwiftUI

/// Neighbourhood graph around one component: ring 1 = direct relations, ring 2 = their relations.
struct ArgumentGraphView: View {
    var debate: Debate
    @Binding var focusId: String

    private let nodeSize = CGSize(width: 128, height: 60)
    private let r1: CGFloat = 175
    private let r2: CGFloat = 330
    private var canvas: CGSize { CGSize(width: r2 * 2 + nodeSize.width + 40, height: r2 * 2 + nodeSize.height + 40) }

    struct Node: Identifiable { let id: String; let component: Component; let ring: Int; var pos: CGPoint }
    struct Edge: Hashable { let source: String; let target: String; let type: String }

    private func build() -> ([Node], [Edge]) {
        let byId = debate.componentsById
        guard let center = byId[focusId] else { return ([], []) }
        func neighbours(_ c: Component) -> [String] { (c.supports + c.attacks + c.supportedBy + c.attackedBy + c.equivalentTo).filter { byId[$0] != nil } }
        let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        var nodes = [Node(id: center.id, component: center, ring: 0, pos: mid)]
        var seen: Set<String> = [center.id]
        var uniq = Set<String>(); let ring1 = neighbours(center).filter { uniq.insert($0).inserted }
        let step = 2 * .pi / CGFloat(max(ring1.count, 1))
        var ring2: [(id: String, angle: CGFloat)] = []
        for (i, id) in ring1.enumerated() where !seen.contains(id) {
            let angle = -CGFloat.pi / 2 + step * CGFloat(i)
            seen.insert(id)
            nodes.append(Node(id: id, component: byId[id]!, ring: 1, pos: CGPoint(x: mid.x + r1 * cos(angle), y: mid.y + r1 * sin(angle))))
            for n in neighbours(byId[id]!) where !seen.contains(n) && ring2.count < 18 { seen.insert(n); ring2.append((n, angle)) }
        }
        // spread ring-2 nodes around their parent's angle
        for (parentAngle, group) in Dictionary(grouping: ring2, by: \.angle) {
            let spread = min(step * 0.9, 0.55 * CGFloat(group.count))
            for (j, item) in group.enumerated() {
                let a = parentAngle + (group.count == 1 ? 0 : -spread / 2 + spread * CGFloat(j) / CGFloat(group.count - 1))
                nodes.append(Node(id: item.id, component: byId[item.id]!, ring: 2, pos: CGPoint(x: mid.x + r2 * cos(a), y: mid.y + r2 * sin(a))))
            }
        }
        let edges = debate.relations.filter { seen.contains($0.source) && seen.contains($0.target) }.map { Edge(source: $0.source, target: $0.target, type: $0.type) }
        return (nodes, Array(Set(edges)))
    }

    var body: some View {
        let (nodes, edges) = build()
        let pos = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.pos) })
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ZStack {
                    Canvas { ctx, _ in
                        for e in edges {
                            guard let a = pos[e.source], let b = pos[e.target] else { continue }
                            let color: Color = e.type == "Support" ? .support : e.type == "Attack" ? .attack : .equivalent
                            let (p, q) = trim(a, b)
                            var path = Path(); path.move(to: p); path.addLine(to: q)
                            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.2, dash: e.type == "Equivalent" ? [5, 4] : []))
                            if e.type != "Equivalent" { ctx.fill(arrowHead(at: q, from: p), with: .color(color)) }
                        }
                    }
                    ForEach(nodes) { n in
                        NodeView(component: n.component, isFocus: n.ring == 0, dim: n.ring == 2)
                            .frame(width: nodeSize.width, height: nodeSize.height)
                            .position(n.pos)
                            .onTapGesture { withAnimation(.snappy) { focusId = n.id } }
                    }
                    Color.clear.frame(width: 1, height: 1).position(x: canvas.width / 2, y: canvas.height / 2).id("center")
                }
                .frame(width: canvas.width, height: canvas.height)
            }
            .onAppear { proxy.scrollTo("center", anchor: .center) }
            .onChange(of: focusId) { withAnimation { proxy.scrollTo("center", anchor: .center) } }
        }
    }

    /// Shortens a segment so it starts and ends at the node borders.
    private func trim(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        func border(_ from: CGPoint, toward to: CGPoint) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let sx = abs(dx) > 0.01 ? (nodeSize.width / 2 + 3) / abs(dx) : .infinity
            let sy = abs(dy) > 0.01 ? (nodeSize.height / 2 + 3) / abs(dy) : .infinity
            let s = min(sx, sy)
            return CGPoint(x: from.x + dx * s, y: from.y + dy * s)
        }
        return (border(a, toward: b), border(b, toward: a))
    }

    private func arrowHead(at tip: CGPoint, from: CGPoint) -> Path {
        let angle = atan2(tip.y - from.y, tip.x - from.x), len: CGFloat = 11, w: CGFloat = 0.45
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x - len * cos(angle - w), y: tip.y - len * sin(angle - w)))
        p.addLine(to: CGPoint(x: tip.x - len * cos(angle + w), y: tip.y - len * sin(angle + w)))
        p.closeSubpath()
        return p
    }
}

struct NodeView: View {
    var component: Component
    var isFocus: Bool
    var dim: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(component.type.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(component.color)
                Spacer()
                if !component.fallacies.isEmpty { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Color.fallacy) }
                Text(component.speaker.capitalized).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(component.text).font(.system(size: 11, design: .serif)).lineLimit(3).foregroundStyle(.primary)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(component.color, lineWidth: isFocus ? 2.5 : 1))
        .shadow(color: .black.opacity(isFocus ? 0.18 : 0.06), radius: isFocus ? 6 : 2, y: 1)
        .opacity(dim ? 0.72 : 1)
    }
}

struct ComponentSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var debate: Debate
    @State var componentId: String

    var body: some View {
        let c = debate.componentsById[componentId]!
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if c.relationCount == 0 {
                        ContentUnavailableView("No relations", systemImage: "point.3.connected.trianglepath.dotted", description: Text("This \(c.type.lowercased()) is not linked to other components in the annotation."))
                            .frame(height: 180)
                    } else {
                        ArgumentGraphView(debate: debate, focusId: $componentId)
                            .frame(height: 380)
                            .background(Color(uiColor: .systemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        HStack(spacing: 14) {
                            EdgeLegend(color: .support, label: "supports", dashed: false)
                            EdgeLegend(color: .attack, label: "attacks", dashed: false)
                            EdgeLegend(color: .equivalent, label: "equivalent", dashed: true)
                            Spacer()
                            Text("tap a node to recentre").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(c.type).font(.caption.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3).background(c.color, in: Capsule())
                            Text(store.politician(c.politician)?.name ?? c.speaker.capitalized).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(c.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        Text("“\(c.text)”").font(.body).fontDesign(.serif).lineSpacing(3).textSelection(.enabled)
                    }
                    .padding(14)
                    .background(c.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                    ForEach(c.fallacies, id: \.self) { fid in
                        if let f = debate.fallaciesById[fid] { FallacyBadge(fallacy: f) }
                    }

                    RelationList(title: "Supported by", ids: c.supportedBy, color: .support, debate: debate, focus: $componentId)
                    RelationList(title: "Attacked by", ids: c.attackedBy, color: .attack, debate: debate, focus: $componentId)
                    RelationList(title: "Supports", ids: c.supports, color: .support, debate: debate, focus: $componentId)
                    RelationList(title: "Attacks", ids: c.attacks, color: .attack, debate: debate, focus: $componentId)
                    RelationList(title: "Equivalent to", ids: c.equivalentTo, color: .equivalent, debate: debate, focus: $componentId)
                }
                .padding()
            }
            .navigationTitle("Argument")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: "\(store.politician(c.politician)?.name ?? c.speaker) (\(debate.title)): “\(c.text)”") }
            }
        }
    }
}

struct EdgeLegend: View {
    var color: Color; var label: String; var dashed: Bool
    var body: some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 22, y: 5)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : [])).frame(width: 22, height: 10)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct RelationList: View {
    var title: String
    var ids: [String]
    var color: Color
    var debate: Debate
    @Binding var focus: String
    var body: some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) · \(ids.count)").font(.subheadline.weight(.semibold)).foregroundStyle(color)
                ForEach(ids, id: \.self) { id in
                    if let c = debate.componentsById[id] {
                        Button { withAnimation(.snappy) { focus = id } } label: {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(c.color).frame(width: 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.text).font(.callout).fontDesign(.serif).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text("\(c.type) · \(c.speaker.capitalized)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
    }
}

let fallacyDefinitions: [String: String] = [
    "Ad Hominem": "Attacking the opponent rather than their argument: general attacks, alleging bias, tu quoque, or name-calling and labelling.",
    "Appeal to Emotion": "Persuading through feelings instead of reasons: appeals to fear or pity, loaded language, or flag waving.",
    "Appeal to Authority": "Resting a point on an authority that is unnamed, unqualified, or merely popular opinion, without evidence.",
    "False Cause": "Treating correlation or sequence as causation.",
    "Slippery Slope": "Claiming a first step will inevitably lead to an extreme outcome without showing the chain.",
    "Slogans": "Substituting a brief, striking phrase for an argument.",
]

struct FallacyBadge: View {
    var fallacy: Fallacy
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.fallacy)
            VStack(alignment: .leading, spacing: 2) {
                Text(fallacy.category).font(.subheadline.weight(.semibold))
                if fallacy.subcategory.lowercased() != fallacy.category.lowercased() { Text(fallacy.subcategory).font(.caption).foregroundStyle(.secondary) }
                if let d = fallacyDefinitions[fallacy.category] { Text(d).font(.caption).foregroundStyle(.secondary).padding(.top, 2) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fallacy.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct FallacySheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var debate: Debate
    var fallacy: Fallacy
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FallacyBadge(fallacy: fallacy)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.politician(fallacy.politician)?.name ?? fallacy.speaker.capitalized).font(.subheadline.weight(.semibold))
                        Text("“\(fallacy.text)”").font(.body).fontDesign(.serif).lineSpacing(3).textSelection(.enabled)
                    }
                    .padding(14).background(Color.fallacy.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    if let cid = fallacy.componentId, let c = debate.componentsById[cid] {
                        Text("Attached to a \(c.type.lowercased()) with \(c.relationCount) relation\(c.relationCount == 1 ? "" : "s").").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Fallacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
