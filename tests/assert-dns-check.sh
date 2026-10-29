#!/usr/bin/env bash
# Run src/dns-check.sh against the network the action just joined.
#
# No stubs: a real peer on a real server, names resolved through the runner's
# own resolver. The peer's own record is what makes this possible - a network of
# one peer still publishes a name, and it is the only name here that is certain
# to exist.
set -uo pipefail

DNS_CHECK="${GITHUB_WORKSPACE:-$PWD}/src/dns-check.sh"

# The client is the only thing that knows the domain the server hands out, which
# differs between NetBird cloud and a self-hosted deployment. Reading it back
# keeps this from hard-coding a domain the throwaway server may not use.
fqdn="$(sudo netbird status -d | awk '/FQDN:/ { print $NF; exit }')"

if [ -z "$fqdn" ]; then
  echo '::error::the client reports no FQDN, so it was never given a DNS name'
  sudo netbird status -d
  exit 1
fi

# Present unless the workflow passed --disable-ipv6, and worth naming: the
# resolver hands the v6 answer out ahead of the v4 one, so it is the address a
# later step would actually use.
netbird_ipv6="$(sudo netbird status -6 2> /dev/null || true)"
netbird_ipv6="${netbird_ipv6%%/*}"

echo "the peer calls itself $fqdn, and holds $NETBIRD_IP ${netbird_ipv6:-(no IPv6 overlay)}"

# A name under the peer's own domain that nothing registered. NetBird answers
# for that zone, so this is its NXDOMAIN rather than the public resolver's.
missing="no-such-peer-${GITHUB_RUN_ID:-0}.${fqdn#*.}"

failures=0

# Runs the script the action runs, with the inputs a workflow would set. The
# timeout is per case: the ones expected to pass need room for NetBird's DNS to
# settle, and the ones expected to fail should not spend it.
check() {
  local description="$1" expected_status="$2" expected_output="$3"
  shift 3

  local output status
  output="$(env "$@" bash "$DNS_CHECK" 2>&1)"
  status=$?

  if [ "$status" -ne "$expected_status" ]; then
    echo "::error::${description}: expected exit ${expected_status}, got ${status}"
    printf '%s\n' "$output"
    failures=$((failures + 1))
    return
  fi

  if [ -n "$expected_output" ] && ! printf '%s' "$output" | grep -qF "$expected_output"; then
    echo "::error::${description}: the output does not mention '${expected_output}'"
    printf '%s\n' "$output"
    failures=$((failures + 1))
    return
  fi

  echo "ok - ${description}"
}

echo '=== A name the network really publishes ==='
# The whole point of the input: the peer's own name, resolved through NSS the
# way a later step's curl would, and answering with its address on the overlay.
# Not pinned to a single address: with an IPv6 overlay in play the name answers
# in both families, and which one is printed first is the resolver's business.
check 'the peer resolves its own name' 0 "$fqdn resolved to" \
  INPUT_DNS_HOSTNAMES="$fqdn" INPUT_TIMEOUT=30
check 'and the answer holds its overlay address' 0 "$NETBIRD_IP" \
  INPUT_DNS_HOSTNAMES="$fqdn" INPUT_TIMEOUT=30

check 'the same list written over several lines is read in full' 0 "resolved to $NETBIRD_IP" \
  INPUT_DNS_HOSTNAMES="$fqdn,
$fqdn" INPUT_TIMEOUT=30

echo '=== A name the network does not publish ==='
check 'a name nothing registered is waited on, then fails' 1 "$missing did not resolve" \
  INPUT_DNS_HOSTNAMES="$missing" INPUT_TIMEOUT=5

echo '=== A name that answers from outside the network ==='
# Public DNS still works after joining: NetBird takes over its own zone, not
# every name. So this really is a public answer reaching a real resolver, which
# is the split-horizon failure the guard exists to catch.
check 'a public answer is refused while private addresses are required' 1 'resolved outside the network' \
  INPUT_DNS_HOSTNAMES='example.com' INPUT_TIMEOUT=5

check 'the same name passes once private addresses are not required' 0 'example.com resolved to' \
  INPUT_DNS_HOSTNAMES='example.com' INPUT_DNS_REQUIRE_PRIVATE=false INPUT_TIMEOUT=15

# The guard has to look at both families or the v6 half of a dual-stack answer
# goes unexamined - and that is the half the resolver offers first. Only worth
# asserting when the peer really got a v6 address, which is what --disable-ipv6
# takes away.
if [ -n "$netbird_ipv6" ]; then
  echo '=== The IPv6 half of the answer ==='

  case "${netbird_ipv6,,}" in
    fc* | fd*)
      echo "ok - the overlay address $netbird_ipv6 is unique local, which is what the guard treats as inside"
      ;;
    *)
      echo "::error::the overlay address $netbird_ipv6 is not unique local, so dns-check.sh would refuse the peer's own name"
      failures=$((failures + 1))
      ;;
  esac

  check 'the peer resolves its own name in both families' 0 "$netbird_ipv6" \
    INPUT_DNS_HOSTNAMES="$fqdn" INPUT_TIMEOUT=30
else
  echo 'the peer has no IPv6 overlay address, so there is no v6 half to check'
fi

echo '=== Nothing asked for ==='
check 'a workflow that sets no names does nothing' 0 '' \
  INPUT_DNS_HOSTNAMES='' INPUT_TIMEOUT=5

if [ "$failures" -ne 0 ]; then
  echo "::error::${failures} dns-check case(s) failed against the real network"
  sudo netbird status -d
  exit 1
fi

echo 'the DNS wait behaves against a real network'
