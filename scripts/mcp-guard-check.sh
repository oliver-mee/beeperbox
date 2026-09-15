#!/usr/bin/env bash
# mcp-guard-check.sh <image_ref>
#
# Boots the MCP server from <image_ref> in two modes — open (no auth) and
# token-required — and asserts the tool contract plus the HTTP hardening
# guard matrix (200/403/413/401). Exits non-zero on any failure.
#
# Single source of truth for the MCP gate: used by mcp-test.yml (PR/dispatch)
# AND release.yml's publish gate, so "what the PR tests" and "what blocks a
# release" are identical. Needs docker, curl, jq.
set -u

IMAGE="${1:?usage: mcp-guard-check.sh <image_ref>}"
# Host port base: upstream CI runs on a clean runner and uses 2337x. On a box
# already running a live beeperbox (which publishes 23375/23376), override to a
# free base, e.g. GUARD_PORT_BASE=28373 scripts/mcp-guard-check.sh <image>.
GPB="${GUARD_PORT_BASE:-23373}"
OPEN=mcp-guard-open
AUTH=mcp-guard-auth
RO=mcp-guard-ro
fail=0

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { docker rm -f "$OPEN" "$AUTH" "$RO" >/dev/null 2>&1 || true; }
trap cleanup EXIT

chk() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "PASS: $1 ($3)"; else echo "FAIL: $1 — expected $2 got $3"; fail=1; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
wait_ready() { # url [extra curl args...]
  local url=$1; shift
  for _ in $(seq 1 30); do
    if curl -sf -o /dev/null -X POST "$url" "$@" -d '{"jsonrpc":"2.0","id":0,"method":"tools/list"}'; then return 0; fi
    sleep 1
  done
  return 1
}

# ── open mode ─────────────────────────────────────────────────────
docker run -d --name "$OPEN" -p $((GPB+2)):23375 --entrypoint node "$IMAGE" /opt/mcp/server.js >/dev/null
wait_ready http://127.0.0.1:$((GPB+2)) || { echo "FAIL: open server never became ready"; docker logs "$OPEN"; exit 1; }
U=http://127.0.0.1:$((GPB+2))

names=$(curl -s -X POST "$U" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -r '.result.tools[].name')
for t in list_accounts list_inbox list_unread get_chat read_chat \
         search_messages send_message note_to_self react_to_message archive_chat \
         poll_messages download_asset send_draft list_labels update_label; do
  if echo "$names" | grep -qx "$t"; then echo "PASS: tool $t present"; else echo "FAIL: tool $t missing"; fail=1; fi
done

chk "no-token tools/list -> 200 (back-compat)" 200 \
  "$(code -X POST "$U" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
chk "cross-origin (bad Origin) -> 403" 403 \
  "$(code -X POST "$U" -H 'Origin: https://evil.example' -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}')"
chk "DNS-rebind (bad Host) -> 403" 403 \
  "$(code -X POST "$U" -H 'Host: evil.example' -d '{"jsonrpc":"2.0","id":4,"method":"tools/list"}')"
chk "allowed Origin -> 200" 200 \
  "$(code -X POST "$U" -H 'Origin: http://localhost:3000' -d '{"jsonrpc":"2.0","id":5,"method":"tools/list"}')"
{ printf '{"jsonrpc":"2.0","id":6,"method":"tools/list","pad":"'; head -c 12000000 /dev/zero | tr '\0' 'A'; printf '"}'; } > /tmp/mcp-big.json
chk "12MB body -> 413 (body cap)" 413 \
  "$(code -X POST "$U" -H 'Content-Type: application/json' --data-binary @/tmp/mcp-big.json)"

# ── auth mode ─────────────────────────────────────────────────────
docker run -d --name "$AUTH" -p $((GPB+3)):23375 -e MCP_AUTH_TOKEN=ci-secret \
  --entrypoint node "$IMAGE" /opt/mcp/server.js >/dev/null
