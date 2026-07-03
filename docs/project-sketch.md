**PENSIEVE: PROJECT TIMELINE TRACKER – NATIVE MACOS/IOS APP**

**Objective:**
Build a native macOS/iOS app in Swift and SwiftUI that intelligently tracks work across multiple parallel projects. Automatically capture activities via Git hooks and Claude Code config hooks, maintain comprehensive timelines, generate AI-powered summaries, track cross-project dependencies, surface risks and blockers, and provide a prioritized "What's Next" queue. Leverage Apple's native frameworks for deep OS integration: CloudKit for sync, WidgetKit for dashboard views, Spotlight for search, FSEvents for real-time file monitoring, and Shortcuts for voice control.

**Core Architecture:**

1. **Data Layer – CloudKit + Local SQLite Sync**
   - Primary store: CloudKit (iCloud) for sync across devices
   - Local cache: SQLite for offline access and performance
   - Tables: `events` (timestamped activities with metadata), `projects` (aggregated state, summaries), `dependencies` (cross-project relationships), `checkpoints` (manual user notes)
   - CloudKit schema mirrors SQLite for bidirectional sync
   - Each event: timestamp, projectID, eventType, gitMetadata (branch, commit, files), claudeMetadata (sessionID, tokens, model), semanticDescription, rawData

2. **Capture Layer – Dual Hook Systems**
   - **Git Hooks** (pre-commit, post-commit, post-checkout): Shell scripts that POST to local HTTP endpoint with branch, commit hash, files changed, diff stats
   - **Claude Code Config Hooks** (session start/end, file changes): POST sessionID, timestamp, token usage, files modified
   - Local HTTP endpoint (FastAPI Python backend running via launchd): Receives hooks, validates, enriches, stores to SQLite, syncs to CloudKit
   - **Native FSEvents Integration** (macOS only): Monitor key directories for real-time file changes, supplement hook data with activity signals

3. **Processing Layer**
   - HTTP endpoint receives hook payloads
   - Enrich with metadata (git branch context, file types, etc.)
   - Call Claude API (Anthropic SDK in Python backend) to generate semantic descriptions
   - Persist to SQLite
   - Trigger CloudKit sync
   - Notify SwiftUI app via NotificationCenter for live UI updates

4. **Intelligence Layer – Project Summaries**
   - For each project, aggregate events from last 14 days (configurable)
   - Generate structured summary via Claude:
     - **What It Is**: Project description
     - **Last Work Done**: Recent activities in natural language
     - **Current Blockers**: Unresolved issues
     - **Open Questions**: Inferred from commits, branches, notes
     - **Risks If Not Addressed**: AI-generated risk assessment
     - **Token Cost**: Aggregate spend for this project
   - Regenerate on each new event via background CloudKit subscription

5. **Cross-Project Dependencies**
   - Manual linking: User can connect projects ("ProjectA blocks ProjectB")
   - Auto-detect soft dependencies: shared branches, common file patterns, commit message references
   - Visualize as graph in project detail view

6. **Priority Queue – "What's Next"**
   - Rank by: days since last work, risk level, dependency impact, token efficiency
   - Surface top 3–5 actions with reasoning
   - Manual reordering / priority overrides
   - Sync priority state to CloudKit for consistency across devices

7. **Analytics & Insights**
   - Token spend per project (cumulative, trend charts)
   - Activity heatmap (hot vs. dormant projects)
   - Checkpoint frequency analysis
   - Time-to-next-action metrics

---

**Frontend – Native SwiftUI App (macOS + iOS)**

**Main App Structure:**

1. **Home/Dashboard View**
   - Snapshot of all open projects (count, health status)
   - "What's Next" priority queue (top 3–5 actions)
   - Quick stats: total tokens this week, projects at risk, overdue items
   - Swipe to refresh syncs from CloudKit

2. **Project Detail View**
   - Full project summary (What It Is, Last Work, Blockers, Open Questions, Risks)
   - Timeline: Scrollable, reverse-chronological events with semantic descriptions
   - Metadata per event: branch, commit, files, tokens, timestamp
   - Dependency graph: Visual representation of linked projects
   - Token analytics: Graph of spend over time
   - Manual checkpoint button: User can write quick note, updates summary

3. **Timeline/Activity View**
   - Chronological feed across all projects
   - Filterable by project, date range, event type
   - Swipe actions: Archive project, flag as blocker, add note
   - Pull-to-refresh

4. **Search/Spotlight Integration**
   - Full-text search over project names, summaries, events
   - Native Spotlight indexing: User can ⌘Space + "OAuth" and instantly see related projects/events
   - Quick navigation from Spotlight to project detail

