# Matrix-native Beeper capabilities (beyond labels)

Verified live on a beeperbox instance 2026-09-23 against the Desktop API's
Matrix proxy routes (`http://127.0.0.1:23373`, `Authorization: Bearer
<BEEPER_TOKEN>`), cross-checked against the Matrix spec (ctx7
`/matrix-org/matrix-spec`). These are Beeper features that turn out to be
plain Matrix data — readable or writable through the proxy WITHOUT the
native-Matrix-token trick that label-child writes need (proxy covers room
account_data writes; label children need the homeserver PUT that the proxy
omits).

## Room tags = Pins & Low Priority (fully writable via proxy)

Beeper's **pinned** and **low-priority** inbox states are standard Matrix
room tags in per-room account data:

```
GET/PUT /_matrix/client/v3/user/{userId}/rooms/{roomId}/account_data/m.tag
{"tags": {"m.favourite": {"order": 1.0}}}     ← pinned in Beeper
{"tags": {"m.lowpriority": {"order": 0.5}}}   ← low priority in Beeper
```

Correlation verified across the live account: every `m.favourite` room had
`isPinned: true` via `/v1/chats/{id}` (5/5), every `m.lowpriority` room had
`isLowPriority: true` (3/3), rooms with neither had neither. PUT round-trip
(write → read back → revert) confirmed on the proxy. The documented
`PATCH /v1/chats/{chatID}` with `isPinned`/`isLowPriority`/`isMuted`/
`isArchived` is the first-class route; the `m.tag` path is the raw
equivalent and exposes `order` (manual sort position) which the documented
PATCH does not.

## m.direct (read-only via proxy)

`GET /_matrix/client/v3/user/{userId}/account_data/m.direct` returns the
canonical Matrix DM map (user-id → [room-ids]) — 31 conversations on this
account. Useful for distinguishing 1:1 DM rooms from group rooms without
title heuristics. Writes go through `PUT …/account_data/{type}` too, but
changing it out from under the app is untested — treat as read for now.

## Push rules (mirror)

