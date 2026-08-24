// Sources/PensieveApp/LooseEndRow.swift
import SwiftUI
import PensieveKit

/// One loose-end row: a tappable summary that, when expanded, shows its provenance in a soft rounded
/// box — a couple-line preview of the cited line, with a disclosure to expand to the full surrounding
/// transcript (cited message highlighted, machine-envelope messages dimmed). When the transcript is
/// gone it degrades honestly to the stored quote + a note. This replaces the old side-panel inspector:
/// one click, everything grounded in place. Shared by the detail recall + the middle worklist.
struct LooseEndRow: View {
  let view: LooseEndView
  /// Resolves the surrounding-transcript context off the main actor (file I/O). Pass `model.provenance`.
  let loadProvenance: (LooseEnd) async -> LoadedProvenance?
  /// Confirms a salience label for this loose end (👍 salient / 👎 noise / "" clears). Pass
  /// `model.setLooseEndLabel`.
  let onLabel: (UUID, String) -> Void
  /// The summary as it should render — the on-demand translation when one is stored, else the
  /// English original. An INPUT rather than a lookup inside this row: the backing `translationStore`
  /// is `@ObservationIgnored` on `AppModel`, so a lookup made from inside this row's body would carry
  /// no observation dependency of its own, and a translation landing would never trigger a re-render.
  /// Passing it in as a plain property makes the change a diffable input instead. Pass
  /// `model.displayed(field: .looseEndText, sourceText: view.looseEnd.text)`. `nil` for callers
  /// outside the find-scoped detail pane, which fall back to the English original.
  var displaySummary: String?
  /// Translates this row's summary on demand, then debounced-reindexes. Pass
  /// `{ text in await model.translate(field: .looseEndText, sourceText: text) }`. `nil` hides the
  /// context-menu action outright (as does the target being off) — no caller may show a dead button.
  var onTranslate: ((String) async -> Void)?
  /// Resolves this loose end: `(looseEndID, newStatus, previousStatus, previousResolvedAt)`. The
  /// previous stamp travels with the previous status because undo restores the PAIR. `nil` in surfaces
  /// that do not offer resolution — no caller may show a dead button.
  var onResolve: ((UUID, LooseEndStatus, LooseEndStatus, Date?) -> Void)?
  /// When this equals the row's loose end, the row starts/auto-expands (a search hit landing here).
  var expandedLooseEndID: UUID?
  /// True in the middle column, where ~180pt is usable. Drops bubbles and tightens the type scale.
  var compact: Bool = false
  /// The owning detail pane's find state, when this row participates in find. `nil` in the middle
  /// column and the Review Suggestions list — neither is find-scoped.
  var find: NodeFindState?

  @State private var expanded = false            // the loose-end row itself
  @State private var provenanceExpanded = false  // the provenance box's own show-more/less
  @State private var context: ProvenanceContext?
  @State private var loading = false
  /// Segments parallel to `context.messages`, supplied by the loader when the context loads. A
  /// cache keyed on `ProvenanceMessage.index` would be a hazard — that index is per-session, so it
  /// could serve session A's segments for session B. The loader's cache dodges this: it keys on
  /// loose-end ID, and a loose end has exactly one `sourceEventID`, hence one session.
  @State private var parsed: [[TranscriptSegment]] = []

  /// Optimistic override of the confirmed label so a tap reflects immediately (the injected
  /// `LooseEndView` is an immutable snapshot). nil = show the stored value. The row is filtered out
  /// of the open list on the next reload when confirmed noise.
  @State private var localLabel: String?
  @State private var hovering = false
  /// Optimistic override of the status so a tap reflects immediately (the injected `LooseEndView` is
  /// an immutable snapshot). nil = show the stored value.
  @State private var localStatus: LooseEndStatus?

  /// The label to display: the optimistic local value if the user just tapped, else the stored one.
  private var currentLabel: String { localLabel ?? view.looseEnd.label }
  private var currentStatus: LooseEndStatus { localStatus ?? view.looseEnd.status }

  /// Both the thumb buttons and the context menu write through here.
  private func setLabel(_ value: String) {
    localLabel = value
    onLabel(view.looseEnd.id, value)
  }

  private func resolve(_ newStatus: LooseEndStatus) {
    let previous = currentStatus
    localStatus = newStatus
    onResolve?(view.looseEnd.id, newStatus, previous, view.looseEnd.resolvedAt)
  }

