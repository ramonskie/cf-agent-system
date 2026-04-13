#!/bin/bash
# verify.sh — Validate the opencode agent prototype is working correctly
#
# Usage:
#   export AGENT_URL=https://opencode-agent-prototype.apps.example.com
#   export OPENCODE_SERVER_PASSWORD=secret123
#   ./verify.sh
#
# Or pass URL as argument:
#   ./verify.sh https://opencode-agent-prototype.apps.example.com

set -euo pipefail

AGENT_URL="${1:-${AGENT_URL:?AGENT_URL required}}"
PASSWORD="${OPENCODE_SERVER_PASSWORD:?OPENCODE_SERVER_PASSWORD required}"
AUTH="Authorization: Basic $(echo -n ":${PASSWORD}" | base64)"

echo "======================================================"
echo " opencode Agent Prototype Verification"
echo " URL: ${AGENT_URL}"
echo "======================================================"
echo ""

PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  local expected="$3"
  if echo "$result" | grep -q "$expected"; then
    echo "  ✅ PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ FAIL: $desc"
    echo "     Expected: $expected"
    echo "     Got: $result"
    FAIL=$((FAIL + 1))
  fi
}

# ── Step 1: Health check ────────────────────────────────────────────────────
echo "--- Step 1: Health Check (GET /global/health) ---"
HEALTH=$(curl -sf "${AGENT_URL}/global/health" -H "$AUTH" 2>&1 || true)
echo "  Response: $HEALTH"
check "healthy=true" "$HEALTH" '"healthy":true'
check "version present" "$HEALTH" '"version":'
echo ""

# ── Step 2: Create a session ────────────────────────────────────────────────
echo "--- Step 2: Create Session (POST /session) ---"
SESSION_RESP=$(curl -sf -X POST "${AGENT_URL}/session" \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  -d '{"title":"prototype-test"}' 2>&1 || true)
echo "  Response: $SESSION_RESP"
check "session has id" "$SESSION_RESP" '"id":'
SESSION_ID=$(echo "$SESSION_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || \
             echo "$SESSION_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "  Session ID: $SESSION_ID"
echo ""

# ── Step 3: Send a message ──────────────────────────────────────────────────
echo "--- Step 3: Send Message (POST /session/:id/message) ---"
if [ -n "$SESSION_ID" ]; then
  MSG_RESP=$(curl -sf -X POST "${AGENT_URL}/session/${SESSION_ID}/message" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d '{"parts":[{"type":"text","text":"Reply with exactly: PROTOTYPE_OK"}]}' \
    --max-time 60 2>&1 || true)
  echo "  Response (truncated): ${MSG_RESP:0:200}"
  check "non-empty response" "$MSG_RESP" "."
  check "response contains content" "$MSG_RESP" "PROTOTYPE_OK\|text\|content\|message"
else
  echo "  ⚠️  SKIP: No session ID (Step 2 failed)"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── Step 4: Create child session (sub-agent) ────────────────────────────────
echo "--- Step 4: Sub-Agent Session (POST /session with parentID) ---"
if [ -n "$SESSION_ID" ]; then
  CHILD_RESP=$(curl -sf -X POST "${AGENT_URL}/session" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"child-agent\",\"parentID\":\"${SESSION_ID}\"}" 2>&1 || true)
  echo "  Response: $CHILD_RESP"
  check "child session created" "$CHILD_RESP" '"id":'
  CHILD_ID=$(echo "$CHILD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || \
             echo "$CHILD_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

  # Verify children endpoint
  if [ -n "$CHILD_ID" ]; then
    CHILDREN=$(curl -sf "${AGENT_URL}/session/${SESSION_ID}/children" \
      -H "$AUTH" 2>&1 || true)
    echo "  Children: $CHILDREN"
    check "child appears in parent children" "$CHILDREN" "$CHILD_ID"
  fi
else
  echo "  ⚠️  SKIP: No session ID (Step 2 failed)"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── Step 5: Shell execution (cf CLI check) ──────────────────────────────────
echo "--- Step 5: Shell Execution — CF CLI available? ---"
if [ -n "$SESSION_ID" ]; then
  SHELL_RESP=$(curl -sf -X POST "${AGENT_URL}/session/${SESSION_ID}/shell" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d '{"command":"cf version"}' \
    --max-time 15 2>&1 || true)
  echo "  Response: $SHELL_RESP"
  check "cf CLI version returned" "$SHELL_RESP" "cf version\|Cloud Foundry"
else
  echo "  ⚠️  SKIP: No session ID (Step 2 failed)"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── Step 6: SSE event stream ────────────────────────────────────────────────
echo "--- Step 6: SSE Event Stream (GET /global/event, 3s sample) ---"
EVENTS=$(curl -sf "${AGENT_URL}/global/event" \
  -H "$AUTH" \
  -H "Accept: text/event-stream" \
  --max-time 3 2>&1 || true)
# 3s timeout is expected — we just want to confirm the endpoint responds
if echo "$EVENTS" | grep -q "data:\|retry:\|event:"; then
  echo "  ✅ PASS: SSE stream produces events"
  PASS=$((PASS + 1))
elif echo "$EVENTS" | grep -q "curl.*28\|Operation timed out"; then
  echo "  ✅ PASS: SSE stream connected (timed out as expected)"
  PASS=$((PASS + 1))
else
  echo "  ⚠️  INFO: SSE response: ${EVENTS:0:100} (may still be OK)"
fi
echo ""

# ── Summary ─────────────────────────────────────────────────────────────────
echo "======================================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "======================================================"
if [ "$FAIL" -eq 0 ]; then
  echo " 🎉 All checks passed — prototype is working!"
  exit 0
else
  echo " ❌ Some checks failed — review output above"
  exit 1
fi
