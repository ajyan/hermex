# Design

Hermex's look: **calm chat, colorful objects.** The reading surface stays quiet and neutral so long agent output is easy on the eyes. Color lives on discrete *things*: a tool step, a goal, a Brain page, an approval. Each kind of thing always wears the same paper, the same one it wears in the Daily Brief, so the brief, Goals, and chat read as one app.

## Principles

1. **Neutral ground, paper objects.** Canvases, bubbles, and body text use the `hx*` neutrals. Paper color appears only on an object you could tap, link, or act on.
2. **A color means a kind.** Paper is assigned by object type, never by sequence, position, or status. If two things share a paper, they are the same kind of thing.
3. **Papers are papers in any light.** Paper and ink values are the same in light and dark appearance, like index cards on a dark desk. Content on a paper renders with `.environment(\.colorScheme, .light)`.
4. **Nous blue means interactive.** `Color.accentColor` (`#0053FD` / `#4A84FE`) is the tint for controls, the send button, links, and "Atlas is working". It is never a paper.
5. **Status colors stay semantic.** `hxSuccess`, `hxWarning`, and `hxDanger` mark outcomes (done, needs care, failed). They are not object colors.

## Color

### Neutrals (existing, `Config/HermexColors.swift`)

| Token | Light | Dark | Use |
|---|---|---|---|
| `hxCanvas` | `#F8FAFF` | `#0D1117` | Screen background |
| `hxSurface` | `#FFFFFF` | `#161B22` | Rows, composer, neutral cards |
| `hxTextPrimary` | `#17171A` | `#E6EDF3` | Body text |
| `hxTextSecondary` | `#666678` | `#7D8590` | Metadata, run summaries |
| `hxSeparator` | `#D0D7DE` | `#30363D` | Hairlines |
| `hxUserBubble` | `#DAE7FD` | `#17243A` | User messages |

Prefer `hx*` over UIKit system colors (`secondarySystemBackground`, `.label`, `.separator`) in new and touched code.

### Papers (`HermexPaper`, `Config/HermexColors.swift`)

`DeckPalette` and `GoalPaper` read these; draw on one with `.paperSurface(_:cornerRadius:)` (`Config/HermexStyle.swift`), which also forces light appearance and puts the paper in `\.hxPaper` so decision buttons and submit controls take its ink.

| Paper | Paper | Ink | Brief card |
|---|---|---|---|
| `opener` | `#FFF1DC` | `#3A2410` | Today |
| `quote` | `#D9E8FF` | `#0E3264` | Quote |
| `book` | `#FFDCE6` | `#6B1534` | Book highlight |
| `wiki` | `#D3F2E2` | `#0E4A33` | From your wiki |
| `reading` | `#FFE4D1` | `#5A2A0C` | From your reading |
| `notes` | `#E6DCFF` | `#33197A` | From your notes |
| `video` | `#D2F0F4` | `#0B4650` | Video |
| `past` | `#FFEFC2` | `#4E3A00` | On this day |
| `advisor` | `#E4EEF6` | `#14324A` | Check-in |
| `plain` | `#F4F0E8` | `#2A2A28` | Library, follow-ups |

Every pair keeps ink-on-paper body text above 7:1. Secondary text on a paper is the ink at 0.7 opacity, never `hxTextSecondary`.

### The object key (chat and drawer)

Named in `HermexStyle.swift`; `HermexPaper.forTool(_:)` maps tool kinds.

| Object | Name | Paper |
|---|---|---|
| Approval, clarification, anything waiting on the user | `.request` | `opener` |
| Brain or wiki page (`brain://` citation), a search | `.knowledge` | `wiki` |
| File read, written, or listed; file attachments | `.file` | `notes` |
| Web search or fetch | `.web` | `video` |
| Memory or skill | `.recall` | `advisor` |
| Shell, code, delegation, everything else; chat source badges | `.tool` | `plain` |
| Goal | the goal's own paper (`GoalPaper`) | any |

A failed tool step keeps its paper and adds an `hxDanger` symbol and label. The paper never turns red.

## Components

- **Tool chip** (`ToolCallChip`). A capsule in the call's paper: symbol, target (cut at 24 characters), and an ellipsis while running or a red `xmark` after failing. A live group shows its newest four, with older calls behind a `+N` chip on `hxSurface`.
- **Run summary.** A settled group folds to one `hxTextSecondary` line: up to three paper dots, the call itself or `N steps`, a red `N failed` when any did, and a chevron. Tapping chips or the summary opens the full log; "Expand Tools by Default" starts it open.
- **Object card** (`BrainCitationCards`). Each Brain page a reply links (up to three) gets a `knowledge` card under it: radius `md`, symbol, ink title, ink 0.7 module name. It opens through the same router as the inline link.
- **Action card.** An approval or clarification: `request` paper. Primary decision buttons fill with ink and paper-colored text; secondary ones wash in ink at 0.08.
- **Hero paper.** A Daily Brief card or Goal hero: radius `xl` with the `paper` shadow. It is the only lifted paper.

## Shape

One radius scale, as `HXRadius` in `Config/`:

| Token | pt | Use |
|---|---|---|
| `xs` | 6 | Inline code, thumbnails, small tiles |
| `sm` | 10 | Rows, attachment tiles, tool-log rows |
| `md` | 14 | Object cards, chips' containers, quote chips |
| `lg` | 18 | Section cards, action cards, the expanded composer |
| `xl` | 28 | Hero papers (Deck cards, the Goal hero) |

Use `.continuous` corners everywhere. Capsules are capsules, not a large radius.

## Elevation

Shadows, as `.hxShadow(_:)`:

- **`paper`**: black at 0.08, radius 14, y 6. Only for hero papers. **`stacked`** (0.06, radius 10, y 4) for deck cards waiting behind the top one.
- **`float`**: black at 0.12 (light) or 0.28 (dark), radius 14, y 6. Only for the composer and floating glass controls.

Everything inline in chat is flat.

## Type

- SF Pro through `AppFont` and Dynamic Type styles. No `.system(size:)` in new or touched code. Tool rows move to `.footnote` and `.caption`.
- Serif (New York) through `AppFont.serif` only, for brief and goal display text and quoted words a person saved. Chat content stays SF.

## Motion

A live chip fades in as its call arrives (off for replays and under Reduce Motion), and opening the log uses the chat disclosure motion. Nothing loops or repaints continuously.

## Still to migrate

New and touched code uses the tokens; older one-offs move when their screen is next touched: chat's inner radii (8, 9, 12, 16, 20), Settings cards and rows, Kanban and Tasks status tints, `BotProfileAppearance` hexes, and the Voice Call orb's own blue.
