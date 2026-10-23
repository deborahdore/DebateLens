import SwiftUI
import NaturalLanguage
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// A claim or premise handed to the model, numbered [1]…[n] in the prompt, with the debate metadata it is read with.
struct SummarySource: Hashable {
    var hit: Hit
    var component: Component
    var year: Int
    var date: String
    var context: [String]
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

    var isBusy: Bool {
        switch status { case .downloading, .loading, .writing: true; default: false }
    }

    /// Where the Hugging Face client keeps downloads inside the app sandbox (Library/Caches/huggingface).
    static let cacheURL = URL.cachesDirectory.appending(path: "huggingface")

    /// Bytes the downloaded model takes on disk, partial downloads included. Symlinks are skipped so blobs count once.
    static func cacheSize() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        let files = FileManager.default.enumerator(at: cacheURL, includingPropertiesForKeys: keys)
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Removes the model from disk and memory; the next summary asks to download it again. Summaries already written are kept.
    func deleteModel() {
        guard !isBusy else { return }
        loading = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        UserDefaults.standard.set(false, forKey: Self.readyKey)
        status = .idle
    }

    /// Downloads (first time, ~1 GB) and loads the model once; concurrent callers share the same load.
    func prepare() async throws -> ModelContainer {
        #if targetEnvironment(simulator)
        throw NSError(domain: "DebateLens", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLX needs a real iPhone or iPad; it does not run in the Simulator."])
        #else
        if loading == nil {
            let downloaded = UserDefaults.standard.bool(forKey: Self.readyKey)
            status = downloaded ? .loading : .downloading(0)
            UIApplication.shared.isIdleTimerDisabled = true   // a locked screen suspends the app and drops the 1 GB transfer
            loading = Task {
                try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: Self.model
                ) { progress in
                    let f = progress.fractionCompleted
                    // Once every file is on disk the weights are being loaded, not downloaded.
                    Task { @MainActor in if case .downloading = self.status { self.status = f < 1 ? .downloading(f) : .loading } }
                }
            }
        }
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            let container = try await loading!.value
            UserDefaults.standard.set(true, forKey: Self.readyKey)
            if status != .writing { status = .idle }
            return container
        } catch {
            loading = nil
            let stage = if case .downloading = status { "Download failed" } else { "Loading the model failed" }
            print("Summarizer: \(stage):", error)
            status = .failed("\(stage): \(Self.message(for: error))")
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
                instructions: "You summarise the positions of US presidential candidates for journalists and fact-checkers. You only use the numbered claims and the debate details given with them, and never add facts, dates, numbers or opinions that are not there. You report what the candidate said, not whether it is true. Write neutral, plain English.",
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
            print("Summarizer:", error)
            // When the download or load failed, prepare() has already shown a more precise message.
            if activeKey == key && status == .writing { status = .failed(Self.message(for: error)) }
        }
    }

    /// The Hugging Face client throws plain Swift errors with no localized text, which `localizedDescription` turns into
    /// "The operation couldn't be completed. (HuggingFace.HTTPClientError error 1.)"; for those, their own description is shown.
    static func message(for error: Error) -> String {
        error is LocalizedError || (error as NSError).userInfo[NSLocalizedDescriptionKey] != nil
            ? error.localizedDescription : String(describing: error)
    }

    /// Picks what the model reads: the politician's claims (premises only if there are too few claims),
    /// deduplicated, the 24 with most support, then put back in chronological order. Each one carries
    /// its debate (kind, date, opponents), what it replied to, its reasons, its attackers and its annotated fallacies.
    static func sources(from hits: [Hit], store: DataStore) -> [SummarySource] {
        let all = hits.compactMap { h -> SummarySource? in
            let d = store.debate(h.debateId)
            guard let c = d.componentsById[h.componentId ?? ""] else { return nil }
            let date = d.date?.prettyDate ?? String(d.year)
            let opponents = d.participants.filter { $0 != c.politician }.compactMap { store.politician($0)?.name }
            var context = ["\(c.type.lowercased()) in the \(d.kind.lowercased()) debate of \(date)" + (opponents.isEmpty ? "" : ", against \(opponents.joined(separator: " and "))")]
            // What it answered: the last earlier turn by someone else that asks something ("Mr. Trump, two minutes?" is skipped).
            if let i = d.turns.firstIndex(where: { $0.id == h.turnId }),
               let prev = d.turns[..<i].last(where: { $0.politician != c.politician && $0.text.contains("?") && $0.text.count >= 60 }) {
                let who = store.politician(prev.politician)?.name
                    ?? (prev.speaker.contains("QUESTION") ? "an audience member" : prev.speaker == "MODERATOR" ? "the moderator" : "\(prev.speaker.capitalized) (moderator or panelist)")
                let said = prev.text.count > 180 ? "…" + prev.text.suffix(180) : prev.text
                context.append("replying to \(who): \"\(said.trimmingCharacters(in: .whitespacesAndNewlines))\"")
            }
            let reasons = c.supportedBy.compactMap { d.componentsById[$0] }
            if let r = reasons.first {
                context.append("reason given: \"\(r.text.prefix(160))\"" + (reasons.count > 1 ? " (and \(reasons.count - 1) more)" : ""))
            }
            let attackers = Set(c.attackedBy.compactMap { d.componentsById[$0] }.map { store.politician($0.politician)?.name ?? $0.speaker.capitalized })
            if !attackers.isEmpty { context.append("attacked by \(attackers.sorted().joined(separator: " and "))") }
            let fallacies = c.fallacies.compactMap { d.fallaciesById[$0] }.map { $0.subcategory.isEmpty ? $0.category : "\($0.category) (\($0.subcategory))" }
            if !fallacies.isEmpty { context.append("annotated fallacy: \(fallacies.joined(separator: ", "))") }
            return SummarySource(hit: h, component: c, year: d.year, date: date, context: context)
        }
        let claims = all.filter(\.component.isClaim)
        var seen = Set<String>()
        let pool = (claims.count >= 3 ? claims : all).filter { seen.insert($0.component.text.lowercased()).inserted }
        return pool.sorted { $0.component.supportedBy.count > $1.component.supportedBy.count }
            .prefix(24)
            .sorted { ($0.year, Int($0.hit.debateId.prefix { $0.isNumber }) ?? 0, $0.hit.turnId) < ($1.year, Int($1.hit.debateId.prefix { $0.isNumber }) ?? 0, $1.hit.turnId) }
    }

    static func prompt(topic: String, politician: Politician, sources: [SummarySource]) -> String {
        let blocks = sources.enumerated().map { i, s in
            "[\(i + 1)] \"\(s.component.text.prefix(280))\"\n" + s.context.map { "    \($0)" }.joined(separator: "\n")
        }
        return """
        Topic: "\(topic)"
        Candidate: \(politician.name) (\(politician.partyName)), in debates from \(politician.yearSpan)

        What \(politician.name) said in US presidential debates that mentions the topic, oldest first, each with the debate it comes from:
        \(blocks.joined(separator: "\n\n"))

        Write 2 to 4 sentences describing what \(politician.name) argues about "\(topic)": the position taken, the main reasons given, and whether it changed from one debate to another.
        Rules:
        - Use only the information above. Any date or year you mention must appear in the details of a claim you cite.
        - End each sentence with the numbers of the claims it relies on in square brackets, like [2] or [1, 4]. Do not refer to claims by their number inside a sentence.
        - Report what was said, not whether it is true.
        """
    }

    /// Keeps only sentences that cite at least one real source number; strips any <think> block.
    /// Citations used as words ("[1] and [3] both…") become "Claims 1 and 3 both…"; a sentence naming a claim that doesn't exist is dropped.
    static func ground(_ raw: String, sourceCount: Int) -> [Sentence] {
        let cite = try! Regex(#"\[(\d+(?:\s*,\s*\d+)*)\]"#)
        let trailing = try! Regex(#"(?:\s*\[[\d,\s]+\])+\s*([.!?]?)\s*$"#)
        let numbers = { (t: String) in t.matches(of: try! Regex(#"\d+"#)).compactMap { Int($0.output[0].substring ?? "") } }
        var text = raw.replacing(try! Regex(#"(?s)<think>.*?</think>"#), with: "")
        // "… taxes. [1][3] He…" → "… taxes [1][3]. He…" so the citation stays with its sentence, but in
        // "… taxes. [4] [1] and [3] both…" the [1] opens the next sentence and is left there.
        text = text.replacing(try! Regex(#"([.!?])\s*((?:\[[\d,\s]+\]\s*)+?)(?=\s*(?:$|\n|[A-Z"“]|\[[\d,\s]+\]\s+[a-z]))"#)) { m in
            "\(m.output[2].substring ?? "")\(m.output[1].substring ?? "") "
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [Sentence] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var body = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            var refs: [Int] = []
            if let m = body.firstMatch(of: trailing) {
                refs += numbers(String(body[m.range]))
                body = String(body[..<m.range.lowerBound]) + (m.output[1].substring ?? "")
            }
            var namesMissing = false
            body = body.replacing(cite) { m in
                let n = numbers(String(m.output[0].substring ?? ""))
                if n.contains(where: { $0 < 1 || $0 > sourceCount }) { namesMissing = true }
                refs += n
                let list = n.count == 1 ? "\(n[0])" : n.dropLast().map(String.init).joined(separator: ", ") + " and \(n.last!)"
                return (n.count == 1 ? "claim " : "claims ") + list
            }
            body = body.replacing(try! Regex(#"\s+([.!?,;:])"#)) { m in String(m.output[1].substring ?? "") }
                .replacing(try! Regex(#"\s{2,}"#), with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("claim") { body = "C" + body.dropFirst() }
            let valid = Array(Set(refs.filter { $0 >= 1 && $0 <= sourceCount })).sorted()
            if !valid.isEmpty && !body.isEmpty && !namesMissing { out.append(Sentence(text: body, refs: valid)) }
            return true
        }
        return out
    }
}

/// Search section: "What X argues about <topic>", with each cited claim as a row that opens the transcript.
struct TopicSummarySection: View {
    @Environment(Summarizer.self) private var summarizer
    @AppStorage(Summarizer.readyKey) private var modelReady = false
    @State private var cacheBytes: Int64 = 0
    @State private var confirmDelete = false
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
                                    Text("\(s.date) · \(s.component.id)").font(.caption2).foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 8) {
                if sources.count >= 3 {
                    Text("Written on your device by \(Summarizer.modelName) from \(politician.name)'s own claims only. It can still misread them, so check the cited sources.")
                }
                if cacheBytes > 0 && !summarizer.isBusy {
                    Button("Delete summary model (\(cacheBytes.formatted(.byteCount(style: .file))))", role: .destructive) { confirmDelete = true }
                        .font(.footnote)
                }
            }
            .task(id: summarizer.status) { cacheBytes = Summarizer.cacheSize() }
            .confirmationDialog("Delete \(Summarizer.modelName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete (\(cacheBytes.formatted(.byteCount(style: .file))))", role: .destructive) {
                    summarizer.deleteModel()
                    cacheBytes = Summarizer.cacheSize()
                }
            } message: {
                Text("Summaries will need the model to be downloaded again (about 1 GB).")
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
