# DebateLens

An iOS app that lets journalists read US presidential debates (1960–2020) as annotated argumentation: every claim and premise a candidate made, what supports or attacks it, and which fallacies were used. Built on **ElecDeb60to20** (46 debates, 31k argument components, ~22k relations, 1.5k fallacies).

## What the app does

| Tab | What a journalist gets |
|---|---|
| **Politicians** | 33 candidates, sortable by era, name, argument volume or fallacy count. A profile shows claims/premises/fallacies/relations, a fallacy-type chart, arguments per debate, and a one-paragraph reading of the candidate's argumentative style (assertion-heavy vs justification-heavy, number of direct attacks, fallacies per 100 components). |
| **Debates** | Every debate grouped by year. Opens the transcript as speech bubbles: candidates left/right with a party-coloured bar, moderators centred and muted. Claims (violet) and premises (ochre) are highlighted inline; fallacies are underlined in crimson. Filters: hide claims/premises/fallacies, show only argumentative turns, one speaker only. |
| **Argument sheet** | Tapping a highlighted passage opens the argument graph: the component in the centre, its direct relations in the first ring, their relations in a second ring. Green arrows = support, red = attack, dashed grey = equivalent. Tap a node to recentre; relation lists below double as navigation. Attached fallacies are shown with their definition. Share exports the quote with attribution. |
| **Fallacies** | All annotated fallacies, filterable by candidate and category, with a chart of the distribution and a definition of the selected category. Each instance jumps into the transcript at that turn. |
| **Search** | Full-text search over every claim and premise across all debates, filterable by type and candidate, with hits highlighted; jumps into the transcript with the argument sheet already open. |

### Beyond the initial idea

- **Two levels of fallacy annotation.** Fallacies attached to a component are shown inside the argument sheet; fallacies annotated on free text (no component) are tappable on their own.
- **Cross-debate identity.** `CLINTON` in 1992 and 2016 are different people, `BUSH` in 1988 and 2004 too; a (label, year) → politician map resolves this and adds party and role. Moderators and panelists stay visible but are not treated as politicians.
- **Argument-style profile**, not just counts: premise/claim ratio, attacks initiated, fallacy rate normalised to annotated debates only (fallacy annotation covers 31 of 46 debates; the rest are reported as *not annotated* rather than *zero*).
- **Discontinuous spans** from the brat annotations are rendered correctly (e.g. a claim interrupted by its own premise).
- **Provenance everywhere.** Component ids (`T123`) are shown so a finding can be traced back to the dataset.

## Build

Requirements: Xcode 16+, iOS 18 deployment target (uses `Color.mix`). Open `DebateLens.xcodeproj`, pick a simulator, run. There are no dependencies. The project uses Xcode 16's synchronized folders, so adding a Swift file to `DebateLens/` is enough.

I could not compile on my side (no Xcode in this environment), so a first build may surface one or two type-check nits; the code is written against iOS 17/18 SwiftUI, Charts and Observation APIs.

## Data pipeline

`Tools/build_dataset.py` converts the dataset into per-debate JSON used by the app:

```
python Tools/build_dataset.py <ElecDeb60to20>/data/annotations DebateLens/Resources/Data
```

Sources used: `txt/` (transcripts, turn boundaries and char offsets), `relations/*.ann` (components with discontinuous spans + Support/Attack/Equivalent relations), `fallacies/fallacies_with_span.csv` (fallacy type, subtype, text span, linked component), `arguments/` (debate dates). Output: `index.json` (debate summaries + politician stats) and `debates/<id>.json` (turns, components with resolved speaker and relation lists, relations, fallacies). Total ≈ 17 MB, loaded lazily per debate; Search and Fallacies index all debates on first use.

## Layout

```
DebateLens/
  DebateLensApp.swift     tabs, routes, shared small views
  Models.swift            Codable models, colour palette
  DataStore.swift         bundle loading, caching, cross-debate queries
  PoliticianViews.swift   list, profile, charts
  DebateView.swift        transcript bubbles, inline highlighting
  ArgumentGraphView.swift graph (Canvas), argument & fallacy sheets
  ExplorerViews.swift     fallacy explorer, search
  Resources/Data/         generated JSON
Tools/build_dataset.py    converter
```

## Natural next steps

- Topic layer: cluster claims by subject (the SBERT embeddings already in `arguments/` would do) so a journalist can follow *deficit* or *Iraq* across decades.
- Claim reuse: the `Equivalent` relation plus embeddings could surface the same claim repeated across debates or years.
- Live mode: run the RooseBERT/FallacyRag pipeline on a new transcript and load it in the same JSON format; the app is format-agnostic beyond `index.json`.
- Export: PDF/Markdown of one argument graph for a fact-check piece.
- iPad: three-column layout (politician / transcript / graph) would suit the form factor.
