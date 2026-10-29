#!/usr/bin/env bash
# Exercise how src/connect.sh splits the 'args' input, by capturing the argument
# list `netbird up` was actually handed.
#
# The e2e job runs the real client against a real server, but it passes no extra
# flags, and a run that had quietly dropped half of them would still connect and
# pass. Only a stub can show what the client was really asked for.
set -uo pipefail

SCRIPT="${GITHUB_WORKSPACE:-$PWD}/src/connect.sh"
WORK="$(mktemp -d)"
BIN="$WORK/bin"
CAPTURE="$WORK/up-args"
SENTINEL="$WORK/executed"

trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN"

# Records what `netbird up` was given, one argument per line, and answers every
# status check so the script runs through instead of waiting out its timeout.
cat > "$BIN/sudo" << 'EOF'
#!/usr/bin/env bash
shift # the 'netbird' that the script calls through sudo

case "${1:-}" in
  up)
    shift
    printf '%s\n' "$@" > "$CAPTURE_FILE"
    ;;
  status)
    # '-4' asks for the peer address, which the script reports as an output.
    if [ "${2:-}" = '-4' ]; then
      echo '100.64.0.5/10'
    fi
    ;;
esac

exit 0
EOF

chmod +x "$BIN"/*

failures=0

# The script always builds the first four arguments itself, and one of them is a
# random temp path, so the expectation covers only what the input contributed.
check() {
  local description="$1" input="$2" expected="$3"

  : > "$CAPTURE"

  local output status actual
  output="$(
    env PATH="$BIN:$PATH" CAPTURE_FILE="$CAPTURE" RUNNER_TEMP="$WORK" \
      GITHUB_OUTPUT="$WORK/github-output" INPUT_SETUP_KEY='dummy-key' \
      INPUT_PEER_NAME='' INPUT_TIMEOUT=5 INPUT_ARGS="$input" \
      bash "$SCRIPT" 2>&1
  )"
  status=$?

  if [ "$status" -ne 0 ]; then
    echo "::error::${description}: the script exited ${status}"
    printf '%s\n' "$output"
    failures=$((failures + 1))
    return
  fi

  actual="$(tail -n +5 "$CAPTURE")"

  if [ "$actual" != "$expected" ]; then
    echo "::error::${description}: expected these arguments"
    printf '%s\n' "$expected"
    echo 'but netbird up was given'
    printf '%s\n' "$actual"
    failures=$((failures + 1))
    return
  fi

  echo "ok - ${description}"
}

# The bug this guards: `read -a` on its own stops at the first newline, so a
# block listing one flag per line - the way a workflow naturally writes more
# than one - reached the client as its first flag alone, and the job still
# passed. Anything connectivity or security related simply went missing.
echo '=== Every line of the input is used ==='
check 'a YAML block with one flag per line passes both' \
  '--disable-dns
--disable-ipv6' \
  '--disable-dns
--disable-ipv6'
check 'blank lines and indentation do not become arguments' \
  '
  --disable-dns

	--disable-ipv6
' \
  '--disable-dns
--disable-ipv6'

echo '=== Every kind of whitespace separates ==='
check 'spaces separate' '--disable-dns --disable-ipv6' '--disable-dns
--disable-ipv6'
check 'tabs separate' "$(printf -- '--disable-dns\t--disable-ipv6')" '--disable-dns
--disable-ipv6'
check 'a flag and its value are two arguments, not one' \
  '--dns-resolver-address 100.64.0.1' \
  '--dns-resolver-address
100.64.0.1'

# Whitespace is the only separator, so a comma has to survive inside the
# argument it belongs to - several client flags take a comma-separated list.
echo '=== Only whitespace separates ==='
check 'a comma stays inside the argument' \
  '--extra-iface-blacklist eth0,eth1
--disable-dns' \
  '--extra-iface-blacklist
eth0,eth1
--disable-dns'

echo '=== Nothing asked for ==='
check 'an empty input adds nothing' '' ''
check 'whitespace on its own adds nothing either' '
   	
' ''

# The input is split, never evaluated. If that ever changes, whatever a workflow
# interpolated into 'args' becomes code running as the job.
echo '=== The input is never shell ==='
# The expectation splits mid-substitution because the space inside it separates
# like any other: there is nothing here the script treats as syntax.
check 'shell metacharacters are passed through as text' \
  "\$(touch $SENTINEL) \`touch $SENTINEL\` --x=a;touch" \
  "\$(touch
$SENTINEL)
\`touch
$SENTINEL\`
--x=a;touch"

if [ -e "$SENTINEL" ]; then
  echo '::error::the input was executed as shell rather than passed as arguments'
  failures=$((failures + 1))
else
  echo 'ok - none of it ran as a command'
fi

# Splitting the input appends to the list the script already built, so a mistake
# there could just as easily drop the setup key as the extra flags.
echo '=== The arguments the script builds itself survive ==='
if [ "$(sed -n '1p;3p' "$CAPTURE")" = '--setup-key-file
--management-url' ]; then
  echo 'ok - the key and the management URL are still in place'
else
  echo '::error::the arguments the script builds itself were disturbed:'
  cat "$CAPTURE"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "::error::${failures} connect args case(s) failed"
  exit 1
fi

echo 'every connect args case passed'
