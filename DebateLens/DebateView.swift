import SwiftUI

struct DebateListView: View {
    @Environment(DataStore.self) private var store
    var body: some View {
        let byYear = Dictionary(grouping: store.summaries, by: \.year).sorted { $0.key > $1.key }
        List {
            ForEach(byYear, id: \.key) { year, list in
                Section("\(year)") {
                    ForEach(list) { s in NavigationLink(value: Route.debate(id: s.id)) { DebateRow(summary: s) } }
                }
            }
        }
        .navigationTitle("Debates")
    }
}

struct DebateView: View {
    @Environment(DataStore.self) private var store
    let debateId: String
    var initialTurn: Int? = nil
    var initialComponent: String? = nil
    var initialFallacy: String? = nil

    @State private var selectedComponent: SelectedID?
    @State private var selectedFallacy: SelectedID?
    @State private var showClaims = true
    @State private var showPremises = true
    @State private var showFallacies = true
    @State private var argumentsOnly = false
    @State private var speakerFilter: String?

    var body: some View {
        let debate = store.debate(debateId)
        let turns = debate.turns.filter { t in
            (speakerFilter == nil || t.politician == speakerFilter) &&
            (!argumentsOnly || debate.components.contains(where: { $0.turnId == t.id }) || debate.fallacies.contains(where: { $0.turnId == t.id }))
        }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    DebateHeader(debate: debate)
                    ForEach(turns) { turn in
                        TurnBubble(debate: debate, turn: turn, side: side(for: turn, in: debate),
                                   showClaims: showClaims, showPremises: showPremises, showFallacies: showFallacies)
                        .id(turn.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .onAppear {
                if let t = initialTurn { DispatchQueue.main.async { withAnimation { proxy.scrollTo(t, anchor: .top) } } }
                if let c = initialComponent { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { selectedComponent = SelectedID(id: c) } }
                if let f = initialFallacy { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { selectedFallacy = SelectedID(id: f) } }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.host == "c" { selectedComponent = SelectedID(id: url.lastPathComponent) } else if url.host == "f" { selectedFallacy = SelectedID(id: url.lastPathComponent) }
            return .handled
        })
        .navigationTitle("\(debate.year) \(debate.kind)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Toggle("Claims", isOn: $showClaims)
                Toggle("Premises", isOn: $showPremises)
                Toggle("Fallacies", isOn: $showFallacies)
                Divider()
                Toggle("Argumentative turns only", isOn: $argumentsOnly)
                Picker("Speaker", selection: $speakerFilter) {
                    Text("Everyone").tag(String?.none)
                    ForEach(debate.participants, id: \.self) { Text(store.politician($0)?.name ?? $0).tag(String?.some($0)) }
                }
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
        }
        .sheet(item: $selectedComponent) { sel in ComponentSheet(debate: debate, componentId: sel.id) }
        .sheet(item: $selectedFallacy) { sel in FallacySheet(debate: debate, fallacy: debate.fallaciesById[sel.id]!) }
    }

    private func side(for turn: Turn, in debate: Debate) -> Side {
        guard let p = turn.politician, let i = debate.participants.firstIndex(of: p) else { return .center }
        return i % 2 == 0 ? .leading : .trailing
    }
}

struct SelectedID: Identifiable, Hashable { let id: String }

enum Side { case leading, trailing, center }

struct DebateHeader: View {
    @Environment(DataStore.self) private var store
    var debate: Debate
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(debate.date?.prettyDate ?? "\(debate.year)").font(.title3.weight(.semibold))
            HStack(spacing: 14) {
                ForEach(debate.participants, id: \.self) { id in
                    let p = store.politician(id)
                    HStack(spacing: 5) { PartyDot(politician: p); Text(p?.name ?? id).font(.subheadline) }
                }
            }
            HStack(spacing: 14) {
                LegendSwatch(color: .claim, label: "claim", count: debate.components.filter(\.isClaim).count)
                LegendSwatch(color: .premise, label: "premise", count: debate.components.filter { !$0.isClaim }.count)
                LegendSwatch(color: .fallacy, label: "fallacy", count: debate.fallacies.count, underline: true)
            }
            .padding(.top, 2)
            Text("Tap any highlighted passage to see what it supports, what attacks it, and any fallacy attached to it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

struct LegendSwatch: View {
    var color: Color; var label: String; var count: Int; var underline = false
    var body: some View {
        HStack(spacing: 4) {
            if underline { Text("ab").font(.caption).underline(true, color: color) }
            else { RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.22)).frame(width: 16, height: 12) }
            Text("\(count) \(label)\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TurnBubble: View {
    @Environment(DataStore.self) private var store
    var debate: Debate
    var turn: Turn
    var side: Side
    var showClaims: Bool
    var showPremises: Bool
    var showFallacies: Bool

    var body: some View {
        let politician = store.politician(turn.politician)
        let comps = debate.components.filter { $0.turnId == turn.id }
        let fals = debate.fallacies.filter { $0.turnId == turn.id }
        HStack(alignment: .top, spacing: 0) {
            if side == .trailing { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    PartyDot(politician: politician)
                    Text(politician?.name ?? turn.speaker.capitalized).font(.caption.weight(.semibold)).foregroundStyle(politician == nil ? .secondary : .primary)
                    Spacer()
                    if !comps.isEmpty { Text("\(comps.count)").font(.caption2.monospacedDigit()).foregroundStyle(.claim) }
                    if !fals.isEmpty { Text("\(fals.count)").font(.caption2.monospacedDigit()).foregroundStyle(.fallacy) }
                }
                Text(attributed(comps: comps, fallacies: fals))
                    .font(side == .center ? .callout : .body)
                    .fontDesign(.serif)
                    .lineSpacing(3)
                    .foregroundStyle(side == .center ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(side == .center ? Color.bubbleModerator : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .leading) {
                if let politician { UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16).fill(politician.partyColor).frame(width: 4) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if side == .leading { Spacer(minLength: 40) }
        }
    }

    private func attributed(comps: [Component], fallacies: [Fallacy]) -> AttributedString {
        var a = AttributedString(turn.text)
        let n = a.unicodeScalars.count
        func range(_ s: Int, _ e: Int) -> Range<AttributedString.Index>? {
            let lo = max(0, min(n, s - turn.start)), hi = max(0, min(n, e - turn.start))
            guard lo < hi else { return nil }
            let u = a.unicodeScalars
            return u.index(u.startIndex, offsetBy: lo)..<u.index(u.startIndex, offsetBy: hi)
        }
        for c in comps where c.isClaim ? showClaims : showPremises {
            for seg in c.segments { if let r = range(seg.start, seg.end) {
                a[r].backgroundColor = c.color.opacity(0.16)
                a[r].foregroundColor = c.isClaim ? Color.claim.mix(with: .primary, by: 0.35) : Color.premise.mix(with: .primary, by: 0.45)
                a[r].link = URL(string: "debatelens://c/\(c.id)")
            } }
        }
        if showFallacies {
            for f in fallacies { if let s = f.start, let e = f.end, let r = range(s, e) {
                a[r].underlineStyle = Text.LineStyle(pattern: .solid, color: .fallacy)
                if f.componentId == nil || !comps.contains(where: { $0.id == f.componentId }) { a[r].link = URL(string: "debatelens://f/\(f.id)") }
            } }
        }
        return a
    }
}
