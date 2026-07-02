#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") -f <projects-file> -t <token> -o <org-key> -r <repository-name> [OPTIONS]

Provisions monorepo projects on SonarQube Cloud.

Required:
  -f <file>      Path to JSON file with project list
                 Format: [{ "projectKey": "...", "projectName": "..." }, ...]
  -t <token>     SonarCloud Personal Access Token
  -o <org>       Organization key
  -r <repo name> The exact name of the repository on the DevOps platform (Bitbucket, GitHub, GitLab, or Azure DevOps).
                 This repository should be part of the DevOps platform organization bound to the SonarCloud organization.
                 It is matched exactly against the "name" field in the dop-repositories API response.

Optional:
  -u <url>     SonarCloud URL (default: https://sonarcloud.io)
  -n <type>    newCodeDefinitionType (default: previous_version)
  -v <value>   newCodeDefinitionValue (default: previous_version)
  -h           Show this help message
EOF
}

# Check dependencies
echo "Checking prerequisites..."
missing_deps=()
command -v jq   &>/dev/null || missing_deps+=("jq")
command -v curl &>/dev/null || missing_deps+=("curl")
if [[ ${#missing_deps[@]} -gt 0 ]]; then
  echo "Error: missing required tool(s): ${missing_deps[*]}" >&2
  echo "Install jq: https://jqlang.org/download/" >&2
  echo "Install curl: https://curl.se/download.html" >&2
  exit 1
fi
echo "Prerequisites OK."

# Defaults
SONAR_URL="https://sonarcloud.io"
NEW_CODE_TYPE="previous_version"
NEW_CODE_VALUE="previous_version"

# Required (unset until parsed)
PROJECTS_FILE=""
TOKEN=""
ORG_KEY=""
REPO_NAME=""

while getopts ":f:t:o:r:u:n:v:h" opt; do
  case $opt in
    f) PROJECTS_FILE="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    o) ORG_KEY="$OPTARG" ;;
    r) REPO_NAME="$OPTARG" ;;
    u) SONAR_URL="$OPTARG" ;;
    n) NEW_CODE_TYPE="$OPTARG" ;;
    v) NEW_CODE_VALUE="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "Error: option -$OPTARG requires an argument." >&2; usage; exit 1 ;;
    \?) echo "Error: unknown option -$OPTARG." >&2; usage; exit 1 ;;
    *) ;;
  esac
done

# Validate required parameters
missing=()
[[ -z "$PROJECTS_FILE" ]] && missing+=("-f <projects-file>")
[[ -z "$TOKEN" ]]         && missing+=("-t <token>")
[[ -z "$ORG_KEY" ]]       && missing+=("-o <org-key>")
[[ -z "$REPO_NAME" ]]     && missing+=("-r <repository-name>")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required argument(s): ${missing[*]}" >&2
  usage
  exit 1
fi

# Validate the projects file
if [[ ! -f "$PROJECTS_FILE" ]]; then
  echo "Error: projects file not found: $PROJECTS_FILE" >&2
  exit 1
fi

if ! jq empty "$PROJECTS_FILE" 2>/dev/null; then
  echo "Error: projects file is not valid JSON: $PROJECTS_FILE" >&2
  exit 1
fi

