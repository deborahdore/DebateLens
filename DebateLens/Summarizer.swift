import SwiftUI
import NaturalLanguage
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// A claim or premise handed to the model, numbered [1]…[n] in the prompt.
struct SummarySource: Hashable {
    var hit: Hit
    var component: Component
    var year: Int
}

/// On-device topic summaries: what a politician argues about a search term, written by
/// Qwen3-1.7B (4-bit, Apache 2.0) through MLX from that politician's own claims only.
/// Every sentence must cite the numbered claims it relies on; sentences that cite nothing valid are dropped.
@MainActor @Observable
final class Summarizer {
    struct Sentence: Hashable { var text: String; var refs: [Int] }
    enum Status: Equatable { case idle, downloading(Double), loading, writing, failed(String) }

    static let model = LLMRegistry.qwen3_1_7b_4bit
    static let modelName = "Qwen3-1.7B"
    static let readyKey = "summaryModelReady"

    private(set) var status: Status = .idle
    private(set) var activeKey: String?
    private(set) var draft = ""
    private(set) var results: [String: [Sentence]] = [:]
    @ObservationIgnored private var loading: Task<ModelContainer, Error>?

    /// Downloads (first time, ~1 GB) and loads the model once; concurrent callers share the same load.
    func prepare() async throws -> ModelContainer {
        #if targetEnvironment(simulator)
        throw NSError(domain: "DebateLens", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLX needs a real iPhone or iPad; it does not run in the Simulator."])
        #else
        if loading == nil {
            let downloaded = UserDefaults.standard.bool(forKey: Self.readyKey)
            status = downloaded ? .loading : .downloading(0)
            loading = Task {
                try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: Self.model
                ) { progress in
                    let f = progress.fractionCompleted
                    Task { @MainActor in if case .downloading = self.status { self.status = .downloading(f) } }
                }
            }
        }
        do {
            let container = try await loading!.value
            UserDefaults.standard.set(true, forKey: Self.readyKey)
            if status != .writing { status = .idle }
            return container
        } catch {
            loading = nil
            status = .failed(error.localizedDescription)
            throw error
        }
        #endif
    }

    func summarize(key: String, topic: String, politician: Politician, sources: [SummarySource]) async {
        guard results[key] == nil else { return }
        activeKey = key
        draft = ""
        do {
            let container = try await prepare()
            try Task.checkCancellation()
            status = .writing
            let session = ChatSession(
                container,
                instructions: "You summarise the positions of US presidential candidates for journalists and fact-checkers. You only use the numbered claims you are given and never add facts, dates, numbers or opinions that are not in them. Write neutral, plain English.",
                generateParameters: GenerateParameters(maxTokens: 320, temperature: 0.3, topP: 0.9),
                additionalContext: ["enable_thinking": false]
            )
            for try await chunk in session.streamResponse(to: Self.prompt(topic: topic, politician: politician, sources: sources)) {
                try Task.checkCancellation()
                draft += chunk
            }
            results[key] = Self.ground(draft, sourceCount: sources.count)
            status = .idle
        } catch is CancellationError {
            if activeKey == key { status = .idle }
        } catch {
            if activeKey == key { status = .failed(error.localizedDescription) }
        }
    }

    /// Picks what the model reads: the politician's claims (premises only if there are too few claims),
    /// deduplicated, the 30 with most support, then put back in chronological order.
    static func sources(from hits: [Hit], store: DataStore) -> [SummarySource] {
        let all = hits.compactMap { h -> SummarySource? in
            let d = store.debate(h.debateId)
            return d.componentsById[h.componentId ?? ""].map { SummarySource(hit: h, component: $0, year: d.year) }
        }
        let claims = all.filter(\.component.isClaim)
        var seen = Set<String>()
        let pool = (claims.count >= 3 ? claims : all).filter { seen.insert($0.component.text.lowercased()).inserted }
        return pool.sorted { $0.component.supportedBy.count > $1.component.supportedBy.count }
            .prefix(30)
            .sorted { ($0.year, $0.hit.turnId) < ($1.year, $1.hit.turnId) }
    }

    static func prompt(topic: String, politician: Politician, sources: [SummarySource]) -> String {
        let lines = sources.enumerated().map { i, s in "[\(i + 1)] (\(s.year)) \(String(s.component.text.prefix(280)))" }
        return """
        Topic: "\(topic)"
        Candidate: \(politician.name) (\(politician.partyName))

        Claims made by \(politician.name) in US presidential debates that mention the topic:
        \(lines.joined(separator: "\n"))

        Write 2 to 4 sentences describing what \(politician.name) argues about "\(topic)": the position taken, the main reasons given, and any change over the years. After each sentence, put the numbers of the claims it relies on in square brackets, like [2] or [1, 4]. Use only the claims above.
        """
    }

