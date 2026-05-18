# Threadline layout & design system

Research and recommendations for the macOS overlay UI. Grounded in product docs
(`threadline-v1-direction.md`, `product-wow-ideas.md`), the overlay codebase
(`ContentView.swift`, `Panel.swift`, `TerminalTheme.swift`, `WorkStatus.swift`),
and the core use case: global hotkey → scan inbox → jump back.

---

## 1. North star

Threadline is **not** another IDE, chat UI, or agent dashboard. It is a
**pre-PR trust inbox**:

> Which AI session needs me, is the work safe to review, and how do I get back
> there in one action?

Every layout and token decision should serve six questions (from V1 direction):

| Priority | Question | UI job |
|----------|----------|--------|
| 1 | What needs attention **now**? | Ranked list, status color, sort |
| 2 | What changed? | File count, branch, diff digest |
| 3 | Did tests run? | Evidence line, not buried in a tab |
| 4 | Risky or ready? | One human label (`Ready`, `Risky`, …) |
| 5 | What should I do next? | Single recommended action |
| 6 | Jump back? | Primary CTA + **Return** |

**Design principle:**

```text
Messy AI session → clear trust state → one human action
```

If a screen element does not help that chain, it is secondary or belongs behind
disclosure.

---

## 2. Current state audit

### Strengths

- **Correct shell layout**: `HSplitView` — agents list (220–360px) + detail
  (360px+). Matches macOS patterns (Mail, Finder, Xcode navigators).
- **Strong domain model**: `WorkStatus` + `WorkState` with rank-based sort
  matches “Attention Radar” from product ideas.
- **Semantic status colors** already exist (`workStatusColor`, tool badges,
  diff +/- greens/reds).
- **Keyboard-first jump**: Return in `Panel.swift` + `JumpButton`.
- **TerminalTheme**: reads Ghostty/Alacritty/Kitty background — foundation for
  “feels like my dev environment” (currently unused in SwiftUI).
- **Information density** fits power users: monospaced paths, compact rows,
  file diffs inline.

### Gaps vs product vision

| Product says | UI does today |
|--------------|----------------|
| One card = status + reason + **one action** | Row shows tool, status, reason, summary, time — action only in detail header |
| First screen = ranked inbox | Folder sections + selection; sort is internal, not visually “inbox” |
| Minimal categories | 4 detail tabs + folder pane + stats grids — lots of parallel surfaces |
| “Extremely obvious” | User must learn tab model (Overview / Tasks / Files / Summary) |

### Technical debt (design-system level)

From `ContentView.swift`:

- **113+ inline** `.font(.system(size: …))` and **duplicated RGB** literals.
- **No shared tokens file** — helpers like `sectionTitle`, `badgeColor`,
  `workStatusColor` live in one ~1,200-line view.
- **Two selection modes** (folder vs agent) with different detail panes.
- **Typography scale is implicit**: 9 / 10 / 11 / 12 / 13 / 17 / 20pt with no
  named roles.
- **Spacing is ad hoc**: 4, 6, 8, 10, 12, 14, 18, 20 without a scale.

The README ASCII mockup is **simpler and closer to V1** than the tabbed detail
pane:

```text
Claude  [assistant] writing the panel now…
        ~/Projects/threadline · claude-opus-4-7 · 12s
```

That is a **single-scan row**, not a mini dashboard.

---

## 3. Aesthetic direction

### Positioning: “Native macOS ops console”

Not generic SaaS (Inter + purple gradient). Not brutalist chaos. Not a second
IDE.

| Attribute | Choice | Why |
|-----------|--------|-----|
| Tone | Calm, utilitarian, trustworthy | Users decide whether to trust AI work |
| Density | Medium-high in list; breathable in detail | Scan 10–20 sessions quickly |
| Motion | Minimal (selection, expand file, jump) | Utility app; hotkey toggled constantly |
| Typography | **SF Pro** for status/reason; **SF Mono** for paths, metrics, diffs | Native + terminal literacy |
| Color | Semantic status palette + tool accents; neutrals from system | Accessibility + dark/light |
| Chrome | Standard `NSWindow`, transparent titlebar | Feels like a real Mac app |

### Optional differentiation: terminal-adaptive chrome

Wire `TerminalTheme.backgroundColor` into a subtle window tint or sidebar edge
when the frontmost app is Ghostty/Alacritty/Kitty. Reinforces “this app sits
next to my terminal” without cloning terminal UI.

---

## 4. Layout architecture

### Level 0 — Window

Keep current defaults (`880×520`, min `520×320`, persisted frame).

### Level 1 — Two-pane master–detail (keep)

```text
┌─────────────────────────────────────────────────────────────┐
│ [optional toolbar: search, filter, refresh]                 │
├──────────────────┬──────────────────────────────────────────┤
│  INBOX (260px)   │  TRUST CARD (flex)                       │
│  ranked rows     │  status · reason · next action · Open    │
│                  │  ─────────────────────────────────────   │
│                  │  evidence (collapsible)                  │
│                  │  files / diff / timeline                 │
└──────────────────┴──────────────────────────────────────────┘
│ footer: ↵ Open · ⌃⌥⌘T toggle                               │
└─────────────────────────────────────────────────────────────┘
```

