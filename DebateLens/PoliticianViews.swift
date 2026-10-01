import SwiftUI
import Charts

struct PoliticianListView: View {
    @Environment(DataStore.self) private var store
    @State private var query = ""
    @State private var sort = Sort.chronological

    enum Sort: String, CaseIterable { case chronological = "Era", name = "Name", claims = "Most claims", fallacies = "Most fallacies" }

    var rows: [Politician] {
        var list = store.politicians.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .chronological: break
        case .name: list.sort { $0.name.split(separator: " ").last! < $1.name.split(separator: " ").last! }
        case .claims: list.sort { $0.claims > $1.claims }
        case .fallacies: list.sort { $0.fallacies > $1.fallacies }
        }
        return list
    }

    var body: some View {
        List(rows) { p in
            NavigationLink(value: Route.politician(p.id)) {
                HStack(spacing: 12) {
                    PartyDot(politician: p)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.headline)
                        Text("\(p.yearSpan) · \(p.debates.count) debate\(p.debates.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(p.claims + p.premises) arguments").font(.caption.monospacedDigit()).foregroundStyle(.claim)
                        Text("\(p.fallacies) fallacies").font(.caption.monospacedDigit()).foregroundStyle(p.fallacies == 0 ? .secondary : .fallacy)
                    }
                }
            }
        }
        .navigationTitle("Politicians")
        .searchable(text: $query, prompt: "Candidate name")
        .toolbar {
            Menu { Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) } } }
            label: { Image(systemName: "arrow.up.arrow.down") }
        }
    }
}

struct PoliticianDetailView: View {
    @Environment(DataStore.self) private var store
    let politicianId: String

    var body: some View {
        let p = store.politician(politicianId)!
        let debates = p.debates.map { store.debate($0) }
        List {
            Section {
                HStack(spacing: 10) {
                    PartyDot(politician: p)
                    Text(p.partyName).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(p.yearSpan).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack {
                    StatPill(value: p.claims, label: "claims", color: .claim)
                    StatPill(value: p.premises, label: "premises", color: .premise)
                    StatPill(value: p.fallacies, label: "fallacies", color: .fallacy)
                    StatPill(value: relations(in: debates), label: "relations", color: .support)
                }
                .padding(.vertical, 4)
                Text(interpretation(p, debates: debates)).font(.footnote).foregroundStyle(.secondary)
            }

            let counts = fallacyCounts(debates)
            if !counts.isEmpty {
                Section("Fallacies by type") {
                    Chart(counts, id: \.category) { c in
                        BarMark(x: .value("Count", c.count), y: .value("Type", c.category))
                            .foregroundStyle(Color.fallacy.gradient)
                            .annotation(position: .trailing) { Text("\(c.count)").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(counts.count) * 34 + 10)
                }
            }

            Section("Arguments per debate") {
                Chart(debates) { d in
                    let mine = d.components.filter { $0.politician == p.id }
                    BarMark(x: .value("Debate", d.date?.prettyDate ?? d.id), y: .value("Count", mine.filter(\.isClaim).count)).foregroundStyle(by: .value("Type", "Claims"))
                    BarMark(x: .value("Debate", d.date?.prettyDate ?? d.id), y: .value("Count", mine.filter { !$0.isClaim }.count)).foregroundStyle(by: .value("Type", "Premises"))
                }
                .chartForegroundStyleScale(["Claims": Color.claim, "Premises": Color.premise])
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .frame(height: 160)
            }

            Section("Debates") {
                ForEach(debates) { d in
                    NavigationLink(value: Route.debate(id: d.id)) { DebateRow(summary: store.summary(d.id)!, focus: p.id) }
                }
            }
        }
        .navigationTitle(p.name)
        .navigationBarTitleDisplayMode(.large)
    }

    private func relations(in debates: [Debate]) -> Int {
        debates.reduce(0) { acc, d in acc + d.relations.filter { d.componentsById[$0.source]?.politician == politicianId }.count }
    }

    private func fallacyCounts(_ debates: [Debate]) -> [(category: String, count: Int)] {
        Dictionary(grouping: debates.flatMap(\.fallacies).filter { $0.politician == politicianId }, by: \.category)
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    private func interpretation(_ p: Politician, debates: [Debate]) -> String {
        let ratio = Double(p.premises) / Double(max(p.claims, 1))
        let attacks = debates.reduce(0) { acc, d in acc + d.relations.filter { r in r.type == "Attack" && d.componentsById[r.source]?.politician == p.id }.count }
        let style = ratio >= 1.05 ? "argues mostly by justification: more premises than claims" : ratio <= 0.85 ? "leans on assertion: claims outnumber the premises backing them" : "keeps claims and premises in balance"
        let annotated = debates.filter { !$0.fallacies.isEmpty }
        let annotatedComponents = annotated.reduce(0) { acc, d in acc + d.components.filter { c in c.politician == p.id }.count }
        let fall = annotated.isEmpty ? "No fallacy annotations exist for these debates yet."
            : "\(String(format: "%.1f", Double(p.fallacies) / Double(max(annotatedComponents, 1)) * 100)) fallacies per 100 components across \(annotated.count) annotated debate\(annotated.count == 1 ? "" : "s")."
        return "\(p.name) \(style) (\(p.premises) : \(p.claims)); \(attacks) direct attacks on other components. \(fall)"
    }
}

struct DebateRow: View {
    @Environment(DataStore.self) private var store
    var summary: DebateSummary
    var focus: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(summary.kind) debate").font(.headline)
            Text(summary.date?.prettyDate ?? "\(summary.year)").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(summary.participants, id: \.self) { id in
                    let p = store.politician(id)
                    HStack(spacing: 4) { PartyDot(politician: p); Text(p?.name.split(separator: " ").last.map(String.init) ?? id) }
                        .font(.caption).fontWeight(id == focus ? .semibold : .regular)
                }
                Spacer()
                Text("\(summary.claims + summary.premises)").foregroundStyle(.claim)
                if summary.fallacies > 0 { Text("\(summary.fallacies)").foregroundStyle(.fallacy) }
            }
            .font(.caption.monospacedDigit())
        }
    }
}
