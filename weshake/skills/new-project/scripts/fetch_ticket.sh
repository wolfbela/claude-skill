#!/bin/bash
set -euo pipefail

# Argument: ticket URL
TICKET_URL="$1"

COOKIE_FILE="/tmp/plane_cookies.txt"
PLANE_URL="https://plane.oovoom.com"

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

# Step 2: Convert browse URL to API URL
# Input:  https://plane.oovoom.com/weshake/browse/WESHAKEV2-45/
# Output: https://plane.oovoom.com/api/workspaces/weshake/work-items/WESHAKEV2-45/
API_URL=$(echo "$TICKET_URL" | sed 's|/weshake/browse/|/api/workspaces/weshake/work-items/|')

# Step 3: Fetch ticket
RESPONSE=$(curl -s -X GET "$API_URL" \
  -b "csrftoken=${CSRF_TOKEN}" \
  -b "session-id=${SESSION_ID}")

echo "${RESPONSE}"

# Cleanup
rm -f "${COOKIE_FILE}"