### Level 2 — Inbox column

**Sort by `workState.rank` globally**, not only within folders. Folders become
**group headers**, not separate detail modes.

**Row anatomy (one glance):**

```text
●  CLD  Claude          Needs you          4m
         waiting for approval · auth.ts +2
```

| Zone | Content |
|------|---------|
| Leading | Status dot (7px) |
| Identity | Tool badge + name |
| Trust | `WorkStatus` (semibold, colored) |
| Meta | reason or summary (secondary, 1 line) |
| Trailing | `timeAgoShort` |

Remove from default row: duplicate tool line, long reason + summary competing.

**Folder header** stays; selecting a folder should **filter inbox**, not replace
detail with `FolderDetailsPane`. Folder stats belong in detail header when a
folder is selected.

### Level 3 — Detail pane (collapse tabs → stack)

Replace segmented `Overview | Tasks | Files | Summary` with **one scrollable
trust card** + disclosures:

1. **Hero** (always visible)
   - Large status (`Needs you`)
   - Reason (one line)
   - **Primary button**: `Open` (text only) + hint `↵`
   - Secondary: next action text (`Run tests`, `Review diff`)

2. **Evidence strip** (always visible, compact)
   - changed · tests · risk · branch
   - Compact chips instead of a padded card + 2×2 grid

3. **Disclosures** (collapsed by default except Files when `ready`/`risky`)
   - Files & diff
   - Tasks (only if non-empty)
   - Summary (lazy load)
   - X-Ray (power user)

Use tabs only when modes are truly unrelated. Here, everything supports “can I
trust this session?” — one vertical story is stronger.

### Level 4 — Footer chrome (missing today)

Persistent footer in detail:

```text
↵ Open session    ·    ⌃⌥⌘T hide
```

Teaches keyboard model without tooltips alone.

---

## 5. Design system specification

Create `overlay/Sources/threadline-overlay/DesignSystem/` (or
`ThreadlineDesign.swift`) — **tokens + components**, not scattered in
`ContentView`.

### 5.1 Color tokens

**Neutrals** — prefer semantic AppKit/SwiftUI:

- `textPrimary` → `.primary`
- `textSecondary` → `.secondary`
- `surface` → `Color(nsColor: .controlBackgroundColor)`
- `surfaceElevated` → window background + opacity layer
- `separator` → `Divider` / `.separatorColor`

**Status** (single source of truth — map 1:1 to `WorkStatus`):

| Token | Use | Suggested value (dark) |
|-------|-----|------------------------|
| `status.needsYou` | dot, label | orange `rgb(255, 140, 26)` |
| `status.testsFailed` | | red `rgb(255, 77, 77)` |
| `status.stuck` | | pink `rgb(242, 89, 166)` |
| `status.risky` | | amber `rgb(255, 199, 26)` |
| `status.ready` | | green `rgb(77, 217, 115)` |
| `status.working` | | blue `rgb(102, 179, 255)` |
| `status.done` | | `.secondary` |

**Tool** (badges only — do not reuse for status):

| Tool | Badge | Color |
|------|-------|-------|
| Claude | CLD | orange |
| Codex | CDX | green |
| Cursor | CUR | purple |

**Diff**:

- `diff.added` / `diff.removed` — keep current green/red; never use for status.

### 5.2 Typography scale

| Token | Size | Weight | Design | Use |
|-------|------|--------|--------|-----|
| `caption` | 9 | semibold | mono | `AGENTS`, section labels |
| `label` | 10 | regular | mono | counts, timestamps |
| `rowTitle` | 12 | semibold | default | tool name, status in row |
| `rowSub` | 10–11 | regular | default | reason, summary |
| `body` | 13 | regular | default | detail prose |
| `bodyMono` | 12–13 | regular | mono | paths, stats values |
| `title` | 20 | semibold | default/mono | detail header |
| `hero` | 17 | semibold | default | work status headline |

**Rule:** Monospace only for **machine data** (paths, branch, metrics, diffs).
Human sentences use SF Pro.

### 5.3 Spacing scale (4pt base)

| Token | px | Use |
|-------|-----|-----|
| `xs` | 4 | icon gaps, chip padding |
| `sm` | 8 | row internal, button pad |
| `md` | 12 | sidebar header, card pad |
| `lg` | 16 | section gap |
| `xl` | 20 | detail outer margin |

Standardize: sidebar header `md` horizontal; detail `xl`; section gaps `lg`.

### 5.4 Radius & stroke

| Token | Value | Use |
|-------|-------|-----|
| `radius.sm` | 4 | chips, tool tags |
| `radius.md` | 6 | cards |
| `radius.button` | 5 | primary buttons |
| `stroke.subtle` | 0.5px @ 15–35% opacity | outlined buttons, cards |

### 5.5 Component library

