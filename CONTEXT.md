# Hermex Domain

Canonical language for Hermex concepts that need consistent names across the product, planning, and support.

## Servers

**Webui server**:
A configured `hermes-webui` server. Hermex signs in to it with its password and cookie, and it opens on the session list.
_Avoid_: server (alone, when the kind matters), WebUI

**Hermes server**:
A configured Hermes dashboard that Hermex reaches directly. Its sign-in is its own Hermes connection, and it opens on the Bots inbox.
_Avoid_: Hermes connection (that is the sign-in), bot server

**Connection mode**:
How this iPhone reaches the server, chosen in the connect form: Same Wi-Fi, Private network or Cloudflare Tunnel. It changes only the form's placeholder, help and header rows, and is not saved.
_Avoid_: network type, connection type

## Kanban

**Kanban**:
The Hermex destination for organizing and operating server-backed work across workflow states.
_Avoid_: Boards, Tasks

**Board**:
A named container of Kanban work and its workflow states.
_Avoid_: Kanban, project

**Card**:
An individual unit of work on a Board.
_Avoid_: Task, Kanban task, work item

**Status**:
The workflow state of a Card: Triage, To Do, Ready, Running, Blocked, Done, or Archived.
_Avoid_: Column, lane, stage

**Column**:
A visual grouping of Cards that share a Status.
_Avoid_: Status, lane

**Lane**:
An optional visual grouping of Cards by Profile, including an Unassigned lane.
_Avoid_: Status, column

**Profile**:
A Hermes agent configuration that can perform Card work.
_Avoid_: Assignee, user, agent

**Assignment**:
The relationship between a Card and the Profile selected to perform it. A Card without that relationship is Unassigned.
_Avoid_: Ownership

**Prerequisite**:
A Card that must precede another Card in a dependency relationship.
_Avoid_: Parent, blocker

**Dependent**:
A Card that relies on a Prerequisite.
_Avoid_: Child, blocked card

**Dispatcher**:
The server operation that claims eligible Ready Cards and may launch worker processes.
_Avoid_: Runner, launcher

**Preview Dispatch**:
A dry run that reports expected Dispatcher outcomes without launching workers.
_Avoid_: Test run, simulate dispatcher

**Run Dispatcher**:
The action that invokes the Dispatcher and may launch workers or consume API budget.
_Avoid_: Dispatch, run

**Dispatch Run**:
The recorded execution of the Dispatcher.
_Avoid_: Run, dispatcher result

**Archived**:
The Status of a Card removed from the active workflow.
_Avoid_: Deleted

**Archive Card**:
The action that changes a Card's Status to Archived.
_Avoid_: Delete Card, remove Card

**Archive Board**:
The action that removes a non-default Board from active use. Hermex cannot restore an archived Board in-app.
_Avoid_: Delete Board, remove Board

**Bulk Action**:
A named operation applied to multiple selected Cards.
_Avoid_: Bulk update, batch operation

**Select Cards**:
The mode for choosing Cards before applying a Bulk Action.
_Avoid_: Multi-select, bulk mode

## Brain

**Brain module**:
One of the Brain's five sections over the server's second-brain vault: People, Wiki, Articles, Journal or Highlights. Each opens a list of its Brain items.
_Avoid_: Brain section, category, collection

**Brain item**:
One entry in a Brain module, identified by its module and vault id: a person, wiki page, article, journal day, book or video. It opens in the reader (books in the highlights view).
_Avoid_: note, document, entry, page (for the item itself)

**Bite**:
One reviewable piece of a saved Brain item: a key idea or takeaway from an article, a quote, or a book highlight. A Bite is a card in the Review and opens its Brain item (a key idea opens its article with that idea expanded).
_Avoid_: flashcard, snippet, excerpt

**Review**:
The Brain's daily deck of Bites, opened from Today on the Brain home: ten cards you swipe through, then a summary with "Ten more" for another batch. Your position is kept per server and day.
_Avoid_: quiz, rediscover, feed

**Hub**:
A wiki page where many other wiki pages meet (at least five link to or from it), found from the vault's links rather than curated. A Brain item's parent hub shows as its trail, and the reader's pager steps through the hub's pages. Front matter `up:` (or `parent:`) sets the parent by hand.
_Avoid_: map of content, MOC, category

**Encounter**:
One dated meeting with a person, logged on their Brain item under a `###` date heading (an optional ` — title` after the date) and parsed by the server into the person page's timeline, newest first.
_Avoid_: interaction, touchpoint, log entry

**Due for a catch-up**:
A person whose last visit is well past their own rhythm: more than twice their cadence (the median gap between their last six visits, days within three days of each other counting as one visit; 90 days with fewer than three) and at least three weeks. Contacts marked `Contact Frequency: Infrequent` (or Low) are never due; Annual ones fall back to half a year. The first section of the People list.
_Avoid_: overdue, stale contact, relationship pulse (the older vault script this replaces in the app)

**Unlinked mention**:
A Brain item whose text names another item without a `[[link]]` to it. The reader lists them under the item's linked mentions.
_Avoid_: missing link, implicit backlink

## Daily Deck

**Seal**:
Filing a v2 weekly review deck. Its close card reads "Seal the week", the server writes the Week record, and the app lands on the week's page. Sealing again after an edit rewrites the record.
_Avoid_: file (for a v2 weekly review), submit, close the week

**Week record**:
A sealed week as the vault keeps it in `weekly-checkins/`: `<Sunday>-week-ending.json` for the app and a markdown page beside it, plus an optional photo in `weekly-checkins/photos/<Sunday>.jpg`. Opens as the week page, from the calendar or the year of weeks.
_Avoid_: check-in, weekly summary, journal entry

## Chat

**Fork**:
A chat created from another chat's history by Fork From Here or `/branch` (`/api/session/branch`). The server marks it `session_source: fork` with a `parent_session_id`, and Hermex shows a "Forked from" row that opens the parent. Agent child sessions (subagents, cron, CLI `/new`) also carry a parent but are not Forks.
_Avoid_: Branch (for the chat), child session

## Voice calls

**Call memories**:
The notes and people Atlas drew on for one call turn: the server's `context_sources` for the run, plus what its finished tool calls read (a `brain ask` answer's citations, a `crm show`, a file read or search). At most six, reset when the next turn is sent.
_Avoid_: sources (alone, in product copy), citations

**Constellation**:
The call screen's starfield: a 3D cloud of stars that flocks out while Atlas thinks, lights each call memory as a node, and lands in that turn's shape when the reply starts. Each turn's memories get a fresh random layout.
_Avoid_: orb (the earlier visual), graph

