import SwiftUI

@main
struct DebateLensApp: App {
    @State private var store = DataStore()
    @State private var summarizer = Summarizer()

    var body: some Scene {
        WindowGroup {
            RootView().environment(store).environment(summarizer).tint(Color.claim)
        }
    }
}

enum Route: Hashable {
    case politician(String)
    case debate(id: String, turn: Int? = nil, component: String? = nil, fallacy: String? = nil)
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { PoliticianListView().withRoutes() }
                .tabItem { Label("Politicians", systemImage: "person.2") }
            NavigationStack { DebateListView().withRoutes() }
                .tabItem { Label("Debates", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack { FallacyExplorerView().withRoutes() }
                .tabItem { Label("Fallacies", systemImage: "exclamationmark.triangle") }
            NavigationStack { SearchView().withRoutes() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
    }
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .politician(let id): PoliticianDetailView(politicianId: id)
            case .debate(let id, let turn, let component, let fallacy): DebateView(debateId: id, initialTurn: turn, initialComponent: component, initialFallacy: fallacy)
            }
        }
    }
}

/// Small coloured dot for party membership; grey for moderators.
struct PartyDot: View {
    var politician: Politician?
    var body: some View {
        Circle().fill(politician?.partyColor ?? .gray.opacity(0.4)).frame(width: 9, height: 9)
    }
}

struct StatPill: View {
    var value: Int
    var label: String
    var color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value.formatted()).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
