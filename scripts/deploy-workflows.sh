#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash scripts/deploy-workflows.sh upsert workflow/my-flow.json
#   bash scripts/deploy-workflows.sh delete workflow/my-flow.json
#
# For local use, export N8N_API_URL and N8N_API_KEY before running.

MODE="$1"
FILE="$2"

API_URL="${N8N_API_URL:?N8N_API_URL is required}"
API_KEY="${N8N_API_KEY:?N8N_API_KEY is required}"
AUTH_HEADER="X-N8N-API-KEY: $API_KEY"

upsert_workflow() {
  local file="$1"
  local body; body=$(cat "$file")
  local id; id=$(echo "$body" | jq -r '.id // empty')
  local name; name=$(echo "$body" | jq -r '.name')
  local active; active=$(echo "$body" | jq -r '.active')

  if [ -z "$id" ]; then
    echo "ERROR: $file has no .id field" >&2
    exit 1
  fi

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$AUTH_HEADER" \
    "$API_URL/api/v1/workflows/$id")

  if [ "$status" = "200" ]; then
    echo "Updating: $name ($id)"
    curl -s -X PUT \
      -H "Content-Type: application/json" \
      -H "$AUTH_HEADER" \
      -d "$body" \
      "$API_URL/api/v1/workflows/$id" | jq '{id:.id, name:.name}'
  else
    echo "Creating: $name ($id)"
    curl -s -X POST \
      -H "Content-Type: application/json" \
      -H "$AUTH_HEADER" \
      -d "$body" \
      "$API_URL/api/v1/workflows" | jq '{id:.id, name:.name}'
  fi

  if [ "$active" = "true" ]; then
    echo "Activating: $name"
    curl -s -X POST -H "$AUTH_HEADER" "$API_URL/api/v1/workflows/$id/activate" > /dev/null
  else
    curl -s -X POST -H "$AUTH_HEADER" "$API_URL/api/v1/workflows/$id/deactivate" > /dev/null
  fi
}

delete_workflow() {
  local file="$1"
  local body; body=$(git show HEAD~1:"$file" 2>/dev/null || true)

  if [ -z "$body" ]; then
    echo "WARNING: could not recover $file from git history — skipping delete" >&2
    return
  fi

  local id; id=$(echo "$body" | jq -r '.id // empty')
  local name; name=$(echo "$body" | jq -r '.name')

  if [ -z "$id" ]; then
    echo "WARNING: no .id in recovered $file — skipping delete" >&2
    return
  fi

  echo "Deleting: $name ($id)"
  curl -s -X DELETE \
    -H "$AUTH_HEADER" \
    "$API_URL/api/v1/workflows/$id"
}

case "$MODE" in
  upsert) upsert_workflow "$FILE" ;;
  delete) delete_workflow "$FILE" ;;
  *) echo "Usage: $0 <upsert|delete> <workflow-file>" >&2; exit 1 ;;
esac
