import ArgumentParser
import Foundation
import PensieveKit

/// The committed `eval-config.json` (roster/bars/judge/pricing) lands in a later task. Until then
/// — and defensively even after, if the file is briefly absent/corrupt — fall back to a config
/// with an empty roster (a no-op sweep, not a crash); `--n`/`--seed` still steer corpus sampling.
/// Built in code rather than decoded from a JSON literal, so a new `EvalConfig` field fails the
/// build here instead of crashing the command at runtime.
private func loadEvalConfig() -> EvalConfig {
  if let cfg = try? EvalConfig.load(from: EvalPaths.configURL()) { return cfg }
  return EvalConfig(
    roster: [],
    referenceProvider: "on-device",
    judge: ModelSpec(label: "judge", kind: "foundationModels", inputPricePerM: 0, outputPricePerM: 0),
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
      var cfg = loadEvalConfig()
      if let corpusSize { cfg.corpusSize = corpusSize }
      if let seed { cfg.corpusSeed = seed }

      // Eval is a strictly read-only observer of the canonical store — it never creates one.
      // No store on disk (or unopenable) degrades to an empty, gracefully-written corpus.
      guard let database = try? openCanonicalReadOnly() else {
        let manifest = CorpusManifest(seed: cfg.corpusSeed, contentHash: CorpusHash.hash([]), counts: [:], stressItems: [])
        try CorpusBuilder.write([], manifest: manifest, to: EvalPaths.corpusDir())
        print("Sampled 0 items; corpus \(manifest.contentHash). (no canonical store found)")
        return
      }
      let (items, manifest) = try CorpusBuilder.build(database: database, projectsDir: PensievePaths.claudeProjectsURL(), config: cfg)
      try CorpusBuilder.write(items, manifest: manifest, to: EvalPaths.corpusDir())
      print("Sampled \(items.count) items; corpus \(manifest.contentHash).")
    }
  }

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Sweep task×model and score.")
    @Option(name: .long) var task: String?
    @Option(name: .long) var model: String?
    func run() async throws {
      let cfg = loadEvalConfig()
      for problem in TaskRegistry.consistencyProblems(config: cfg) { print("warning: \(problem)") }

      let items = CorpusBuilder.loadFrozen(from: EvalPaths.corpusDir())
      guard !items.isEmpty else {
        print("No frozen corpus — run `pensieve eval sample` first.")
        return
      }
      let manifest = (try? Data(contentsOf: EvalPaths.manifestURL()))
        .flatMap { try? JSONDecoder().decode(CorpusManifest.self, from: $0) }

      guard let refSpec = cfg.spec(label: cfg.referenceProvider) else {
        print("Reference provider '\(cfg.referenceProvider)' not in roster — nothing to run.")
        return
      }
      let keychain = KeychainSecretStore()
      let judgeKey = ModelProviderFactory.needsKey(cfg.judge)
        ? keychain.read(account: ModelProviderFactory.apiKeyAccount(for: cfg.judge)) : nil
      guard let judgeProvider = ModelProviderFactory.make(cfg.judge, apiKey: judgeKey) else {
        print("Judge model unavailable (missing key or provider) — nothing to run.")
        return
      }
      let judge = Judge(provider: judgeProvider)
      let gold = GoldSet.load(from: EvalPaths.goldURL())
      let runner = Runner(config: cfg, keychain: keychain)

      let context = RunSweepContext(cfg: cfg, refSpec: refSpec, runner: runner, gold: gold, judge: judge)
      var taskScorecards: [TaskScorecard] = []
      for evalTask in TaskRegistry.all where task == nil || evalTask.id == task {
        let taskItems = items.filter { CellScoring.taskID(for: $0) == evalTask.id }
        guard !taskItems.isEmpty else { continue }
        if let scorecard = await Self.scoreTask(evalTask: evalTask, taskItems: taskItems, model: model, context: context) {
          taskScorecards.append(scorecard)
        }
      }

      let scorecard = Scorecard(corpusHash: manifest?.contentHash ?? "", tasks: taskScorecards)
      try EvalPaths.ensureDir(EvalPaths.dir())
      let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
      try enc.encode(scorecard).write(to: EvalPaths.scorecardURL())
      try ReportRenderer.markdown(scorecard).write(to: EvalPaths.reportURL(), atomically: true, encoding: .utf8)
      print("Run complete → \(EvalPaths.reportURL().path)")
    }

    /// One task's slice of the sweep: score every roster spec (reference first) against `taskItems`
    /// and turn the results into a recommendation. Pure code movement out of `run()` to keep its
    /// cyclomatic complexity down — same statements, same order, same behavior. The per-sweep
    /// services (`cfg`/`refSpec`/`runner`/`gold`/`judge`) are constant across every task in the loop,
    /// so they're bundled into `context` to keep this under the parameter-count limit.
    private static func scoreTask(evalTask: any EvalTask, taskItems: [CorpusItem],
                                  model: String?, context: RunSweepContext) async -> TaskScorecard? {
      let (cfg, refSpec, runner, gold, judge) = (context.cfg, context.refSpec, context.runner, context.gold, context.judge)
      // Reference first (it doubles as the incumbent bar's basis), then the rest of the roster.
      let specs = ([refSpec] + cfg.roster.filter { $0.label != refSpec.label })
        .filter { model == nil || $0.label == model || $0.label == refSpec.label }

      var incumbent: CellScore?
      var scores: [CellScore] = []
      for spec in specs {
        var samples: [CellSample] = []
        for item in taskItems { samples += await runner.runCell(task: evalTask, item: item, spec: spec, repeats: 1) }
        guard !samples.isEmpty else { continue }   // model unavailable for this spec — skip, don't fake a score
        let cellScore = await CellScoring.score(task: evalTask, items: taskItems, samples: samples,
                                               spec: spec, references: ScoringReferences(gold: gold, judge: judge))
        if spec.label == refSpec.label { incumbent = cellScore }
        scores.append(cellScore)
      }
      guard !scores.isEmpty else { return nil }
      let bar = DecisionEngine.effectiveBar(task: evalTask.id, config: cfg, incumbent: incumbent)
      let recommendation = DecisionEngine.recommend(task: evalTask.id, scores: scores, bar: bar,
                                                    incumbentLabel: refSpec.label, noiseMargin: cfg.noiseMargin)
      return TaskScorecard(task: evalTask.id, cells: scores, recommendation: recommendation, judgeAgreement: nil)
    }
  }

  /// Bundles the sweep-wide services `Run.run()` builds once (config, reference spec, runner, gold
  /// set, judge) so `scoreTask` can take them as a single parameter and stay under the
  /// function-parameter-count limit. File-private to `Eval`; not part of any wire contract.
  private struct RunSweepContext {
    let cfg: EvalConfig
    let refSpec: ModelSpec
    let runner: Runner
    let gold: GoldSet
    let judge: Judge
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
    func run() async throws {
      guard task == "extraction" else {
        print("Gold labeling is only implemented for the 'extraction' task.")
        return
      }
      let extractionItems: [ExtractionCorpusItem] = CorpusBuilder.loadFrozen(from: EvalPaths.corpusDir()).compactMap {
        if case .extraction(let extractionItem) = $0 { return extractionItem }; return nil
      }
      guard !extractionItems.isEmpty else {
        print("No frozen extraction items — run `pensieve eval sample` first.")
        return
      }
      var gold = GoldSet.load(from: EvalPaths.goldURL())
      for item in extractionItems {
        print("\n--- item \(item.id) (\(item.shape)) ---")
        for message in item.messages where message.isUserPrompt {
          print("[\(message.index)] \(message.text.prefix(200))")
        }
        print("Known loose-end quotes for this item, one per line, blank line to finish:")
        var quotes: [String] = []
        while let line = readLine(), !line.isEmpty { quotes.append(line) }
        gold.recall[item.id] = quotes

        var labels: [CandidateLabel] = []
        for quote in quotes {
          print("Is «\(quote)» genuinely grounded? [y/n]: ", terminator: "")
          let answer = readLine()?.lowercased() ?? "y"
          labels.append(CandidateLabel(quote: quote, grounded: answer != "n"))
        }
        gold.grounding[item.id] = labels
      }
      try gold.save(to: EvalPaths.goldURL())
      print("Gold labeling for \(task) → \(EvalPaths.goldURL().path)")
    }
  }
}