    /// Keeps only sentences that cite at least one real source number; strips any <think> block.
    static func ground(_ raw: String, sourceCount: Int) -> [Sentence] {
        let cite = try! Regex(#"\[(\d+(?:\s*,\s*\d+)*)\]"#)
        var text = raw.replacing(try! Regex(#"(?s)<think>.*?</think>"#), with: "")
        // "… taxes. [1][3]" → "… taxes [1][3]." so the citation stays with its sentence.
        text = text.replacing(try! Regex(#"([.!?])\s*((?:\[[\d,\s]+\]\s*)+)"#)) { m in
            "\(m.output[2].substring ?? "")\(m.output[1].substring ?? "") "
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [Sentence] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range])
            let refs = s.matches(of: cite).flatMap { m in
                String(m.output[1].substring ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            let valid = Array(Set(refs.filter { (1...max(sourceCount, 1)).contains($0) })).sorted()
            let body = s.replacing(cite, with: "")
                .replacing(try! Regex(#"\s+([.!?,;:])"#)) { m in String(m.output[1].substring ?? "") }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !valid.isEmpty && !body.isEmpty { out.append(Sentence(text: body, refs: valid)) }
            return true
        }
        return out
    }
}

/// Search section: "What X argues about <topic>", with each cited claim as a row that opens the transcript.
struct TopicSummarySection: View {
    @Environment(Summarizer.self) private var summarizer
    @AppStorage(Summarizer.readyKey) private var modelReady = false
    var topic: String
    var politician: Politician
    var sources: [SummarySource]

    private var key: String { "\(politician.id)|\(topic.lowercased())" }
    private var isActive: Bool { summarizer.activeKey == key }

    var body: some View {
        Section {
            if sources.count < 3 {
                Text("Not enough material for a summary: \(politician.name) has \(sources.count) claim\(sources.count == 1 ? "" : "s") mentioning “\(topic)”.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let sentences = summarizer.results[key] {
                if sentences.isEmpty {
                    Text("The model's answer couldn't be tied to the claims, so it isn't shown.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(attributed(sentences)).font(.callout).fontDesign(.serif)
                    ForEach(Array(Set(sentences.flatMap(\.refs))).sorted().filter { $0 <= sources.count }, id: \.self) { i in
                        let s = sources[i - 1]
                        NavigationLink(value: Route.debate(id: s.hit.debateId, turn: s.hit.turnId, component: s.component.id)) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("[\(i)]").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Color.claim)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.component.text).font(.footnote).fontDesign(.serif).lineLimit(3)
                                    Text("\(s.year) · \(s.component.id)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                statusView
            }
        } header: {
            // The task sits on the header (a single view) so it runs once per section, not once per row.
            Label("What \(politician.name) argues about “\(topic)”", systemImage: "sparkles")
                .textCase(nil)
                .task(id: "\(key)|\(modelReady)") {
                    guard modelReady, sources.count >= 3, summarizer.results[key] == nil else { return }
                    try? await Task.sleep(for: .milliseconds(700))   // wait until the user stops typing
                    guard !Task.isCancelled else { return }
                    await summarizer.summarize(key: key, topic: topic, politician: politician, sources: sources)
                }
        } footer: {
            if sources.count >= 3 {
                Text("Written on your device by \(Summarizer.modelName) from \(politician.name)'s own claims only. It can still misread them, so check the cited sources.")
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        #if targetEnvironment(simulator)
        Text("Summaries run on-device with MLX, which needs a real iPhone or iPad. Run the app on a device to try them.")
            .font(.callout).foregroundStyle(.secondary)
        #else
        switch summarizer.status {
        case .downloading(let f):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading \(Summarizer.modelName)…").font(.callout)
                ProgressView(value: f)
            }
        case .loading:
            HStack { ProgressView(); Text("Loading the model…").font(.callout).foregroundStyle(.secondary) }
        case .writing where isActive:
            HStack(alignment: .top) {
                ProgressView()
                Text(summarizer.draft.isEmpty ? "Reading \(sources.count) claims…" : summarizer.draft)
                    .font(.callout).fontDesign(.serif).foregroundStyle(.secondary)
            }
        case .failed(let message) where isActive || !modelReady:
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.callout).foregroundStyle(.secondary)
                Button("Try again") { Task { await summarizer.summarize(key: key, topic: topic, politician: politician, sources: sources) } }
            }
        default:
            if modelReady {
                HStack { ProgressView(); Text("Waiting…").font(.callout).foregroundStyle(.secondary) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get an automatic summary of each candidate's position, written on your device from the claims below. Nothing leaves your phone.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Download summary model (about 1 GB)") { Task { _ = try? await summarizer.prepare() } }
                }
            }
        }
        #endif
    }

    private func attributed(_ sentences: [Summarizer.Sentence]) -> AttributedString {
        var a = AttributedString()
        for s in sentences {
            a += AttributedString(s.text + " ")
            var r = AttributedString("[" + s.refs.map(String.init).joined(separator: ", ") + "] ")
            r.foregroundColor = Color.claim
            r.font = Font.caption.weight(.semibold)
            a += r
        }
        return a
    }
}
