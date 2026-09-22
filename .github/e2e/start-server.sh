#!/usr/bin/env bash
# Boot a throwaway NetBird server on the runner and mint what the end-to-end job
# needs from it: an admin token, and a setup key for the action to register with.
set -euo pipefail

API_URL="${API_URL:-http://localhost:8081}"
# Pinned so an upstream release cannot turn a green run red on its own. Bump it
# deliberately; 'latest' is one tag push away from breaking every branch at once.
IMAGE="${NETBIRD_SERVER_IMAGE:-netbirdio/netbird-server:0.79.0}"
CONFIG="${GITHUB_WORKSPACE:-$PWD}/.github/e2e/config.yaml"

# NB_SETUP_PAT_ENABLED opens /api/setup, which creates the first owner and hands
# back a token without anyone logging in. It is the only way to bootstrap the
# server unattended, and it closes itself once an account exists.
# NB_DISABLE_GEOLOCATION because the server otherwise downloads the MaxMind
# GeoLite2 database on first boot and calls log.Fatal on any failure - an
# upstream checksum mismatch is enough to kill the whole job. Nothing here
# geolocates a peer.
# dataDir has to exist before the server starts - it creates the SQLite file in
# there, not the directory - and the image ships without it. tmpfs rather than a
# volume: none of this outlives the job, and nothing is left on the runner.
echo '=== Starting the NetBird server ==='
docker run --detach --name netbird-server \
  --network host \
  --env NB_SETUP_PAT_ENABLED=true \
  --env NB_DISABLE_GEOLOCATION=true \
  --tmpfs /var/lib/netbird \
  --volume "$CONFIG:/etc/netbird/config.yaml:ro" \
  "$IMAGE" --config /etc/netbird/config.yaml

# Waiting on the management API rather than the relay's healthcheck, because the
# API is the part the rest of this script and the action itself talk to. Any
# HTTP status answers the only question being asked - is it listening - so the
# probe does not depend on what the endpoint decides to return.
echo '=== Waiting for it to come up ==='
for _ in $(seq 60); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$API_URL/api/instance" 2> /dev/null || true)"

  case "$code" in
    2* | 3* | 4*)
      server_ready=1
      break
      ;;
  esac

  # A server that died is never coming up, so stop waiting out the full budget.
  if [ -z "$(docker ps --quiet --filter name=netbird-server)" ]; then
    break
  fi

  sleep 2
done

if [ -z "${server_ready:-}" ]; then
  if [ -z "$(docker ps --quiet --filter name=netbird-server)" ]; then
    echo "::error::the NetBird server exited before it was ready, with code $(docker inspect --format '{{.State.ExitCode}}' netbird-server)"
  else
    echo "::error::the NetBird server is running but never answered on $API_URL"
  fi

  docker logs netbird-server
  exit 1
fi

# setup_required tells us the bootstrap below is still open to us.
curl -fsS --max-time 10 "$API_URL/api/instance" | jq .

echo '=== Creating the owner and an admin token ==='
setup_response="$(curl -fsS --max-time 30 -X POST "$API_URL/api/setup" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data '{"email":"admin@example.com","name":"E2E Admin","password":"e2e-Admin-Password-1","create_pat":true,"pat_expire_in":1}')"

pat="$(printf '%s' "$setup_response" | jq -r '.personal_access_token // empty')"

if [ -z "$pat" ]; then
  echo '::error::/api/setup returned no token, so the server cannot be bootstrapped'
  printf '%s\n' "$setup_response"
  docker logs netbird-server
  exit 1
fi

echo "::add-mask::$pat"

echo '=== Creating a setup key ==='
key_response="$(curl -fsS --max-time 30 -X POST "$API_URL/api/setup-keys" \
  -H "Authorization: Token $pat" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data '{"name":"e2e","type":"reusable","expires_in":86400,"auto_groups":[],"usage_limit":0,"ephemeral":true}')"

setup_key="$(printf '%s' "$key_response" | jq -r '.key // empty')"

if [ -z "$setup_key" ]; then
  echo '::error::could not create a setup key'
  printf '%s\n' "$key_response"
  exit 1
fi

echo "::add-mask::$setup_key"

{
  echo "pat=$pat"
  echo "setup-key=$setup_key"
} >> "$GITHUB_OUTPUT"

echo 'the server is ready and a setup key is waiting'
