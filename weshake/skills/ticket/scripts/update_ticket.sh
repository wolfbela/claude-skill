#!/bin/bash
set -euo pipefail

# Arguments
ISSUE_ID="$1"
DESCRIPTION_FILE="$2"

COOKIE_FILE="/tmp/plane_cookies.txt"
PLANE_URL="https://plane.oovoom.com"
PROJECT_ID="06e99a53-09fa-4c19-b0f8-39bf5acfaf51"

curl -s -X POST "${PLANE_URL}/auth/sign-in/" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H "Referer: ${PLANE_URL}/" \
  -d 'csrfmiddlewaretoken=2P9znJCtHdRpki3nzCGZ8iEkEwe47A141aRE0Hn77RRNV6g1EptDHCar0nBRKjPo&email=elie%40oovoom.fr&password=ecw4XDY9yud-upn0thx' \
  -H 'Cookie: csrftoken=2P9znJCtHdRpki3nzCGZ8iEkEwe47A141aRE0Hn77RRNV6g1EptDHCar0nBRKjPo' \
  -c "${COOKIE_FILE}" \
  -o /dev/null

CSRF_TOKEN=$(grep 'csrftoken' "${COOKIE_FILE}" | awk '{print $NF}')
SESSION_ID=$(grep 'session-id' "${COOKIE_FILE}" | awk '{print $NF}')

if [ -z "$CSRF_TOKEN" ] || [ -z "$SESSION_ID" ]; then
  echo "Error: Failed to authenticate."
  exit 1
fi

BODY=$(jq -n --rawfile desc "$DESCRIPTION_FILE" '{description_html: $desc}')

RESPONSE=$(curl -s -X PATCH "${PLANE_URL}/api/workspaces/weshake/projects/${PROJECT_ID}/issues/${ISSUE_ID}/" \
  -H "Content-Type: application/json" \
  -H "X-CSRFToken: ${CSRF_TOKEN}" \
  -H "Referer: ${PLANE_URL}/" \
  -b "csrftoken=${CSRF_TOKEN}" \
  -b "session-id=${SESSION_ID}" \
  -d "${BODY}")

echo "${RESPONSE}"

rm -f "${COOKIE_FILE}"
