#!/usr/bin/env bash
# Wait until the names the job depends on resolve inside the network.
#
# `netbird status --check startup` covers management, signal and relay, not DNS -
# a peer can be fully connected while a name still fails to resolve.
#
# Must run after the exit node is selected, so it sees the network the job will.
set -euo pipefail

DNS_HOSTNAMES="${INPUT_DNS_HOSTNAMES:-}"
REQUIRE_PRIVATE="${INPUT_DNS_REQUIRE_PRIVATE:-true}"
TIMEOUT="${INPUT_TIMEOUT:-60}"
DIAGNOSTICS="${INPUT_DIAGNOSTICS:-false}"

# Before the validation below: a workflow that never sets 'dns-hostnames' must
# not be able to fail here.
if [ -z "${DNS_HOSTNAMES//[[:space:],]/}" ]; then
  exit 0
fi

case "$REQUIRE_PRIVATE" in
  true | false) ;;
  *)
    echo "::error::input 'dns-require-private' must be 'true' or 'false', got '$REQUIRE_PRIVATE'"
    exit 1
    ;;
esac

case "$TIMEOUT" in
  '' | *[!0-9]*)
    echo "::error::input 'timeout' must be a whole number of seconds, got '$TIMEOUT'"
    exit 1
    ;;
esac

if [ "$TIMEOUT" -lt 1 ]; then
  echo "::error::input 'timeout' must be at least 1 second, got '$TIMEOUT'"
  exit 1
fi

# Commas, spaces and newlines all separate. The `tr` matters: `read -a` alone
# stops at the first newline and silently checks only the names before it.
hosts=()
declare -A seen=()

read -r -a entries <<< "$(printf '%s' "$DNS_HOSTNAMES" | tr ',\n\t' '   ')"

