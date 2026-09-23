# Setup NetBird (GitHub Action)

<p align="center">
  <img src="https://raw.githubusercontent.com/ankurk91/netbird-action/main/.github/banner.jpg?v=3"
    alt="Setup NetBird - connect your GitHub Actions CI runners to your NetBird network" width="100%">
</p>

[![tests](https://github.com/ankurk91/netbird-action/actions/workflows/tests.yaml/badge.svg)](https://github.com/ankurk91/netbird-action/actions)
[![lint](https://github.com/ankurk91/netbird-action/actions/workflows/lint.yaml/badge.svg)](https://github.com/ankurk91/netbird-action/actions)
[![marketplace](https://img.shields.io/badge/marketplace-setup--netbird-blue?logo=github)](https://github.com/marketplace/actions/setup-netbird)
[![runner](https://img.shields.io/badge/runner-Linux%20only-blue?logo=linux&logoColor=white)](#requirements)

A GitHub Action that installs the [NetBird](https://netbird.io) client on an Ubuntu runner and joins your network with a
setup key, so the rest of the job can reach your private peers. It can also route the runner's traffic through an exit
node.

## Setup

1. In the NetBird dashboard, open Settings → **Setup Keys** and create one for your runners:

   - Turn on **Ephemeral Peers**.
   - **One-off** if a single job uses it, **reusable** otherwise.
   - Set a proper expiry.
   - Give it a group your access policies already allow, so the runner can reach what it needs.

2. Add the key as a repository secret named `NETBIRD_SETUP_KEY`.

> [!IMPORTANT]
> The key must be **ephemeral**. The action leaves the peer registered when the job ends — see [Cleanup](#cleanup) —
> so without it every run adds a peer to your dashboard for you to delete by hand.

> [!WARNING]
> Never commit the setup key or pass it as a plain string — anyone holding it can register a peer on your network.

## Usage

The only input you need is `setup-key`. Everything else below is optional and shown at its default, apart from
`exit-node` and `dns-hostnames`, which do nothing until you set them:

```yaml
name: Testing

on:
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - name: Connect to the NetBird network
        id: netbird
        uses: ankurk91/netbird-action@v2
        with:
          setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
          # Point this at your own deployment when you self-host.
          management-url: https://api.netbird.io:443
          # Peer name in the dashboard. Every leg of a matrix shares one run id,
          # so give those a name of their own.
          peer-name: gh-${{ github.run_id }}-${{ github.run_attempt }}
          # Network ID of the route to send traffic through. Off when empty.
          exit-node: ${{ vars.NETBIRD_EXIT_NODE_ID }}
          # Names that must resolve before this step finishes. Off when empty.
          dns-hostnames: ''
          # Only accept addresses inside your network.
          dns-require-private: true
          # Extra flags for the NetBird client.
          args: ''
          # Client release to install. Pin it to keep runs reproducible.
          version: latest
          # How long to wait for the peer, the route and the DNS names.
          timeout: 60
          # Undo everything when the job ends. Only needed on self-hosted.
          cleanup: false
          diagnostics: false

      # From here the runner is a peer and can reach the others.
      - name: Do work on the private network
        run: |
          echo "this runner is ${{ steps.netbird.outputs.netbird-ip }} on the network"
          curl -s http://internal-service.netbird.cloud
```

There is no disconnect step to add — see [Cleanup](#cleanup).

> [!WARNING]
> An exit node carries `0.0.0.0/0`, so the runner's connection to GitHub goes through it too. If the exit node cannot
> reach GitHub, the job hangs after this step rather than failing.

## Inputs

| Input                 | Required | Default                      | Description                                                                                  |
|-----------------------|----------|------------------------------|----------------------------------------------------------------------------------------------|
| `setup-key`           | **yes**  | —                            | Setup key from the dashboard. Always pass this from a secret.                                |
| `management-url`      | no       | `https://api.netbird.io:443` | Management service URL. Set this when you self-host NetBird.                                 |
| `peer-name`           | no       | `gh-<run id>-<run attempt>`  | Peer name shown in the dashboard.                                                            |
| `exit-node`           | no       | —                            | Network ID to route through. The route must be distributed to this peer's group.             |
| `dns-hostnames`       | no       | —                            | Names that must resolve before the action finishes. See [Waiting for DNS](#waiting-for-dns). |
| `dns-require-private` | no       | `true`                       | Only accept a `dns-hostnames` name that points inside your network.                          |
| `args`                | no       | —                            | Extra flags appended to `netbird up`, split on whitespace - one per line works.              |
| `version`             | no       | `latest`                     | Client release to install. See [Client version](#client-version).                            |
| `github-token`        | no       | `${{ github.token }}`        | Raises the API rate limit when `version` is pinned. Only sent then.                          |
| `timeout`             | no       | `60`                         | Seconds to wait for the peer, the exit node route, and the DNS names.                        |
| `cleanup`             | no       | `false`                      | Undo everything when the job ends. See [Cleanup](#cleanup).                                  |
| `diagnostics`         | no       | `false`                      | Print the peer state to the job log. See [Diagnostics](#diagnostics).                        |

## Outputs

| Output       | Description                                                               |
|--------------|---------------------------------------------------------------------------|
| `netbird-ip` | The runner's IPv4 address inside the NetBird network, e.g. `100.64.0.33`. |

This is the runner's address *inside your network* — what your other peers use to reach it. It is not the runner's
public IP.

## Waiting for DNS

Being connected is not the same as being able to resolve your private hostnames. If the next step in your job reaches a
service *by name*, list those names and the action waits until they work before it hands over:

```yaml
- uses: ankurk91/netbird-action@v2
  with:
    setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
    dns-hostnames: postgres.netbird.cloud, internal-service.netbird.cloud
```

By default, a name only counts as ready once it points *inside* your network, so a step cannot quietly talk to a public
endpoint when it meant to reach a private one. Set `dns-require-private: false` for a name that is supposed to answer
publicly.

Without this the action still waits for the peer to connect — it just does not check that your names resolve.

## Cleanup

A GitHub-hosted runner is destroyed when the job ends, and your ephemeral setup key takes the peer out of the dashboard
once it has been offline for ten minutes.

Self-hosted runners are the exception, because the machine outlives the job — set `cleanup: true` there, or the next job
on it inherits a network it never asked to join.

## Requirements

* An Ubuntu runner (`ubuntu-latest`, `ubuntu-24.04`, `ubuntu-26.04`, their `-arm` variants, or self-hosted Ubuntu).
* NetBird client **0.67.0 or newer**.

## Client version

Leave `version` at `latest` for the newest client, or pin it (`0.78.1`) to keep every run identical. The minimum is
**0.67.0**. A client already installed on the runner is kept as it is.

## Diagnostics

`diagnostics: true` prints the peer's state to the job log while you work out why a connection is failing.

It is off by default because that output describes your private network, and job logs reach more people than your
dashboard does. Failures print an anonymized summary either way.

## Changelog

Upgrading? See [CHANGELOG.md](CHANGELOG.md).

## Troubleshooting

Something not working? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Curious how any of this behaves under the hood? See [HOW-IT-WORKS.md](HOW-IT-WORKS.md).

## License

[MIT](LICENSE.txt)
