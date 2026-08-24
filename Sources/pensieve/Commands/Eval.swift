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
    private static func makeJudge(_ spec: ModelSpec, keychain: KeychainSecretStore) -> Judge? {
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
      return TaskScorecard(task: evalTask.id, cells: scores, recommendation: recommendation, judgeAgreement: nil)
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
    func run() async throws {
      guard task == "extraction" else {
        print("Gold labeling is only implemented for the 'extraction' task.")
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
