# Design

Hermex's look: **calm chat, colorful objects.** The reading surface stays quiet and neutral so long agent output is easy on the eyes. Color lives on discrete *things*: a tool step, a goal, a Brain page, an approval. Each kind of thing always wears the same color, the same paper it wears in the Daily Brief, so the Brief, Goals, and chat read as one app.

## Principles

1. **Neutral ground, colored objects.** Canvases, bubbles, and body text use the `hx*` neutrals. Color appears only on an object you could tap, link, or act on.
2. **A color means a kind.** Color is assigned by object type, never by sequence, position, or status. If two things share a color, they are the same kind of thing.
3. **Whole cards are papers; small objects glow.** A card that fills the screen (a Brief card, the Goal hero) is a light paper in both appearances, like an index card on a dark desk. Everything smaller on the app's own canvas (chips, request cards, drawer icons, log icons) uses the paper's **glow**: its hue on a faint wash, deep in light mode and bright in dark mode. Pale pastel bits read as white specks on a dark screen; a glow keeps its color at any size.
4. **Nous blue means interactive.** `Color.accentColor` (`#0053FD` / `#4A84FE`) is the tint for controls, the send button, links, and "Atlas is working". It is never an object color.
5. **Status colors stay semantic.** `hxSuccess`, `hxWarning`, and `hxDanger` mark outcomes (done, needs care, failed). They are not object colors.

## Color

### Neutrals (`Config/HermexColors.swift`)

| Token | Light | Dark | Use |
|---|---|---|---|
| `hxCanvas` | `#F8FAFF` | `#0D1117` | Every screen background, chat included (navy-tinted, never pure black) |
| `hxSurface` | `#FFFFFF` | `#161B22` | Rows, composer, the opaque base under floating cards |
| `hxTextPrimary` | `#17171A` | `#E6EDF3` | Body text |
| `hxTextSecondary` | `#666678` | `#7D8590` | Metadata |
| `hxSeparator` | `#D0D7DE` | `#30363D` | Hairlines |
| `hxUserBubble` | `#DAE7FD` | `#17243A` | User messages |

Prefer `hx*` over UIKit system colors (`systemBackground`, `secondarySystemBackground`, `.label`, `.separator`) in new and touched code.

### Papers (`HermexPaper`, `Config/HermexColors.swift`)

Each paper has two renderings:

- **Paper** (`paper`, `ink`, `secondaryInk` = ink at 0.75): the bright card, identical in both appearances. Draw it in light appearance so system text stays legible on it. Used by `DeckPalette` (Brief cards) and `GoalPaper` (Goal hero).
- **Glow** (`glow`, `wash`, `edge`, `onGlow`): for small objects on `hxCanvas`. `glow` is the text and symbol color, `wash` the hue at 16%, `edge` a 0.5 pt hairline in the hue (so a wash keeps its edge on the light canvas), `onGlow` the text on a solid `glow` fill. Glow text clears 4.5:1 on its wash in both appearances (`DesignSystemTests` checks every paper).

| Paper | Paper / ink | Glow light / dark | Brief card |
|---|---|---|---|
| `opener` | `#FFF1DC` / `#3A2410` | `#8A5200` / `#F6C77E` | Today |
| `quote` | `#D9E8FF` / `#0E3264` | `#1D4FB8` / `#8DB4FF` | Quote |
| `book` | `#FFDCE6` / `#6B1534` | `#A8335E` / `#F59AB8` | Book highlight |
| `wiki` | `#D3F2E2` / `#0E4A33` | `#137049` / `#5FD3A0` | From your wiki |
| `reading` | `#FFE4D1` / `#5A2A0C` | `#9A4410` / `#F5A37A` | From your reading |
| `notes` | `#E6DCFF` / `#33197A` | `#5B3FC4` / `#B39DFF` | From your notes |
| `video` | `#D2F0F4` / `#0B4650` | `#0E6D7A` / `#5CCFE0` | Video |
| `past` | `#FFEFC2` / `#4E3A00` | `#7A5C00` / `#E8C55A` | On this day |
| `advisor` | `#E4EEF6` / `#14324A` | `#2E5878` / `#9DBEDD` | Check-in |
| `plain` | `#F4F0E8` / `#2A2A28` | `#5E5646` / `#D6CDBB` | Library, follow-ups |

### The object key

Named in `Config/HermexStyle.swift`; `HermexPaper.forTool(_:)` maps tool kinds.

| Object | Name | Paper |
|---|---|---|
| Approval, clarification, anything waiting on the user | `.request` | `opener` |
| Brain or wiki page (`brain://` citation) | `.knowledge` | `wiki` |
| File read, written, listed, or searched (grep, find); file attachments | `.file` | `notes` |
| Web search or fetch | `.web` | `video` |
| Memory or skill | `.recall` | `advisor` |
| Shell, code, delegation, everything else; chat source badges | `.tool` | `plain` |
| Goal | the goal's own paper (`GoalPaper`) | any |
| Drawer sections: Daily Brief, Brain, Goals | `opener`, `.knowledge`, `book` | |

