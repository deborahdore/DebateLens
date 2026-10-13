import Foundation
import Observation

@Observable
final class DataStore {
    let index: DebateIndex
    @ObservationIgnored private(set) var debates: [String: Debate] = [:]   // cache; not observed so body-time loads are safe
    private(set) var allLoaded = false
    private(set) var loadingProgress: Double = 0

    var politicians: [Politician] { index.politicians.values.sorted { $0.years.first! == $1.years.first! ? $0.name < $1.name : $0.years.first! < $1.years.first! } }
    var summaries: [DebateSummary] { index.debates }

    init() {
        index = try! JSONDecoder().decode(DebateIndex.self, from: Data(contentsOf: DataStore.url(for: "index")))
    }

    private static func url(for name: String) -> URL {
        // Xcode may flatten the Data folder into the bundle root or keep it as a subdirectory.
        Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Data/debates")
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Data")
            ?? Bundle.main.url(forResource: name, withExtension: "json")!
    }

    private static func decode(_ id: String) -> Debate {
        var d = try! JSONDecoder().decode(Debate.self, from: Data(contentsOf: url(for: id)))
        d.buildIndexes()
        return d
    }

    func politician(_ id: String?) -> Politician? { id.flatMap { index.politicians[$0] } }
    func summary(_ id: String) -> DebateSummary? { index.debates.first { $0.id == id } }

    /// Synchronous, cached per-debate load (~50–400 KB each, decodes in a few ms).
    func debate(_ id: String) -> Debate {
        if let d = debates[id] { return d }
        let d = DataStore.decode(id)
        debates[id] = d
        return d
    }

    /// Loads every debate off the main thread; needed for global search and the fallacy explorer.
    func loadAll() async {
        guard !allLoaded else { return }
        let ids = index.debates.map(\.id)
        for (i, id) in ids.enumerated() where debates[id] == nil {
            let d = await Task.detached(priority: .userInitiated) { DataStore.decode(id) }.value
            debates[id] = d
            loadingProgress = Double(i + 1) / Double(ids.count)
        }
        allLoaded = true
    }

    // MARK: cross-debate queries (require loadAll)

    var allFallacies: [FallacyHit] {
        summaries.flatMap { s in (debates[s.id]?.fallacies ?? []).map { FallacyHit(fallacy: $0, debate: debates[s.id]!) } }
    }

    func fallacies(for politician: String?, category: String? = nil) -> [FallacyHit] {
        allFallacies.filter { (politician == nil || $0.fallacy.politician == politician) && (category == nil || $0.fallacy.category == category) }
    }

    func fallacyCounts(for politician: String?) -> [(category: String, count: Int)] {
        Dictionary(grouping: fallacies(for: politician), by: \.fallacy.category).map { (category: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }
    }

    func search(_ query: String, type: String?, politician: String?) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        return summaries.flatMap { s -> [Hit] in
            guard let d = debates[s.id] else { return [] }
            return d.components.filter {
                $0.turnId != nil && (type == nil || $0.type == type) && (politician == nil || $0.politician == politician) && $0.text.lowercased().contains(q)
            }.map { Hit(debateId: d.id, turnId: $0.turnId!, componentId: $0.id, fallacyId: nil) }
        }
    }
}

struct FallacyHit: Identifiable {
    let fallacy: Fallacy
    let debate: Debate
    var id: String { debate.id + "/" + fallacy.id }
}
