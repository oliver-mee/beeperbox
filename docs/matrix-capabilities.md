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