| Component | Responsibility |
|-----------|----------------|
| `TLSectionHeader` | uppercase tracked label |
| `TLStatusDot` | maps `WorkStatus` → color |
| `TLToolBadge` | tool badge + color |
| `TLInboxRow` | full row layout |
| `TLTrustCard` | hero status + reason + actions |
| `TLMetricChip` | label + value for stats |
| `TLPrimaryButton` | Open / Review — text only, optional `↵` |
| `TLDisclosureSection` | Files, Tasks, X-Ray |
| `TLDiffBlock` | diff display + shared colors |
| `TLEmptyState` | “no open agents”, “select an agent” |

### 5.6 Interaction patterns

| Action | Pattern |
|--------|---------|
| Primary | One outlined button per screen (`Open`) |
| Secondary | Plain text button or disclosure |
| Selection | List highlight + status dot |
| Jump success | Window hides — no toast noise |
| Disabled Open | 50% opacity + secondary color |

Avoid icon-only buttons unless meaning is universal (chevron for expand is fine).

---

## 6. Information hierarchy rules

### One primary signal per row

Pick **either** `WorkStatus` **or** `SourceState` dot semantics for the list.
**Recommendation:** list uses **`WorkStatus` only**; use a tiny live pulse when
`working` if needed.

### One action per session

Surface `workState.nextAction` in detail hero.

| Status | Primary CTA | Secondary hint |
|--------|-------------|----------------|
| Needs you | Open | “Reply in terminal” |
| Risky | Open | “Run tests” |
| Ready | Open | “Review diff” |
| Tests failed | Open | “Inspect failure” |

`Open` stays the muscle-memory action; next action is guidance.

### Progressive disclosure order

1. Trust (status, reason, action)
2. Change summary (files, branch)
3. Test evidence
4. File diffs
5. Tasks, summary, X-Ray

### Copy style

- **Status**: Title Case (`Needs you`)
- **Reason**: lowercase phrase (`3 files changed - no test evidence`)
- **Sections**: `ALL CAPS` + tracking — only for section boundaries

---

## 7. Layout specs (pixels)

| Element | Spec |
|---------|------|
| Inbox row min height | 44px |
| Inbox row padding | `sm` vertical, `md` horizontal |
| Status dot | 7px list / 10px detail |
| Badge | 9pt bold mono, pad 5×1, radius 3 |
| Detail hero | min 72px, status 17pt + reason 13pt |
| Stats | prefer horizontal chips over 3-column grid until >6 metrics |
| File row | chevron + filename; collapsed path secondary |
| Min detail width | 360px |
| Ideal first-run | 880×520 centered |

---

## 8. Simplify (high impact)

1. Merge folder detail into agent detail — folder selection = filter + aggregated
   files in disclosure.
2. Replace tabs with scroll + disclosures.
3. Global attention sort at inbox level.
4. Extract design tokens before next visual pass.
5. Dedupe row metadata — one secondary line max.
6. Footer with shortcuts.
7. Defer fancy motion, custom fonts, gradients.

---

## 9. Keep investing in

- Diff digest in Files
- Work summary concept — flatten to chips, not nested card-in-card
- X-Ray behind disclosure
- TerminalTheme integration (subtle)
- Monospace paths
- Return to jump — never bury it

---

## 10. Implementation phases

| Phase | Deliverable | Outcome |
|-------|-------------|---------|
| **A** | `ThreadlineDesign.swift` tokens + `TLStatusDot`, `TLToolBadge`, `TLSectionHeader` | Consistent colors/type |
| **B** | `TLInboxRow` + global sort | Inbox matches product doc |
| **C** | `TLTrustCard` detail hero + footer | One-glance trust + Open |
| **D** | Tab removal → disclosures | Simpler mental model |
| **E** | Folder = filter only | Single detail paradigm |
| **F** | TerminalTheme tint (optional) | Distinctive native feel |

---

## 11. Anti-patterns

- Dashboard widgets (charts, trust scores, team views)
- Multiple competing status indicators per row
- Icon-heavy toolbars
- Generic AI palette (purple gradients, Inter)
- Chat-bubble layouts
- Hiding **Open** / Return behind menus
- Light-only or dark-only without testing `NSColor` semantic colors

---

## 12. Reference mental models (not copies)

| Product | Borrow |
|---------|--------|
| **Raycast** | Keyboard-first, compact list, single primary action |
| **Linear** | Status color discipline, one issue = one state |
| **macOS Mail** | Sidebar list + detail, standard window |
| **Activity Monitor** | Dense monospace metrics for power users |
| **GitHub PR checks** | Pass/fail/risk as evidence, not narrative |

---

## Bottom line

The **layout skeleton is right** (split view, resizable window, jump on Return).
The biggest gap is **aligning hierarchy with the product promise**: ranked trust
inbox, one status, one action, evidence below the fold.

The design system should be a small **semantic token layer + 8–10 components**,
monospaced for data and SF Pro for judgment calls — not a large component
library or marketing-site aesthetic.
