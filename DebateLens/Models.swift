import SwiftUI

struct DebateIndex: Codable {
    var debates: [DebateSummary]
    var politicians: [String: Politician]
}

struct DebateSummary: Codable, Identifiable, Hashable {
    var id: String
    var year: Int
    var date: String?
    var kind: String
    var title: String
    var participants: [String]
    var turnCount: Int
    var claims: Int
    var premises: Int
    var relations: Int
    var fallacies: Int
}

struct Politician: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var party: String
    var labels: [String]
    var debates: [String]
    var years: [Int]
    var claims: Int
    var premises: Int
    var fallacies: Int

    var partyName: String { ["D": "Democrat", "R": "Republican", "I": "Independent"][party] ?? party }
    var partyColor: Color { ["D": Color(red: 0.16, green: 0.40, blue: 0.75), "R": Color(red: 0.78, green: 0.22, blue: 0.22)][party] ?? Color(red: 0.45, green: 0.35, blue: 0.60) }
    var yearSpan: String { years.count == 1 ? "\(years[0])" : "\(years.first!)–\(years.last!)" }
}

struct Debate: Codable, Identifiable {
    var id: String
    var year: Int
    var date: String?
    var kind: String
    var title: String
    var participants: [String]
    var turns: [Turn]
    var components: [Component]
    var relations: [Relation]
    var fallacies: [Fallacy]

    // Lookups built once after decoding (see DataStore.decode).
    var componentsById: [String: Component] = [:]
    var fallaciesById: [String: Fallacy] = [:]

    enum CodingKeys: String, CodingKey { case id, year, date, kind, title, participants, turns, components, relations, fallacies }

    mutating func buildIndexes() {
        componentsById = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        fallaciesById = Dictionary(uniqueKeysWithValues: fallacies.map { ($0.id, $0) })
    }
}

struct Turn: Codable, Identifiable, Hashable {
    var id: Int
    var speaker: String
    var politician: String?
    var start: Int
    var end: Int
    var text: String
}

struct Segment: Codable, Hashable {
    var start: Int
    var end: Int
}

struct Component: Codable, Identifiable, Hashable {
    var id: String
    var type: String
    var text: String
    var turnId: Int?
    var speaker: String
    var politician: String?
    var segments: [Segment]
    var fallacies: [String]
    var supports: [String]
    var attacks: [String]
    var supportedBy: [String]
    var attackedBy: [String]
    var equivalentTo: [String]

    var isClaim: Bool { type == "Claim" }
    var color: Color { isClaim ? .claim : .premise }
    var relationCount: Int { supports.count + attacks.count + supportedBy.count + attackedBy.count + equivalentTo.count }
}

struct Relation: Codable, Identifiable, Hashable {
    var id: String
    var type: String
    var source: String
    var target: String
}

struct Fallacy: Codable, Identifiable, Hashable {
    var id: String
    var category: String
    var subcategory: String
    var text: String
    var componentId: String?
    var start: Int?
    var end: Int?
    var turnId: Int?
    var speaker: String
    var politician: String?
}

/// A component or fallacy located in a specific debate, used by search and cross-debate lists.
struct Hit: Identifiable, Hashable {
    var debateId: String
    var turnId: Int
    var componentId: String?
    var fallacyId: String?
    var id: String { "\(debateId)/\(componentId ?? fallacyId ?? "\(turnId)")" }
}

extension Color {
    static let claim = Color(red: 0.36, green: 0.29, blue: 0.76)
    static let premise = Color(red: 0.75, green: 0.54, blue: 0.12)
    static let fallacy = Color(red: 0.76, green: 0.09, blue: 0.36)
    static let support = Color(red: 0.16, green: 0.58, blue: 0.34)
    static let attack = Color(red: 0.80, green: 0.20, blue: 0.16)
    static let equivalent = Color.gray
    static let paper = Color(uiColor: .systemBackground)
    static let bubbleModerator = Color(uiColor: .secondarySystemBackground)
}

extension String {
    /// "1984-10-07" → "7 Oct 1984"
    var prettyDate: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: self) else { return self }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
