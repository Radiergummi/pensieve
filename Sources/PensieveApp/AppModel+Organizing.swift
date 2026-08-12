// Sources/PensieveApp/AppModel+Organizing.swift
import Foundation
import PensieveKit

extension AppModel {
  /// A refusal: the view was stale, so REFRESH (that's the remedy — the phantom node disappears and
  /// the "try again" copy becomes true), then surface the alert. Post-write state changes are skipped.
  /// NOT private: AppModel+Recall.swift's loose-end label write also calls it.
  func refuse(_ verb: String, _ name: String) {
    refresh()
    presentedError = .refusal(verb, name)
  }

  /// A throw: a real DB error. Do NOT refresh — an error tells us nothing about staleness.
  /// NOT private: AppModel+Recall.swift's loose-end label write also calls it.
  func fail(_ verb: String, _ name: String, _ error: Error) {
    presentedError = .failure(verb, name, error)
  }

  /// The display name for a node id, falling back to a neutral word when it's already gone.
  func displayName(_ id: UUID) -> String {
    node(id)?.name ?? String(localized: "this item")
  }

  /// Default kind for a new node: a child of a project/domain is a strand; everything else a project.
  func defaultKind(under parentID: UUID?) -> NodeKind {
    guard let parentID, let parent = node(parentID) else { return .project }
    return (parent.kind == .project || parent.kind == .domain) ? .strand : .project
  }

  /// Open the New Node modal (replaces the old immediate-insert + inline-rename flow → fixes #3).
  func presentNewNode(under parentID: UUID?) { editingNode = NodeEditRequest(mode: .new(parent: parentID)) }
  /// Open the Edit modal for an existing node.
  func presentEditNode(_ node: Node) { editingNode = NodeEditRequest(mode: .edit(node)) }

  /// Whether `nodeID` may be deleted (no live source or auto-birthed strand in its subtree → won't resurrect on sync).
  func canDelete(_ nodeID: UUID) -> Bool {
    guard let database else { return false }
    return (try? NodeCommands.subtreeIsActivityBorn(database, nodeID: nodeID)) == false
  }

  func move(_ nodeID: UUID, under newParentID: UUID?) {
    guard let database else { return }
    let label = displayName(nodeID)
    do {
      // false ⇒ cycle guard, unknown node, or unknown parent — all stale-state rejections.
      let succeeded = try NodeCommands.reparent(database, nodeID: nodeID, newParentID: newParentID)
      if succeeded { refresh() } else { refuse(String(localized: "move"), label) }
    } catch {
      fail(String(localized: "move"), label, error)
    }
  }

  func archive(_ nodeID: UUID) {
    guard let database else { return }
    let label = displayName(nodeID)
    // Captured BEFORE the write: after it, the subtree has left the active tree.
    let subtree = NodeForest.descendantIDs(of: nodeID, in: allNodes).union([nodeID])
    do {
      // false ⇒ the node vanished between menu-open and click — a stale-state rejection.
      let succeeded = try NodeCommands.archive(database, nodeID: nodeID)
      guard succeeded else { refuse(String(localized: "archive"), label); return }
      // Selection moves off the whole archived subtree so we don't strand the detail pane on a
      // node that just left the active tree.
      if let sel = selectedNodeID, subtree.contains(sel) { selectedNodeID = nil }
      if case .node(let id) = sidebarSelection, subtree.contains(id) { sidebarSelection = .briefing }
      refresh()
    } catch {
      fail(String(localized: "archive"), label, error)
    }
  }

  func unarchive(_ nodeID: UUID) {
    guard let database else { return }
    let label = displayName(nodeID)
    do {
      let succeeded = try NodeCommands.unarchive(database, nodeID: nodeID)
      if succeeded { refresh() } else { refuse(String(localized: "unarchive"), label) }
    } catch {
      fail(String(localized: "unarchive"), label, error)
    }
  }

