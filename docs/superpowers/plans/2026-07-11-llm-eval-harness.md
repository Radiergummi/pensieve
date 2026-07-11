# LLM Evaluation Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `pensieve eval` harness that drives Pensieve's real generative components with the model swapped, judge-scores the outputs, and recommends a defensible on-device-first default model per task.

**Architecture:** New `Sources/PensieveKit/Eval/` module (pure, tested logic) + a thin `pensieve eval` CLI subcommand group. Each `EvalTask` runs the real component with **stage-isolation** (swap the model only at the stage under test; pin every other model-calling stage to a fixed reference provider). A frozen, content-hashed corpus (private, gitignored) feeds the sweep; an Opus/Sonnet judge scores outputs; a pure `DecisionEngine` applies incumbent-anchored acceptance bars and the locality→cost→latency→quality rule.

**Tech Stack:** Swift 6, swift-argument-parser, SQLiteData (GRDB), CryptoKit (hashing), Swift Testing. macOS 14 floor (Foundation Models paths gated `@available(macOS 26.0, *)`).

## Global Constraints

- **Swift only. No Python, ever.**
- **PensieveKit floor is `.macOS(.v14)`**; all Foundation Models use sites must be gated `if #available(macOS 26.0, *)` / `#if canImport(FoundationModels)`.
- **The extraction trust gate is sacred** — `LooseEndVerifier.verify` (deterministic verbatim check) stays in the extraction path; the harness never surfaces an unverified loose end.
- **SQLiteData predicates use `.eq(x)`, not `== x`.** Kind strings come from `CaptureKind`/`SourceKind` constants.
- **No shared mutable `static ISO8601DateFormatter`.** Use `Date.ISO8601FormatStyle` or a local instance. Use `ContinuousClock` for latency (monotonic).
- **The corpus and all run outputs are private work text** → everything under `.eval/` is gitignored and never committed.
- **API keys are Keychain-only**, keyed by `ModelUnderTest` **label** — never in config, corpus, logs, or report.
- **Logic lives in tested PensieveKit; the CLI stays thin.** Real model calls are a manual/integration step, never in CI.
- **Deviations from the spec, accepted at plan time:** (1) temperature-0 is *not* wired (neither provider exposes it; variance handled by k-repeat + median + fabrication-must-reproduce); (2) token counts are estimated as `ceil(chars/4)` (providers don't surface usage) and labeled as estimates in the report.

---

## File Structure

- `Sources/PensieveKit/Eval/EvalConfig.swift` — `ModelSpec`, `TaskBar`, `EvalConfig` (+ JSON load).
- `Sources/PensieveKit/Eval/ModelProviderFactory.swift` — build a provider from a `ModelSpec`; label-keyed key resolution.
- `Sources/PensieveKit/Eval/CorpusDTO.swift` — `Codable` DTOs for `TranscriptMessage`, `Event`, `ProjectContext` + converters; the three `*CorpusItem` types; `CorpusItem` enum.
- `Sources/PensieveKit/Eval/CorpusHash.swift` — SHA256 content hash; `CorpusManifest`.
- `Sources/PensieveKit/Eval/CorpusSampler.swift` — `SeededRNG` (SplitMix64) + pure stratified selection.
- `Sources/PensieveKit/Eval/EvalTask.swift` — `EvalTask` protocol, `TaskOutput`, `ScorerKind`, `TaskRegistry`.
- `Sources/PensieveKit/Eval/ExtractionTask.swift` — stage-isolated extraction task.
- `Sources/PensieveKit/Eval/NarrationTask.swift` + `DescriptionTask.swift` — the two rubric tasks.
- `Sources/PensieveKit/Eval/Judge.swift` — `JudgeVerdict`, `CandidateLabel`, rubric + grounding prompts, blinded scoring, JSON decode.
- `Sources/PensieveKit/Eval/Agreement.swift` — judge-vs-human agreement rate.
- `Sources/PensieveKit/Eval/TokenEstimate.swift` — char/4 token + cost estimate.
- `Sources/PensieveKit/Eval/Runner.swift` — `CellSample`, sweep, outcome classification, latency.
- `Sources/PensieveKit/Eval/Scorecard.swift` — `JudgedCell`, aggregation (median, majority-fabrication), incumbent-anchored bars, `DecisionEngine`, `Recommendation`.
- `Sources/PensieveKit/Eval/ReportRenderer.swift` — `scorecard.json` + `report.md`.
- `Sources/PensieveKit/Eval/GoldSet.swift` — gold-label persistence.
- `Sources/PensieveKit/Eval/CorpusBuilder.swift` — impure: DB/transcripts/git → frozen files (smoke-verified).
- `Sources/PensieveKit/Eval/EvalPaths.swift` — `.eval/` locations.
- `Sources/pensieve/Commands/Eval.swift` — `eval` parent + `sample`/`run`/`report`/`keys`/`gold` subcommands.
- `Sources/PensieveKit/Eval/README.md` — "Add a task in 3 steps" recipe.
- Modify: `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift` (optional `classifierProvider`).
- Modify: `Sources/PensieveKit/LLM/LLMProvider.swift` (doc-comment pointer).
- Modify: `Sources/pensieve/Pensieve.swift` (register `Eval`).
- Modify: `.gitignore` (add `.eval/`), `CLAUDE.md` (convention line).
- Tests: `Tests/PensieveKitTests/Eval*Tests.swift`.

---

## Task 1: EvalConfig + gitignore

**Files:**
- Create: `Sources/PensieveKit/Eval/EvalConfig.swift`
- Create: `Sources/PensieveKit/Eval/EvalPaths.swift`
- Modify: `.gitignore`
- Test: `Tests/PensieveKitTests/EvalConfigTests.swift`

**Interfaces:**
- Produces: `ModelSpec{label:String, kind:String, flavor:CloudFlavor?, baseURL:String?, model:String?, inputPricePerM:Double, outputPricePerM:Double}`; `TaskBar{task:String, inheritFromIncumbent:Bool, precision:Double?, recall:Double?, quality:Double?}`; `EvalConfig{roster:[ModelSpec], referenceProvider:String, judge:ModelSpec, bars:[TaskBar], corpusSize:Int, corpusSeed:UInt64, noiseMargin:Double}` with `static func load(from:URL) throws -> EvalConfig` and `func bar(for task:String) -> TaskBar?`; `enum EvalPaths` with `static func dir() -> URL`, `corpusDir()`, `manifestURL()`, `scorecardURL()`, `reportURL()`, `goldURL()`, `configURL()`.

- [ ] **Step 1: Add `.eval/` to `.gitignore`**

Append to `.gitignore`:
```
# Eval harness — private work text + run outputs, never committed
.eval/
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/PensieveKitTests/EvalConfigTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func evalConfigDecodesRosterAndBars() throws {
  let json = """
  {
    "referenceProvider": "apple/foundation-models",
    "corpusSize": 30, "corpusSeed": 42, "noiseMargin": 0.03,
    "judge": {"label":"anthropic/opus","kind":"cloud","flavor":"anthropic","baseURL":"https://api.anthropic.com","model":"claude-opus-4-8","inputPricePerM":15,"outputPricePerM":75},
    "roster": [
      {"label":"apple/foundation-models","kind":"foundationModels","inputPricePerM":0,"outputPricePerM":0},
      {"label":"openai/gpt-5-nano","kind":"cloud","flavor":"openAICompatible","baseURL":"https://api.openai.com/v1","model":"gpt-5-nano","inputPricePerM":0.05,"outputPricePerM":0.4}
    ],
    "bars": [
      {"task":"extraction","inheritFromIncumbent":true},
      {"task":"narration","inheritFromIncumbent":true}
    ]
  }
  """
  let url = tempURL("eval-config", ext: "json")
  try json.data(using: .utf8)!.write(to: url)
  let cfg = try EvalConfig.load(from: url)
  #expect(cfg.roster.count == 2)
  #expect(cfg.referenceProvider == "apple/foundation-models")
  #expect(cfg.roster[0].inputPricePerM == 0)
  #expect(cfg.bar(for: "extraction")?.inheritFromIncumbent == true)
  #expect(cfg.bar(for: "missing") == nil)
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./scripts/test.sh --filter EvalConfigTests`
Expected: FAIL — `EvalConfig` / `EvalPaths` undefined.

- [ ] **Step 4: Implement `EvalConfig.swift` and `EvalPaths.swift`**

```swift
// Sources/PensieveKit/Eval/EvalConfig.swift
import Foundation

public struct ModelSpec: Codable, Sendable, Equatable {
  public var label: String
  public var kind: String            // "foundationModels" | "cloud"
  public var flavor: CloudFlavor?
  public var baseURL: String?
  public var model: String?
  public var inputPricePerM: Double
  public var outputPricePerM: Double
  public var isOnDevice: Bool { kind == "foundationModels" }
}

public struct TaskBar: Codable, Sendable, Equatable {
  public var task: String
  public var inheritFromIncumbent: Bool
  public var precision: Double?
  public var recall: Double?
  public var quality: Double?
}

public struct EvalConfig: Codable, Sendable, Equatable {
  public var roster: [ModelSpec]
  public var referenceProvider: String
  public var judge: ModelSpec
  public var bars: [TaskBar]
  public var corpusSize: Int
  public var corpusSeed: UInt64
  public var noiseMargin: Double

  public static func load(from url: URL) throws -> EvalConfig {
    try JSONDecoder().decode(EvalConfig.self, from: Data(contentsOf: url))
  }
  public func bar(for task: String) -> TaskBar? { bars.first { $0.task == task } }
  public func spec(label: String) -> ModelSpec? { roster.first { $0.label == label } }
}
```

```swift
// Sources/PensieveKit/Eval/EvalPaths.swift
import Foundation

public enum EvalPaths {
  public static func dir() -> URL {
    if let o = ProcessInfo.processInfo.environment["PENSIEVE_EVAL_DIR"] {
      return URL(fileURLWithPath: o)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".eval")
  }
  public static func corpusDir() -> URL { dir().appendingPathComponent("corpus") }
  public static func manifestURL() -> URL { corpusDir().appendingPathComponent("manifest.json") }
  public static func scorecardURL() -> URL { dir().appendingPathComponent("scorecard.json") }
  public static func reportURL() -> URL { dir().appendingPathComponent("report.md") }
  public static func goldURL() -> URL { dir().appendingPathComponent("gold.json") }
  public static func configURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("eval-config.json")
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test.sh --filter EvalConfigTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Eval/EvalConfig.swift Sources/PensieveKit/Eval/EvalPaths.swift Tests/PensieveKitTests/EvalConfigTests.swift .gitignore
git commit -m "feat(eval): config model + paths + gitignore .eval/"
```

---

## Task 2: Model provider factory (label-keyed key)

**Files:**
- Create: `Sources/PensieveKit/Eval/ModelProviderFactory.swift`
- Test: `Tests/PensieveKitTests/ModelProviderFactoryTests.swift`

**Interfaces:**
- Consumes: `ModelSpec` (Task 1), `CloudConfig`, `CloudLLMProvider`, `FoundationModelsProvider`.
- Produces: `enum ModelProviderFactory` with `static func apiKeyAccount(for:ModelSpec) -> String`, `static func needsKey(_:ModelSpec) -> Bool`, `static func make(_ spec:ModelSpec, apiKey:String?) -> (any LLMProvider)?` (nil when a key is required but missing, or on-device unavailable).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/ModelProviderFactoryTests.swift
import Testing
@testable import PensieveKit

private let onDevice = ModelSpec(label: "apple/foundation-models", kind: "foundationModels", flavor: nil, baseURL: nil, model: nil, inputPricePerM: 0, outputPricePerM: 0)
private let cloud = ModelSpec(label: "openai/gpt-5-nano", kind: "cloud", flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-5-nano", inputPricePerM: 0.05, outputPricePerM: 0.4)

@Test func keyAccountIsTheLabel() {
  #expect(ModelProviderFactory.apiKeyAccount(for: cloud) == "openai/gpt-5-nano")
}
@Test func onDeviceNeedsNoKey() {
  #expect(ModelProviderFactory.needsKey(onDevice) == false)
  #expect(ModelProviderFactory.needsKey(cloud) == true)
}
@Test func cloudWithoutKeyIsNil() {
  #expect(ModelProviderFactory.make(cloud, apiKey: nil) == nil)
}
@Test func cloudWithKeyBuildsProvider() {
  #expect(ModelProviderFactory.make(cloud, apiKey: "sk-x") != nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ModelProviderFactoryTests`
Expected: FAIL — `ModelProviderFactory` undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Eval/ModelProviderFactory.swift
import Foundation

public enum ModelProviderFactory {
  public static func apiKeyAccount(for spec: ModelSpec) -> String { spec.label }

  public static func needsKey(_ spec: ModelSpec) -> Bool {
    guard !spec.isOnDevice else { return false }
    let cfg = cloudConfig(spec)
    return !(cfg?.isLocalEndpoint ?? false)
  }

  public static func make(_ spec: ModelSpec, apiKey: String?) -> (any LLMProvider)? {
    if spec.isOnDevice {
      #if canImport(FoundationModels)
      if #available(macOS 26.0, *) { return FoundationModelsProvider() }
      #endif
      return nil
    }
    guard let cfg = cloudConfig(spec), cfg.isUsable else { return nil }
    if needsKey(spec) && (apiKey == nil || apiKey!.isEmpty) { return nil }
    return CloudLLMProvider(config: cfg, apiKey: apiKey ?? "")
  }

  private static func cloudConfig(_ spec: ModelSpec) -> CloudConfig? {
    guard let flavor = spec.flavor, let base = spec.baseURL, let model = spec.model else { return nil }
    return CloudConfig(flavor: flavor, baseURL: base, model: model)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter ModelProviderFactoryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/ModelProviderFactory.swift Tests/PensieveKitTests/ModelProviderFactoryTests.swift
git commit -m "feat(eval): label-keyed model provider factory"
```

---

## Task 3: Corpus DTOs + converters

**Files:**
- Create: `Sources/PensieveKit/Eval/CorpusDTO.swift`
- Test: `Tests/PensieveKitTests/CorpusDTOTests.swift`

**Interfaces:**
- Consumes: `TranscriptMessage{index,role,text,timestamp?,isUserPrompt}`, `Event` (all fields), `ProjectContext{dirName,gitRemote?,readmeHead?,claudeMdHead?,manifest?}`.
- Produces: `TranscriptMessageDTO`, `EventDTO`, `ProjectContextDTO` (all `Codable`) each with `init(_ domain:)` and `toDomain()`; item types `ExtractionCorpusItem{id,shape,messages:[TranscriptMessageDTO]}`, `NarrationCorpusItem{id,nodeName,events:[EventDTO]}`, `DescriptionCorpusItem{id,context:ProjectContextDTO}`; `enum CorpusItem { case extraction(ExtractionCorpusItem); case narration(NarrationCorpusItem); case description(DescriptionCorpusItem) }` with `var id: String`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/CorpusDTOTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func transcriptMessageRoundTrips() throws {
  let m = TranscriptMessage(index: 3, role: "user", text: "ship it", timestamp: nil, isUserPrompt: true)
  let dto = TranscriptMessageDTO(m)
  let data = try JSONEncoder().encode(dto)
  let back = try JSONDecoder().decode(TranscriptMessageDTO.self, from: data).toDomain()
  #expect(back.index == 3 && back.role == "user" && back.text == "ship it" && back.isUserPrompt)
}

@Test func projectContextRoundTrips() throws {
  let ctx = ProjectContext(dirName: "colibri", gitRemote: "git@x", readmeHead: "# hi", claudeMdHead: nil, manifest: "a\nb")
  let back = ProjectContextDTO(ctx).toDomain()
  #expect(back.dirName == "colibri" && back.gitRemote == "git@x" && back.manifest == "a\nb" && back.claudeMdHead == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter CorpusDTOTests`
Expected: FAIL — DTO types undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Eval/CorpusDTO.swift
import Foundation

public struct TranscriptMessageDTO: Codable, Sendable {
  public var index: Int; public var role: String; public var text: String
  public var timestamp: Date?; public var isUserPrompt: Bool
  public init(_ m: TranscriptMessage) {
    index = m.index; role = m.role; text = m.text; timestamp = m.timestamp; isUserPrompt = m.isUserPrompt
  }
  public func toDomain() -> TranscriptMessage {
    TranscriptMessage(index: index, role: role, text: text, timestamp: timestamp, isUserPrompt: isUserPrompt)
  }
}

public struct EventDTO: Codable, Sendable {
  public var id: UUID; public var nodeID: UUID; public var sourceID: UUID
  public var occurredAt: Date; public var kind: String; public var summary: String
  public var detailJSON: String; public var fingerprint: String?; public var branchKey: String?
  public var extractedAt: Date?; public var extractedMessageCount: Int; public var extractedTranscriptSize: Int
  public var workSummary: String?; public var createdAt: Date
  public init(_ e: Event) {
    id = e.id; nodeID = e.nodeID; sourceID = e.sourceID; occurredAt = e.occurredAt; kind = e.kind
    summary = e.summary; detailJSON = e.detailJSON; fingerprint = e.fingerprint; branchKey = e.branchKey
    extractedAt = e.extractedAt; extractedMessageCount = e.extractedMessageCount
    extractedTranscriptSize = e.extractedTranscriptSize; workSummary = e.workSummary; createdAt = e.createdAt
  }
  public func toDomain() -> Event {
    Event(id: id, nodeID: nodeID, sourceID: sourceID, occurredAt: occurredAt, kind: kind, summary: summary,
          detailJSON: detailJSON, fingerprint: fingerprint, branchKey: branchKey, extractedAt: extractedAt,
          extractedMessageCount: extractedMessageCount, extractedTranscriptSize: extractedTranscriptSize,
          workSummary: workSummary, createdAt: createdAt)
  }
}

public struct ProjectContextDTO: Codable, Sendable {
  public var dirName: String; public var gitRemote: String?; public var readmeHead: String?
  public var claudeMdHead: String?; public var manifest: String?
  public init(_ c: ProjectContext) {
    dirName = c.dirName; gitRemote = c.gitRemote; readmeHead = c.readmeHead
    claudeMdHead = c.claudeMdHead; manifest = c.manifest
  }
  public func toDomain() -> ProjectContext {
    ProjectContext(dirName: dirName, gitRemote: gitRemote, readmeHead: readmeHead,
                   claudeMdHead: claudeMdHead, manifest: manifest)
  }
}

public struct ExtractionCorpusItem: Codable, Sendable {
  public var id: String; public var shape: String; public var messages: [TranscriptMessageDTO]
  public init(id: String, shape: String, messages: [TranscriptMessageDTO]) {
    self.id = id; self.shape = shape; self.messages = messages
  }
}
public struct NarrationCorpusItem: Codable, Sendable {
  public var id: String; public var nodeName: String; public var events: [EventDTO]
  public init(id: String, nodeName: String, events: [EventDTO]) {
    self.id = id; self.nodeName = nodeName; self.events = events
  }
}
public struct DescriptionCorpusItem: Codable, Sendable {
  public var id: String; public var context: ProjectContextDTO
  public init(id: String, context: ProjectContextDTO) { self.id = id; self.context = context }
}

public enum CorpusItem: Sendable {
  case extraction(ExtractionCorpusItem)
  case narration(NarrationCorpusItem)
  case description(DescriptionCorpusItem)
  public var id: String {
    switch self {
    case .extraction(let i): return i.id
    case .narration(let i): return i.id
    case .description(let i): return i.id
    }
  }
}
```

> Note: confirm the `Event.init(...)` memberwise argument order matches `Event.swift`. If `@Table` suppresses the memberwise init, add an explicit `public init` to `Event` in a separate 1-line change, or map fields via a mutable `var`.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter CorpusDTOTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/CorpusDTO.swift Tests/PensieveKitTests/CorpusDTOTests.swift
git commit -m "feat(eval): Codable corpus DTOs + converters"
```

---

## Task 4: Corpus hash + manifest

**Files:**
- Create: `Sources/PensieveKit/Eval/CorpusHash.swift`
- Test: `Tests/PensieveKitTests/CorpusHashTests.swift`

**Interfaces:**
- Produces: `enum CorpusHash { static func hash(_ parts:[Data]) -> String }` (SHA256 hex over length-prefixed, order-preserving concatenation); `struct CorpusManifest: Codable, Sendable { var seed:UInt64; var contentHash:String; var counts:[String:Int]; var stressItems:[String] }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/CorpusHashTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func hashIsStableAndOrderSensitive() {
  let a = Data("one".utf8), b = Data("two".utf8)
  #expect(CorpusHash.hash([a, b]) == CorpusHash.hash([a, b]))
  #expect(CorpusHash.hash([a, b]) != CorpusHash.hash([b, a]))
  #expect(CorpusHash.hash([a, b]).count == 64) // hex sha256
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter CorpusHashTests`
Expected: FAIL — `CorpusHash` undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Eval/CorpusHash.swift
import Foundation
import CryptoKit

public enum CorpusHash {
  public static func hash(_ parts: [Data]) -> String {
    var hasher = SHA256()
    for p in parts {
      var len = UInt64(p.count).littleEndian
      withUnsafeBytes(of: &len) { hasher.update(data: Data($0)) }  // length-prefix → order/boundary sensitive
      hasher.update(data: p)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public struct CorpusManifest: Codable, Sendable {
  public var seed: UInt64
  public var contentHash: String
  public var counts: [String: Int]
  public var stressItems: [String]
  public init(seed: UInt64, contentHash: String, counts: [String: Int], stressItems: [String]) {
    self.seed = seed; self.contentHash = contentHash; self.counts = counts; self.stressItems = stressItems
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter CorpusHashTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/CorpusHash.swift Tests/PensieveKitTests/CorpusHashTests.swift
git commit -m "feat(eval): corpus content hash + manifest"
```

---

## Task 5: Deterministic stratified sampler

**Files:**
- Create: `Sources/PensieveKit/Eval/CorpusSampler.swift`
- Test: `Tests/PensieveKitTests/CorpusSamplerTests.swift`

**Interfaces:**
- Produces: `struct SeededRNG: RandomNumberGenerator { init(seed:UInt64); mutating func next() -> UInt64 }` (SplitMix64); `enum CorpusSampler { static func select<T>(from pool:[(strata:String, isStress:Bool, item:T)], size:Int, seed:UInt64) -> [T] }` — always includes every `isStress` item, fills the remainder round-robin across strata using the seeded RNG, deterministic for a given seed.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/CorpusSamplerTests.swift
import Testing
@testable import PensieveKit

private func pool() -> [(strata: String, isStress: Bool, item: Int)] {
  (0..<40).map { (strata: ["short","long","compacted"][$0 % 3], isStress: $0 == 7, item: $0) }
}

@Test func sameSeedSameSelection() {
  let a = CorpusSampler.select(from: pool(), size: 10, seed: 42)
  let b = CorpusSampler.select(from: pool(), size: 10, seed: 42)
  #expect(a == b)
}
@Test func differentSeedDiffers() {
  let a = CorpusSampler.select(from: pool(), size: 10, seed: 1)
  let b = CorpusSampler.select(from: pool(), size: 10, seed: 2)
  #expect(a != b)
}
@Test func stressItemsAlwaysIncluded() {
  let a = CorpusSampler.select(from: pool(), size: 3, seed: 99)
  #expect(a.contains(7)) // the stress item survives even a tiny sample
}
@Test func spreadsAcrossStrata() {
  let picks = CorpusSampler.select(from: pool(), size: 9, seed: 5)
  let strataOf = Dictionary(uniqueKeysWithValues: pool().map { ($0.item, $0.strata) })
  let kinds = Set(picks.map { strataOf[$0]! })
  #expect(kinds.count == 3) // all three shapes represented
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter CorpusSamplerTests`
Expected: FAIL — `CorpusSampler`/`SeededRNG` undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Eval/CorpusSampler.swift
import Foundation

public struct SeededRNG: RandomNumberGenerator {
  private var state: UInt64
  public init(seed: UInt64) { state = seed }
  public mutating func next() -> UInt64 {   // SplitMix64
    state &+= 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
  }
}

public enum CorpusSampler {
  public static func select<T>(from pool: [(strata: String, isStress: Bool, item: T)],
                               size: Int, seed: UInt64) -> [T] {
    var rng = SeededRNG(seed: seed)
    let stress = pool.filter { $0.isStress }
    var chosen = stress.map { $0.item }
    var remaining = size - chosen.count
    if remaining <= 0 { return chosen }

    // Group non-stress by strata, shuffle each group deterministically.
    var byStrata: [String: [T]] = [:]
    for entry in pool where !entry.isStress { byStrata[entry.strata, default: []].append(entry.item) }
    let strataOrder = byStrata.keys.sorted()
    var queues = strataOrder.map { key -> [T] in
      var arr = byStrata[key]!
      arr.shuffle(using: &rng)
      return arr
    }
    // Round-robin across strata until we hit `size` or exhaust the pool.
    var idx = 0
    while remaining > 0 && queues.contains(where: { !$0.isEmpty }) {
      let q = idx % queues.count
      if !queues[q].isEmpty { chosen.append(queues[q].removeLast()); remaining -= 1 }
      idx += 1
    }
    return chosen
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter CorpusSamplerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/CorpusSampler.swift Tests/PensieveKitTests/CorpusSamplerTests.swift
git commit -m "feat(eval): deterministic stratified sampler with stress items"
```

---

## Task 6: EvalTask protocol + registry + consistency guard

**Files:**
- Create: `Sources/PensieveKit/Eval/EvalTask.swift`
- Test: `Tests/PensieveKitTests/EvalTaskRegistryTests.swift`

**Interfaces:**
- Consumes: `CorpusItem`, `VerifiedLooseEnd`.
- Produces: `enum ScorerKind: Sendable { case extraction; case rubric(dimensions:[String]) }`; `struct TaskOutput: Sendable { var text:String; var looseEnds:[VerifiedLooseEnd]? }`; `protocol EvalTask: Sendable { var id:String {get}; var scorer:ScorerKind {get}; func run(item:CorpusItem, model:any LLMProvider, reference:any LLMProvider) async throws -> TaskOutput }`; `enum TaskRegistry { static let all:[any EvalTask]; static func task(id:String) -> (any EvalTask)?; static func consistencyProblems(config:EvalConfig) -> [String] }`.
- Note: `TaskRegistry.all` is populated with the three concrete tasks in Tasks 7–8; for this task it starts empty and the consistency guard is tested against a stub.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/EvalTaskRegistryTests.swift
import Testing
@testable import PensieveKit

private struct StubTask: EvalTask {
  let id: String; let scorer: ScorerKind = .rubric(dimensions: ["x"])
  func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput { .init(text: "", looseEnds: nil) }
}

@Test func consistencyFlagsTaskWithoutBar() {
  let cfg = EvalConfig(roster: [], referenceProvider: "r",
                       judge: ModelSpec(label:"j",kind:"cloud",flavor:.anthropic,baseURL:"b",model:"m",inputPricePerM:1,outputPricePerM:1),
                       bars: [TaskBar(task: "narration", inheritFromIncumbent: true, precision: nil, recall: nil, quality: nil)],
                       corpusSize: 10, corpusSeed: 1, noiseMargin: 0.03)
  let problems = TaskRegistry.consistency(tasks: [StubTask(id: "extraction"), StubTask(id: "narration")], config: cfg)
  #expect(problems.contains { $0.contains("extraction") }) // no bar for extraction
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter EvalTaskRegistryTests`
Expected: FAIL — `EvalTask`/`TaskRegistry` undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Eval/EvalTask.swift
import Foundation

public enum ScorerKind: Sendable { case extraction; case rubric(dimensions: [String]) }

public struct TaskOutput: Sendable {
  public var text: String
  public var looseEnds: [VerifiedLooseEnd]?
  public init(text: String, looseEnds: [VerifiedLooseEnd]?) { self.text = text; self.looseEnds = looseEnds }
}

public protocol EvalTask: Sendable {
  var id: String { get }
  var scorer: ScorerKind { get }
  func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput
}

public enum TaskRegistry {
  // Populated in Tasks 7–8.
  public static var all: [any EvalTask] { [ExtractionTask(), NarrationTask(), DescriptionTask()] }
  public static func task(id: String) -> (any EvalTask)? { all.first { $0.id == id } }

  /// Registry ↔ config consistency: every task needs a bar; every bar needs a task.
  public static func consistency(tasks: [any EvalTask], config: EvalConfig) -> [String] {
    var problems: [String] = []
    let taskIDs = Set(tasks.map { $0.id })
    let barTasks = Set(config.bars.map { $0.task })
    for t in taskIDs where !barTasks.contains(t) { problems.append("task '\(t)' has no bar in eval-config.json") }
    for b in barTasks where !taskIDs.contains(b) { problems.append("bar '\(b)' has no registered task") }
    return problems
  }
  public static func consistencyProblems(config: EvalConfig) -> [String] { consistency(tasks: all, config: config) }
}
```

> Because `TaskRegistry.all` references the three concrete tasks, this file will not compile until Tasks 7–8 add them. To keep this task independently green, temporarily set `static var all: [any EvalTask] { [] }` and change the test to inject `[StubTask(...)]` via `consistency(tasks:config:)` (as written above). Task 8's final step flips `all` to the three real tasks and re-runs the suite.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter EvalTaskRegistryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/EvalTask.swift Tests/PensieveKitTests/EvalTaskRegistryTests.swift
git commit -m "feat(eval): EvalTask protocol + registry + consistency guard"
```

---

## Task 7: Extraction task (stage-isolated)

**Files:**
- Modify: `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift` (inject classifier provider)
- Create: `Sources/PensieveKit/Eval/ExtractionTask.swift`
- Test: `Tests/PensieveKitTests/ExtractionTaskTests.swift`

**Interfaces:**
- Consumes: `LooseEndExtractor`, `LooseEndVerifier.verify(_:messages:)`, `IntentClassifier`, `CorpusItem`, `TaskOutput`.
- Modifies: `LooseEndExtractor.init(provider:, classifierProvider:(any LLMProvider)? = nil, chunkCharBudget:Int = 2500)` — `classifierProvider ?? provider` is used for the intent filter; **default keeps production behavior unchanged.**
- Produces: `struct ExtractionTask: EvalTask` with `id = "extraction"`, `scorer = .extraction`, running `classifier(reference) → extract(model) → verify(deterministic)` and returning verified loose ends.

- [ ] **Step 1: Modify `LooseEndExtractor` to accept a classifier provider**

In `Sources/PensieveKit/Intelligence/LooseEndExtractor.swift`, change the stored provider/init and the classifier call site (around line 42):

```swift
private let provider: any LLMProvider
private let classifierProvider: any LLMProvider
private let chunkCharBudget: Int

public init(provider: any LLMProvider,
            classifierProvider: (any LLMProvider)? = nil,
            chunkCharBudget: Int = 2500) {
  self.provider = provider
  self.classifierProvider = classifierProvider ?? provider
  self.chunkCharBudget = chunkCharBudget
}
```

At the existing call site, replace `IntentClassifier(provider: provider)` with `IntentClassifier(provider: classifierProvider)`.

- [ ] **Step 2: Write the failing test**

```swift
// Tests/PensieveKitTests/ExtractionTaskTests.swift
import Testing
@testable import PensieveKit

// classifier that keeps everything (genuine), extractor that emits one candidate quoting a real message
private struct KeepAllClassifier: LLMProvider {
  func complete(prompt: String) async throws -> String { "[]" } // fail-open path keeps all
}
private struct OneCandidateExtractor: LLMProvider {
  func complete(prompt: String) async throws -> String { "" }
  func extractCandidates(prompt: String) async throws -> [LooseEndCandidate] {
    [LooseEndCandidate(text: "follow up on retries", quote: "we should revisit retries", messageIndex: 0)]
  }
}

@Test func extractionTaskSurfacesVerifiedLooseEnds() async throws {
  let msgs = [TranscriptMessageDTO(TranscriptMessage(index: 0, role: "user", text: "we should revisit retries later", timestamp: nil, isUserPrompt: true))]
  let item = CorpusItem.extraction(ExtractionCorpusItem(id: "x1", shape: "short", messages: msgs))
  let out = try await ExtractionTask().run(item: item, model: OneCandidateExtractor(), reference: KeepAllClassifier())
  #expect(out.looseEnds?.count == 1)
  #expect(out.looseEnds?.first?.quote == "we should revisit retries") // verbatim substring of the message
}

@Test func extractionTaskRejectsWrongItemType() async {
  let item = CorpusItem.narration(NarrationCorpusItem(id: "n", nodeName: "x", events: []))
  await #expect(throws: (any Error).self) {
    _ = try await ExtractionTask().run(item: item, model: OneCandidateExtractor(), reference: KeepAllClassifier())
  }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./scripts/test.sh --filter ExtractionTaskTests`
Expected: FAIL — `ExtractionTask` undefined.

- [ ] **Step 4: Implement**

```swift
// Sources/PensieveKit/Eval/ExtractionTask.swift
import Foundation

public struct EvalTaskError: Error, Sendable { public let message: String }

public struct ExtractionTask: EvalTask {
  public init() {}
  public let id = "extraction"
  public let scorer: ScorerKind = .extraction

  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .extraction(let ext) = item else { throw EvalTaskError(message: "extraction task got non-extraction item") }
    let messages = ext.messages.map { $0.toDomain() }
    // Stage-isolation: classifier pinned to `reference`, extraction swapped to `model`.
    let candidates = try await LooseEndExtractor(provider: model, classifierProvider: reference).extract(from: messages)
    let verified = candidates.compactMap { LooseEndVerifier.verify($0, messages: messages) }
    let text = verified.map { "- \($0.text)  «\($0.quote)»" }.joined(separator: "\n")
    return TaskOutput(text: text, looseEnds: verified)
  }
}
```

- [ ] **Step 5: Run tests (extraction task + full suite for the production change)**

Run: `./scripts/test.sh --filter ExtractionTaskTests` then `./scripts/test.sh --filter LooseEnd`
Expected: PASS, and existing `LooseEndExtractor`/extraction tests still green (default-arg keeps production behavior).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Intelligence/LooseEndExtractor.swift Sources/PensieveKit/Eval/ExtractionTask.swift Tests/PensieveKitTests/ExtractionTaskTests.swift
git commit -m "feat(eval): stage-isolated extraction task (classifier pinned to reference)"
```

---

## Task 8: Narration + Description tasks

**Files:**
- Create: `Sources/PensieveKit/Eval/NarrationTask.swift`, `Sources/PensieveKit/Eval/DescriptionTask.swift`
- Test: `Tests/PensieveKitTests/NarrationDescriptionTaskTests.swift`

**Interfaces:**
- Consumes: `SummaryBuilder.narrate(project:events:)`, `Node`, `ProjectContext.describePrompt(_:)`, `NodeDescriber.sanitize(_:)`.
- Produces: `struct NarrationTask: EvalTask` (`id="narration"`, `scorer=.rubric(["grounded","complete","concise","noInventedFacts"])`); `struct DescriptionTask: EvalTask` (`id="description"`, `scorer=.rubric(["accurate","specific"])`, drives `describePrompt → model.complete → sanitize`).
- Finalizes: `TaskRegistry.all = [ExtractionTask(), NarrationTask(), DescriptionTask()]`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/NarrationDescriptionTaskTests.swift
import Testing
@testable import PensieveKit

private struct EchoProvider: LLMProvider {
  let text: String
  func complete(prompt: String) async throws -> String { text }
}

@Test func narrationTaskReturnsProse() async throws {
  let item = CorpusItem.narration(NarrationCorpusItem(id: "n1", nodeName: "colibri", events: []))
  // narrate returns nil on no events → task yields empty text, not a crash
  let out = try await NarrationTask().run(item: item, model: EchoProvider(text: "worked on auth"), reference: EchoProvider(text: ""))
  #expect(out.looseEnds == nil)
}

@Test func descriptionTaskSanitizesModelOutput() async throws {
  let ctx = ProjectContextDTO(ProjectContext(dirName: "colibri", gitRemote: nil, readmeHead: "# Colibri", claudeMdHead: nil, manifest: "src/main.swift"))
  let item = CorpusItem.description(DescriptionCorpusItem(id: "d1", context: ctx))
  let out = try await DescriptionTask().run(item: item, model: EchoProvider(text: "A native macOS recipe app."), reference: EchoProvider(text: ""))
  #expect(out.text == "A native macOS recipe app.")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter NarrationDescriptionTaskTests`
Expected: FAIL — task types undefined.

- [ ] **Step 3: Implement both tasks**

```swift
// Sources/PensieveKit/Eval/NarrationTask.swift
import Foundation

public struct NarrationTask: EvalTask {
  public init() {}
  public let id = "narration"
  public let scorer: ScorerKind = .rubric(dimensions: ["grounded", "complete", "concise", "noInventedFacts"])

  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .narration(let n) = item else { throw EvalTaskError(message: "narration task got non-narration item") }
    let node = Node(name: n.nodeName)
    let events = n.events.map { $0.toDomain() }
    let prose = await SummaryBuilder(provider: model).narrate(project: node, events: events)
    return TaskOutput(text: prose ?? "", looseEnds: nil)
  }
}
```

```swift
// Sources/PensieveKit/Eval/DescriptionTask.swift
import Foundation

public struct DescriptionTask: EvalTask {
  public init() {}
  public let id = "description"
  public let scorer: ScorerKind = .rubric(dimensions: ["accurate", "specific"])

  public func run(item: CorpusItem, model: any LLMProvider, reference: any LLMProvider) async throws -> TaskOutput {
    guard case .description(let d) = item else { throw EvalTaskError(message: "description task got non-description item") }
    let ctx = d.context.toDomain()
    let prompt = ProjectContext.describePrompt(ctx)
    let raw = (try? await model.complete(prompt: prompt)) ?? ""
    let cleaned = NodeDescriber.sanitize(raw) ?? ""
    return TaskOutput(text: cleaned, looseEnds: nil)
  }
}
```

> Confirm `Node(name:)` is a valid initializer (it is used this way in `SummaryBuilderNarrateTests`). If `Node` requires more fields, mirror the initializer used in that test file.

- [ ] **Step 4: Run tests (task suite + registry consistency now that `all` is populated)**

Run: `./scripts/test.sh --filter NarrationDescriptionTaskTests` then `./scripts/test.sh --filter EvalTaskRegistryTests`
Expected: PASS. Ensure `TaskRegistry.all` returns the three tasks (revert the temporary `[]` from Task 6 if still present).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/NarrationTask.swift Sources/PensieveKit/Eval/DescriptionTask.swift Sources/PensieveKit/Eval/EvalTask.swift Tests/PensieveKitTests/NarrationDescriptionTaskTests.swift
git commit -m "feat(eval): narration + description tasks; finalize task registry"
```

---

## Task 9: Token/cost estimate

**Files:**
- Create: `Sources/PensieveKit/Eval/TokenEstimate.swift`
- Test: `Tests/PensieveKitTests/TokenEstimateTests.swift`

**Interfaces:**
- Produces: `enum TokenEstimate { static func tokens(_ text:String) -> Int; static func costUSD(inputText:String, outputText:String, spec:ModelSpec) -> Double }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/TokenEstimateTests.swift
import Testing
@testable import PensieveKit

@Test func tokensAreCharsOverFourCeil() {
  #expect(TokenEstimate.tokens("") == 0)
  #expect(TokenEstimate.tokens("abcd") == 1)
  #expect(TokenEstimate.tokens("abcde") == 2)
}
@Test func onDeviceCostsZero() {
  let fm = ModelSpec(label: "apple/foundation-models", kind: "foundationModels", flavor: nil, baseURL: nil, model: nil, inputPricePerM: 0, outputPricePerM: 0)
  #expect(TokenEstimate.costUSD(inputText: String(repeating: "x", count: 4000), outputText: "yyyy", spec: fm) == 0)
}
@Test func cloudCostUsesPrices() {
  let m = ModelSpec(label: "openai/gpt-5-nano", kind: "cloud", flavor: .openAICompatible, baseURL: "b", model: "m", inputPricePerM: 1.0, outputPricePerM: 2.0)
  // 4_000_000 chars → 1_000_000 input tokens → $1.0; 8_000_000 chars → 2_000_000 output tokens → $4.0
  let cost = TokenEstimate.costUSD(inputText: String(repeating: "x", count: 4_000_000), outputText: String(repeating: "y", count: 8_000_000), spec: m)
  #expect(abs(cost - 5.0) < 1e-6)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter TokenEstimateTests`
Expected: FAIL — `TokenEstimate` undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Eval/TokenEstimate.swift
import Foundation

public enum TokenEstimate {
  public static func tokens(_ text: String) -> Int { Int(ceil(Double(text.count) / 4.0)) }
  public static func costUSD(inputText: String, outputText: String, spec: ModelSpec) -> Double {
    let inTok = Double(tokens(inputText)), outTok = Double(tokens(outputText))
    return inTok / 1_000_000 * spec.inputPricePerM + outTok / 1_000_000 * spec.outputPricePerM
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter TokenEstimateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/TokenEstimate.swift Tests/PensieveKitTests/TokenEstimateTests.swift
git commit -m "feat(eval): estimated token + cost model"
```

---

## Task 10: Judge (blinded scoring + grounding labels + agreement)

**Files:**
- Create: `Sources/PensieveKit/Eval/Judge.swift`, `Sources/PensieveKit/Eval/Agreement.swift`
- Test: `Tests/PensieveKitTests/JudgeTests.swift`, `Tests/PensieveKitTests/AgreementTests.swift`

**Interfaces:**
- Consumes: `LLMProvider`, `VerifiedLooseEnd`.
- Produces: `struct CandidateLabel: Codable, Sendable { var quote:String; var grounded:Bool }`; `struct JudgeVerdict: Codable, Sendable { var quality:Double?; var dimensionScores:[String:Double]?; var candidateLabels:[CandidateLabel]? }`; `struct Judge: Sendable { init(provider:any LLMProvider); func scoreRubric(output:String, dimensions:[String], sourceContext:String) async -> JudgeVerdict?; func labelGrounding(looseEnds:[VerifiedLooseEnd], source:String) async -> [CandidateLabel]? }` (both **blinded**: prompts never include a model label); `enum JudgeDecode { static func object<T:Decodable>(_ raw:String, as:T.Type) -> T? }`; `enum Agreement { static func rate(judge:[CandidateLabel], human:[CandidateLabel]) -> Double? }`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/JudgeTests.swift
import Testing
@testable import PensieveKit

private struct JSONProvider: LLMProvider {
  let json: String
  func complete(prompt: String) async throws -> String { json }
}

@Test func judgeDecodesRubricFromFencedJSON() async {
  let p = JSONProvider(json: "```json\n{\"dimensionScores\":{\"grounded\":1.0,\"concise\":0.5},\"quality\":0.75}\n```")
  let v = await Judge(provider: p).scoreRubric(output: "prose", dimensions: ["grounded","concise"], sourceContext: "ctx")
  #expect(v?.quality == 0.75)
  #expect(v?.dimensionScores?["grounded"] == 1.0)
}

@Test func judgeLabelsGrounding() async {
  let p = JSONProvider(json: "{\"candidateLabels\":[{\"quote\":\"revisit retries\",\"grounded\":true},{\"quote\":\"call Bob\",\"grounded\":false}]}")
  let le = [VerifiedLooseEnd(text: "t", quote: "revisit retries", role: "user", sourceMessageIndex: 0),
            VerifiedLooseEnd(text: "t2", quote: "call Bob", role: "user", sourceMessageIndex: 1)]
  let labels = await Judge(provider: p).labelGrounding(looseEnds: le, source: "we should revisit retries")
  #expect(labels?.count == 2)
  #expect(labels?.first(where: { $0.quote == "call Bob" })?.grounded == false)
}

@Test func judgeReturnsNilOnGarbage() async {
  let v = await Judge(provider: JSONProvider(json: "not json at all")).scoreRubric(output: "x", dimensions: ["a"], sourceContext: "c")
  #expect(v == nil)
}
```

```swift
// Tests/PensieveKitTests/AgreementTests.swift
import Testing
@testable import PensieveKit

@Test func agreementRateCountsMatches() {
  let judge = [CandidateLabel(quote: "a", grounded: true), CandidateLabel(quote: "b", grounded: false)]
  let human = [CandidateLabel(quote: "a", grounded: true), CandidateLabel(quote: "b", grounded: true)]
  #expect(Agreement.rate(judge: judge, human: human) == 0.5)
}
@Test func agreementNilWhenNoOverlap() {
  #expect(Agreement.rate(judge: [], human: []) == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter JudgeTests` and `./scripts/test.sh --filter AgreementTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement `Judge.swift`**

```swift
// Sources/PensieveKit/Eval/Judge.swift
import Foundation

public struct CandidateLabel: Codable, Sendable, Equatable {
  public var quote: String; public var grounded: Bool
  public init(quote: String, grounded: Bool) { self.quote = quote; self.grounded = grounded }
}

public struct JudgeVerdict: Codable, Sendable, Equatable {
  public var quality: Double?
  public var dimensionScores: [String: Double]?
  public var candidateLabels: [CandidateLabel]?
}

public enum JudgeDecode {
  /// Extract the first balanced JSON object/array substring and decode it (tolerates ``` fences + prose).
  public static func object<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
    guard let start = raw.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
    let open = raw[start], close: Character = (open == "{") ? "}" : "]"
    var depth = 0, end: String.Index? = nil
    var i = start
    while i < raw.endIndex {
      if raw[i] == open { depth += 1 } else if raw[i] == close { depth -= 1; if depth == 0 { end = i; break } }
      i = raw.index(after: i)
    }
    guard let e = end else { return nil }
    let slice = String(raw[start...e])
    return try? JSONDecoder().decode(T.self, from: Data(slice.utf8))
  }
}

public struct Judge: Sendable {
  private let provider: any LLMProvider
  public init(provider: any LLMProvider) { self.provider = provider }

  // Blinded: no model identity in any prompt.
  public func scoreRubric(output: String, dimensions: [String], sourceContext: String) async -> JudgeVerdict? {
    let dims = dimensions.joined(separator: ", ")
    let prompt = """
    You are grading a generated text against its source. Score each dimension in [0,1].
    Dimensions: \(dims).
    Return ONLY JSON: {"dimensionScores": {"<dim>": <0..1>, ...}, "quality": <mean 0..1>}.

    SOURCE:
    \(sourceContext)

    GENERATED:
    \(output)
    """
    guard let raw = try? await provider.complete(prompt: prompt) else { return nil }
    return JudgeDecode.object(raw, as: JudgeVerdict.self)
  }

  public func labelGrounding(looseEnds: [VerifiedLooseEnd], source: String) async -> [CandidateLabel]? {
    guard !looseEnds.isEmpty else { return [] }
    let quotes = looseEnds.enumerated().map { "\($0.offset). «\($0.element.quote)»" }.joined(separator: "\n")
    let prompt = """
    For each candidate quote, decide if it is genuinely grounded in the SOURCE (true) or fabricated / not supported (false).
    Return ONLY JSON: {"candidateLabels": [{"quote": "<verbatim quote>", "grounded": true|false}, ...]}.

    SOURCE:
    \(source)

    CANDIDATES:
    \(quotes)
    """
    guard let raw = try? await provider.complete(prompt: prompt) else { return nil }
    return JudgeDecode.object(raw, as: JudgeVerdict.self)?.candidateLabels
  }
}
```

```swift
// Sources/PensieveKit/Eval/Agreement.swift
import Foundation

public enum Agreement {
  /// Fraction of quotes where the judge's grounded flag matches the human's. nil if no shared quotes.
  public static func rate(judge: [CandidateLabel], human: [CandidateLabel]) -> Double? {
    let judgeMap = Dictionary(judge.map { ($0.quote, $0.grounded) }, uniquingKeysWith: { a, _ in a })
    let shared = human.filter { judgeMap[$0.quote] != nil }
    guard !shared.isEmpty else { return nil }
    let matches = shared.filter { judgeMap[$0.quote] == $0.grounded }.count
    return Double(matches) / Double(shared.count)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter JudgeTests` and `./scripts/test.sh --filter AgreementTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/Judge.swift Sources/PensieveKit/Eval/Agreement.swift Tests/PensieveKitTests/JudgeTests.swift Tests/PensieveKitTests/AgreementTests.swift
git commit -m "feat(eval): blinded judge (rubric + grounding) and agreement metric"
```

---

## Task 11: Scorecard aggregation + decision engine

**Files:**
- Create: `Sources/PensieveKit/Eval/Scorecard.swift`
- Test: `Tests/PensieveKitTests/DecisionEngineTests.swift`

**Interfaces:**
- Consumes: `ModelSpec`, `EvalConfig`, `TaskBar`, `CandidateLabel`.
- Produces:
  - `struct CellScore: Sendable { var modelLabel:String; var isOnDevice:Bool; var quality:Double?; var precision:Double?; var recall:Double?; var costUSD:Double; var latencyP50:Double; var reproducedFabrication:Bool }`
  - `struct EffectiveBar: Sendable { var precision:Double?; var recall:Double?; var quality:Double? }`
  - `enum DecisionEngine { static func effectiveBar(task:String, config:EvalConfig, incumbent:CellScore?) -> EffectiveBar; static func recommend(task:String, scores:[CellScore], bar:EffectiveBar, incumbentLabel:String, noiseMargin:Double) -> Recommendation }`
  - `struct Recommendation: Sendable, Equatable { var task:String; var winner:String; var clearedBar:[String]; var reason:String }`
  - `enum Aggregate { static func median(_ xs:[Double]) -> Double?; static func majorityFabrication(_ flags:[Bool]) -> Bool }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PensieveKitTests/DecisionEngineTests.swift
import Testing
@testable import PensieveKit

private func score(_ label: String, onDevice: Bool, q: Double, cost: Double, lat: Double, fab: Bool = false, prec: Double? = nil, rec: Double? = nil) -> CellScore {
  CellScore(modelLabel: label, isOnDevice: onDevice, quality: q, precision: prec, recall: rec, costUSD: cost, latencyP50: lat, reproducedFabrication: fab)
}

@Test func medianAndMajority() {
  #expect(Aggregate.median([1, 3, 2]) == 2)
  #expect(Aggregate.median([]) == nil)
  #expect(Aggregate.majorityFabrication([true, true, false]) == true)
  #expect(Aggregate.majorityFabrication([true, false, false]) == false)
}

@Test func localIncumbentThatClearsAlwaysWinsEvenIfCloudScoresHigher() {
  // Local-first north star: quality above the bar is worth nothing. FM clears → FM wins.
  let scores = [score("apple/fm", onDevice: true, q: 0.80, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, q: 0.95, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.70)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm")
}

@Test func challengerWinsWhenIncumbentFailsTheBar() {
  // Absolute (config) bar the incumbent misses → cheapest-passing challenger wins.
  let scores = [score("apple/fm", onDevice: true, q: 0.60, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, q: 0.90, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.85)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "openai/nano")     // FM (0.60) excluded; nano (0.90) clears 0.85 by margin
  #expect(rec.clearedBar == ["openai/nano"])
}

@Test func fallsBackToIncumbentWhenNothingClears() {
  let scores = [score("apple/fm", onDevice: true, q: 0.50, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, q: 0.55, cost: 0.001, lat: 300)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.90)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm")        // nobody cleared → incumbent fallback
}

@Test func fabricationHardFailsExtractionRegardlessOfQuality() {
  let scores = [score("apple/fm", onDevice: true, q: 0, cost: 0, lat: 900, prec: 1.0, rec: 0.8),
                score("grok/fast", onDevice: false, q: 0, cost: 0.001, lat: 200, fab: true, prec: 0.99, rec: 0.95)]
  let bar = EffectiveBar(precision: 1.0, recall: 0.8, quality: nil)
  let rec = DecisionEngine.recommend(task: "extraction", scores: scores, bar: bar, incumbentLabel: "apple/fm", noiseMargin: 0.03)
  #expect(rec.clearedBar.contains("grok/fast") == false) // reproduced fabrication → excluded
  #expect(rec.winner == "apple/fm")
}

@Test func localityBreaksTiesAmongClearingChallengers() {
  // both clear the bar and beat incumbent; cheaper-but-online vs on-device-that-also-clears
  let scores = [score("apple/fm", onDevice: true, q: 0.95, cost: 0, lat: 900),
                score("openai/nano", onDevice: false, q: 0.97, cost: 0.001, lat: 200)]
  let bar = EffectiveBar(precision: nil, recall: nil, quality: 0.70)
  let rec = DecisionEngine.recommend(task: "narration", scores: scores, bar: bar, incumbentLabel: "zzz-not-in-set", noiseMargin: 0.03)
  #expect(rec.winner == "apple/fm") // locality first among bar-clearing models
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter DecisionEngineTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement `Scorecard.swift`**

```swift
// Sources/PensieveKit/Eval/Scorecard.swift
import Foundation

public struct CellScore: Sendable, Codable, Equatable {
  public var modelLabel: String
  public var isOnDevice: Bool
  public var quality: Double?
  public var precision: Double?
  public var recall: Double?
  public var costUSD: Double
  public var latencyP50: Double
  public var reproducedFabrication: Bool
  public init(modelLabel: String, isOnDevice: Bool, quality: Double?, precision: Double?, recall: Double?, costUSD: Double, latencyP50: Double, reproducedFabrication: Bool) {
    self.modelLabel = modelLabel; self.isOnDevice = isOnDevice; self.quality = quality; self.precision = precision
    self.recall = recall; self.costUSD = costUSD; self.latencyP50 = latencyP50; self.reproducedFabrication = reproducedFabrication
  }
}

public struct EffectiveBar: Sendable, Equatable {
  public var precision: Double?; public var recall: Double?; public var quality: Double?
  public init(precision: Double?, recall: Double?, quality: Double?) { self.precision = precision; self.recall = recall; self.quality = quality }
}

public struct Recommendation: Sendable, Codable, Equatable {
  public var task: String; public var winner: String; public var clearedBar: [String]; public var reason: String
}

public enum Aggregate {
  public static func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
  }
  public static func majorityFabrication(_ flags: [Bool]) -> Bool {
    guard !flags.isEmpty else { return false }
    return flags.filter { $0 }.count * 2 > flags.count
  }
}

public enum DecisionEngine {
  public static func effectiveBar(task: String, config: EvalConfig, incumbent: CellScore?) -> EffectiveBar {
    let bar = config.bar(for: task)
    if bar?.inheritFromIncumbent == true, let inc = incumbent {
      return EffectiveBar(precision: inc.precision, recall: inc.recall, quality: inc.quality)
    }
    return EffectiveBar(precision: bar?.precision, recall: bar?.recall, quality: bar?.quality)
  }

  public static func recommend(task: String, scores: [CellScore], bar: EffectiveBar,
                               incumbentLabel: String, noiseMargin: Double) -> Recommendation {
    // A model clears the bar only ROBUSTLY (by ≥ noiseMargin on soft axes). The precision
    // hard-gate (reproduced fabrication) excludes a model regardless of every other score —
    // and it applies to EVERYONE, including the on-device incumbent.
    func clears(_ s: CellScore) -> Bool {
      if task == "extraction" && s.reproducedFabrication { return false }
      if let p = bar.precision, (s.precision ?? -1) + 1e-9 < p { return false }
      if let r = bar.recall, (s.recall ?? -1) + 1e-9 < r + noiseMargin { return false }
      if let q = bar.quality, (s.quality ?? -1) + 1e-9 < q + noiseMargin { return false }
      return true
    }
    let cleared = scores.filter(clears)
    let clearedLabels = cleared.map { $0.modelLabel }

    // Local-first: rank bar-clearing models by locality → cost → latency → quality. The on-device
    // incumbent ($0, local) tops this whenever it clears, so we never switch to cloud merely for
    // quality-above-bar. A challenger wins only when the incumbent is EXCLUDED (failed the bar or
    // reproduced a fabrication).
    let ranked = cleared.sorted { a, b in
      if a.isOnDevice != b.isOnDevice { return a.isOnDevice && !b.isOnDevice }
      if a.costUSD != b.costUSD { return a.costUSD < b.costUSD }
      if a.latencyP50 != b.latencyP50 { return a.latencyP50 < b.latencyP50 }
      return (a.quality ?? 0) > (b.quality ?? 0)
    }
    guard let winner = ranked.first else {
      return Recommendation(task: task, winner: incumbentLabel, clearedBar: clearedLabels,
                            reason: "no model cleared the bar; fell back to incumbent")
    }
    let reason = winner.modelLabel == incumbentLabel
      ? "incumbent clears the bar (local-first)"
      : "incumbent excluded; cheapest-local bar-clearing model by locality→cost→latency→quality"
    return Recommendation(task: task, winner: winner.modelLabel, clearedBar: clearedLabels, reason: reason)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter DecisionEngineTests`
Expected: PASS (all five tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/Scorecard.swift Tests/PensieveKitTests/DecisionEngineTests.swift
git commit -m "feat(eval): scorecard aggregation + incumbent-anchored decision engine"
```

---

## Task 12: Gold set persistence

**Files:**
- Create: `Sources/PensieveKit/Eval/GoldSet.swift`
- Test: `Tests/PensieveKitTests/GoldSetTests.swift`

**Interfaces:**
- Produces: `struct GoldSet: Codable, Sendable { var recall:[String:[String]]; var grounding:[String:[CandidateLabel]] }` (keyed by corpus item id: `recall[itemID]` = human-known loose-end quotes; `grounding[itemID]` = human grounded/fabricated labels) with `static func load(from:URL) -> GoldSet` (empty on missing) and `func save(to:URL) throws`; `func recallScore(itemID:String, surfaced:[String]) -> Double?`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/GoldSetTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func goldSetRoundTripsAndScoresRecall() throws {
  var g = GoldSet(recall: ["x1": ["revisit retries", "call Bob"]], grounding: [:])
  let url = tempURL("gold", ext: "json")
  try g.save(to: url)
  let loaded = GoldSet.load(from: url)
  // surfaced hits one of two known → recall 0.5
  #expect(loaded.recallScore(itemID: "x1", surfaced: ["revisit retries"]) == 0.5)
  #expect(loaded.recallScore(itemID: "unknown", surfaced: []) == nil)
}

@Test func goldSetLoadMissingIsEmpty() {
  let g = GoldSet.load(from: tempURL("nope", ext: "json"))
  #expect(g.recall.isEmpty && g.grounding.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter GoldSetTests`
Expected: FAIL — `GoldSet` undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Eval/GoldSet.swift
import Foundation

public struct GoldSet: Codable, Sendable {
  public var recall: [String: [String]]              // itemID → known loose-end quotes
  public var grounding: [String: [CandidateLabel]]   // itemID → human grounded/fabricated labels
  public init(recall: [String: [String]], grounding: [String: [CandidateLabel]]) {
    self.recall = recall; self.grounding = grounding
  }
  public static func load(from url: URL) -> GoldSet {
    guard let data = try? Data(contentsOf: url),
          let g = try? JSONDecoder().decode(GoldSet.self, from: data) else { return GoldSet(recall: [:], grounding: [:]) }
    return g
  }
  public func save(to url: URL) throws {
    try EvalPaths.ensureDir(url.deletingLastPathComponent())
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(self).write(to: url)
  }
  /// Fraction of known quotes that were surfaced (verbatim). nil if this item has no gold entry.
  public func recallScore(itemID: String, surfaced: [String]) -> Double? {
    guard let known = recall[itemID], !known.isEmpty else { return nil }
    let hit = known.filter { surfaced.contains($0) }.count
    return Double(hit) / Double(known.count)
  }
}
```

Add to `EvalPaths` (Task 1 file):
```swift
public static func ensureDir(_ url: URL) throws {
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter GoldSetTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/GoldSet.swift Sources/PensieveKit/Eval/EvalPaths.swift Tests/PensieveKitTests/GoldSetTests.swift
git commit -m "feat(eval): gold-set persistence + recall scoring"
```

---

## Task 13: Report renderer

**Files:**
- Create: `Sources/PensieveKit/Eval/ReportRenderer.swift`
- Test: `Tests/PensieveKitTests/ReportRendererTests.swift`

**Interfaces:**
- Consumes: `CellScore`, `Recommendation`.
- Produces: `struct Scorecard: Codable, Sendable { var corpusHash:String; var tasks:[TaskScorecard] }`; `struct TaskScorecard: Codable, Sendable { var task:String; var cells:[CellScore]; var recommendation:Recommendation; var judgeAgreement:Double? }`; `enum ReportRenderer { static func markdown(_ s:Scorecard) -> String }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PensieveKitTests/ReportRendererTests.swift
import Testing
@testable import PensieveKit

@Test func markdownIncludesRecommendationAndCaveats() {
  let cells = [CellScore(modelLabel: "apple/fm", isOnDevice: true, quality: 0.8, precision: nil, recall: nil, costUSD: 0, latencyP50: 900, reproducedFabrication: false)]
  let rec = Recommendation(task: "narration", winner: "apple/fm", clearedBar: ["apple/fm"], reason: "incumbent clears")
  let sc = Scorecard(corpusHash: "abc123", tasks: [TaskScorecard(task: "narration", cells: cells, recommendation: rec, judgeAgreement: 0.9)])
  let md = ReportRenderer.markdown(sc)
  #expect(md.contains("abc123"))                 // corpus hash recorded
  #expect(md.contains("apple/fm"))               // model row
  #expect(md.contains("Recommended: apple/fm"))  // recommendation surfaced
  #expect(md.contains("estimate"))               // cost-estimate caveat present
  #expect(md.contains("not like-for-like"))      // latency caveat present
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ReportRendererTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/PensieveKit/Eval/ReportRenderer.swift
import Foundation

public struct Scorecard: Codable, Sendable {
  public var corpusHash: String
  public var tasks: [TaskScorecard]
  public init(corpusHash: String, tasks: [TaskScorecard]) { self.corpusHash = corpusHash; self.tasks = tasks }
}
public struct TaskScorecard: Codable, Sendable {
  public var task: String
  public var cells: [CellScore]
  public var recommendation: Recommendation
  public var judgeAgreement: Double?
  public init(task: String, cells: [CellScore], recommendation: Recommendation, judgeAgreement: Double?) {
    self.task = task; self.cells = cells; self.recommendation = recommendation; self.judgeAgreement = judgeAgreement
  }
}

public enum ReportRenderer {
  public static func markdown(_ s: Scorecard) -> String {
    var out = "# Pensieve LLM Eval Scorecard\n\n"
    out += "Corpus: `\(s.corpusHash)` — recommendation valid for work resembling this corpus; re-sample if your workload shifts.\n\n"
    out += "> Caveats: `$/run` is an **estimate** (chars/4 tokens × config price; judge cost excluded). "
    out += "Latency is **not like-for-like** (on-device is hardware-bound local compute + multiple calls; cloud is a network round-trip).\n\n"
    for t in s.tasks {
      out += "## \(t.task)\n\n"
      if let a = t.judgeAgreement { out += "Judge-vs-human agreement: **\(String(format: "%.0f%%", a * 100))**\n\n" }
      out += "| model | quality | precision | recall | $/run (est) | p50 latency | fab? |\n|---|---|---|---|---|---|---|\n"
      for c in t.cells {
        func f(_ d: Double?) -> String { d.map { String(format: "%.2f", $0) } ?? "—" }
        out += "| \(c.modelLabel)\(c.isOnDevice ? " (local)" : "") | \(f(c.quality)) | \(f(c.precision)) | \(f(c.recall)) | $\(String(format: "%.4f", c.costUSD)) | \(Int(c.latencyP50))ms | \(c.reproducedFabrication ? "⚠︎" : "") |\n"
      }
      out += "\n**Recommended: \(t.recommendation.winner)** — \(t.recommendation.reason)\n\n"
    }
    return out
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter ReportRendererTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PensieveKit/Eval/ReportRenderer.swift Tests/PensieveKitTests/ReportRendererTests.swift
git commit -m "feat(eval): scorecard model + markdown report with caveats"
```

---

## Task 14: Runner + CorpusBuilder + CLI (integration wiring)

This task wires the pure units into the impure runner, corpus builder, and CLI. Its logic pieces (outcome classification) are unit-tested; the DB/transcript/git/HTTP paths are **smoke-verified** against a throwaway store (repo convention: real model calls are not in CI).

**Files:**
- Create: `Sources/PensieveKit/Eval/Runner.swift`, `Sources/PensieveKit/Eval/CorpusBuilder.swift`
- Create: `Sources/pensieve/Commands/Eval.swift`
- Modify: `Sources/pensieve/Pensieve.swift` (register `Eval.self`)
- Test: `Tests/PensieveKitTests/RunnerOutcomeTests.swift`

**Interfaces:**
- Consumes: everything above; `KeychainSecretStore`, `openCanonicalDatabaseReadOnly`, `TranscriptDiscovery`/`ParsedSession` (for extraction items), `ProjectContext.gather`.
- Produces:
  - `struct CellSample: Sendable, Codable { var task:String; var modelLabel:String; var itemID:String; var outputText:String; var looseEndQuotes:[String]?; var latencyMS:Double; var estInputTokens:Int; var estOutputTokens:Int; var outcome:String }`
  - `enum RunOutcome { static func classify(_ error:Error?) -> String }` → `"success" | "parseFail" | "providerError"`
  - `struct Runner { init(config:EvalConfig, keychain:KeychainSecretStore); func runCell(task:any EvalTask, item:CorpusItem, spec:ModelSpec, repeats:Int) async -> [CellSample] }`
  - `enum CorpusBuilder { static func build(db:any DatabaseReader, projectsDir:URL, config:EvalConfig) throws -> ([CorpusItem], CorpusManifest) }`
  - CLI: `pensieve eval sample|run|report|keys set <label>|gold extraction`

- [ ] **Step 1: Write the failing unit test (outcome classification)**

```swift
// Tests/PensieveKitTests/RunnerOutcomeTests.swift
import Testing
@testable import PensieveKit

@Test func classifyMapsErrors() {
  #expect(RunOutcome.classify(nil) == "success")
  #expect(RunOutcome.classify(LLMError.providerFailed("not a parseable index array")) == "parseFail")
  #expect(RunOutcome.classify(LLMError.providerFailed("HTTP 500")) == "providerError")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter RunnerOutcomeTests`
Expected: FAIL — `RunOutcome` undefined.

- [ ] **Step 3: Implement `RunOutcome` + `Runner`**

```swift
// Sources/PensieveKit/Eval/Runner.swift
import Foundation

public enum RunOutcome {
  public static func classify(_ error: Error?) -> String {
    guard let error else { return "success" }
    if case LLMError.providerFailed(let msg) = error,
       msg.localizedCaseInsensitiveContains("parseable") || msg.localizedCaseInsensitiveContains("parse") || msg.localizedCaseInsensitiveContains("json") {
      return "parseFail"
    }
    return "providerError"
  }
}

public struct CellSample: Sendable, Codable {
  public var task: String; public var modelLabel: String; public var itemID: String
  public var outputText: String; public var looseEndQuotes: [String]?
  public var latencyMS: Double; public var estInputTokens: Int; public var estOutputTokens: Int; public var outcome: String
}

public struct Runner {
  private let config: EvalConfig
  private let keychain: KeychainSecretStore
  public init(config: EvalConfig, keychain: KeychainSecretStore = KeychainSecretStore()) {
    self.config = config; self.keychain = keychain
  }

  /// Runs one (task, item, model) cell `repeats` times. Skips (returns []) if the model can't be built (missing key / unavailable).
  public func runCell(task: any EvalTask, item: CorpusItem, spec: ModelSpec, repeats: Int) async -> [CellSample] {
    let apiKey = ModelProviderFactory.needsKey(spec) ? keychain.read(account: ModelProviderFactory.apiKeyAccount(for: spec)) : nil
    guard let model = ModelProviderFactory.make(spec, apiKey: apiKey) else { return [] }
    guard let refSpec = config.spec(label: config.referenceProvider),
          let reference = ModelProviderFactory.make(refSpec, apiKey: nil) else { return [] }

    var samples: [CellSample] = []
    let clock = ContinuousClock()
    for _ in 0..<max(1, repeats) {
      var output = TaskOutput(text: "", looseEnds: nil)
      var err: Error?
      let elapsed = await measure(clock) {
        do { output = try await task.run(item: item, model: model, reference: reference) } catch { err = error }
      }
      samples.append(CellSample(
        task: task.id, modelLabel: spec.label, itemID: item.id,
        outputText: output.text, looseEndQuotes: output.looseEnds?.map { $0.quote },
        latencyMS: elapsed, estInputTokens: 0, estOutputTokens: TokenEstimate.tokens(output.text),
        outcome: RunOutcome.classify(err)))
    }
    return samples
  }

  private func measure(_ clock: ContinuousClock, _ body: () async -> Void) async -> Double {
    let start = clock.now
    await body()
    let d = start.duration(to: clock.now).components            // (seconds, attoseconds)
    return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15   // → ms (seconds included!)
  }
}
```

> The `estInputTokens` is left 0 here because the isolated-stage prompt is internal to the component; the report's cost estimate uses `outputText` + a per-task fixed input estimate captured in `CorpusBuilder` if desired. Keep it simple: cost ranking is locality-dominated. If input-cost fidelity is later needed, thread the built prompt out of each task.

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `./scripts/test.sh --filter RunnerOutcomeTests`
Expected: PASS.

- [ ] **Step 5: Implement `CorpusBuilder` (impure; smoke-verified)**

```swift
// Sources/PensieveKit/Eval/CorpusBuilder.swift
import Foundation
import SQLiteData

public enum CorpusBuilder {
  /// Reads the canonical store (+ transcripts/git) and produces a frozen, stratified corpus for all tasks.
  public static func build(db: any DatabaseReader, projectsDir: URL, config: EvalConfig) throws -> ([CorpusItem], CorpusManifest) {
    // 1. Narration items: active nodes with events (fully DB-derived).
    // 2. Extraction items: parse transcripts via TranscriptDiscovery/ParsedSession; shape = short/long/compacted by message count/size + compaction markers.
    // 3. Description items: for nodes with a sole gitRepo source, ProjectContext.gather(commonDir:) → DTO (pin repo state).
    // Build pools tagged (strata, isStress), call CorpusSampler.select per task, then hash all serialized items.
    // (Full body assembled during implementation against the live schema; see Query layer for node/event/source reads.)
    fatalError("implement against live schema during Task 14")
  }
}
```

Implement the body using the Query layer (node/event/source reads), `TranscriptDiscovery` for transcripts, and `ProjectContext.gather`. Tag stress items: longest transcript, one compacted session (contains a compaction marker), one empty/near-empty node. Serialize each `CorpusItem` to `.eval/corpus/<task>/<id>.json`; compute `CorpusHash.hash` over the serialized items in stable id order; write `CorpusManifest`.

- [ ] **Step 6: Implement the CLI (`Eval.swift`) and register it**

```swift
// Sources/pensieve/Commands/Eval.swift
import ArgumentParser
import Foundation
import PensieveKit

struct Eval: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "eval",
    abstract: "Evaluate LLMs per task and recommend an on-device-first default.",
    subcommands: [Sample.self, Run.self, Report.self, Keys.self, Gold.self])

  struct Sample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sample", abstract: "Freeze/refresh the corpus.")
    @Option(name: .long) var n: Int?
    @Option(name: .long) var seed: UInt64?
    func run() async throws {
      var cfg = try EvalConfig.load(from: EvalPaths.configURL())
      if let n { cfg.corpusSize = n }; if let seed { cfg.corpusSeed = seed }
      let db = try openCanonicalReadOnly()
      let (items, manifest) = try CorpusBuilder.build(db: db, projectsDir: PensievePaths.claudeProjectsURL(), config: cfg)
      // write items + manifest under EvalPaths.corpusDir()
      print("Sampled \(items.count) items; corpus \(manifest.contentHash).")
    }
  }

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Sweep task×model and score.")
    @Option(name: .long) var task: String?
    @Option(name: .long) var model: String?
    func run() async throws {
      // load config + frozen corpus; run reference first (bars), then all models; judge; build Scorecard; write json + md.
      // near-bar cells re-run with repeats=3; median + majorityFabrication applied in Scorecard aggregation.
      print("Run complete → \(EvalPaths.reportURL().path)")
    }
  }

  struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "report", abstract: "Print the latest scorecard.")
    func run() throws { print((try? String(contentsOf: EvalPaths.reportURL(), encoding: .utf8)) ?? "No report yet.") }
  }

  struct Keys: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keys", abstract: "Store an API key for a model label.", subcommands: [Set.self])
    struct Set: ParsableCommand {
      static let configuration = CommandConfiguration(commandName: "set")
      @Argument var label: String
      func run() throws {
        print("Paste API key for \(label): ", terminator: "")
        guard let key = readLine(), !key.isEmpty else { throw ValidationError("no key") }
        KeychainSecretStore().write(key, account: label)
        print("Stored for \(label).")
      }
    }
  }

  struct Gold: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gold", abstract: "Label recall + grounding for judge calibration.")
    @Argument var task: String
    func run() async throws {
      // interactive: for each extraction corpus item, prompt for known loose-end quotes + grounded/fabricated labels; persist GoldSet.
      print("Gold labeling for \(task) → \(EvalPaths.goldURL().path)")
    }
  }
}
```

Register in `Sources/pensieve/Pensieve.swift` by appending `Eval.self` to the root `subcommands:` array.

- [ ] **Step 7: Run the full suite + build the CLI**

Run: `./scripts/test.sh` then `swift build`
Expected: all tests PASS; `pensieve` builds with the `eval` subcommand group.

- [ ] **Step 8: Smoke-verify against a throwaway store**

```bash
export PENSIEVE_DB=$(mktemp -d)/p.sqlite
export PENSIEVE_EVAL_DIR=$(mktemp -d)/.eval
swift run pensieve eval --help
swift run pensieve eval sample --n 5 --seed 1   # exercises CorpusBuilder against an empty store (should no-op gracefully)
```
Expected: help lists `sample/run/report/keys/gold`; `sample` runs without crashing on an empty store (0 items) — fix `CorpusBuilder` empty-pool handling if it traps.

- [ ] **Step 9: Commit**

```bash
git add Sources/PensieveKit/Eval/Runner.swift Sources/PensieveKit/Eval/CorpusBuilder.swift Sources/pensieve/Commands/Eval.swift Sources/pensieve/Pensieve.swift Tests/PensieveKitTests/RunnerOutcomeTests.swift
git commit -m "feat(eval): runner, corpus builder, and pensieve eval CLI"
```

---

## Task 15: Discoverability (README + CLAUDE.md + seam pointer + sample config)

**Files:**
- Create: `Sources/PensieveKit/Eval/README.md`, `eval-config.json`
- Modify: `Sources/PensieveKit/LLM/LLMProvider.swift` (doc-comment), `CLAUDE.md`

- [ ] **Step 1: Write `Sources/PensieveKit/Eval/README.md`**

Include: the one-paragraph purpose; the **stage-isolation** rule; the **incumbent-anchored bar** convention; and a copy-paste "Add a task in 3 steps" recipe with the narration task as the worked example (implement `EvalTask`, add to `TaskRegistry.all`, add a `TaskBar` to `eval-config.json`); note the `registry ↔ config consistency` test that enforces it.

- [ ] **Step 2: Add the seam doc-comment**

Prepend to the `LLMProvider` protocol declaration in `Sources/PensieveKit/LLM/LLMProvider.swift`:
```swift
/// Any new task that calls a model through this seam should be evaluated by the harness —
/// register an `EvalTask` and let `pensieve eval` choose its default (on-device-first),
/// don't hand-pick a model. See `Sources/PensieveKit/Eval/README.md`.
```

- [ ] **Step 3: Add the CLAUDE.md convention line**

Under "Conventions & gotchas" in `CLAUDE.md`, add:
```
- **New LLM-backed tasks must register an `EvalTask`** and get their default model from `pensieve eval` (on-device-first), not a hand-picked constant. See `Sources/PensieveKit/Eval/README.md`. A `registry ↔ config` test fails the suite otherwise.
```

- [ ] **Step 4: Write `eval-config.json`**

A committed starter config with the six-model roster (Apple FM as `referenceProvider`, OpenAI nano/mini, xAI Grok Fast, Gemini Flash-Lite/Flash, Haiku), the Opus/Sonnet judge, three `inheritFromIncumbent: true` bars (extraction/narration/description), `corpusSize: 30`, `corpusSeed: 42`, `noiseMargin: 0.03`. Prices from the spec's roster table (update at runtime as needed). **No API keys.**

- [ ] **Step 5: Verify the consistency guard against the real config**

Add/confirm a test:
```swift
// Tests/PensieveKitTests/EvalConfigConsistencyTests.swift
import Testing
import Foundation
@testable import PensieveKit

@Test func shippedConfigHasBarsForEveryTask() throws {
  let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("eval-config.json")
  let cfg = try EvalConfig.load(from: url)
  #expect(TaskRegistry.consistencyProblems(config: cfg).isEmpty)
}
```

Run: `./scripts/test.sh --filter EvalConfigConsistencyTests`
Expected: PASS (every registered task has a bar; no orphan bars).

- [ ] **Step 6: Commit**

```bash
git add Sources/PensieveKit/Eval/README.md eval-config.json Sources/PensieveKit/LLM/LLMProvider.swift CLAUDE.md Tests/PensieveKitTests/EvalConfigConsistencyTests.swift
git commit -m "docs(eval): README recipe, seam pointer, CLAUDE.md convention, starter config"
```

---

## Final verification

- [ ] Run the full suite: `./scripts/test.sh` — all green.
- [ ] Build the CLI: `swift build` — clean.
- [ ] `swift run pensieve eval --help` lists `sample/run/report/keys/gold`.
- [ ] `git status` clean; `.eval/` is gitignored and untracked.
- [ ] Manual (user, with keys): `pensieve eval keys set openai/gpt-5-nano`, `pensieve eval sample`, `pensieve eval run`, `pensieve eval report` → a scorecard recommending a default per task with judge-vs-human agreement printed.

---

## Notes for the implementer

- **Task 14 is the only integration-heavy task.** Its pure logic (`RunOutcome`) is unit-tested; the `CorpusBuilder` body and the `Run` sweep are assembled against the live schema and smoke-verified, matching the repo rule that real model calls are never in CI.
- **`Event` memberwise init (Task 3):** if `@Table` suppresses it, add an explicit `public init` to `Event` in a tiny separate commit before Task 3.
- **`TaskRegistry.all` ordering (Tasks 6–8):** keep the temporary `[]` in Task 6 to stay green, flip to the three tasks at the end of Task 8.
- **Two-phase run for k=3 (Task 14 `Run`):** first pass `repeats=1` for all cells → compute incumbent-anchored bars → re-run cells whose quality/recall is within `noiseMargin` of a bar with `repeats=3` → `Aggregate.median` for quality, `Aggregate.majorityFabrication` for the precision gate.
- **Judge cost is excluded** from `CellScore.costUSD` — only the candidate model's estimated production cost is ranked.
