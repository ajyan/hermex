# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## This fork

`AGENTS.md` above is the upstream maintainer's file, written from Uzair's point of view. This checkout is Andrew's fork, and the notes below take precedence where they differ.

- **Remotes.** `origin` is `ajyan/hermex`, and every branch, PR, and issue goes there (`gh pr create --repo ajyan/hermex`, base `master`). `upstream` (`uzairansaruzi/hermex`) is fetch-only: merge from it to sync, never push, open PRs, or file issues there. Read `AGENTS.md`'s "issue", "PR", and "file it upstream" guidance as targeting the fork.
- **Branch TestFlight and the `6GYD9C9N6R` team are Uzair's.** For device installs, use Xcode or `xcodebuild` + `devicectl` with a personal team.
- **The server is a fork too.** The live `hermes-webui` runs a local fork with extra routes (for example `api/vault_goals.py` for Goals and `api/tutor*.py` for Interview Prep). `.codex-tmp/hermes-webui` (upstream) does not have them, so verify those contracts against the fork's source or by curling the live server.
- **Fork-only features** live in `HermesMobile/Features/`: `DailyDeck` (the daily brief, read from workspace files), `Goals`, `Body` (workout tracker, Sleep link, Baki the coach), `Brain` (including `Brain/Prep/` for Interview Prep), `VoiceCall`, and `Activity`.
- **Design language.** [DESIGN.md](DESIGN.md) defines the "calm chat, colorful objects" direction: neutral `hx*` surfaces, a fixed paper color per object kind, and accent blue only for controls. Read it before UI work.
- **Bots.** [docs/agents/bots.md](docs/agents/bots.md) covers the direct-Hermes Bot connection.
- **Disk.** A simulator made for one piece of work is named `iPhone 17 (<slug>)`, a lowercase slug, so the vault watcher can delete it once it has sat shut down for 7 days; delete it yourself when the work lands. Phone installs reuse `build/device-dd`, and compile checks reuse one `-derivedDataPath`, never a new dated folder per run.

## Build quick reference

```bash
xcodebuildmcp simulator build-and-run --output jsonl
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17' build
scripts/test-sim <udid> --only HermesMobileTests/<TestClass>
```

`DEVELOPMENT.md` has the details (simulator assignment, signing in, raw `xcodebuild` fallback).
