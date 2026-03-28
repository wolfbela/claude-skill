#!/bin/bash
set -euo pipefail

# Arguments
NAME="$1"
DESCRIPTION="$2"

COOKIE_FILE="/tmp/plane_cookies.txt"
PLANE_URL="https://plane.oovoom.com"
PROJECT_ID="06e99a53-09fa-4c19-b0f8-39bf5acfaf51"

# Step 1: Login to get session cookies
curl -s -X POST "${PLANE_URL}/auth/sign-in/" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H "Referer: ${PLANE_URL}/" \
  -d 'csrfmiddlewaretoken=2P9znJCtHdRpki3nzCGZ8iEkEwe47A141aRE0Hn77RRNV6g1EptDHCar0nBRKjPo&email=elie%40oovoom.fr&password=ecw4XDY9yud-upn0thx' \
  -H 'Cookie: csrftoken=2P9znJCtHdRpki3nzCGZ8iEkEwe47A141aRE0Hn77RRNV6g1EptDHCar0nBRKjPo' \
  -c "${COOKIE_FILE}" \
  -o /dev/null

# Extract cookies from cookie file
CSRF_TOKEN=$(grep 'csrftoken' "${COOKIE_FILE}" | awk '{print $NF}')
SESSION_ID=$(grep 'session-id' "${COOKIE_FILE}" | awk '{print $NF}')

if [ -z "$CSRF_TOKEN" ] || [ -z "$SESSION_ID" ]; then
  echo "Error: Failed to authenticate. Could not retrieve session cookies."
  exit 1
fi

# Step 2: Build JSON body with jq for proper escaping
BODY=$(jq -n \
  --arg name "$NAME" \
  --arg desc "$DESCRIPTION" \
  --arg project_id "$PROJECT_ID" \
  '{
    project_id: $project_id,
    type_id: null,
    name: $name,
    description_html: $desc,
    estimate_point: null,
    state_id: "",
    parent_id: null,
    priority: "none",
    assignee_ids: [],
    label_ids: [],
    cycle_id: null,
    module_ids: null,
    start_date: null,
    target_date: null
  }')

RESPONSE=$(curl -s -X POST "${PLANE_URL}/api/workspaces/weshake/projects/${PROJECT_ID}/issues/" \
  -H "Content-Type: application/json" \
  -H "X-CSRFToken: ${CSRF_TOKEN}" \
  -H "Referer: ${PLANE_URL}/" \
  -b "csrftoken=${CSRF_TOKEN}" \
  -b "session-id=${SESSION_ID}" \
  -d "${BODY}")

echo "${RESPONSE}"

# Cleanup
rm -f "${COOKIE_FILE}"
