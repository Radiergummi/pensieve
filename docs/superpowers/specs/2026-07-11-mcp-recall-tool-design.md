# MCP `recall` tool — expose transcript context over MCP

**Date:** 2026-07-11
**Status:** Approved design (brainstorm complete)
**Depends on:** the MCP context server (`pensieve mcp`, `docs/superpowers/specs/2026-07-08-mcp-context-server-design.md`) and the `ProvenanceQueries` kernel (three-pane slice 3b).

## Motivation

The first real-world dogfooding win of the Pensieve MCP server also exposed its ceiling.
A Claude Code session was asked to *"recall a conversation about reintroducing rector and
what it resolved to."* The MCP surface (`prime` + `project_context`) **found** the topic
immediately — a cited loose end *"nailed it."* But to actually **reconstruct the discussion
and its outcome**, the model then made ~5 shell calls: locate the `.jsonl` transcript on
disk, grep it, read the surrounding window.

The gap is precise: the MCP server hands back **pointers, not passages**. A loose end is
returned as `text` + a one-sentence `quote` + `role` + `ageDays` — enough to *recognize* the
topic, not enough to *recall* the conversation. And Pensieve **already computes the passage**:
`ProvenanceQueries.context(...)` resolves a loose end → its source `cc.session` event → the
surrounding transcript window (cited message flagged, honest degradation when the transcript
is gone). The app's ⌘⌥I inspector uses it. **It is simply not exposed over MCP**, so the model
reinvented — badly, via shell — a retrieval that already exists and is tested.

## Scope

**In scope (this pass): expose recall.** A read-only MCP tool that returns a loose end's
surrounding transcript window, replacing the shell round-trip. No LLM, verbatim only, inside
the trust gate.

**Explicitly deferred (→ backlog, with reasoning):**

- **Keyword search tool** — jump straight to the relevant loose end/event across projects
  instead of scanning all of a node's loose ends (104 in the incident). Deferred because it is
  a *find* problem, orthogonal to *expand*, and needs its own ranking/query design. **Note:** a
  tested `SearchQueries` Kit kernel already exists (in-app find, 2026-07-11) over the grounded
  corpus — the natural substrate when this is built.
- **Semantic / vector recall** (`sqlite-vec` + on-device embeddings) — recall without exact
  words. Deferred because it is a large project (embedding pipeline, migration, index
  maintenance) already tracked as a standing loose end.
- **`whats_next` → recall handle** — `whats_next` returns a quote string, not an id; recall
  handles come only from `project_context`. Deferred to keep this pass minimal (one extra hop:
  `project_context` on the node to obtain handles).
- **Event-centric recall** — `ProvenanceQueries` is loose-end-centric (it needs a
  `sourceMessageIndex` to center on); `cc.session` events have no single center message.

## Design

### Approach (chosen)

A **loose-end-keyed `recall` tool**, plus exposing loose-end **ids** on `project_context` so
the model has a handle to pass. The new flow is:

```
project_context  →  loose ends now carry `id`  →  recall(loose_end_id)  →  transcript window
```

Zero shell calls.

Rejected alternatives:
- **Fold transcript windows eagerly into `project_context`.** N loose ends × windows = large
  payloads, almost all unused (104 loose ends in the incident). Breaks the pointer/expand
  separation.
- **A `pensieve://looseend/{id}` resource.** Recall is a mid-reasoning *agent action*, not a
  user-attachable context blob → a tool is the right surface. (A resource could be added later
  if a user-attach use case appears; YAGNI now.)

### Kit — new payload + kernel method (tested)

In `Sources/PensieveKit/Query/SessionContextQueries.swift`, alongside the existing
`Bundle*`/`WhatsNextItem` JSON-shaped payloads:

```swift
public struct RecallMessage: Codable, Sendable {
  public let index: Int
  public let role: String
  public let text: String
  public let isCited: Bool
  public let isUserPrompt: Bool
}

public struct RecallBundle: Codable, Sendable {
  public let looseEndText: String
  public let quote: String
  public let transcriptAvailable: Bool
  public let sessionOccurredAt: Date       // the source cc.session event's occurredAt
  public let messages: [RecallMessage]     // empty when transcriptAvailable == false
}
```

```swift
/// Recall the surrounding transcript conversation around a loose end. Fetches the LooseEnd by
/// UUID, delegates to the tested `ProvenanceQueries.context(radius:)`, and shapes the JSON.
/// Returns nil if the id resolves to no loose end; returns a bundle with
/// transcriptAvailable == false (+ the stored quote) if the transcript is gone. No LLM,
/// verbatim only — inside the trust gate.
public static func recall(looseEndID: UUID, radius: Int,
                          _ db: any DatabaseReader) throws -> RecallBundle?
```

The kernel:
1. Fetches the `LooseEnd` by id (`LooseEnd.where { $0.id.eq(looseEndID) }.fetchOne`); `nil` if absent.
2. Calls `ProvenanceQueries.context(db, looseEnd:, radius:)` — **unchanged**; it already takes a
   `radius` and already handles the missing/stale/gone-transcript cases with its two-part guard.
3. Maps `ProvenanceContext.messages` → `[RecallMessage]` and reads `sourceEvent.occurredAt` and
   `transcriptAvailable` into the bundle.

No change to `ProvenanceQueries` — the radius flows straight through.

### Bundle contract change (additive)

Add `public let id: UUID` to `BundleLooseEnd` and populate it in
`SessionContextQueries.bundle(...)` from `$0.looseEnd.id`. This is additive to the
`project_context` JSON output — existing consumers keep working; the model now sees a handle.

### MCP surface (thin)

In `Sources/pensieve/Commands/Mcp.swift`, register a third tool in `ListTools`:

```
recall  (readOnlyHint: true, openWorldHint: false)
  loose_end_id : string (required, UUID)   — from project_context loose ends
  radius       : number (optional)         — messages each side; default 8
  description  : "Recall the surrounding transcript conversation around a loose end —
                 reconstruct how a discussion went and how it resolved."
```

`CallTool` dispatch validates `loose_end_id` as a UUID (invalid → `isError` result), reads
`radius` (default **8**, larger than the inspector's 4 because recall reconstructs rather than
just highlights), and calls a new thin `PensieveMCP.recallJSON(looseEndID:radius:)` that opens
the store read-only, calls the kernel, and encodes via the existing `result(_:)` path (same
`maxResultSizeChars` hint). Encodes `null` for an unknown id.

### Trust gate

Recall returns **only** verbatim captured transcript text with the cited message flagged, or an
honest `transcriptAvailable: false` + the stored quote. No model in the loop. This is strictly
inside the grounded-with-provenance boundary — the same guarantee the inspector already ships.

## Testing

PensieveKit tests for `SessionContextQueries.recall(...)`:
- Happy path: loose end whose transcript exists → `transcriptAvailable == true`, the cited
  message present with `isCited == true`, window bounded by `radius`.
- Unknown id → `nil`.
- Transcript gone / stale (source event has no on-disk transcript, or the cited message no
  longer contains the quote) → `transcriptAvailable == false`, `messages == []`, `quote`
  preserved. (Leans on `ProvenanceQueries`' existing guard — assert it surfaces through the
  bundle.)
- `radius` respected (window width scales).
- `bundle(...)` now emits a non-nil `id` per loose end.

The MCP command layer stays thin and is exercised as today (no app-style unit tests for the
CLI dispatch; the kernel carries the coverage).

## Out of scope / non-goals

No search, no semantic recall, no `whats_next` handle, no event-centric recall (all backlogged
above). No change to `ProvenanceQueries`, the trust gate, or the narration path.
