#!/usr/bin/env bash
# Hand the runner back the way it was found, once the job is over.
#
# Matters on self-hosted runners only: without this the daemon stays connected, an
# exit node keeps carrying traffic and the peer key stays on disk, so the next job
# on that machine inherits a network it never asked to join.
#
# Best effort throughout - the job's work is already done, so a cleanup that
# cannot finish warns rather than fails. Hence no 'set -e' and the '|| true's.
set -uo pipefail

CONNECTED="${STATE_NB_CONNECTED:-false}"
EXIT_NODE="${STATE_NB_EXIT_NODE:-}"
INSTALLED="${STATE_NB_INSTALLED:-false}"
SERVICE_STARTED="${STATE_NB_SERVICE_STARTED:-false}"
WAS_LOGGED_IN="${STATE_NB_WAS_LOGGED_IN:-false}"

# The e2e job runs this directly, then the post step runs it again. The marker
# stops the second pass warning through commands that cannot work twice.
MARKER="${RUNNER_TEMP:-/tmp}/netbird-action-cleaned"

if [ -e "$MARKER" ]; then
  echo 'the runner was already cleaned up, nothing to do'
  exit 0
fi

if ! command -v netbird > /dev/null; then
  echo 'no NetBird client on this runner, nothing to do'
  exit 0
fi

# Nothing recorded, so the action never got far enough to change anything.
if [ "$CONNECTED" != 'true' ] && [ "$INSTALLED" != 'true' ] && [ "$SERVICE_STARTED" != 'true' ]; then
  echo 'the action did not connect or install anything, nothing to do'
  exit 0
fi

echo '=== Cleaning up ==='
touch "$MARKER" 2> /dev/null || true

done_steps=()

if [ -n "$EXIT_NODE" ]; then
  if sudo netbird routes deselect "$EXIT_NODE" > /dev/null 2>&1; then
    done_steps+=("deselected the exit node '$EXIT_NODE'")
  else
    echo "::warning::could not deselect the exit node '$EXIT_NODE'"
  fi
fi

if [ "$CONNECTED" = 'true' ]; then
  # connect.sh records the login before attempting it, so a peer that never came
  # up reaches here too. Its deregister fails rightly - only warn if one was live.
  if sudo netbird status --check startup > /dev/null 2>&1; then
    peer_was_up=1
  fi

  # 'logout' is an alias for 'deregister', dropping the peer from the dashboard
  # now rather than after the ephemeral timeout. It reaches the management service
  # through the daemon, so it must run before the 'down' and service stop below.
  if sudo netbird logout > /dev/null 2>&1; then
    done_steps+=('deregistered the peer')
  elif [ -n "${peer_was_up:-}" ]; then
    echo '::warning::could not deregister the peer, so it may still be registered with the management service. An ephemeral setup key removes it once it has been offline for 10 minutes; a key that is not ephemeral leaves it in the dashboard to delete by hand.'
  fi

  if sudo netbird down > /dev/null 2>&1; then
    done_steps+=('disconnected from the network')
  fi
fi

if [ "$INSTALLED" = 'true' ]; then
  # The binary is left behind on purpose: it holds nothing secret, and a
  # self-hosted runner would otherwise re-download it every job.
  sudo netbird service stop > /dev/null 2>&1 || true

  if sudo netbird service uninstall > /dev/null 2>&1; then
    done_steps+=('uninstalled the service')
  else
    echo '::warning::could not uninstall the NetBird service'
  fi

  # Holds the peer key, so this matters most on a runner that keeps its disk.
  # /etc/netbird is where older clients kept the same thing.
  if sudo rm -rf /var/lib/netbird /etc/netbird > /dev/null 2>&1; then
    done_steps+=('removed the client configuration')
  else
    echo '::warning::could not remove /var/lib/netbird, which holds the peer key'
  fi
elif [ "$SERVICE_STARTED" = 'true' ]; then
  # The client was already here with its service down, so stopping it restores it.
  if sudo netbird service stop > /dev/null 2>&1; then
    done_steps+=('stopped the service the action started')
  else
    echo '::warning::could not stop the NetBird service'
  fi
fi

# Last, because it is the one thing here the action cannot put right itself.
if [ "$WAS_LOGGED_IN" = 'true' ]; then
  echo '::warning::this runner was already logged in to a NetBird network before the action ran. That session was replaced by the one the action created, and has now been ended - the runner is no longer on its original network. Log it back in, or keep this action off runners that manage their own NetBird client.'
fi

if [ "${#done_steps[@]}" -eq 0 ]; then
  echo 'nothing could be cleaned up, see the warnings above'
else
  for step in "${done_steps[@]}"; do
    echo "$step"
  done
fi