5. **Settings View**
   - iCloud sync toggle (on/off, show sync status)
   - Refresh interval for summaries
   - Token cost configuration (optional, for analytics)
   - Git hooks configuration (path to repos, auto-discover toggle)
   - Notification preferences (risk alerts, overdue reminders)
   - Data export (markdown, JSON)

---

**Native macOS/iOS Features:**

1. **WidgetKit & Lock Screen Widgets**
   - **Dashboard Widget** (macOS, iOS): Shows "What's Next" (top 3 actions) at a glance
   - **Lock Screen Widget** (iOS): Quick peek at your current priority queue
   - Small, medium, large sizes; updates via CloudKit subscription

2. **Spotlight Search**
   - Index all projects and events
   - User searches "RabbitMQ" → instantly sees all related timelines across projects
   - Deep links from search results to project detail view

3. **CloudKit Sync**
   - Seamless sync across macOS, iPhone, iPad
   - Offline-first: local SQLite always works, CloudKit syncs when available
   - Conflict resolution: last-write-wins with user notification on conflicts
   - Background sync via CloudKit push notifications

4. **FSEvents (macOS)**
   - Monitor git repo directories for real-time file changes
   - Supplement hook data: even if a hook misfires, you detect activity
   - Optional: show "currently working on" indicator based on recent file touches

5. **Shortcuts/Siri Integration**
   - Shortcut: "What's next?" → reads top 3 priorities aloud
   - Shortcut: "Add checkpoint" → open quick note entry
   - Shortcut: "Show project X" → deep link to project detail
   - Use SiriKit for voice control

6. **Native Notifications**
   - UNUserNotificationCenter for OS-level alerts
   - Alert: Project overdue (X days since last work)
   - Alert: New blocker detected
   - Alert: CloudKit sync failed (offline, retry needed)
   - Rich notifications with actions: "View Project", "Add Checkpoint"

7. **Menu Bar App (macOS)**
   - Optional: Always-visible menu bar icon showing "What's Next" summary
   - Click to expand priority queue
   - Quick access without opening full app

---

**Backend – Lightweight Python Service**

- **FastAPI** HTTP endpoint for hook ingestion
- **SQLite** local cache
- **Anthropic SDK** for Claude API calls (summaries, descriptions)
- Runs via **launchd** (macOS system service, auto-start)
- Syncs SQLite → CloudKit via a simple CloudKit REST wrapper or native CloudKit SDK call from Swift
- Low overhead: only 50–100MB memory footprint

---

**SwiftUI Tech Stack:**
- **SwiftUI**: Declarative UI, automatic Light/Dark mode, accessibility
- **Combine**: Reactive state management (ObservableObject, @Published)
- **CloudKit**: iCloud sync, push notifications
- **WidgetKit**: Dashboard and Lock Screen widgets
- **CoreSpotlight**: Spotlight indexing
- **AppKit** (macOS only): Menu bar integration
- **CoreServices** (macOS only): FSEvents file monitoring
- **UserNotifications**: OS-level notifications
- **Intents/SiriKit**: Shortcuts and voice control

---

**Implementation Phases:**

1. **Phase 1 (MVP – macOS only):**
   - Basic SwiftUI app with project list, detail view
   - Local SQLite storage
   - Hook capture via Python backend
   - Timeline view with raw events
   - Manual checkpoint entry

2. **Phase 2:**
   - CloudKit sync
   - AI-powered summaries (Claude API)
   - "What's Next" priority queue
   - Project summary view

3. **Phase 3:**
   - WidgetKit dashboard widget
   - Spotlight search integration
   - Dependency tracking & visualization

4. **Phase 4:**
   - iOS companion app
   - Lock Screen widget
   - Shortcuts/Siri integration
   - Menu bar app (macOS)
   - FSEvents real-time monitoring

---

**Open Questions:**

1. **CloudKit vs. Local-Only:** Start with CloudKit for future multi-device support, or keep local-only for simplicity and privacy?
2. **Menu Bar App:** Worth building for quick access, or overkill for Phase 1?
3. **FSEvents vs. Hooks Only:** Should we implement real-time file monitoring, or rely entirely on Git hooks?
4. **Spotlight Indexing:** Full-text index all events, or just project names?
5. **Notifications:** Desktop alerts for overdue projects, or too noisy?
6. **Export Formats:** Markdown, JSON, or both?
7. **Dark Mode:** Auto-follow system, or user toggle?
8. **Accessibility:** VoiceOver support required from day one, or Phase 4?
9. **Performance:** Should summaries cache aggressively, or regenerate frequently?
10. **Multi-Device Conflict:** If you edit a summary on iPhone and Mac simultaneously, how should conflicts resolve?
