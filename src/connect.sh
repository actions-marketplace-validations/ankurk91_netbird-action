#!/usr/bin/env bash
# Register the runner as a peer and put it on the network.
set -euo pipefail

SETUP_KEY="${INPUT_SETUP_KEY:-}"
MANAGEMENT_URL="${INPUT_MANAGEMENT_URL:-https://api.netbird.io:443}"
PEER_NAME="${INPUT_PEER_NAME:-}"
EXIT_NODE="${INPUT_EXIT_NODE:-}"
EXTRA_ARGS="${INPUT_ARGS:-}"
TIMEOUT="${INPUT_TIMEOUT:-60}"
DIAGNOSTICS="${INPUT_DIAGNOSTICS:-false}"

if [ -z "$SETUP_KEY" ]; then
  echo "::error::input 'setup-key' is empty"
  exit 1
fi

# A key passed from `vars` instead of `secrets` reaches the log unmasked
# otherwise, and every failure path below prints diagnostics.
echo "::add-mask::$SETUP_KEY"

case "$DIAGNOSTICS" in
  true | false) ;;
  *)
    echo "::error::input 'diagnostics' must be 'true' or 'false', got '$DIAGNOSTICS'"
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

# Read by diagnostics.sh, which runs later - by then an exit node may be carrying
# the traffic, so it cannot take this reading itself.
IP_BEFORE_FILE="${RUNNER_TEMP:-/tmp}/netbird-public-ip-before"

# Read by the post step at the end of the job. See install.sh for why a missing
# GITHUB_STATE is not an error.
save_state() {
  if [ -n "${GITHUB_STATE:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_STATE"
  fi
}

# The action fills this in from the run it belongs to, so it is only ever empty
# when someone passes an empty string deliberately - which means the client
# falls back to the runner's own hostname.
if [ -n "$PEER_NAME" ] &&
  ! [[ $PEER_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
  echo "::error::input 'peer-name' cannot be used as a peer name: '$PEER_NAME'. Use letters, digits and hyphens, up to 63 characters, not starting or ending with a hyphen."
  exit 1
fi

if [ "$DIAGNOSTICS" = 'true' ]; then
  curl -4 -s --connect-timeout 3 --max-time 5 https://icanhazip.com > "$IP_BEFORE_FILE" || true
fi

# Passing the key as --setup-key would leave it in the process list, where any
# other job on a shared self-hosted runner can read it.
key_file="$(mktemp "${RUNNER_TEMP:-/tmp}/netbird-setup-key.XXXXXX")"
trap 'rm -f "$key_file"' EXIT

printf '%s' "$SETUP_KEY" > "$key_file"

up_args=(--setup-key-file "$key_file" --management-url "$MANAGEMENT_URL")

if [ -n "$PEER_NAME" ]; then
  up_args+=(--hostname "$PEER_NAME")
fi

# Whitespace is the only separator here, so an argument cannot contain one. The
# `tr` matters: `read -a` alone stops at the first newline and silently drops
# every flag after it. Commas are left alone - flag values carry them.
read -r -a extra_args <<< "$(printf '%s' "$EXTRA_ARGS" | tr '\n\t' '  ')"
up_args+=("${extra_args[@]}")

# A runner that manages its own client is already on a network, and the login
# below replaces that session rather than adding to it. The cleanup cannot put it
# back, so it says so instead of leaving the runner quietly off its own network.
if sudo netbird status --check startup > /dev/null 2>&1; then
  save_state NB_WAS_LOGGED_IN true
fi

# Recorded before the login rather than after it, because a login that fails
# part-way can still have registered the peer, and that is exactly the case where
# leaving it behind would matter.
save_state NB_CONNECTED true

echo "=== Connecting as '${PEER_NAME:-$(hostname)}' ==="
sudo netbird up "${up_args[@]}"

rm -f "$key_file"
trap - EXIT

# `netbird up` returns once the daemon has accepted the login, which is earlier
# than the peer being able to carry traffic: the signal connection and the
# network map both follow. Waiting here keeps a later step from failing on a
# peer that was merely registered.
echo '=== Waiting for the peer to connect ==='
for _ in $(seq "$TIMEOUT"); do
  # 'startup' is management and signal both connected, plus a relay available
  # when the network has any. It exits 0 or 1 and says which leg is missing, so
  # nothing here depends on how the status report happens to be worded.
  if check_error="$(sudo netbird status --check startup 2>&1)"; then
    connected=1
    break
  fi

  sleep 1
done

if [ -z "${connected:-}" ]; then
  # A GitHub annotation is one line, and the check writes its reason as its own.
  reason="${check_error:-the daemon did not answer}"
  echo "::error::the peer did not reach the network within ${TIMEOUT}s (${reason//$'\n'/ }). Check the setup key has not expired or hit its usage limit, and that the management URL is right."
  sudo netbird status -d -A || true
  exit 1
fi

echo 'peer connected'

if [ -n "$EXIT_NODE" ]; then
  echo "=== Selecting the exit node '$EXIT_NODE' ==="

  # The route only exists on this peer once the management service has pushed a
  # network map naming it, which lands after the login the loop above waited on.
  for _ in $(seq "$TIMEOUT"); do
    if sudo netbird routes ls | grep -qF "$EXIT_NODE"; then
      route_available=1
      break
    fi

    sleep 1
  done

  if [ -z "${route_available:-}" ]; then
    echo "::error::exit node '$EXIT_NODE' was never distributed to this peer. Check the network ID, and that the route's distribution groups cover the group the setup key assigns."
    sudo netbird routes ls || true
    sudo netbird status -d -A || true
    exit 1
  fi

  # Replaces the current selection, so from here the runner's traffic for that
  # network - the whole internet, for an exit node - goes through it.
  sudo netbird routes select "$EXIT_NODE"
  save_state NB_EXIT_NODE "$EXIT_NODE"
  echo 'exit node selected'
fi

# The peer's own address on the overlay network, which is what a later step
# needs to tell other peers where to reach this runner.
netbird_ip="$(sudo netbird status -4 2> /dev/null || true)"
netbird_ip="${netbird_ip%%/*}"
echo "netbird-ip=${netbird_ip}" >> "$GITHUB_OUTPUT"

