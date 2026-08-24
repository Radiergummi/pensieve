import ArgumentParser
import Foundation
import PensieveKit

/// Falls back to a config with an empty roster (a no-op sweep, not a crash) when
/// `eval-config.json` is absent or unreadable; `--n`/`--seed` still steer corpus sampling. Built in
/// code rather than decoded from a JSON literal, so a new `EvalConfig` field fails the build here
/// instead of crashing the command at runtime.
///
/// A DECODE failure is reported, not swallowed. The old `try?` collapsed "no file" and "the JSON is
/// wrong" into the same silent empty roster, so a typo'd bar or a stray comma surfaced as
/// "reference provider not in roster — nothing to run" and sent you debugging the roster you had
/// just written correctly.
private func loadEvalConfig() -> EvalConfig {
  let url = EvalPaths.configURL()
  if FileManager.default.fileExists(atPath: url.path) {
    do {
      return try EvalConfig.load(from: url)
    } catch {
      FileHandle.standardError.write(Data("""
        error: could not read \(url.path): \(error)
        Falling back to an empty roster — fix the file, this is NOT a roster problem.\n
        """.utf8))
    }
  }
  return EvalConfig(
    roster: [],
    referenceProvider: "on-device",
    judge: ModelSpec(label: "judge", kind: ModelSpec.foundationModelsKind,
                     inputPricePerM: 0, outputPricePerM: 0),
    bars: [],
    corpusSize: 20,
    corpusSeed: 0,
    noiseMargin: 0.05)
}

/// `Eval.Keys`'s `set` subcommand. Moved to file scope (was `Eval.Keys.Set`, nested two levels deep)
/// — pure move, same `commandName`/`@Argument`/behavior, just no longer nested inside `Keys`.
private struct KeysSet: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "set")
  @Argument var label: String
  func run() throws {
    print("Paste API key for \(label): ", terminator: "")
    guard let key = readLine(), !key.isEmpty else { throw ValidationError("no key") }
    KeychainSecretStore().write(key, account: label)
    print("Stored for \(label).")
  }
}

