#!/usr/bin/env bash
# Check that the cleanup really takes the runner back off the network, from both
# ends: what the client reports, and whether the server still has the peer.
#
# The post step cannot be observed from inside the job it belongs to - it runs
# after every step, including the ones that could assert on it. So the cleanup is
# run here as a step of its own, with the state a real run records, and the post
# step that follows this job then finds its own marker and does nothing.
set -euo pipefail

API_URL="${API_URL:-http://localhost:8081}"

echo '=== Cleaning up ==='
STATE_NB_CONNECTED=true STATE_NB_INSTALLED=true bash src/cleanup.sh

echo '=== What the client reports ==='
# The service is uninstalled by now, so the CLI has no daemon to ask and the
# check cannot pass. Either way what matters is that it does not report a peer
# that is still up.
if sudo netbird status --check startup > /dev/null 2>&1; then
  echo '::error::the peer is still connected after the cleanup'
  sudo netbird status -d || true
  exit 1
fi

echo 'the client is no longer connected'

# The action installed the client in this job, so the cleanup owns the whole
# install - including the key it left on disk.
if [ -e /var/lib/netbird ]; then
  echo '::error::/var/lib/netbird survived the cleanup, so the peer key is still on the runner'
  sudo ls -la /var/lib/netbird || true
  exit 1
fi

echo 'the client configuration is gone from the runner'

echo '=== What the server knows ==='
peers="$(curl -fsS --max-time 30 "$API_URL/api/peers" \
  -H "Authorization: Token $NETBIRD_PAT" \
  -H 'Accept: application/json')"

printf '%s' "$peers" | jq -r '.[] | "name=\(.name)\thostname=\(.hostname)\t\(.ip)\tconnected=\(.connected)"'

# This is the assertion the whole change turns on. A peer that was merely
# disconnected would still be listed here, waiting out the ten minutes an
# ephemeral key takes to reap it; a deregistered one is gone from the server now.
if printf '%s' "$peers" | jq -e --arg ip "$NETBIRD_IP" 'any(.[]; .ip == $ip)' > /dev/null; then
  echo "::error::the server still has a peer at $NETBIRD_IP, so the cleanup did not deregister it"
  exit 1
fi

echo "the server no longer has a peer at $NETBIRD_IP"

# The post step runs this a second time at the end of every job, so a second pass
# has to be harmless. It is also the only part of the post step this job can
# check for itself.
echo '=== Running the cleanup again ==='
STATE_NB_CONNECTED=true STATE_NB_INSTALLED=true bash src/cleanup.sh

echo 'the cleanup is safe to run twice'
