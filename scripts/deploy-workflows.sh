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
CURL_OPTS=(--connect-timeout 30 --max-time 120)

# Strip fields the n8n API considers read-only on create/update.
# settings is allow-listed to its known valid keys to avoid "additional properties" errors.
strip_readonly() {
  jq '
    del(.id, .active, .versionId, .meta, .tags) |
    if .settings then .settings = {executionOrder: .settings.executionOrder} else . end
  '
}

# Inject server-side credential IDs by matching type+name first, falling back
# to type-only so single-credential types (Slack, OpenAI) still resolve.
inject_credential_ids() {
  local creds_json="$1"
  jq --argjson creds "$creds_json" '
    .nodes |= map(
      if .credentials then
        .credentials |= with_entries(
          .key as $ctype |
          .value.name as $cname |
          (
            ($creds.data // []) |
            (map(select(.type == $ctype and .name == $cname)) | .[0].id) //
            (map(select(.type == $ctype)) | .[0].id) //
            null
          ) as $id |
          if $id then .value.id = $id else . end
        )
      else . end
    )
  '
}

# Call n8n API and print a summary; fail loudly if the response is not JSON
# or does not contain the expected fields.
api_call() {
  local method="$1"; shift
  local url="$1"; shift
  local response http_code

  response=$(curl -s "${CURL_OPTS[@]}" -w '\n__HTTP_STATUS__%{http_code}' "$@" -X "$method" "$url")
  http_code=$(echo "$response" | tail -1 | sed 's/__HTTP_STATUS__//')
  response=$(echo "$response" | sed '$d')

  if ! echo "$response" | jq empty 2>/dev/null; then
    echo "ERROR: n8n returned non-JSON (HTTP $http_code):" >&2
    echo "$response" >&2
    exit 1
  fi

  if [ "$http_code" -ge 400 ]; then
    echo "ERROR: n8n returned HTTP $http_code:" >&2
    echo "$response" | jq . >&2
    exit 1
  fi

  echo "$response"
}

upsert_workflow() {
  local file="$1"
  local body; body=$(cat "$file")
  local name; name=$(echo "$body" | jq -r '.name')
  local active; active=$(echo "$body" | jq -r '.active')

  local creds_list; creds_list=$(curl -s "${CURL_OPTS[@]}" -H "$AUTH_HEADER" "$API_URL/api/v1/credentials?limit=250")
  local payload; payload=$(echo "$body" | strip_readonly | inject_credential_ids "$creds_list")

  # Look up by name — n8n owns the ID; the JSON id field is only for local reference
  local list; list=$(curl -s "${CURL_OPTS[@]}" -H "$AUTH_HEADER" "$API_URL/api/v1/workflows?limit=250")
  local existing_id; existing_id=$(echo "$list" | jq -r --arg name "$name" '.data[] | select(.name == $name) | .id' | head -1)

  if [ -n "$existing_id" ]; then
    local server_active; server_active=$(echo "$list" | jq -r --arg name "$name" '.data[] | select(.name == $name) | .active' | head -1)
    if [ "$server_active" = "true" ]; then
      echo "Deactivating: $name (before update)"
      curl -s "${CURL_OPTS[@]}" -X POST -H "$AUTH_HEADER" "$API_URL/api/v1/workflows/$existing_id/deactivate" > /dev/null
    fi
    echo "Updating: $name ($existing_id)"
    api_call PUT "$API_URL/api/v1/workflows/$existing_id" \
      -H "Content-Type: application/json" \
      -H "$AUTH_HEADER" \
      -d "$payload" | jq '{id:.id, name:.name}'
  else
    echo "Creating: $name"
    local result; result=$(api_call POST "$API_URL/api/v1/workflows" \
      -H "Content-Type: application/json" \
      -H "$AUTH_HEADER" \
      -d "$payload")
    existing_id=$(echo "$result" | jq -r '.id')
    echo "$result" | jq '{id:.id, name:.name}'
  fi

  if [ "$active" = "true" ]; then
    echo "Activating: $name"
    curl -s "${CURL_OPTS[@]}" -X POST -H "$AUTH_HEADER" "$API_URL/api/v1/workflows/$existing_id/activate" > /dev/null
  else
    curl -s "${CURL_OPTS[@]}" -X POST -H "$AUTH_HEADER" "$API_URL/api/v1/workflows/$existing_id/deactivate" > /dev/null
  fi
}

delete_workflow() {
  local file="$1"
  local body; body=$(git show HEAD~1:"$file" 2>/dev/null || true)

  if [ -z "$body" ]; then
    echo "WARNING: could not recover $file from git history — skipping delete" >&2
    return
  fi

  local name; name=$(echo "$body" | jq -r '.name')

  # Look up by name to get the n8n-assigned ID
  local list; list=$(curl -s "${CURL_OPTS[@]}" -H "$AUTH_HEADER" "$API_URL/api/v1/workflows?limit=250")
  local existing_id; existing_id=$(echo "$list" | jq -r --arg name "$name" '.data[] | select(.name == $name) | .id' | head -1)

  if [ -z "$existing_id" ]; then
    echo "WARNING: $name not found on server — skipping delete" >&2
    return
  fi

  echo "Deleting: $name ($existing_id)"
  curl -s "${CURL_OPTS[@]}" -X DELETE \
    -H "$AUTH_HEADER" \
    "$API_URL/api/v1/workflows/$existing_id"
}

case "$MODE" in
  upsert) upsert_workflow "$FILE" ;;
  delete) delete_workflow "$FILE" ;;
  *) echo "Usage: $0 <upsert|delete> <workflow-file>" >&2; exit 1 ;;
esac
