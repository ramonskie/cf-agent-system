#!/bin/bash
# push.sh — Build, push Docker image and cf push the opencode agent prototype
#
# Usage:
#   export REGISTRY=ghcr.io/yourorg
#   export CF_API=https://api.sys.example.com
#   export CF_ORG=myorg
#   export CF_SPACE=myspace
#   export ANTHROPIC_API_KEY=sk-ant-...
#   export OPENCODE_SERVER_PASSWORD=secret123
#   ./push.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="${REGISTRY:-ghcr.io/yourorg}"
IMAGE="${REGISTRY}/opencode-agent:latest"

echo "=== Step 1: Build Docker image ==="
docker build -t "$IMAGE" "$SCRIPT_DIR"

echo "=== Step 2: Push Docker image ==="
docker push "$IMAGE"

echo "=== Step 3: CF target ==="
cf api "${CF_API:?CF_API required}"
# Assumes already logged in: cf login or cf auth

cf target -o "${CF_ORG:?CF_ORG required}" -s "${CF_SPACE:?CF_SPACE required}"

echo "=== Step 4: Set secrets as env vars ==="
# Note: in production these would come from CredHub refs in manifest.yml
# For prototype we set them directly

echo "=== Step 5: CF push ==="
# Update manifest to use our built image
sed "s|ghcr.io/YOUR_ORG/opencode-agent:latest|${IMAGE}|" \
    "$SCRIPT_DIR/manifest.yml" > /tmp/manifest-resolved.yml

cf push -f /tmp/manifest-resolved.yml \
  --var anthropic-api-key="${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY required}" \
  --var opencode-password="${OPENCODE_SERVER_PASSWORD:?OPENCODE_SERVER_PASSWORD required}" \
  --var cf-client-secret="${CF_CLIENT_SECRET:-placeholder}"

echo ""
echo "=== Push complete ==="
APP_ROUTE=$(cf app opencode-agent-prototype | grep routes | awk '{print $2}')
echo "Agent URL: https://${APP_ROUTE}"
echo ""
echo "Next step: run ./verify.sh https://${APP_ROUTE}"
