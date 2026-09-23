# Beeper labels: two systems, one scope

Beeper has **two parallel label systems**. Both live inside the Matrix account
Beeper hosts locally, and the Desktop API proxy (`:23373` on this box, token in
`.env` → `BEEPER_TOKEN`) reaches both — but they behave differently. Everything
below was reverse-engineered and verified live on 2026-09-23.

## 1. Official labels = Matrix spaces (what the app renders)

An official label is an `m.space` room whose `m.room.create` content carries
`com.beeper.label: true`. Memberships are `m.space.child` state events (one per
chat, `state_key` = the chat's room id). `GET /v1/labels` and each chat's
`labels[]` field are projections of these spaces.

```
POST /_matrix/client/v3/createRoom
{
  "creation_content": { "type": "m.space", "com.beeper.label": true },
  "name": "My Label",
  "preset": "private_chat",
  "initial_state": [
    { "type": "com.beeper.label.color", "state_key": "", "content": { "color_index": 1 } },
    { "type": "com.beeper.label.icon",  "state_key": "", "content": { "icon": "1282-496" } },
    { "type": "m.space.child", "state_key": "<chat-room-id>", "content": { "via": ["beeper.com"] } }
  ]
}
```

Verified facts:

- **`com.beeper.label: true` is the only requirement** for app recognition.
  Color and icon events are cosmetic (the app sets defaults on create and edits
  them natively afterwards — API-created spaces behave exactly like app-made
  ones, probes 2026-09-23).
- **`via: ["beeper.com"]` in the child content is NOT optional in practice**:
  with empty `{}` content the label still lists in `/v1/labels`, but no chat
  reports carrying it (the `labels[]` projection stays null). Always seed
  `via`.
- **Children can only be seeded at creation.** The state proxy is GET-only
  (`PUT /_matrix/client/v3/rooms/{id}/state/...` → 404), so there is no API
  path to add or remove a chat from an existing official label. Edit roster =
  recreate a fresh space with the full roster and `leave` the old one.
- Do not send an explicit `m.room.power_levels` in `initial_state` — the proxy
  500s with "Creator user must not appear in content.users"; the default PLs
  from `preset: private_chat` already give the owner 100.
- **Delete / retire:** `POST /_matrix/client/v3/rooms/{id}/leave`. The label
  disappears from `/v1/labels` (the list is derived from *joined* label rooms).
  The space itself orphans server-side; rejoining resurrects it.
- **Plan caps are not enforced by the client:** on the Free plan the app
  rendered every official label present in the account (verified 2026-09-23
  with five simultaneous labels). The help-centre "1 label" limit is marketing
  surface, not code.

## 2. Legacy labels = account_data (invisible to the app)

A single Matrix account-data event,
`GET/PUT /_matrix/client/v3/user/{userId}/account_data/com.beeper.labels`,
whose body is `{ uuid: { title, rooms: [chat ids], isShownInInbox, createdAt } }`
(the body *is* the map — no wrapper key). This is the pre-migration store; the
current app no longer renders it. `PUT` replaces the whole event: read, merge,
write back.

## In beeperbox

- `list_labels` returns **both systems**, each label tagged
  `source: "official" | "legacy"` (official labels' `label_id` is the space's
  room id).
- `MCP_LABEL_ALLOW` / `MCP_LABEL_ALLOW_WORK` scope titles/ids are matched
  case-insensitively across both stores and the scopes **union**, so a scope
  like `MCP_LABEL_ALLOW=Official Work` fences the instance to an app-visible
  space's children, and `update_label`-managed legacy labels keep working
  unchanged.
- `update_label` writes **only the legacy store** (it is an account-data tool).
  Targeting an official label — by room id or by a title that matches an
  official space — is refused with `-32602` rather than minting a ghost
  account-data entry the app never shows. Curate official rosters in the app
  UI or by recreating the space (this file, §1).
- Fail-closed holds: if the space enumeration errors under a configured scope,
  strict mode raises instead of silently shrinking the fence.
