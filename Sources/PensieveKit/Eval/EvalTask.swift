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

  /// Registry ↔ config consistency: every task needs a bar; every bar needs a task.
  public static func consistency(tasks: [any EvalTask], config: EvalConfig) -> [String] {
    var problems: [String] = []
    let taskIDs = Set(tasks.map { $0.id })
    let barTasks = Set(config.bars.map { $0.task })
    for taskID in taskIDs where !barTasks.contains(taskID) { problems.append("task '\(taskID)' has no bar in eval-config.json") }
    for barTask in barTasks where !taskIDs.contains(barTask) { problems.append("bar '\(barTask)' has no registered task") }
    return problems
  }
  public static func consistencyProblems(config: EvalConfig) -> [String] { consistency(tasks: all, config: config) }
}