  /// Merge `sourceID` into `targetID`. `ProjectResolver.group` returns Void and never validates that
  /// the TARGET still exists: a concurrently-deleted target aborts the whole transaction on an FK
  /// violation (no data loss — but "FOREIGN KEY constraint failed" is not copy we show a human). So
  /// pre-check both nodes and emit the normal refusal instead. `group` itself stays untouched.
  func merge(_ sourceID: UUID, into targetID: UUID) {
    guard let database, sourceID != targetID else { return }
    let label = displayName(sourceID)

    let bothExist = (try? database.read { database in
      try Node.where { $0.id.eq(sourceID) }.fetchOne(database) != nil
        && Node.where { $0.id.eq(targetID) }.fetchOne(database) != nil
    }) ?? false
    guard bothExist else { refuse(String(localized: "merge"), label); return }

    do {
      try ProjectResolver(database: database).group(targetID, into: [sourceID])
      // The source node is gone: move any state that referenced it onto the survivor.
      if selectedNodeID == sourceID { selectedNodeID = targetID }
      if sidebarSelection == .node(sourceID) { sidebarSelection = .node(targetID) }
      refresh()
    } catch {
      fail(String(localized: "merge"), label, error)
    }
  }

  /// Legal Move/Merge targets for `nodeID`: every node except itself, its descendants, and any
  /// archived node (an active node moved/merged under an archived parent would immediately become
  /// a phantom top-level root — see Finding 3 of the archive-nodes whole-branch review).
  func moveTargets(for nodeID: UUID) -> [Node] {
    let banned = NodeForest.descendantIDs(of: nodeID, in: allNodes).union([nodeID])
    return allNodes.filter { !banned.contains($0.id) && $0.state != .archived }.sorted { $0.name < $1.name }
  }

  /// Delete a (source-free) node and its subtree via the Kit cascade. Moves selection off it.
  func deleteNode(_ nodeID: UUID) {
    guard let database else { return }
    let label = displayName(nodeID)
    do {
      switch try NodeCommands.delete(database, nodeID: nodeID) {
      case .deleted:
        if selectedNodeID == nodeID { selectedNodeID = nil }
        if sidebarSelection == .node(nodeID) { sidebarSelection = .briefing }
        refresh()
      case .blocked:
        // The subtree is activity-born — it would resurrect on the next sync. `canDelete` already
        // gates the menu, so this only fires on a stale menu; the copy names the real reason.
        refresh()
        presentedError = AppError(
          title: String(localized: "Can’t delete “\(label)”"),
          message: String(localized: "It still has captured sources or activity that would return on the next sync."))
      case .notFound:
        refuse(String(localized: "delete"), label)
      }
    } catch {
      fail(String(localized: "delete"), label, error)
    }
  }

  /// Destructive-confirmation copy for the currently-pending delete. Names the node; warns about
  /// nested items when the subtree isn’t a leaf. (Exact event counts would need a Kit read; the
  /// subtree shape from the in-memory forest is enough for an honest warning.)
  func deleteConfirmationText() -> String {
    guard let id = pendingDeleteNodeID, let node = node(id) else { return "" }
    let hasChildren = allNodes.contains { $0.parentID == id }
    if hasChildren {
      return String(localized: """
        Delete “\(node.name)” and everything nested under it? Captured activity and loose ends \
        are removed. This can’t be undone.
        """)
    }
    return String(localized: "Delete “\(node.name)”? Its captured activity and loose ends are removed. This can’t be undone.")
  }

  /// Commit the New Node modal: insert fully-formed, select it.
  func commitNewNode(parent parentID: UUID?, fields: NodeFields) {
    guard let database else { return }
    let trimmed = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      // nil ⇒ the parent id didn't resolve (deleted under the menu). Name the PARENT: the new node
      // doesn't exist yet, so its own name would be meaningless in the copy.
      guard let new = try NodeCommands.add(database, name: trimmed, kind: fields.kind,
                                           parent: parentID?.uuidString, description: "",
                                           icon: fields.icon, colorTag: fields.colorTag, context: fields.context) else {
        let parentName = parentID.map { displayName($0) } ?? String(localized: "the top level")
        refresh()
        presentedError = .cannotAddUnder(parentName)
        return
      }
      refresh()
      sidebarSelection = .node(new.id); selectedNodeID = new.id
    } catch {
      fail(String(localized: "create"), trimmed, error)
    }
  }

  /// Commit the Edit modal: atomic name/kind/icon/colorTag update.
  func updateNode(_ nodeID: UUID, fields: NodeFields) {
    guard let database else { return }
    let trimmed = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let label = displayName(nodeID)
    do {
      var trimmedFields = fields
      trimmedFields.name = trimmed
      let succeeded = try NodeCommands.update(database, nodeID: nodeID, fields: trimmedFields)
      if succeeded { refresh() } else { refuse(String(localized: "rename"), label) }
    } catch {
      fail(String(localized: "rename"), label, error)
    }
  }
}
