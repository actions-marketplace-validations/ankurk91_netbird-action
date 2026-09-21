# Security Policy

## Supported versions

Only the newest release gets fixes. Pin the action to a major tag so you keep receiving them:

```yaml
- uses: ankurk91/netbird-action@v2
```

Pin to a full commit SHA instead if your threat model calls for it — a tag can be moved, a SHA cannot.

## Reporting a vulnerability

Please do not open a public issue, and do not include a working setup key in anything you send.

Report it through [private vulnerability reporting](https://github.com/ankurk91/netbird-action/security/advisories/new),
which keeps the report between us until a fix is released. 

This is a side project, so please allow a few days for a first reply. I will confirm I received the report, tell you
whether I agree it is a problem, and credit you in the advisory unless you would rather I did not.

## What is worth reporting

The action handles a setup key, which is a credential that can register a peer on your network. Anything that leaks one
is the most serious thing here — for example a way to get the key into the job log past `::add-mask::`, or to leave it
readable on the runner after the action finishes.

Also worth reporting: a way to make the action install something other than the official NetBird release, or to get an
input evaluated as a shell command.

## What is out of scope

The NetBird client and server themselves are not maintained here. Report those
to [NetBird](https://github.com/netbirdio/netbird/security/policy).

Job logs are readable by anyone who can read the repository, so `diagnostics: true` printing your network layout is
working as documented rather than a vulnerability. The same goes for an exit node carrying the runner's traffic — that
is what selecting one does.
