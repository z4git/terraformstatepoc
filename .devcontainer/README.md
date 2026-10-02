# claudedevcontainer

A Dev Container for running [Claude Code](https://claude.com/claude-code) in an
isolated environment with a firewall that blocks local/private address space.

The point of the firewall is to keep the agent off your local network: it has
unrestricted internet access, but cannot reach the Docker host, the LAN, or
anything else in private address space.

## Quick start

1. Install Docker and the VS Code
   [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
   extension.
2. Open this folder in VS Code → **Dev Containers: Reopen in Container**.
3. In the container terminal: `claude` — the first run prints a login URL you
   open on your host; the session persists in a named volume across rebuilds.

Without VS Code: `npm i -g @devcontainers/cli && devcontainer up --workspace-folder .`

## What's inside

| | |
|---|---|
| Base | `node:22-bookworm`, non-root user `node`, workspace at `/workspace` |
| Claude | `@anthropic-ai/claude-code` installed globally |
| Tools | `git`, `gh`, `ripgrep`, `fzf`, `jq`, `zsh` (default shell) |
| Terraform | `terraform` from the HashiCorp apt repo (pin with the `TERRAFORM_VERSION` build arg), VS Code `hashicorp.terraform` extension |
| Persisted | `/home/node/.claude` (login + session state), `/commandhistory` (shell history) |

## The firewall

`.devcontainer/init-firewall.sh` runs as root on every container start
(`postStartCommand` — iptables rules live in the network namespace and are lost
when the container stops). It allows all egress to the internet and blocks
traffic to local/private ranges (`BLOCKED_RANGES` at the top of the script):
RFC1918 (`10/8`, `172.16/12`, `192.168/16`), link-local (`169.254/16`), and
CGNAT (`100.64/10`).

Kept open so the container still works: loopback, DNS, replies to inbound
port-forwards, and container-to-container traffic within nested docker bridge
networks.

It then self-verifies: `example.com` must succeed and the Docker host gateway
must be unreachable, otherwise it exits non-zero and container startup fails
loudly. A firewall that silently didn't apply is worse than one that refuses
to start.

**Changing the blocked ranges:** edit `BLOCKED_RANGES`, then re-run
`sudo /usr/local/bin/init-firewall.sh` (or rebuild).

**Turning it off:** remove `postStartCommand` and `runArgs` from
`devcontainer.json`. You'll also want to do this if your Docker runtime can't
grant `NET_ADMIN`/`NET_RAW` (some rootless and Podman setups) — the symptom is
container startup failing inside `init-firewall.sh`.

## Authentication

You log in once, interactively, on the first `claude` run inside the container.
No tokens, no API keys, nothing to copy from the host.

```
$ claude
```

Claude prints a login URL. Open it in your host browser, approve, paste the
code back into the terminal. The session is written to `/home/node/.claude`,
which is a named volume — so *Dev Containers: Rebuild Container* keeps you
logged in. You log in once per project, not once per rebuild.

Two things can break that first login:

- **No credential variables.** If `ANTHROPIC_API_KEY` or
  `CLAUDE_CODE_OAUTH_TOKEN` is set in the container, it takes precedence over
  the stored login — and an empty or stale one 401s instead of falling back.
  Nothing here sets them; check with `env | grep -E 'ANTHROPIC|CLAUDE'` in a
  container terminal if you see auth errors, and make sure you don't add them
  to `remoteEnv`.
- **The firewall.** All internet endpoints are reachable, so login should just
  work. If networking misbehaves, re-run `sudo /usr/local/bin/init-firewall.sh`
  and check its output.

To log out or switch accounts, run `/logout` in Claude, or delete the volume:
`docker volume rm claude-code-config-<devcontainerId>`.

**Sharing one login across projects.** The config volume name ends in
`${devcontainerId}`, so each project gets its own. Change the mount source in
`devcontainer.json` to a fixed name like `claude-code-config` and every project
reuses the same login.

## Adapting it to a project

- **Different language:** change the base image in `Dockerfile`, or add Dev
  Container [features](https://containers.dev/features) (`python`, `go`, …).
- **Private registries / internal APIs on the LAN:** these sit in blocked
  address space — carve an exception out of `BLOCKED_RANGES` (or add an ACCEPT
  rule for the specific host before the drop rules) and re-run the script.