  /// A thumb the user has actually set stays visible unconditionally — a confirmed label is recorded
  /// state, not an affordance, and hiding it would make the app appear to forget a decision. The
  /// machine's *suggestion* earns no such permanence.
  private var showsThumbs: Bool { hovering || !currentLabel.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Button {
          expanded.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.caption2).foregroundStyle(.secondary)
            looseEndText
          }
        }
        .buttonStyle(.plain)
        Spacer()
        thumbs
      }

      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          provenanceBody
          // Was a hand-built `%lldd ago` whose catalog key said `%@d ago`, so it never matched and
          // rendered English inside a German window. Foundation formats the date instead — no
          // interpolated Int, no key, no way to mis-author it.
          //
          // The cited message's `role` used to lead this line. It was deleted in C1: all 1076 loose
          // ends carry "user" and structurally cannot carry otherwise (LooseEndVerifier guards
          // isUserPrompt), so it spent a word — untranslated, under a localized speaker caption —
          // restating what the rail already says and could never contradict.
          Text(view.occurredAt.formatted(.dateTime.year().month().day())
            + NodeMeta.separator
            + NodeMeta.relative(view.occurredAt))
            .metaText()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.leading, 18)
        .padding(.top, 2)
      }
    }
    .padding(.vertical, 2)
    // Without this the row's hit region is only its rendered glyphs — the `Spacer()` between the
    // text and the thumbs is dead space, so moving the pointer horizontally toward a thumb left
    // the hover region and the thumb vanished before it could be clicked.
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    // Keyboard- and pointer-free access to the same two verbs the hover-revealed thumbs offer.
    .contextMenu {
      // Resolution first: it is the common action, and it answers a different question from the
      // salience verbs below the divider.
      if onResolve != nil {
        LooseEndStatusMenu(status: currentStatus, resolve: resolve)
        Divider()
      }
      Button("Mark as a real loose end") { setLabel(LooseEndLabel.salient) }
      Button("Mark as not a loose end") { setLabel(LooseEndLabel.noise) }
      if !currentLabel.isEmpty {
        Divider()
        Button("Clear rating") { setLabel(LooseEndLabel.unlabeled) }
      }
      if let onTranslate, TranslationTarget.resolved() != TranslationTarget.off {
        Divider()
        Button(LocalizedStringKey("Translate")) {
          Task { await onTranslate(view.looseEnd.text) }
        }
      }
    }
    // Swipe is a pointer affordance in the List-backed feeds; the context menu is the discoverable
    // one everywhere; the keyboard verbs in `LooseEndResolveCommands` are the burn-down one. Swipe
    // and the menu share `LooseEndResolveVerb` — which this comment used to claim while the swipe
    // branch restated the open-row verbs inline and gated on `status == .open`, so a closed row
    // offered Reopen from the menu and nothing from a swipe. The commands are deliberately not on
    // that shared list; see their own doc for why.
    //
    // NOTE: this is INERT in `DetailView`, which renders loose ends in a VStack inside a ScrollView
    // rather than a List. That is expected, not a regression — the detail pane is covered by the
    // context menu and the menu commands.
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if onResolve != nil {
        ForEach(LooseEndResolveVerb.verbs(for: currentStatus)) { verb in
          Button(verb.title) { resolve(verb.id) }.tint(verb.tint)
        }
      }
    }
    // Load the surrounding transcript the first time the row is expanded (cached thereafter).
    .task(id: expanded) {
      guard expanded, context == nil else { return }
      loading = true
      let loaded = await loadProvenance(view.looseEnd)
      context = loaded?.context
      // Segments come from the loader, NOT a second TranscriptMarkup.parse here: the find document
      // indexes these exact arrays by position, so a separate parse could disagree about ordinals.
      parsed = loaded?.segments ?? []
      loading = false
      // The window this row renders is the truth. The sweep may have recorded a different one — the
      // loader re-slices a transcript that grew since — so let the rendered window correct the
      // document, keeping its segment ordinals and the on-screen ordinals the same numbers.
      find?.noteRenderedProvenance(looseEndID: view.looseEnd.id, loaded: loaded,
                                   quote: view.looseEnd.quote)
    }
    .onAppear {
      if expandedLooseEndID == view.looseEnd.id { expanded = true }
      if isFindTarget { revealForFind() }
    }
    .onChange(of: expandedLooseEndID) { _, newValue in
      if newValue == view.looseEnd.id { expanded = true }
    }
    // Drop the optimistic override once the reload hands this row the stored value. Without it an
    // undone flip left the row's badge (which reads the snapshot) disagreeing with its own context
    // menu (which reads the override) — one row answering the same question two ways.
    .onChange(of: view.looseEnd.status) { _, _ in localStatus = nil }
    // The per-window find channel, ALONGSIDE the app-wide `expandedLooseEndID` above and never
    // instead of it: that property is read by the detail pane in every open window, so driving find
    // through it would expand this row in every ⌘⌥N recall window and clobber a pending search or
    // Spotlight landing.
    .onChange(of: isFindTarget) { _, forced in
      if forced { revealForFind() }
    }
  }

  /// True while find has force-expanded this row to reveal a match inside it.
  private var isFindTarget: Bool { find?.forcedExpansions.contains(view.looseEnd.id) ?? false }

  /// Opens the row AND its provenance disclosure for a find target — both, unconditionally. The
  /// collapsed preview renders a SINGLE segment (`previewSegments`) at view-ordinal 0 whatever that
  /// segment's true position is, so a document anchor for any other segment has no on-screen site to
  /// highlight or scroll to while the disclosure is shut.
  private func revealForFind() {
    expanded = true
    provenanceExpanded = true
  }

  @ViewBuilder private var looseEndText: some View {
    let anchor = FindAnchor.looseEndText(view.looseEnd.id)
    // Computed ONCE and shared by both consumers — the highlight-run lookup and the rendered text —
    // so find can never disagree with what is actually on screen (an English query would silently
    // stop matching a row whose summary was translated, or vice versa).
    let text = displaySummary ?? view.looseEnd.text
    let runs = find?.runs(for: anchor, text: text) ?? []
    Group {
      if runs.isEmpty {
        Text(text).prose()
      } else {
        HighlightedText(runs: runs, currentOffset: find?.currentOffset(in: anchor)).prose()
      }
    }
    .findSite(anchor, find)
  }

  @ViewBuilder private var provenanceBody: some View {
    if let context, context.transcriptAvailable {
      let cited = context.messages.first(where: \.isCited) ?? context.messages.first
      if context.messages.count > 1 {
        if provenanceExpanded {
          // 18 clears MarkdownUI's 14pt paragraph margin (`Theme.basic`), restoring within-paragraph <
          // between-paragraphs (14) < between-messages (18) — the spec's pre-committed Risk #3
          // fallback ("reinstate a hairline rule between messages"), taken as spacing, not a rule.
          VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(context.messages.enumerated()), id: \.element.index) { offset, message in
              messageRow(message,
                         showsRole: offset == 0
                           || speakerClass(for: context.messages[offset - 1]) != speakerClass(for: message))
            }
          }
        } else if let cited {
          previewRow(cited)
        }
        disclosureButton
      } else {
        ForEach(context.messages, id: \.index) { messageRow($0, showsRole: true) }
      }
    } else if loading {
      ProgressView().controlSize(.small)
    } else {
      quoteFallback
      if context != nil {
        Text("Surrounding context unavailable (transcript changed or removed).").metaText()
      }
    }
  }

  /// Honest fallback: the stored verbatim quote + why there's no surrounding context.
  ///
  /// A find site like any other text this row renders itself. It has to be: on the measured store 85%
  /// of loose ends have no surviving transcript and degrade to exactly this quote, so the
  /// `.looseEndQuote` unit the document mints for them would otherwise be a counted match with nowhere
  /// to scroll and nothing tinted — the user told a match is here and shown nothing.
  @ViewBuilder private var quoteFallback: some View {
    let anchor = FindAnchor.looseEndQuote(view.looseEnd.id)
    let runs = find?.runs(for: anchor, text: view.looseEnd.quote) ?? []
    Group {
      if runs.isEmpty {
        Text(view.looseEnd.quote)
      } else {
        HighlightedText(runs: runs, currentOffset: find?.currentOffset(in: anchor))
      }
    }
    .prose().italic().padding(.leading, 10)
    .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
    .findSite(anchor, find)
  }

  @ViewBuilder private var thumbs: some View {
    HStack(spacing: 10) {
      thumb(systemFilled: "hand.thumbsup.fill", systemOutline: "hand.thumbsup",
            value: LooseEndLabel.salient, help: String(localized: "Mark as a real loose end"))
      thumb(systemFilled: "hand.thumbsdown.fill", systemOutline: "hand.thumbsdown",
            value: LooseEndLabel.noise, help: String(localized: "Mark as not a loose end"))
    }
    .font(.caption)
    // Opacity, not `if` — the row must not reflow when the pointer arrives.
    .opacity(showsThumbs ? 1 : 0)
    .allowsHitTesting(showsThumbs)
    .accessibilityHidden(!showsThumbs)
  }

  /// One thumb. Filled when the confirmed label matches; a faint pre-highlight when only SUGGESTED
  /// (guess awaiting confirm). Tapping toggles: tap the active label again to clear it.
  @ViewBuilder private func thumb(systemFilled: String, systemOutline: String,
                                  value: String, help: String) -> some View {
    let confirmed = currentLabel == value
    let suggested = currentLabel.isEmpty && view.looseEnd.labelSuggestion == value
    Button {
      setLabel(confirmed ? LooseEndLabel.unlabeled : value)
    } label: {
      Image(systemName: confirmed ? systemFilled : systemOutline)
        .foregroundStyle(confirmed ? Color.accentColor : (suggested ? Color.accentColor.opacity(0.55) : Color.secondary))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }

  private var disclosureButton: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) { provenanceExpanded.toggle() }
    } label: {
      Label(provenanceExpanded ? "Show less" : "Show more",
            systemImage: provenanceExpanded ? "chevron.up" : "chevron.down")
        .font(.caption).foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .padding(.top, 2)
  }

  /// Collapsed preview: the cited message's first renderable segment, capped to a few lines.
  ///
  /// `compact` is the ROW's, not hardcoded `true`. It was hardcoded until C1, which meant the detail
  /// pane previewed a message in the compact layout and then re-rendered it railed on "Show more" —
  /// one disclosure, two layout modes, for the message that is collapsed by default whenever the
  /// window holds more than one.
  @ViewBuilder private func previewRow(_ message: ProvenanceMessage) -> some View {
    TranscriptMessageView(message: message, segments: previewSegments(for: message),
                          compact: compact)
      .lineLimit(3)
  }

  @ViewBuilder private func messageRow(_ message: ProvenanceMessage, showsRole: Bool) -> some View {
    let messageSegments = segments(for: message)
    TranscriptMessageView(message: message, segments: messageSegments,
                          compact: compact, showsRoleLabel: showsRole,
                          highlights: highlights(for: message, segments: messageSegments),
                          // Only on a find-scoped surface: handing an anchor to the middle column or
                          // Review Suggestions would put an `.id()` on segments that never had one,
                          // changing their view identity for a scroll target nothing can reach.
                          anchorForSegment: find == nil ? nil : { ordinal in
                            .transcriptSegment(looseEndID: view.looseEnd.id,
                                               messageIndex: message.index, segment: ordinal)
                          },
                          find: find)
  }
}

