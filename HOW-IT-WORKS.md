# How it works

Background for the behaviour the [README](README.md) describes at feature level. Nothing here is needed to use the
action — read it when you want to know *why* something behaves the way it does, or when
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) sends you here.

## Waiting for DNS

### What the peer wait covers, and what it does not

Before this action hands over it waits for the peer itself: the management service connected, the signal service
connected, and a relay available when your network has one. That is the control plane — enough to say the runner has
joined, and nothing at all about DNS.

So a job can be perfectly connected and still fail on the very next line, if that line reaches a peer *by name* rather
than by address. `dns-hostnames` is what closes the gap.

### Writing the list

Commas, spaces and newlines all separate, so a longer list can be written as a block:

```yaml
    dns-hostnames: |
      internal-service.netbird.cloud
      postgres.netbird.cloud
```

Hostnames only. A scheme, a port, a path or a bare IP address is refused when the action starts rather than waited on
and reported later as a name that would not resolve — an address resolves to itself, so waiting on one would prove
nothing.

All the names share one `timeout` between them, not one each.

### How a name is checked

Names are resolved with `getent`, which goes through the same resolver path `curl` and everything else on the runner
takes. A pass therefore means the runner can really resolve the name, rather than only that NetBird reports having a
nameserver.

Both address families are checked. NetBird gives every peer an IPv6 overlay address unless you pass `--disable-ipv6`,
and the resolver hands out the IPv6 answer first — so a name whose `AAAA` record points off the network would otherwise
slip through on the strength of a perfectly good `A` record.

### Why the address has to be private

Resolving is not enough on a split-horizon name — one that exists in public DNS *and* in a NetBird zone. Public DNS can
answer first while NetBird's zone is still settling, and then the name resolves to the far side of the network: the step
after this one leaves the mesh to reach it and says nothing about having done so, which usually surfaces later as a
confusing `403` from an API that was supposed to be internal.

So `dns-require-private` is on by default, and a name only counts as ready once **every** address it resolves to is a
private one: the NetBird range (`100.64.0.0/10`), RFC 1918 (`10/8`, `172.16/12`, `192.168/16`), or — for IPv6 — a unique
local address (`fc00::/7`). Until then the action keeps waiting, and on timeout it says which name answered with which
public address.

What it checks is that the answer is **not publicly routable**. That is not the same as proving the address is reached
*through NetBird*: a runner may already have a route to `10.0.0.0/8` of its own, or another VPN may own it. The check
catches a name escaping to the public internet, which is the failure that goes unnoticed; it does not audit which
private network the answer belongs to.

Turn it off for a name that is *meant* to answer with a public address — one reached through an exit node, typically:

```yaml
    dns-hostnames: api.example.com
    dns-require-private: false
```

## The `netbird-ip` output

The address the runner holds *on the overlay network* — what other peers use to reach it. It is not the runner's public
IP, and it does not change when an exit node is selected: an exit node changes where the runner's outbound traffic
leaves from, not the address it answers on.

## Client version

`version` accepts either form, `0.78.1` or `v0.78.1`. If the runner already carries a NetBird client the action keeps it
rather than replacing it, and warns so a pin that was not honoured does not pass unnoticed.

The action needs NetBird **0.67.0 or newer** because its waits use `netbird status --check`, which NetBird added in that
release. That check exits 0 or 1 and names the leg that is missing, so the action reads a health check rather than
matching English in the status report — wording NetBird is free to change in any release.

Pinning also changes where the version is looked up. `latest` reads NetBird's own CDN, while a pinned tag is resolved
through `api.github.com`, which allows 60 unauthenticated requests an hour per IP address. Hosted runners share egress
addresses, so a busy account can reach that limit and watch installs start failing.

So the action sends `github-token` when, and only when, you pin a version, which lifts the limit to 1000 requests an
hour for the repository. It defaults to the workflow's own `GITHUB_TOKEN` and needs no setup. The `latest` path gains
nothing from a token, so it never sees one.

## Diagnostics

With `diagnostics: true` the action prints the NetBird IP, `netbird status -d`, the networks the peer holds, the routing
table, the runner's public IP before and after connecting, and — on a DNS failure — the resolver's own view from
`resolvectl status`.

Failures print `netbird status -d` with NetBird's own anonymizer on whether or not diagnostics are enabled, so a broken
run stays diagnosable without turning the full output on. Note that the anonymizer masks public addresses and
non-NetBird domains; it deliberately keeps private and CGNAT ranges, which are the ones you need to read the output.

## Cleanup

Off by default, so a registered peer, a connected daemon and the peer key under `/var/lib/netbird` outlive the job. On a
hosted runner all of that dies with the machine and only the dashboard entry remains, which is why the setup key has to
be ephemeral.

`cleanup: true` deregisters the peer, disconnects, and removes the service and configuration if the action installed
them. The binary stays — it holds nothing secret, and a self-hosted runner would re-download it every job. Every step is
best effort, so one that cannot finish warns rather than fails. Only `false` and the default skip it; any other value
cleans up and warns.
