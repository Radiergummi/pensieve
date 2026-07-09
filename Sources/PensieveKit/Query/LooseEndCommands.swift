import Foundation
import SQLiteData
import GRDB

/// The `LooseEnd.label` / `.labelSuggestion` string values. Centralized like `NodeContext` /
/// `CaptureKind` so a typo can't silently misfile a label. `""` = unlabeled (the default).
public enum LooseEndLabel {
  public static let unlabeled = ""
  public static let salient = "salient"
  public static let noise = "noise"
}