# Validate schema: must be a non-empty array of objects with string projectKey and projectName
schema_errors=$(jq -r '
  if type != "array" then "root must be an array"
  elif length == 0 then "array must not be empty"
  else
    to_entries[] |
    .key as $idx |
    .value |
    if type != "object" then "entry \($idx): must be an object"
    elif (.projectKey | type) != "string" then "entry \($idx): missing or non-string projectKey"
    elif (.projectName | type) != "string" then "entry \($idx): missing or non-string projectName"
    else empty
    end
  end
' "$PROJECTS_FILE" 2>/dev/null)

if [[ -n "$schema_errors" ]]; then
  echo "Error: projects file failed schema validation:" >&2
  echo "$schema_errors" | while IFS= read -r line; do echo "  - $line" >&2; done
  exit 1
fi

# Constants for curl response parsing
CURL_STATUS_FORMAT='\n%{http_code}'
AWK_SPLIT_STATUS='NR>1{print prev} {prev=$0}'

# Derive API base URL by stripping any existing subdomain and prepending "api.".
# Examples:
#   https://sonarcloud.io        → https://api.sonarcloud.io
#   https://sc-staging.io        → https://api.sc-staging.io
#   https://dev11.sc-dev11.io    → https://api.sc-dev11.io  (subdomain stripped)
#   https://dev.sc-dev.io        → https://api.sc-dev.io    (subdomain stripped)
API_BASE_URL=$(echo "${SONAR_URL%/}" | sed -E 's|^(https?://)([^.]+\.)?([^./]+\.[^./]+)$|\1api.\3|')

# Resolve the organization ID from the org key
ORG_URL="${API_BASE_URL}/organizations/organizations?organizationKey=${ORG_KEY}"
echo "Resolving organization ID (${ORG_URL})..."
ORG_RESPONSE=$(curl -s -w "${CURL_STATUS_FORMAT}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${ORG_URL}")

ORG_BODY=$(echo "$ORG_RESPONSE" | awk "${AWK_SPLIT_STATUS}")
ORG_STATUS=$(echo "$ORG_RESPONSE" | tail -n 1)

if [[ "$ORG_STATUS" -lt 200 || "$ORG_STATUS" -ge 300 ]]; then
  echo "Error: failed to fetch organization (HTTP $ORG_STATUS)" >&2
  echo "$ORG_BODY" | jq . 2>/dev/null || echo "$ORG_BODY" >&2
  exit 1
fi

ORG_ID=$(echo "$ORG_BODY" | jq -r '.[0].id // empty')

if [[ -z "$ORG_ID" ]]; then
  echo "Error: organization '${ORG_KEY}' not found or returned no ID." >&2
  exit 1
fi

echo "Resolved organization ID: ${ORG_ID}"

# Resolve the DevOps platform type from the organization binding
BINDING_URL="${API_BASE_URL}/dop-translation/organization-bindings?organizationId=${ORG_ID}"
echo "Resolving DevOps platform type (${BINDING_URL})..."
BINDING_RESPONSE=$(curl -s -w "${CURL_STATUS_FORMAT}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${BINDING_URL}")

BINDING_BODY=$(echo "$BINDING_RESPONSE" | awk "${AWK_SPLIT_STATUS}")
BINDING_STATUS=$(echo "$BINDING_RESPONSE" | tail -n 1)

if [[ "$BINDING_STATUS" -lt 200 || "$BINDING_STATUS" -ge 300 ]]; then
  echo "Error: failed to fetch organization binding (HTTP $BINDING_STATUS)" >&2
  echo "$BINDING_BODY" | jq . 2>/dev/null || echo "$BINDING_BODY" >&2
  exit 1
fi

DOP_TYPE=$(echo "$BINDING_BODY" | jq -r '.organizationBindings[0].devOpsPlatform // empty')

if [[ -z "$DOP_TYPE" ]]; then
  echo "Error: no DevOps platform binding found for organization '${ORG_KEY}'." >&2
  echo "Please check if the SonarCloud organization has been bound to a DevOps platform." >&2
  exit 1
fi

echo "Resolved DevOps platform: ${DOP_TYPE}"

# Resolve the repository and construct the installation key via dop-repositories
REPO_URL="${API_BASE_URL}/dop-translation/dop-repositories"
echo "Retrieving installation key (${REPO_URL}?organizationId=${ORG_ID}&q=${REPO_NAME}&pageSize=50)..."
REPO_RESPONSE=$(curl -s -w "${CURL_STATUS_FORMAT}" \
  -H "Authorization: Bearer ${TOKEN}" \
  --get \
  --data-urlencode "organizationId=${ORG_ID}" \
  --data-urlencode "q=${REPO_NAME}" \
  --data-urlencode "pageSize=50" \
  "${REPO_URL}")

# -w appends the HTTP status code as the last line; split body and status accordingly
REPO_BODY=$(echo "$REPO_RESPONSE" | awk "${AWK_SPLIT_STATUS}")
REPO_STATUS=$(echo "$REPO_RESPONSE" | tail -n 1)

if [[ "$REPO_STATUS" -lt 200 || "$REPO_STATUS" -ge 300 ]]; then
  echo "Error: failed to fetch repositories (HTTP $REPO_STATUS)" >&2
  echo "$REPO_BODY" | jq . 2>/dev/null || echo "$REPO_BODY" >&2
  exit 1
fi

MATCH_COUNT=$(echo "$REPO_BODY" | jq \
  --arg name "$REPO_NAME" \
  '[.repositories[] | select(.name == $name)] | length')

if [[ "$MATCH_COUNT" -eq 0 ]]; then
  echo "Error: no repository with name '${REPO_NAME}' found in organization '${ORG_KEY}'" >&2
  exit 1
fi

if [[ "$MATCH_COUNT" -gt 1 ]]; then
  echo "Error: ${MATCH_COUNT} repositories with name '${REPO_NAME}' found in organization '${ORG_KEY}' — cannot disambiguate." >&2
  exit 1
fi

REPO_ID=$(echo "$REPO_BODY" | jq -r \
  --arg name "$REPO_NAME" \
  'first(.repositories[] | select(.name == $name) | .id) // empty')

REPO_SLUG=$(echo "$REPO_BODY" | jq -r \
  --arg name "$REPO_NAME" \
  'first(.repositories[] | select(.name == $name) | .slug) // empty')

if [[ "$DOP_TYPE" == "github" && -z "$REPO_SLUG" ]]; then
  echo "Error: repository '${REPO_NAME}' has no slug — cannot construct installation key for GitHub." >&2
  exit 1
fi

if [[ "$DOP_TYPE" == "github" ]]; then
  INSTALLATION_KEY="${REPO_SLUG}|${REPO_ID}"
else
  INSTALLATION_KEY="${REPO_ID}"
fi

echo "Resolved installation key: ${INSTALLATION_KEY}"

ENDPOINT="${SONAR_URL%/}/api/alm_integration/provision_monorepo_projects"
CHUNK_SIZE=25

PROJECT_COUNT=$(jq 'length' "$PROJECTS_FILE")
CHUNK_COUNT=$(( (PROJECT_COUNT + CHUNK_SIZE - 1) / CHUNK_SIZE ))

echo "Provisioning ${PROJECT_COUNT} project(s) in ${CHUNK_COUNT} chunk(s) of ${CHUNK_SIZE} (${ENDPOINT})..."

for (( chunk = 0; chunk < CHUNK_COUNT; chunk++ )); do
  CHUNK_START=$(( chunk * CHUNK_SIZE + 1 ))
  CHUNK_END=$(( (chunk + 1) * CHUNK_SIZE ))
  [[ $CHUNK_END -gt $PROJECT_COUNT ]] && CHUNK_END=$PROJECT_COUNT

  echo "Chunk $(( chunk + 1 ))/${CHUNK_COUNT}: projects ${CHUNK_START}–${CHUNK_END}..."

  CHUNK_PROJECTS=$(jq \
    --argjson offset "$(( chunk * CHUNK_SIZE ))" \
    --argjson size "$CHUNK_SIZE" \
    --arg ik "$INSTALLATION_KEY" \
    '.[$offset:$offset+$size] | map(. + { installationKey: $ik })' \
    "$PROJECTS_FILE")

  BODY=$(jq -n \
    --arg org "$ORG_KEY" \
    --arg nct "$NEW_CODE_TYPE" \
    --arg ncv "$NEW_CODE_VALUE" \
    --argjson projects "$CHUNK_PROJECTS" \
    '{ organization: $org, newCodeDefinitionType: $nct, newCodeDefinitionValue: $ncv, projects: $projects }')

  HTTP_RESPONSE=$(curl -s -w "${CURL_STATUS_FORMAT}" -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    "$ENDPOINT")

  # -w appends the HTTP status code as the last line; split body and status accordingly
  HTTP_BODY=$(echo "$HTTP_RESPONSE" | awk "${AWK_SPLIT_STATUS}")
  HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n 1)

  if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    echo "Chunk $(( chunk + 1 ))/${CHUNK_COUNT}: done (HTTP ${HTTP_STATUS})"
    [[ -n "$HTTP_BODY" ]] && echo "$HTTP_BODY" | jq . 2>/dev/null || true
  else
    # Chunk rejected — fall back to one project at a time so a single
    # already-existing project doesn't block the rest of the chunk.
    echo "Chunk $(( chunk + 1 ))/${CHUNK_COUNT}: HTTP ${HTTP_STATUS}, retrying project by project..."
    CHUNK_LEN=$(echo "$CHUNK_PROJECTS" | jq 'length')
    for (( i = 0; i < CHUNK_LEN; i++ )); do
      PROJECT=$(echo "$CHUNK_PROJECTS" | jq ".[$i]")
      PROJECT_KEY=$(echo "$PROJECT" | jq -r '.projectKey')

      SINGLE_BODY=$(jq -n \
        --arg org "$ORG_KEY" \
        --arg nct "$NEW_CODE_TYPE" \
        --arg ncv "$NEW_CODE_VALUE" \
        --argjson project "$PROJECT" \
        '{ organization: $org, newCodeDefinitionType: $nct, newCodeDefinitionValue: $ncv, projects: [$project] }')

      SINGLE_RESPONSE=$(curl -s -w "${CURL_STATUS_FORMAT}" -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$SINGLE_BODY" \
        "$ENDPOINT")

      SINGLE_BODY_RESP=$(echo "$SINGLE_RESPONSE" | awk "${AWK_SPLIT_STATUS}")
      SINGLE_STATUS=$(echo "$SINGLE_RESPONSE" | tail -n 1)

      if [[ "$SINGLE_STATUS" -ge 200 && "$SINGLE_STATUS" -lt 300 ]]; then
        echo "  Provisioned: ${PROJECT_KEY}"
      elif echo "$SINGLE_BODY_RESP" | jq -e '[.errors[]?.msg] | any(test("already exists"))' &>/dev/null; then
        echo "  Warning: ${PROJECT_KEY} already exists, skipping."
      else
        echo "  Error: failed to provision ${PROJECT_KEY} (HTTP ${SINGLE_STATUS})" >&2
        echo "$SINGLE_BODY_RESP" | jq . 2>/dev/null || echo "$SINGLE_BODY_RESP" >&2
        exit 1
      fi
    done
    echo "Chunk $(( chunk + 1 ))/${CHUNK_COUNT}: done (via fallback)"
  fi
done

echo "Done. All ${PROJECT_COUNT} project(s) provisioned successfully."
