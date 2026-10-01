import SwiftUI
import Charts

/// Loads every debate once, showing progress; wraps views that need cross-debate data.
struct LoadAll<Content: View>: View {
    @Environment(DataStore.self) private var store
    @ViewBuilder var content: () -> Content
    var body: some View {
        if store.allLoaded { content() }
        else {
            VStack(spacing: 12) {
                ProgressView(value: store.loadingProgress)
                Text("Indexing 46 debates…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(40)
            .task { await store.loadAll() }
        }
    }
}

struct FallacyExplorerView: View {
    @Environment(DataStore.self) private var store
    @State private var politician: String?
    @State private var category: String?

    var body: some View {
        LoadAll {
            let counts = store.fallacyCounts(for: politician)
            let rows = store.fallacies(for: politician, category: category)
            List {
                Section {
                    Picker("Politician", selection: $politician) {
                        Text("All politicians").tag(String?.none)
                        ForEach(store.politicians.filter { $0.fallacies > 0 }) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    if !counts.isEmpty {
                        Chart(counts, id: \.category) { c in
                            BarMark(x: .value("Count", c.count), y: .value("Type", c.category))
                                .foregroundStyle(c.category == category ? Color.fallacy : Color.fallacy.opacity(0.45))
                                .annotation(position: .trailing) { Text("\(c.count)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .chartXAxis(.hidden)
                        .frame(height: CGFloat(counts.count) * 34 + 10)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Chip(label: "All", selected: category == nil) { category = nil }
                                ForEach(counts, id: \.category) { c in Chip(label: c.category, selected: category == c.category) { category = c.category } }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } footer: {
                    if let category, let d = fallacyDefinitions[category] { Text(d) }
                    else { Text("\(rows.count) annotated fallacies. Not every debate has fallacy annotations; unannotated debates simply contribute none.") }
                }
                Section("Instances") {
                    ForEach(rows.prefix(400)) { hit in
                        let f = hit.fallacy, d = hit.debate
                        NavigationLink(value: Route.debate(id: d.id, turn: f.turnId, fallacy: f.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(f.text).font(.callout).fontDesign(.serif).lineLimit(3)
                                HStack(spacing: 6) {
                                    PartyDot(politician: store.politician(f.politician))
                                    Text(store.politician(f.politician)?.name ?? f.speaker.capitalized)
                                    Text("·").foregroundStyle(.tertiary)
                                    Text(f.subcategory).foregroundStyle(.fallacy)
                                    Spacer()
                                    Text("\(d.year)")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if rows.count > 400 { Text("Showing the first 400 of \(rows.count). Narrow the filters to see the rest.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Fallacies")
        }
    }
}

struct Chip: View {
    var label: String; var selected: Bool; var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.fallacy : Color(uiColor: .tertiarySystemFill), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct SearchView: View {
    @Environment(DataStore.self) private var store
    @State private var query = ""
    @State private var type: String?
    @State private var politician: String?

    var body: some View {
        LoadAll {
            let hits = store.search(query, type: type, politician: politician)
            List {
                Section {
                    Picker("Type", selection: $type) {
                        Text("Claims & premises").tag(String?.none)
                        Text("Claims").tag(String?.some("Claim"))
                        Text("Premises").tag(String?.some("Premise"))
                    }
                    .pickerStyle(.segmented)
                    Picker("Politician", selection: $politician) {
                        Text("Anyone").tag(String?.none)
                        ForEach(store.politicians) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                if query.count < 2 {
                    Section { Text("Search what was actually argued — e.g. “deficit”, “Social Security”, “nuclear”, “Iraq” — across every debate from 1960 to 2020.").font(.callout).foregroundStyle(.secondary) }
                } else {
                    Section("\(hits.count) result\(hits.count == 1 ? "" : "s")") {
                        ForEach(hits.prefix(300)) { h in
                            let d = store.debate(h.debateId)
                            let c = d.componentsById[h.componentId!]!
                            NavigationLink(value: Route.debate(id: d.id, turn: h.turnId, component: c.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(highlight(c.text)).font(.callout).fontDesign(.serif).lineLimit(4)
                                    HStack(spacing: 6) {
                                        Text(c.type).foregroundStyle(c.color).fontWeight(.semibold)
                                        PartyDot(politician: store.politician(c.politician))
                                        Text(store.politician(c.politician)?.name ?? c.speaker.capitalized)
                                        Spacer()
                                        if c.relationCount > 0 { Image(systemName: "point.3.connected.trianglepath.dotted") }
                                        if !c.fallacies.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.fallacy) }
                                        Text("\(d.year)")
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Words in a claim or premise")
        }
    }

    private func highlight(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        var searchRange = a.startIndex..<a.endIndex
        while let r = a[searchRange].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Color.claim.opacity(0.2)
            a[r].inlinePresentationIntent = .stronglyEmphasized
            searchRange = r.upperBound..<a.endIndex
        }
        return a
    }
}
