#!/usr/bin/env bash
# Describe the network the runner ended up on.
#
# Must run after the DNS wait: from connect.sh the network map has not landed, so
# the peer count and nameservers read as empty.
#
# Best effort - main.mjs runs this after a failure too and ignores the status.
set -uo pipefail

DIAGNOSTICS="${INPUT_DIAGNOSTICS:-false}"

# Taken by connect.sh before the routes changed.
IP_BEFORE_FILE="${RUNNER_TEMP:-/tmp}/netbird-public-ip-before"

if [ "$DIAGNOSTICS" != 'true' ]; then
  exit 0
fi

echo
echo '=== NetBird addresses ==='
echo "IPv4: $(sudo netbird status -4 2> /dev/null || echo 'unavailable')"

netbird_ipv6="$(sudo netbird status -6 2> /dev/null || true)"
if [[ $netbird_ipv6 == *:* ]]; then
  echo "IPv6: $netbird_ipv6"
fi

# Folded: on a network of any size this is the longest thing in the job log.
echo '::group::NetBird status'
sudo netbird status -d || true
echo '::endgroup::'

echo '::group::Networks'
sudo netbird routes ls || true
echo '::endgroup::'

# `ip route` alone shows nothing: NetBird routes live in their own table behind a
# rule, so the main table looks the same with or without an exit node. The local
# table is dropped - one entry per address on the box, no signal.
echo '::group::Routing'
ip rule show || true
ip route show table all 2> /dev/null | grep -Ev '^(local|broadcast|multicast|anycast) ' || true
echo '::endgroup::'

# With an exit node these must differ. If they match, the traffic never entered
# the tunnel however healthy everything above looks.
echo
echo "Public IP before NetBird: $(cat "$IP_BEFORE_FILE" 2> /dev/null || echo 'not recorded')"
echo "Public IP after NetBird: $(curl -4 -s --connect-timeout 3 --max-time 5 https://icanhazip.com || echo 'unavailable')"

exit 0
