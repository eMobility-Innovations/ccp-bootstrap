# ccp-bootstrap

The public entry point to the eMobility-Innovations Claude Code policy (CCP) setup.
It contains **only** the two bootstrap scripts — no secrets, no configuration. Everything
else lives in the private `claude-code-policy` repo, which these scripts clone after you
sign in to GitHub.

**Generated — do not edit here.** The source is `bootstrap/` in `claude-code-policy`;
`bin/publish-bootstrap.sh` there publishes it to this repo.

| Machine | Run (as your normal user) |
|---|---|
| Windows | `irm https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main/setup.ps1 \| iex` |
| macOS / Linux / WSL | `curl -fsSL https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main/setup.sh \| bash` |

**One command does everything.** It installs what is missing (git, curl, python3, unzip, xz,
GitHub CLI, Node, Claude Code itself via Anthropic's native installer
`curl -fsSL https://claude.ai/install.sh | bash`), then walks you through every sign-in in the
foreground and waits for each browser approval: GitHub, Claude (accounts are listed at
https://claude.fiszu.com), Tailscale, Pangolin, Codex, claude-mem and the fiszu connectors.
You need nothing installed beforehand except `curl` (Linux) — and a normal user with sudo.

**Windows: use WSL Ubuntu.** `setup.ps1` installs WSL + Ubuntu for you and finishes the setup
inside it. Guide: https://dojo.fiszu.com/systems/claude-code-setup/windows-wsl/

Full guide: https://dojo.fiszu.com/systems/claude-code-setup/ (CCP guide:
https://dojo.fiszu.com/devops/installation/ikb-ccp)

## `grafana-api` — Grafana from Claude Code, without CCP

`grafana-api` calls grafana.fiszu.com **as you**, after one browser sign-in with your company
account. CCP installs it automatically; on a machine without CCP:

```bash
mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main/grafana-api -o ~/.local/bin/grafana-api && chmod +x ~/.local/bin/grafana-api
grafana-api login
```