/// The transcript-rendering helpers, in an extension so the struct body stays inside SwiftLint's
/// `type_body_length` cap — which the resolve verbs pushed it past.
extension LooseEndRow {
  /// Segments for a message, by position in the parallel `parsed` array. Falls back to a single
  /// raw markdown segment if the arrays ever disagree — never renders nothing.
  fileprivate func segments(for message: ProvenanceMessage) -> [TranscriptSegment] {
    guard let context,
          let messagePosition = context.messages.firstIndex(where: { $0.index == message.index }),
          messagePosition < parsed.count
    else { return [.markdown(message.text)] }
    return parsed[messagePosition]
  }

  /// The caption shown for a message is its `SpeakerClass`, not its raw `role` — an `assistant`
  /// message that classifies `.system` (e.g. all-`<tool_uses>`) must not be conflated with a
  /// following prose `assistant` message that classifies `.claude`, or the caption is wrongly
  /// suppressed and the reader misattributes the speaker.
  fileprivate func speakerClass(for message: ProvenanceMessage) -> SpeakerClass {
    .of(message, segments: segments(for: message))
  }

  /// The preview shows only the first meaningful segment — a harness envelope alone would tell the
  /// reader nothing about why this loose end exists.
  fileprivate func previewSegments(for message: ProvenanceMessage) -> [TranscriptSegment] {
    let messageSegments = segments(for: message)
    let firstProse = messageSegments.first { segment in
      switch segment {
      case .markdown(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .callout: return true
      case .harness: return false
      }
    }
    return [firstProse ?? messageSegments.first ?? .markdown(message.text)]
  }
}