Add a new kind of object here and in the code together. A failed tool step keeps its color and adds an `hxDanger` mark; the color never turns red.

## Components

- **`HXChip`** (`Config/HermexStyle.swift`): the one chip. A capsule with the wash, edge, and glow, an optional symbol, a label (caption medium, one line, middle-truncated), and an optional trailing mark. Tool calls, run counts, Brain citations, and `+N` all use it. Lay chips out with `FlowRow`, which wraps and offers an over-wide chip the row's width so large text truncates instead of overflowing.
- **Live run.** While Atlas works, each call is a `ToolCallChip`: its target (cut at 24 characters), an ellipsis while running, a red `xmark` after failing. The newest four show; older calls sit behind `+N`.
- **Finished run.** One chip per kind of tool with its count, in the order each kind first ran ("3 commands", "2 searches"), plus a red `xmark` on a kind with failures. Tapping the row opens the full log; "Expand Tools by Default" starts it open. The row is at least 44 pt tall.
- **Tool log rows.** Each row's icon sits on a 20 pt tile in its kind's wash and glow, so the log matches the chip that opened it.
- **Brain citations** (`BrainCitationChips`). Each Brain page a reply links (up to three) gets a knowledge chip under the reply, opening through the same router as the inline link. Hit areas extend 7 pt past the chip.
- **Request cards.** Approvals and clarifications use `.glowSurface(.request, cornerRadius:, opaque: true)`: the wash over `hxSurface` (opaque because they float over transcript text), the edge, and the paper in `\.hxPaper`. Their title and symbol take the glow. Primary decision buttons fill with `glow` and `onGlow` text; secondary ones use the wash and edge.
- **File attachments.** A tile on `.glowSurface(.file, …)`: glow icon and extension, neutral file name.
- **Drawer.** Sections with their own paper show their icon on a 30 pt glow tile; the rest stay neutral so the colored ones stand out.
- **Hero paper.** A Daily Brief card or Goal hero: light paper, radius `xl`, the `paper` shadow. The only lifted paper.

## Shape

One radius scale, as `HXRadius`:

| Token | pt | Use |
|---|---|---|
| `xs` | 6 | Inline code, thumbnails, log icon tiles |
| `sm` | 10 | Rows, attachment tiles, buttons, drawer icon tiles |
| `md` | 14 | Inset blocks, choice buttons |
| `lg` | 18 | Section cards, action cards (approval overlay, Bot request card) |
| `xl` | 28 | Hero papers |

Use `.continuous` corners everywhere. Chips are capsules. The composer keeps its own geometry (`ChatComposerMetrics`: a pill, and 26 pt when expanded), and the clarification card that docks on it uses the same 26 so the two read as one surface.

## Elevation

Shadows, as `.hxShadow(_:)`:

- **`paper`**: black at 0.08, radius 14, y 6, for hero papers. **`stacked`** (0.06, 10, y 4) for deck cards waiting behind the top one.
- **`float`**: black at 0.12 (light) or 0.28 (dark), radius 14, y 6, for the composer and floating glass controls.
- **`modal`**: black at 0.22, radius 18, y 12, for a card over a dimmed screen (the approval overlay).

Everything inline in chat is flat.

## Type

- SF Pro through `AppFont` and Dynamic Type styles. No `.system(size:)` on text. The one exception: an SF Symbol inside a fixed-size control (a round button, a media control) keeps a fixed point size, since a growing glyph would break the control.
- Serif (New York) through `AppFont.serif` only, for Brief and Goal display text and quoted words a person saved. Chat content stays SF.

## Motion

A live chip fades in as its call arrives (off for replays and under Reduce Motion), and opening the log uses the chat disclosure motion. Nothing loops or repaints continuously.

## Decisions and exceptions

- **Links stay Nous blue**, `brain://` ones included: a link is a control (principle 4). The reply's Brain chips carry the Brain color. Coloring individual inline links would also mean replacing the Markdown renderer's link style.
- **Brain covers** derive their ramps from the papers (`BrainStyle.coverPaletteValues`): light is the paper, its hue, its light glow; dark is the hue at 16% and 38% over the navy canvas, then its dark glow.
- **Bot avatar colors** (`BotAvatarColor.palette`) are server data shared with Hermes Desktop, not app chrome, so they keep Desktop's hexes.
- **Project colors** come from the server (`Color(hexString:)`) and are the user's, not the system's.
- **Translucent fills** (`systemFill` family), `tertiaryLabel`, and `placeholderText` stay UIKit: there is no `hx` equivalent and they adapt correctly.