for entry in "${entries[@]}"; do
  # Refuse a URL or 'host:port' by name here, or the wait reports it as a name
  # that would not resolve.
  if ! [[ $entry =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    echo "::error::input 'dns-hostnames' contains '$entry', which is not a hostname. Pass the name on its own, without a scheme, port or path."
    exit 1
  fi

  # getent hands an address straight back without a lookup, so a literal would
  # pass the wait having tested nothing. No TLD is all digits - that splits them.
  if [[ ${entry##*.} =~ ^[0-9]+$ ]]; then
    echo "::error::input 'dns-hostnames' contains '$entry', which is an address rather than a hostname. There is nothing to wait for in an address - pass the name that resolves to it."
    exit 1
  fi

  # A name asked for twice is still one thing to wait for.
  if [ -z "${seen[$entry]+set}" ]; then
    seen["$entry"]=1
    hosts+=("$entry")
  fi
done

# Inside = NetBird's 100.64/10, RFC 1918, or IPv6 unique local. Peers get a ULA
# overlay address too unless the workflow passes '--disable-ipv6'.
is_private_address() {
  local first second

  # fc00::/7 is exactly the addresses opening fc or fd. Link-local and loopback
  # are excluded on purpose - a peer is not reachable on either.
  if [[ $1 == *:* ]]; then
    [[ ${1,,} =~ ^f[cd] ]] && return 0
    return 1
  fi

  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1

  # Base 10 explicitly, or an octet written as '010' is read as octal.
  first="$((10#${BASH_REMATCH[1]}))"
  second="$((10#${BASH_REMATCH[2]}))"

  [ "$first" -eq 10 ] && return 0
  [ "$first" -eq 100 ] && [ "$second" -ge 64 ] && [ "$second" -le 127 ] && return 0
  [ "$first" -eq 172 ] && [ "$second" -ge 16 ] && [ "$second" -le 31 ] && return 0
  [ "$first" -eq 192 ] && [ "$second" -eq 168 ] && return 0

  return 1
}

# getent uses NSS, the same path as the rest of the job, so this proves what a
# later step depends on.
#
# 'ahosts' not 'ahostsv4': a name published only as AAAA would read as
# unresolved, and a private A beside a public AAAA would pass while the next step
# followed the AAAA off the network.
#
# Capped at the remaining deadline - an unresolvable name holds the resolver for
# seconds, and there may be a list of them.
resolve_addresses() {
  local budget=$((deadline - SECONDS))

  if [ "$budget" -lt 1 ]; then
    budget=1
  fi

  timeout "$budget" getent ahosts "$1" 2> /dev/null | awk '{ print $1 }' | sort -u
}

echo '=== Waiting for DNS ==='

# systemd-resolved caches a miss for the zone's SOA lifetime, so a name looked up
# before NetBird registered its domain stays missing long after it would answer.
sudo resolvectl flush-caches > /dev/null 2>&1 || true

if [ "$REQUIRE_PRIVATE" = 'true' ]; then
  echo "waiting for ${hosts[*]} to resolve to a private address"
else
  echo "waiting for ${hosts[*]} to resolve"
fi

declare -A reason=()
pending=("${hosts[@]}")

# A deadline, not a pass count, and read before every lookup. An unresolvable
# name holds the resolver for seconds, so a list of them would run well past
# 'timeout' if the clock were only checked between passes.
deadline=$((SECONDS + TIMEOUT))

while true; do
  still_pending=()
  expired=''

  for host in "${pending[@]}"; do
    # Checked per lookup, not per pass, or a list of slow names spends 'timeout'
    # once each. Keeps the last pass's reason so the error still names every host.
    if [ -n "$expired" ] || [ "$SECONDS" -ge "$deadline" ]; then
      expired=1
      still_pending+=("$host")
      reason["$host"]="${reason[$host]:-was not looked up before the timeout}"
      continue
    fi

    mapfile -t ips < <(resolve_addresses "$host")

    if [ "${#ips[@]}" -eq 0 ]; then
      still_pending+=("$host")
      reason["$host"]='did not resolve'
      continue
    fi

    # Split-horizon: public DNS can answer first while NetBird's zone settles,
    # and the next step then leaves the mesh silently to reach it.
    if [ "$REQUIRE_PRIVATE" = 'true' ]; then
      public_ips=()

      for ip in "${ips[@]}"; do
        is_private_address "$ip" || public_ips+=("$ip")
      done

      if [ "${#public_ips[@]}" -gt 0 ]; then
        still_pending+=("$host")
        reason["$host"]="resolved outside the network, to ${public_ips[*]}"
        continue
      fi
    fi

    echo "$host resolved to ${ips[*]}"
  done

  # The deadline can fall during a pass's last lookup - the check above cannot
  # see that, there being no next name to ask about.
  if [ "$SECONDS" -ge "$deadline" ]; then
    expired=1
  fi

  pending=("${still_pending[@]}")

  # Recorded, not inferred from the clock: a pass landing exactly on the deadline
  # succeeded, and re-reading the time would call it a timeout.
  if [ "${#pending[@]}" -eq 0 ]; then
    ready=1
    break
  fi

  if [ -n "$expired" ]; then
    break
  fi

  sleep 1
done

if [ -z "${ready:-}" ]; then
  details=()

  for host in "${pending[@]}"; do
    details+=("$host ${reason[$host]}")
  done

  # A GitHub annotation is one line, so per-name detail is joined into it.
  joined="$(printf '%s; ' "${details[@]}")"

  echo "::error::DNS was not ready within ${TIMEOUT}s: ${joined%; }. Check that NetBird DNS is on for this peer's group and that the name belongs to a NetBird zone. A name that is meant to answer with a public address needs 'dns-require-private: false'."

  # Says which server answered. Ungated: unlike the resolver config below, this
  # only names hosts the workflow itself asked for.
  if command -v resolvectl > /dev/null; then
    echo '::group::resolvectl query'
    for host in "${pending[@]}"; do
      resolvectl query "$host" || true
    done
    echo '::endgroup::'
  fi

  # Anonymised, like every failure path here. The resolver config below is not -
  # it lists every nameserver handed out - so it stays behind 'diagnostics'.
  sudo netbird status -d -A || true

  if [ "$DIAGNOSTICS" = 'true' ]; then
    echo '::group::resolver configuration'
    cat /etc/resolv.conf || true

    if command -v resolvectl > /dev/null; then
      resolvectl status || true
    fi
    echo '::endgroup::'
  fi

  exit 1
fi

echo 'DNS is ready'
