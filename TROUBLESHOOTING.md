# Troubleshooting

Most of these are quicker to diagnose with the action's diagnostics turned on, which prints the NetBird IP,
`netbird status -d`, the networks the peer holds, the routes and the public IP before and after connecting:

```yaml
- uses: ankurk91/netbird-action@v2
  with:
    setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
    diagnostics: true
```

It is off by default — see [Diagnostics](README.md#diagnostics) — so turn it back off once the connection works.

## The peer did not reach the network within 60s

The client registered with the management service but never came up as connected. The error carries the reason the
client gave — `management not connected`, `signal not connected`, or no relay available — so read that first. In order
of likelihood:

- **The setup key expired or hit its usage limit.** Check it under **Setup Keys** in the dashboard; a one-off key is
  spent after a single peer and a reusable one has a peer count. Rotate it and update the secret.
- **The key is for a different management service.** A self-hosted deployment needs its `management-url` passed too.
- **The management or signal service is unreachable from the runner.** Self-hosted only — a GitHub-hosted runner has to
  be able to reach both over the public internet.
- **No relay is available.** The action waits for one when the network has any configured, because a peer without a
  relay cannot fall back when a direct connection does not form. Self-hosted deployments are where this shows up:
  check the relay is running and that the runner can reach the address the management service hands out for it.

## Exit node was never distributed to this peer

The route exists, but not for this peer. The `exit-node` value has to be the network ID as the dashboard and
`netbird routes ls` show it, and the route's **distribution groups** have to include a group the setup key assigns to
the peer. A key that puts runners in their own group needs that group added to the route.

Turn on `diagnostics` and read the `=== Networks ===` section to see which networks did arrive.

## The job hangs after connecting

An exit node routes all of the runner's traffic, including its connection to GitHub. If the exit node cannot reach
GitHub the runner stops reporting and the job sits until it times out. Drop `exit-node` to confirm that is the cause.

## Reaching a peer by name does not work

NetBird publishes peers under `.netbird.cloud` through its own nameserver. Check the `Nameservers` line in
`netbird status` — if it reports none available, the nameserver group in the dashboard does not cover this peer's group.
Its NetBird IP works either way.

Connecting is not the same as resolving, and the action's own wait covers only the first: management, signal and a
relay. Set [`dns-hostnames`](README.md#waiting-for-dns) to the names the job depends on and the action will wait for those
too, instead of leaving the next step to fail on a name that was not ready yet.

## DNS was not ready within 60s

Which half of the message applies decides what to look at.

**`did not resolve`** — the name never answered. Usually the nameserver group in the dashboard does not cover this
peer's group, so check the `Nameservers` line as above. Otherwise the record does not exist: a peer is published under
the name it registered with, not the name you expected it to have.

**`resolved outside the network`** — the name answered, with a publicly routable address. That is the split-horizon
case: the name exists in public DNS as well as in a NetBird zone, and public DNS won while NetBird's zone was still
settling. Left alone it is worse than a failure, because the next step reaches the public endpoint and never says so —
which tends to surface as a puzzling `403` from an API that was meant to be internal.

If the address named in the message is an **IPv6** one, that is the same problem in the half of the answer that is
easier to miss: a name can have a tidy `100.64.x.x` A record while its AAAA record points at the public internet, and
the AAAA is the one the next step would follow.

If the name is *meant* to answer publicly — one reached through an exit node, say — set `dns-require-private: false`. If
it is not, the record is missing from the NetBird zone and the peer is falling back to public DNS.

What counts as inside the network, and why the check works this way, is in
[How it works](HOW-IT-WORKS.md#why-the-address-has-to-be-private).

## Peers pile up in the dashboard

Every run registers a new peer. The action's post-job step deregisters it when the job ends, so the usual cause is a run
that never reached that step — a cancelled workflow, a runner killed outright, or a job that hit its timeout.

Turn on **Ephemeral** for the setup key to catch those: an ephemeral peer is removed once it has been offline for ten
minutes. A key that is not ephemeral leaves them in the dashboard to delete by hand.

If peers pile up from runs that *did* finish, read the `Post` group for this action at the end of the job log — the
cleanup says what it managed to do, and warns when it could not reach the management service to deregister.

## The NetBird daemon did not come up

The client installed but its service never started. Almost always a self-hosted runner without systemd — a container,
typically. The client runs as a system service and needs an init system to run under.

## This action needs netbird `0.67.0` or newer

Both of the action's waits — for the daemon, and for the peer to reach the network — use `netbird status --check`, which
NetBird added in `0.67.0`.

So either `version` is pinned below `0.67.0`, or the runner already carried an older client — the action keeps a
preinstalled one rather than replacing it, and warns when it does. Raise the pin, or remove the preinstalled client so
the action installs its own. A client reporting something other than a release number, a self-built one, is left alone.

## Permission denied running the client

The runner has no passwordless `sudo`. The client is a system service and every command the action runs goes through
`sudo`. GitHub-hosted runners are fine; a self-hosted one needs its runner user allowed.
