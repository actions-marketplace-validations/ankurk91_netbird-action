#!/usr/bin/env bash
# Check that src/install.sh installed the version it was asked for, and the
# newest release when it was asked for nothing.
set -euo pipefail

EXPECTED="${EXPECTED_VERSION:-}"
LATEST_URL='https://api.github.com/repos/netbirdio/netbird/releases/latest'

installed="$(netbird version)"
echo "=== The runner has ${installed} ==="

if [ -z "$EXPECTED" ]; then
  echo '=== Asking GitHub which release is the newest ==='

  # Unauthenticated callers get 60 requests an hour per IP address, shared with
  # every other runner behind it. The workflow token lifts that to 1000 for the
  # repository, so send it when there is one.
  auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  release="$(curl -fsS --max-time 30 --retry 2 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "${auth[@]}" "$LATEST_URL")"

  # Releases are tagged 'v0.78.1' while the client reports '0.78.1'.
  EXPECTED="$(printf '%s' "$release" | jq -r '.tag_name // empty' | sed 's/^v//')"

  if [ -z "$EXPECTED" ]; then
    echo '::error::the release API returned no tag_name'
    printf '%s\n' "$release"
    exit 1
  fi

  echo "the newest release is ${EXPECTED}"
fi

if [ "$installed" != "$EXPECTED" ]; then
  echo "::error::expected ${EXPECTED}, but the runner ended up with ${installed}"
  exit 1
fi

echo 'the installed version is the one expected'