wait_ready http://127.0.0.1:$((GPB+3)) -H 'Authorization: Bearer ci-secret' \
  || { echo "FAIL: auth server never became ready"; docker logs "$AUTH"; exit 1; }
A=http://127.0.0.1:$((GPB+3))
chk "no auth header -> 401" 401 \
  "$(code -X POST "$A" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
chk "wrong token -> 401" 401 \
  "$(code -X POST "$A" -H 'Authorization: Bearer nope' -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
chk "correct token -> 200" 200 \
  "$(code -X POST "$A" -H 'Authorization: Bearer ci-secret' -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}')"

# ── read-only mode (MCP_READ_ONLY=1 legacy + MCP_TOOL_MODE) ──────
# The mutating verbs must be hidden from tools/list AND rejected in
# tools/call even if a client hardcodes the name; the reads stay available.
docker run -d --name "$RO" -p $((GPB+4)):23375 -e MCP_READ_ONLY=1 \
  --entrypoint node "$IMAGE" /opt/mcp/server.js >/dev/null
wait_ready http://127.0.0.1:$((GPB+4)) \
  || { echo "FAIL: read-only server never became ready"; docker logs "$RO"; exit 1; }
R=http://127.0.0.1:$((GPB+4))

ro_names=$(curl -s -X POST "$R" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -r '.result.tools[].name')
for t in send_message note_to_self react_to_message archive_chat send_draft update_label; do
  if echo "$ro_names" | grep -qx "$t"; then echo "FAIL: write tool $t exposed in read-only mode"; fail=1; else echo "PASS: write tool $t hidden"; fi
done
for t in list_accounts list_inbox list_unread get_chat read_chat \
         search_messages poll_messages download_asset list_labels; do
  if echo "$ro_names" | grep -qx "$t"; then echo "PASS: read tool $t present in read-only mode"; else echo "FAIL: read tool $t missing in read-only mode"; fail=1; fi
done
ro_err=$(curl -s -X POST "$R" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_message","arguments":{}}}' | jq -r '.error.code // empty')
chk "read-only send_message tools/call -> rejected (-32601)" "-32601" "${ro_err:-none}"

# ── notes mode (MCP_TOOL_MODE=notes) ──────────────────────────────
# Reads + self-write (note_to_self, send_draft) only: the agent can jot to
# itself and pre-fill a human's composer, but can never reach a third party.
NOTES=mcp-guard-notes
docker rm -f "$NOTES" >/dev/null 2>&1 || true
docker run -d --name "$NOTES" -p $((GPB+5)):23375 -e MCP_TOOL_MODE=notes \
  --entrypoint node "$IMAGE" /opt/mcp/server.js >/dev/null
cleanup() { docker rm -f "$OPEN" "$AUTH" "$RO" "$NOTES" >/dev/null 2>&1 || true; }
trap cleanup EXIT
wait_ready http://127.0.0.1:$((GPB+5)) \
  || { echo "FAIL: notes server never became ready"; docker logs "$NOTES"; exit 1; }
N=http://127.0.0.1:$((GPB+5))
n_names=$(curl -s -X POST "$N" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -r '.result.tools[].name')
for t in note_to_self send_draft; do
  if echo "$n_names" | grep -qx "$t"; then echo "PASS: notes tool $t present"; else echo "FAIL: notes tool $t missing"; fail=1; fi
done
for t in send_message react_to_message archive_chat update_label; do
  if echo "$n_names" | grep -qx "$t"; then echo "FAIL: outward tool $t exposed in notes mode"; fail=1; else echo "PASS: outward tool $t hidden in notes mode"; fi
done
n_err=$(curl -s -X POST "$N" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_message","arguments":{}}}' | jq -r '.error.code // empty')
chk "notes send_message tools/call -> rejected (-32601)" "-32601" "${n_err:-none}"

if [ "$fail" -eq 0 ]; then echo "=== MCP GUARD CHECK PASSED ==="; else echo "=== MCP GUARD CHECK FAILED ==="; fi
exit "$fail"
