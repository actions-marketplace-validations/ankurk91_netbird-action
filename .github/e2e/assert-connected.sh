#!/usr/bin/env bash
# Check that the action really joined the runner to the throwaway network, from
# both ends: what the client reports, and what the server knows about it.
set -euo pipefail

API_URL="${API_URL:-http://localhost:8081}"

echo '=== What the client reports ==='
sudo netbird status

# The same health check the action waits on: management and signal connected,
# and a relay available. The server-side check further down is what keeps this
# from being the action grading its own work.
if ! sudo netbird status --check startup; then
  echo '::error::the peer did not pass the startup health check'
  exit 1
fi

# The output is what a workflow downstream of this action consumes, so an empty
# or wrong one is a failure of its own even when the peer is fine.
case "$NETBIRD_IP" in
  100.*) ;;
  *)
    echo "::error::the action's netbird-ip output is not an overlay address: '$NETBIRD_IP'"
    exit 1
    ;;
esac

client_ip="$(sudo netbird status -4)"

if [ "$client_ip" != "$NETBIRD_IP" ]; then
  echo "::error::the action reported $NETBIRD_IP but the client holds $client_ip"
  exit 1
fi

echo "the action reported $NETBIRD_IP, which is what the client holds"

echo '=== What the server knows ==='
peers="$(curl -fsS --max-time 30 "$API_URL/api/peers" \
  -H "Authorization: Token $NETBIRD_PAT" \
  -H 'Accept: application/json')"

# name is what --hostname set; hostname is what the runner calls itself.
printf '%s' "$peers" | jq -r '.[] | "name=\(.name)\thostname=\(.hostname)\t\(.ip)\tconnected=\(.connected)"'

# So this covers both the peer arriving and it arriving under the name the run
# gave it, which is the action's default hostname.
if ! printf '%s' "$peers" |
  jq -e --arg h "$PEER_NAME" 'any(.[]; .hostname == $h or .name == $h)' > /dev/null; then
  echo "::error::the server has no peer named '$PEER_NAME'"
  exit 1
fi

if ! printf '%s' "$peers" |
  jq -e --arg ip "$NETBIRD_IP" 'any(.[]; .ip == $ip and .connected)' > /dev/null; then
  echo "::error::the server does not see $NETBIRD_IP as a connected peer"
  exit 1
fi

echo "the server sees '$PEER_NAME' connected at $NETBIRD_IP"