struct Eval: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "eval",
    abstract: "Evaluate LLMs per task and recommend an on-device-first default.",
    subcommands: [Sample.self, Run.self, Report.self, Keys.self, Gold.self])

  struct Sample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sample", abstract: "Freeze/refresh the corpus.")
    // The documented flag is `--n`; pin it so the property can carry an explicit name.
    @Option(name: .customLong("n")) var corpusSize: Int?
    @Option(name: .long) var seed: UInt64?
    func run() async throws {
      var config = loadEvalConfig()
      if let corpusSize { config.corpusSize = corpusSize }
      if let seed { config.corpusSeed = seed }

      // Eval is a strictly read-only observer of the canonical store — it never creates one.
      // No store on disk (or unopenable) degrades to an empty, gracefully-written corpus.
      guard let database = try? openCanonicalReadOnly() else {
        let manifest = CorpusManifest(seed: config.corpusSeed, contentHash: CorpusHash.hash([]), counts: [:], stressItems: [])
        try CorpusBuilder.write([], manifest: manifest, to: EvalPaths.corpusDirectory())
        print("Sampled 0 items; corpus \(manifest.contentHash). (no canonical store found)")
        return
      }
      let (items, manifest) = try CorpusBuilder.build(database: database, projectsDir: PensievePaths.claudeProjectsURL(), config: config)
      try CorpusBuilder.write(items, manifest: manifest, to: EvalPaths.corpusDirectory())
      print("Sampled \(items.count) items; corpus \(manifest.contentHash).")
    }
  }

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Sweep task×model and score.")
    @Option(name: .long) var task: String?
    @Option(name: .long) var model: String?
    func run() async throws {
      let config = loadEvalConfig()
      for problem in TaskRegistry.consistencyProblems(config: config) { print("warning: \(problem)") }

      let items = CorpusBuilder.loadFrozen(from: EvalPaths.corpusDirectory())
      guard !items.isEmpty else {
        print("No frozen corpus — run `pensieve eval sample` first.")
        return
      }
      let manifest = (try? Data(contentsOf: EvalPaths.manifestURL()))
        .flatMap { try? JSONDecoder().decode(CorpusManifest.self, from: $0) }

      guard let referenceSpec = config.spec(label: config.referenceProvider) else {
        print("Reference provider '\(config.referenceProvider)' not in roster — nothing to run.")
        return
      }
      let keychain = KeychainSecretStore()
      let judge = Self.makeJudge(config.judge, keychain: keychain)
      let gold = GoldSet.load(from: EvalPaths.goldURL())
      let runner = Runner(config: config, keychain: keychain)

      let context = RunSweepContext(config: config, referenceSpec: referenceSpec, runner: runner,
                                    gold: gold, judge: judge)
      var taskScorecards: [TaskScorecard] = []
      for evalTask in TaskRegistry.all where task == nil || evalTask.id == task {
        let taskItems = items.filter { CellScoring.taskID(for: $0) == evalTask.id }
        guard !taskItems.isEmpty else { continue }
        // Skip only what the missing judge actually blocks. Extraction is scored against the frozen
        // gold set and needs no judge at all, so an absent API key must not end the sweep — this
        // machine has a Claude subscription and no key, and the project rule is that every new
        // LLM-backed task takes its default model from `pensieve eval`.
        if judge == nil, case .rubric = evalTask.scorer {
          print("warning: SKIPPING task '\(evalTask.id)' — it is judge-scored and the judge "
                + "'\(config.judge.label)' is unavailable. Gold-scored tasks still run.")
          continue
        }
        if let scorecard = await Self.scoreTask(evalTask: evalTask, taskItems: taskItems, model: model, context: context) {
          taskScorecards.append(scorecard)
        }
      }

      let scorecard = Scorecard(corpusHash: manifest?.contentHash ?? "", tasks: taskScorecards)
      try EvalPaths.ensureDirectory(EvalPaths.directory())
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(scorecard).write(to: EvalPaths.scorecardURL())
      try ReportRenderer.markdown(scorecard).write(to: EvalPaths.reportURL(), atomically: true, encoding: .utf8)
      print("Run complete → \(EvalPaths.reportURL().path)")
    }

    /// The rubric judge, or nil. Built once but NON-fatally: the judge is a cloud model needing an
    /// API key, while the gold set is a committed file, so their availability is independent and a
    /// missing key must cost only the judge-scored tasks.
    static func makeJudge(_ spec: ModelSpec, keychain: KeychainSecretStore) -> Judge? {
      let apiKey = ModelProviderFactory.needsKey(spec)
        ? keychain.read(account: ModelProviderFactory.apiKeyAccount(for: spec)) : nil
      guard let provider = ModelProviderFactory.make(spec, apiKey: apiKey) else {
        print("warning: judge '\(spec.label)' unavailable (missing key or provider). "
              + "Store one with `pensieve eval keys set \(spec.label)`, or name a "
              + "'\(ModelSpec.claudeCLIKind)' judge to use the Claude subscription.")
        return nil
      }
      return Judge(provider: provider)
    }

    /// One task's slice of the sweep: score every roster spec (reference first) against `taskItems`
    /// and turn the results into a recommendation. Pure code movement out of `run()` to keep its
    /// cyclomatic complexity down — same statements, same order, same behavior. The per-sweep
    /// services (config, reference spec, runner, gold set, judge) are constant across every task in
    /// the loop, so they're bundled into `context` to keep this under the parameter-count limit.
    /// Every quote any model surfaced this run, folded into `.eval/surfaced.json`.
    ///
    /// A fabrication only exists once a model has produced one, so this is the only place the gold
    /// set's fabricated half can come from — see `SurfacedQuotes`. Best-effort by contract: failing
    /// to record labelling candidates must not turn a completed sweep into a failed one.
    private static func recordSurfaced(_ samples: [CellSample]) {
        guard !samples.isEmpty else { return }
        var surfaced = SurfacedQuotes.load(from: EvalPaths.surfacedURL())
        for sample in samples {
            guard let quotes = sample.looseEndQuotes, !quotes.isEmpty else { continue }
            surfaced.merge(itemID: sample.itemID, quotes: quotes)
        }
        do { try surfaced.save(to: EvalPaths.surfacedURL()) } catch {
            print("warning: could not record surfaced quotes for gold labelling: \(error)")
        }
    }

    private static func scoreTask(evalTask: any EvalTask, taskItems: [CorpusItem],
                                  model: String?, context: RunSweepContext) async -> TaskScorecard? {
      let (config, referenceSpec, runner) = (context.config, context.referenceSpec, context.runner)
      // Reference first (it doubles as the incumbent bar's basis), then the rest of the roster.
      let specs = ([referenceSpec] + config.roster.filter { $0.label != referenceSpec.label })
        .filter { model == nil || $0.label == model || $0.label == referenceSpec.label }

      var incumbent: CellScore?
      var scores: [CellScore] = []
      for spec in specs {
        var samples: [CellSample] = []
        for item in taskItems { samples += await runner.runCell(task: evalTask, item: item, spec: spec, repeats: 1) }
        guard !samples.isEmpty else { continue }   // model unavailable for this spec — skip, don't fake a score
        recordSurfaced(samples)
        let cellScore = await CellScoring.score(
          task: evalTask, items: taskItems, samples: samples, spec: spec,
          references: ScoringReferences(gold: context.gold, judge: context.judge))
        if spec.label == referenceSpec.label { incumbent = cellScore }
        scores.append(cellScore)
      }
      guard !scores.isEmpty else { return nil }
      let bar = DecisionEngine.effectiveBar(task: evalTask.id, config: config, incumbent: incumbent)
      let recommendation = DecisionEngine.recommend(task: evalTask, scores: scores, bar: bar,
                                                    incumbentLabel: referenceSpec.label,
                                                    noiseMargin: config.noiseMargin)
      // Reported ONLY on the gold-scored task the labels came from. Grounding agreement is measured
      // on extraction quotes; stamping it on narration's card would read as "the judge that graded
      // this scorecard was validated", which it would not be — that judge grades a rubric, and no
      // human has rated those outputs. `nil` here is an honest "not measured", not a missing value.
      let agreement: Double?
      if case .extraction = evalTask.scorer { agreement = context.gold.judgeAgreement() } else { agreement = nil }
      return TaskScorecard(task: evalTask.id, cells: scores, recommendation: recommendation,
                           judgeAgreement: agreement)
    }
  }

  /// Bundles the sweep-wide services `Run.run()` builds once (config, reference spec, runner, gold
  /// set, judge) so `scoreTask` can take them as a single parameter and stay under the
  /// function-parameter-count limit. File-private to `Eval`; not part of any wire contract.
  private struct RunSweepContext {
    let config: EvalConfig
    let referenceSpec: ModelSpec
    let runner: Runner
    let gold: GoldSet
    /// nil when the judge model is unavailable. `run()` skips judge-scored tasks in that case, so
    /// reaching `CellScoring` with a nil judge means only that a gold-scored task does not need one.
    let judge: Judge?
  }

  struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "report", abstract: "Print the latest scorecard.")
    func run() throws { print((try? String(contentsOf: EvalPaths.reportURL(), encoding: .utf8)) ?? "No report yet.") }
  }

  struct Keys: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keys", abstract: "Store an API key for a model label.",
                                                     subcommands: [KeysSet.self])
  }

  struct Gold: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gold", abstract: "Label recall + grounding for judge calibration.")
    @Argument var task: String
    /// One item: the human's recall quotes, then a grounded/fabricated verdict on every quote that
    /// needs one — the human's typed quotes plus whatever models surfaced here and nobody has
    /// judged yet.
    private func label(item: ExtractionCorpusItem, gold: inout GoldSet,
                       surfaced: SurfacedQuotes, judge: Judge?) async {
      print("\n--- item \(item.id) (\(item.shape)) ---")
      for message in item.messages where message.isUserPrompt {
        print("[\(message.index)] \(message.text.prefix(200))")
      }
      print("Known loose-end quotes for this item, one per line, blank line to finish:")
      var quotes: [String] = []
      while let line = readLine(), !line.isEmpty { quotes.append(line) }
      gold.recall[item.id] = quotes

      // Anything a model surfaced for this item that carries no human label yet. THIS is where a
      // fabricated quote enters the gold set: nobody can type one in advance, because it does not
      // exist until a model invents it. Without these, `grounding` holds only quotes the human
      // already believed in, so `precision` is always 1 and `reproducedFabrication` never fires.
      let candidates = surfaced.unlabelled(itemID: item.id, gold: gold).filter { !quotes.contains($0) }
      if !candidates.isEmpty {
        print("\(candidates.count) quote(s) surfaced by models here and not yet labelled.")
      }
      let toLabel = quotes + candidates
      guard !toLabel.isEmpty else { return }

      // The judge answers first, on the same quotes, against the same source the models saw. Shown
      // as the default so the human is CORRECTING rather than deciding from scratch — and every
      // correction is one datapoint of agreement, earned from work that had to happen anyway.
      let source = item.messages.map { "[\($0.index)] \($0.text)" }.joined(separator: "\n")
      var judgeLabels: [CandidateLabel] = []
      if let judge {
        judgeLabels = await judge.labelGrounding(quotes: toLabel, source: source) ?? []
        if judgeLabels.isEmpty { print("note: the judge did not answer for this item.") }
      }
      let judgeByQuote = Dictionary(judgeLabels.map { ($0.quote, $0.grounded) },
                                    uniquingKeysWith: { existing, _ in existing })

      var labels: [CandidateLabel] = []
      for quote in toLabel {
        let suggestion = judgeByQuote[quote]
        let hint = suggestion.map { $0 ? " [judge: grounded]" : " [judge: FABRICATED]" } ?? ""
        let fallback = suggestion ?? true
        print("Is «\(quote)» genuinely grounded?\(hint) [y/n, Enter = \(fallback ? "y" : "n")]: ",
              terminator: "")
        let answer = readLine()?.lowercased() ?? ""
        labels.append(CandidateLabel(quote: quote,
                                     grounded: answer.isEmpty ? fallback : answer != "n"))
      }
      gold.grounding[item.id] = labels
      // Only the judge labels a human actually adjudicated. An unanswered quote would otherwise
      // count toward agreement without anyone having checked it.
      if !judgeLabels.isEmpty {
        let answered = Set(labels.map(\.quote))
        gold.judgeGrounding[item.id] = judgeLabels.filter { answered.contains($0.quote) }
      }
    }

    func run() async throws {
      // Compared against the enum case, not the bare literal `"extraction"`. It is only a
      // user-supplied argument check rather than a trust gate, so nothing breaks today — but it is
      // the same string that `Scorecard`'s fabrication gate used to key off (finding 1.17), and a
      // renamed task id would leave this silently refusing the task it is meant to accept.
      guard task == CorpusBuilder.Task.extraction.rawValue else {
        print("Gold labeling is only implemented for the '\(CorpusBuilder.Task.extraction.rawValue)' task.")
        return
      }
      let extractionItems: [ExtractionCorpusItem] = CorpusBuilder.loadFrozen(from: EvalPaths.corpusDirectory()).compactMap {
        if case .extraction(let extractionItem) = $0 { return extractionItem }; return nil
      }
      guard !extractionItems.isEmpty else {
        print("No frozen extraction items — run `pensieve eval sample` first.")
        return
      }
      var gold = GoldSet.load(from: EvalPaths.goldURL())
      let surfaced = SurfacedQuotes.load(from: EvalPaths.surfacedURL())
      // The same judge the sweep would use, built the same way — so the agreement measured here is
      // agreement for the judge that actually scores, not for some other model.
      let judge = Run.makeJudge(loadEvalConfig().judge, keychain: KeychainSecretStore())
      if judge == nil {
        print("note: labelling by hand — no agreement will be measured without a judge.")
      }

      for item in extractionItems {
        await label(item: item, gold: &gold, surfaced: surfaced, judge: judge)
      }
      try gold.save(to: EvalPaths.goldURL())
      print("Gold labeling for \(task) → \(EvalPaths.goldURL().path)")
      if let agreement = gold.judgeAgreement() {
        print(String(format: "Judge-vs-human agreement: %.0f%% (across every labelled quote so far)",
                     agreement * 100))
      }
    }
  }
}
