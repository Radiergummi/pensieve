# Slice 5 label quality — 2026-08-13

The evidence behind the naming design in
`specs/2026-08-13-talk-to-system-slice5-design.md`. Committed for the same reason the
retrieval probes were: **if a number or a claim appears in that spec, the script that produced it
is here.** One finding below is *non-deterministic*, which makes reproducibility the point rather
than a nicety.

Throwaway measurement probes, not production code. Each is standalone and imports no PensieveKit
type — they carry their own copy of the label gate so what they measure is exactly what would ship.

## Running them

Needs macOS 26 (on-device Foundation Models) and the active Xcode 26.6 toolchain.

```sh
swiftc -O lprobe1-label-quality.swift  -o /tmp/lp1 && /tmp/lp1   # 21 quick-adds → label + gate verdict
swiftc -O lprobe2-same-language.swift  -o /tmp/lp2 && /tmp/lp2   # does a same-language instruction fix German?
swiftc -O lprobe3-language-routing.swift -o /tmp/lp3 && /tmp/lp3 # NLLanguageRecognizer + deterministic shortening
```

`lprobe1` and `lprobe2` call the on-device model and take a few minutes. `lprobe3` is pure and
instant.

## What they found

### 1. English label quality is good — 21/21 passed the gate, 16/16 English usable

Representative: `look into why the background sync agent stopped spawning` →
**"Background Sync Agent Issue"**; `syntax highlighting for transcript code fences` →
**"Transcript Code Fence Highlighting"**; `merge inbox for duplicate nodes, the sidebar shows Agent
twice` → **"Duplicate Nodes Merge"**.

Two dropped the distinguishing term — `migrate the loose end resolution verbs into the CLI` →
"CLI Migration", and `spike whether writing tools can attach to a markdown view` → "Markdown View
Attachment" (losing *writing tools*, the actual subject). Both recoverable: the field is editable
before write.

### 2. The gate rejected nothing — 0 of 21

`TextQuality.isTerseLabel` was built for `Ingester.nameStrand`, whose input is 20 event summaries.
A single typed sentence rarely sprawls, so the gate is **cheap tail insurance here, not a
load-bearing filter**. Keep it; don't claim it is doing work.

### 3. German is translated to English, and once wrongly — the decisive finding

| input | label |
|---|---|
| `Steuerunterlagen für 2025 zusammenstellen` | "Tax documents for 2025" |
| `die Bahn-Reklamation für die verspätete Fahrt einreichen` | **"Train Advertisement Claim"** |
| `Geschenk für Mamas Geburtstag besorgen` | "Birthday Gift for Mom" |

A *Reklamation* is a complaint; the model conflated it with *Reklame*. Two problems: translating at
all violates the project rule that node names are content and are never localized, and this
particular output is simply wrong.

**It is not reproducible.** `lprobe2`'s baseline arm returned "Train Delay Compensation" —
semantically correct — for the same input on a later run. Non-determinism makes this *worse* to
rely on, not better: the failure cannot be prompted away and will not show up reliably in testing.

### 4. A same-language instruction does NOT fix it

`lprobe2` compares the base prompt against one adding *"Write the label in the SAME LANGUAGE as the
description; do not translate it."*

| input | base | + same-language |
|---|---|---|
| `Steuerunterlagen für 2025 zusammenstellen` | Tax documents for 2025 | **2025 Tax Documents** (still English) |
| `die Bahn-Reklamation … einreichen` | Train Delay Compensation | **"Später Zuganzeige Einreichen"** (broken German) |
| `Geschenk für Mamas Geburtstag besorgen` | Birthday Gift for Mom | **Gift for Mom's Birthday** (still English) |
| `den Mietvertrag kündigen und die Kaution zurückfordern` | End Lease Agreement | Rent contract termination and refund of deposit |

The ~3B model largely ignores the instruction, and where it complies it produces nonsense
(*Zuganzeige* is not the word). **Prompt engineering does not rescue this.**

### 5. Language routing is viable, and the deterministic fallback is good

`NLLanguageRecognizer` was **11/11 correct**, confidence ≥ 0.92 on every multi-word input.
Single-word inputs are the weak spot but still correct: `taxes` → `en` 0.55, `Steuer` → `de` 0.99.

The reason the non-English fallback works is visible in the same run: **quick-add sentences are
usually already short enough to be their own label.** Nine of eleven inputs were ≤ 60 chars, so a
word-boundary shortening returns them whole — `Steuerunterlagen für 2025 zusammenstellen` (41c) is
a perfectly good node name in the user's own words, guaranteed correct.

Only the 173-char rambling input truncates badly ("I want to eventually get around to thinking
about whether"), which is the known cost of the deterministic path.

## What this changed in the spec

Naming **routes on detected language**: English → the model; anything else → deterministic
word-boundary shortening, never a translation. A side effect worth noting is that the name is now
**never empty**, so a provider failure no longer leaves `Save` disabled — which closes a review
finding about the failure path being worse than "today's modal plus your text".
