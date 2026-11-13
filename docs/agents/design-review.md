# Keeping UI in sync with DESIGN.md

New screens drift from `DESIGN.md` one small choice at a time: a blue button on a colored card, a gray caption, a bar where a dot belongs. Three layers catch drift where it is written, so nobody has to ask for a design review:

1. **The components do it for you.** A glow or wash card (`HXCard`, `.hxCardSurface`, `.glowSurface`) sets its paper as the tint and as `\.hxPaper`, so the controls inside take the card's color. Supporting text uses `.foregroundStyle(.hxSecondary)`, which is the card's `secondaryInk` on a card and `hxTextSecondary` everywhere else. Don't name `Color.accentColor` or `Color.hxTextSecondary` for these; the defaults are right.
2. **The commit hook blocks new drift.** `.githooks/pre-commit` runs `scripts/check-design-drift --staged` on the Swift lines a commit adds and refuses the commit when any break a rule. It is on once per clone: `git config core.hooksPath .githooks`. `scripts/check-design-drift --changed` checks a branch the same way. A documented exception (DESIGN.md § Decisions and exceptions) ends its line with `// design-drift: allow <why>`.
3. **The object key is a test.** `HermesMobileTests/ObjectKeyTests.swift` asserts the paper each kind of thing wears. A new kind of object goes into DESIGN.md's object key, `HermexStyle.swift` and `ObjectKeyTests` in the same change.

## Before committing UI work

After the change builds and its tests pass, and before the commit:

1. Run `scripts/check-design-drift --changed` and fix what it reports.
2. Run a design review of the diff in a subagent. Give it this brief, not your conclusions:

   > Review only this diff (`git diff $(git merge-base HEAD origin/master)` plus uncommitted changes) against DESIGN.md; read DESIGN.md in full first. Report what the drift script can't see: an object in a paper other than the object key's; a control on a glow or wash card forced to Nous blue, or a control on a neutral surface in a paper; supporting text on a card not in `.hxSecondary`/`secondaryInk`; faded text in a hue; numbers drawn as bars or bare counts instead of dots and pips; serif on anything but saved words; a hand-built card, chip, capsule, header, divider or failure instead of `HXCard`, `HXChip`, `ChatDecisionButtonStyle`, `HXSectionHeader`, `hxNavigationTitle`, `HXFailedView`; motion not from `HXMotion` or ignoring Reduce Motion; a screen whose anatomy differs from DESIGN.md's description of it. For each: file:line, the rule (quote DESIGN.md), the fix. Check DESIGN.md § Decisions and exceptions before reporting.

3. Fix what it finds. When the code is right and DESIGN.md is stale, update DESIGN.md in the same change.
4. Note it in the PR body: "Design review: N found, fixed" (or what was left and why).
