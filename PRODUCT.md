# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users
One user: Andrew, a software engineer, driving his personal Hermes agent ("Atlas") from his iPhone 15 Pro. Typical moments are away from the Mac: kicking off or steering an agent run, checking what Atlas did, answering an approval or clarification, and reading results.

## Product Purpose
A personal fork of Hermex: a native SwiftUI thin client for a self-hosted hermes-webui server. All state (sessions, projects, tasks, skills, memory) lives on the server; the app renders and drives it. Success means the phone feels as fluid as the Claude iOS app for chatting with Atlas, while keeping the Hermes-specific controls Andrew actually uses.

## Positioning
Claude-app ergonomics on top of a self-hosted agent: Andrew's own agent, tools, memory, and history, reachable from anywhere over Tailscale, with no third-party chat service in between.

## Operating Context
- Server: hermes-webui on the Mac mini, reached at `https://andrews-mac-mini.tailc3b50d.ts.net` (Tailscale serve, tailnet only); `https://localhost:8787` from the simulator.
- Sessions include Hermes chats plus read-only imported Claude Code sessions.
- Agent runs stream; runs can request approvals and clarifications mid-stream.
- Push notifications are unavailable while the app is signed with a free personal team.

## Capabilities and Constraints
- Fork diverges freely from upstream (uzairansaruzi/hermex); upstream merges are not a goal.
- Single user; no onboarding polish, multi-user, or localization work required.
- Primary navigation follows the Claude iOS app: chat-first, side drawer for chats and search, new-chat in the top bar, agent/model picker in the title, bottom-docked composer.
- Kept one tap away in the drawer: Projects, Tasks/Kanban. Skills, Memory, Usage/Insights, Bots, and profiles move into Settings or secondary screens.
- Existing functionality (streaming, approvals, clarifications, attachments, voice, share extension, live activities) must keep working.
- Undecided: whether imported Claude Code sessions stay in the main chat list or get their own filter.

## Brand Commitments
- Theme: Hermes "Nous blue", matching the Hermes desktop app's default theme (accent `#0053FD` light / `#4A84FE` dark). Binding choice by the user.

## Evidence on Hand
- Live server data (real sessions) for testing; no fabricated content needed.
- Hermes desktop theme source: `/Applications/Hermes.app/Contents/Resources/app.asar.unpacked/dist/assets/i18n-*.js` (`nous` theme `colors` / `darkColors`).

## Product Principles
1. Chat is the home screen; everything else is one gesture away, not stacked above it.
2. The agent's work should be legible: tool calls, approvals, and run state are visible without noise.
3. Fast to resume: the most recent chat and a new chat are always one tap away.
4. Native over custom: prefer iOS system behaviors (sheets, drawers, swipe actions, Dynamic Type).
