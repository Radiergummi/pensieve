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
  public static var all: [any EvalTask] { [ExtractionTask(), NarrationTask(), DescriptionTask()] }
  public static func task(id: String) -> (any EvalTask)? { all.first { $0.id == id } }

  /// Registry ↔ config ↔ corpus consistency: every task needs a bar AND a corpus of its own; every
  /// bar and every corpus folder needs a task.
  ///
  /// The corpus half is not a theoretical symmetry. `CorpusBuilder` pools, writes and reloads items
  /// under a fixed set of task folders, and `CellScoring.taskID(for:)` maps an item back to a task
  /// id. Register a task whose id is in neither and `pensieve eval run` filters the frozen corpus
  /// down to ZERO items for it, `scoreTask` returns nil, and the sweep reports nothing at all for
  /// that task — which reads exactly like "it had no findings" rather than "it never ran".
  public static func consistency(tasks: [any EvalTask], config: EvalConfig) -> [String] {
    var problems: [String] = []
    let taskIDs = Set(tasks.map { $0.id })
    let barTasks = Set(config.bars.map { $0.task })
    let corpusTasks = Set(CorpusBuilder.taskFolders)
    for taskID in taskIDs where !barTasks.contains(taskID) { problems.append("task '\(taskID)' has no bar in eval-config.json") }
    for barTask in barTasks where !taskIDs.contains(barTask) { problems.append("bar '\(barTask)' has no registered task") }
    for taskID in taskIDs where !corpusTasks.contains(taskID) {
      problems.append("task '\(taskID)' has no corpus pool in CorpusBuilder — it would score on zero items")
    }
    for corpusTask in corpusTasks where !taskIDs.contains(corpusTask) {
      problems.append("corpus pool '\(corpusTask)' has no registered task")
    }
    return problems
  }
  public static func consistencyProblems(config: EvalConfig) -> [String] { consistency(tasks: all, config: config) }
}