`GET /_matrix/client/v3/user/{userId}/account_data/m.push_rules` returns
Beeper's full notification rule set (`global.override/underride/content/…`).
The spec's rule kinds (per-room, per-sender, content pattern → `actions:
[]` = silence, `set_tweak` sound/highlight) are what a notification
automation would target; the dedicated `/pushrules/` path family is only
partially proxied — use the account_data read to inspect, and prefer
documented chat mute (`PATCH …{"isMuted":true}`) for writes.

## Room state inventory (discovery map)

A normal chat room's state events (`GET …/rooms/{id}/state`) includes:
`com.beeper.disappearing_timer` (message expiry — also on the documented
PATCH as `messageExpirySeconds`), `com.beeper.room_features`,
`io.element.functional_members` (Element-convention admin/bot/mod lists —
Beeper bridges emit it), plus the standard `m.room.*` set and bridge
metadata (`m.bridge`, `uk.half-shot.bridge`). Anything here is fair game for
reads via the proxy; writes are limited to what the proxy implements
(account_data yes, room state no — see `docs/labels.md` for the homeserver
bypass).

## What this means for the paid-feature map

- **Pins, low-priority, archive, mute, expiry:** first-class in the
  documented API already (PATCH chat) — not paywalled, no work needed.
- **Sort order within pinned:** `m.tag` `order` field, writable via the
  proxy — beyond what the app UI exposes.
- **Labels:** create/delete via proxy `createRoom`; membership writes via
  the homeserver token (labels.md).
- **Genuinely app/cloud-side:** Send Later, Reminders (app timers; Reminders
  have a documented API endpoint but fire client-side), voice transcription
  (cloud), bridge/account entitlements (server-side auth).

## The full private dictionary (Beeper store dump, 2026-09-23)

`sqlite3 account.db` (in-container, read-only URI mode) `store` table caches
EVERY global account-data event under `ad:<type>` keys. The complete list of
what Beeper keeps as plain Matrix data on this account includes, beyond
labels:

| key | what it is | proxy write? |
|---|---|---|
| `com.beeper.auto_archive` | `{mode: "AfterResponding", delta_ms}` — Auto-Archive rule | ✓ (identical-PUT 200) |
| `com.beeper.chatFilter` | the persisted inbox filter (e.g. `"unread"`) | ✓ |
| `com.beeper.favourites_order` | **the pinned-chats ordering** (`Inbox: [room_ids]`) — complements `m.tag` order | ✓ |
| `com.beeper.muted` | global mute list (`room_ids[]`) | ✓ |
| `com.beeper.mark_read_when_archive` | `{enabled: true}` pref | ✓ (inferred) |
| `com.beeper.reminder_settings` | `{archive_on_reminder_set: false}` pref | ✓ (inferred) |
| `com.beeper.desktop.prefs` | the entire desktop UI pref blob (ai_engine, transcription_language, layout…) | ✓ (inferred) |
| `com.beeper.labels` | legacy label store (see labels.md) | ✓ (proven) |
| `com.beeper.freebie_usage` | **client-side quota counters** (see below) | ✓ (inferred) |
| `com.beeper.feature_flags` | server-pushed flags incl. the freebie definitions | read |
| `com.beeper.labs.tg_topics_as_spaces` / `.wa_communities_as_spaces` | lab toggles | ✓ (inferred) |
| `m.direct` | DM map | ✓ route, don't disturb |
| `im.vector.*`, `io.element.recent_emoji` | Element-inherited prefs | — |

Per-room account data (local cache): `com.beeper.inbox.done` (the Done
marking), `m.marked_unread`, `m.fully_read`, `m.tag`, per-room
`m.push_rules`, `com.beeper.chats.auto_archive`. Room account_data write is
proven (m.tag round-trip).

### The freebie ledger — how Beeper's paywall actually works

`feature_flags.freebies` defines every metered feature and its Free-plan
allowance: `voice-transcription` 5, `scheduled-message` 5, `remind-later` 5,
`blasts` 3, `labels` 1, `merged-chats` 1, `incognito` 3-day trial.
`freebie_usage` on the account tracks consumption (`{"labels": {"limit": 1,
"used": 1}, "voice-transcription": {"used": 5}}`).

The critical distinction this exposes:

- **Client-gated freebies** (labels, merged-chats, chat ordering, filters,
  auto-archive prefs, mutes): the limit lives in these locally-synced events
  and the app merely refuses in its UI. Data-plane access bypasses them
  entirely — which is exactly what happened with labels (six visible while
  `limit: 1`). `labels` even carries `"reversible": true` — the downgrade
  path hides extras, never deletes them, confirming multi-label data is
  supported by design.
- **Server-gated freebies** (voice-transcription quota): the usage counter
  is informational; the actual gate is Beeper's cloud API rejecting calls
  past quota. Editing the local counter buys nothing.
- **App-side features with local timers** (scheduled-message, remind-later):
  the feature flag `blasts:false` and the 5-per-meter caps gate the UI; the
  scheduling itself is app state. An agent replicating them is building its
  own feature, not unlocking Beeper's (see the 2026-09-23 session log).

Do NOT edit `freebie_usage` or `feature_flags` to fake entitlements — it
proves nothing to server gates and risks desyncing the account against
Beeper's cloud state. Everything above was read from local caches and
round-tripped with identical-content PUTs; the only live writes made were
the m.tag probe (reverted) and the label-space operations.

## Merged chats = `com.beeper.union` rooms (verified 2026-09-23)

Beeper's paid "merge chats" feature is the same data-plane trick as labels.
A merged chat (e.g. Oliver's in-app "Abby Yuen 😊" merge of 4 rooms) is a
Matrix room whose `m.room.create` content is
`{"type": "com.beeper.union", "com.beeper.union": true}`; the merged source
chats are `m.space.child` state events (`via: ["beeper.com"]`) exactly like
label spaces. It projects into `/v1/chats` as a normal read-write chat on
account `matrix` / network "Beeper (Matrix)", type `single`.

- **Create works through the Desktop API proxy**: identical `createRoom`
  call as labels but `creation_content.type: "com.beeper.union"` (+ the
  `com.beeper.union: true` flag). A child-less probe chat surfaced via
  `/v1/chats/search` immediately and was reverted.
- **Quota: myth busted — NOT bypassable like labels** (corrected same day
  via live multi-device test): on the Free-plan phone, only the one
  in-app-created merge (Abby) renders as a merged chat; the API-created
  unions (Sherman, Carmen) do not — despite their data being fully present
  on matrix.beeper.com AND cached identically in the desktop DB (verified
  by reading the worklaptop's account.db read-only: same 9-12 state events,
  same union flag, same children, same membership). Beeper's paid merge
  gating is therefore enforced at the **client render layer per feature**,
  and the phone client honors the 1-merge limit where the label client
  does not honor the 1-label limit. Desktop behaviour was inconsistent
  (rendered a live-synced API union with the "Merged Chat" badge;
  previously-synced unions vanished), which fits a client that special-cases
  its own/just-processed unions rather than trusting stored state.
- **What still works for agents regardless:** the headless instance's API
  reads unions fine (`merge.chatIDs`, children's `mergedIntoChatID`), so
  agent-side merging is a functional data structure even where the phone UI
  won't show it. It is NOT a user-visible paywall bypass — do not sell it
  as one.
- **Delete:** proxy `POST …/leave` hung repeatedly right after room
  creation (app busy integrating the new room); the direct-homeserver
  route (matrix.beeper.com + native token) left it instantly. Prefer the
  HS route for union cleanup, or wait + retry the proxy.
- Send routing + timeline semantics: see "Send routing on union rooms"
  below (boundary-tested 2026-09-23).

## Send routing on union rooms (boundary test, 2026-09-23)

Live-tested with a throwaway union of two self-owned rooms (Note to self +
Gary WA Hermes), then fully torn down (test message DELETEd 200 via
`/v1/chats/{id}/messages/{msgID}` — documented redaction route works;
union left via HS route; 404 after).

- **`POST /messages` on a union room does NOT broadcast.** The API replies
  `{"chatID": "<first-child>"}` and exactly one copy lands — in the first
  `m.space.child` room. No duplicates, no cross-network fan-out.
- The mechanism is `Chat.merge.defaultChatID` ("Member chat that receives
  messages sent to the merged chat, when the user has picked one" — spec).
  **Child order decides the default when none is stored: the FIRST
  `m.space.child` wins** — proven by two createRoom probes with the same
  pair of rooms in opposite orders (2026-09-23, both torn down). Neither
  app-made (Abby) nor API-made (Sherman) unions persist a `defaultChatID`
  in the API view or any account-data key found in the store. To send to a
  specific member chat, address the child directly — union rooms are an
  inbox convenience, not a send abstraction.
- **Union timelines are UI-only.** `GET /v1/chats/{union}/messages` returns
  empty even for an app-made merge (Abby's: 0 msgs while its WhatsApp child
  has 20) — the merged scrollback the app renders is assembled client-side
  from the children. Agents must read children individually.
- The app's data layer fully accepts API-made unions: children gained
  `mergedIntoChatID` pointing back, union exposes `merge.chatIDs` —
  structurally indistinguishable from in-app merges (verified on the real
  Sherman union: WhatsApp DM + Google Chat DM).

## ctx7 recipes used (repeatable)

`ctx7 library "matrix specification"` → `/matrix-org/matrix-spec`;
`ctx7 docs /matrix-org/matrix-spec "<question>"` for power levels, space
child semantics, redaction, tags, push rules. Cross-check every claim
against the live proxy before trusting the spec — Beeper's Synapse fork
implements exactly what it proxies and 404s the rest.
