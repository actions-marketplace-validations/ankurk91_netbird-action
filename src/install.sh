#!/usr/bin/env bash
# Install the NetBird client and wait for its daemon to answer.
set -euo pipefail

VERSION="${INPUT_VERSION:-latest}"
GH_TOKEN="${INPUT_GITHUB_TOKEN:-}"
INSTALLER_DIR="${RUNNER_TEMP:-/tmp}/netbird-installer"

# A local service start, not a network wait, so it is fixed rather than tied to
# the 'timeout' input.
DAEMON_TIMEOUT=30

# `netbird status --check` landed in 0.67.0. Every wait here and in connect.sh
# uses it rather than parsing the status report.
MIN_VERSION='0.67.0'

# Read by the post step to work out what is the action's to undo. GITHUB_STATE is
# unset when the tests run a script alone, so a note that goes nowhere is fine.
save_state() {
  if [ -n "${GITHUB_STATE:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_STATE"
  fi
}

if [ "${RUNNER_OS:-Linux}" != 'Linux' ]; then
  echo "::error::this action supports Linux runners only, this one is ${RUNNER_OS}"
  exit 1
fi

# Must come before anything below changes the runner: the cleanup restores what
# was here, not what it finds. The install below records NB_INSTALLED separately.
if command -v netbird > /dev/null && sudo netbird status --check live > /dev/null 2>&1; then
  daemon_was_running=1
fi

# Releases are tagged 'v0.78.1'. The input reads better as '0.78.1', so take
# either form.
if [ "$VERSION" != 'latest' ]; then
  case "$VERSION" in
    v*) ;;
    *) VERSION="v${VERSION}" ;;
  esac

  if ! printf '%s' "$VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "::error::input 'version' must be 'latest' or a release such as '0.78.1', got '${INPUT_VERSION}'"
    exit 1
  fi
fi

echo "=== Installing the NetBird client (${VERSION}) ==="
if command -v netbird > /dev/null; then
  echo "already installed ($(netbird version)), skipping"
  save_state NB_INSTALLED false

  # A runner that brings its own client keeps it - say so, or a pinned 'version'
  # looks like it was honoured.
  if [ "$VERSION" != 'latest' ] && [ "v$(netbird version)" != "$VERSION" ]; then
    echo "::warning::this runner already has netbird $(netbird version), so ${VERSION} was not installed"
  fi
else
  mkdir -p "$INSTALLER_DIR"

  curl --fail --no-progress-meter --location \
    --connect-timeout 10 --max-time 60 --retry 2 \
    --output "$INSTALLER_DIR/install.sh" \
    https://pkgs.netbird.io/install.sh

  chmod 755 "$INSTALLER_DIR/install.sh"

  # Only a pinned tag makes the installer hit the GitHub API, so 'latest' has no
  # use for the token.
  if [ "$VERSION" != 'latest' ] && [ -n "$GH_TOKEN" ]; then
    echo "::add-mask::$GH_TOKEN"
    export GITHUB_TOKEN="$GH_TOKEN"
  else
    unset GITHUB_TOKEN
  fi

  # Binary install, not apt: skips the repository and the apt-get update, and
  # covers arm64 on the same path. No desktop here, so no UI.
  #
  # The group is closed on both paths - left open on a failure it would fold the
  # installer's reason away with the rest of the job.
  echo '::group::NetBird installer'
  if ! NETBIRD_RELEASE="$VERSION" USE_BIN_INSTALL=true SKIP_UI_APP=true "$INSTALLER_DIR/install.sh"; then
    echo '::endgroup::'
    echo "::error::the NetBird installer failed for ${VERSION}. If the version is pinned, check that the release exists."
    exit 1
  fi
  echo '::endgroup::'

  # Only this branch installed anything, so only this one lets the cleanup take
  # the whole install back out.
  save_state NB_INSTALLED true
fi

installed="$(netbird version)"
echo "$installed"

# Without --check every wait below burns its full timeout, then blames the daemon
# instead of the version. Only release numbers are judged - a self-built client
# reports something else and is left alone.
if printf '%s' "$installed" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' &&
  [ "$(printf '%s\n%s\n' "$MIN_VERSION" "$installed" | sort -V | head -n1)" != "$MIN_VERSION" ]; then
  echo "::error::this action needs netbird ${MIN_VERSION} or newer, but the runner has ${installed}"
  exit 1
fi

# The service starts before its socket exists, so a connect that follows straight
# on can arrive with nothing listening.
echo '=== Waiting for the NetBird daemon ==='
for i in $(seq "$DAEMON_TIMEOUT"); do
  # 'live' only asks whether the daemon answers. Nothing stronger can pass yet -
  # the peer does not log in until connect.sh runs.
  if sudo netbird status --check live > /dev/null 2>&1; then
    daemon_ready=1
    break
  fi

  # A binary install leaves the service registered but not always running.
  if [ "$i" -eq 1 ]; then
    # Recorded only if the start worked, or the cleanup warns about stopping a
    # service that never came up.
    if sudo netbird service start > /dev/null 2>&1 && [ -z "${daemon_was_running:-}" ]; then
      save_state NB_SERVICE_STARTED true
    fi
  fi

  sleep 1
done

if [ -z "${daemon_ready:-}" ]; then
  echo "::error::the NetBird daemon did not come up within ${DAEMON_TIMEOUT}s"
  sudo netbird service status || true
  exit 1
fi

echo 'the daemon is up'
