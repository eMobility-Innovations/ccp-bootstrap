# ccp-bootstrap

The public entry point to the eMobility-Innovations Claude Code policy (CCP) setup.
It contains the full setup entry points and the standalone connector client, installer and
versioned public control profile. No credentials are included. Full workstation policy lives in the private `claude-code-policy` repo, which these scripts clone after you
sign in to GitHub.

**Full setup scripts are generated.** Their source is `bootstrap/` in `claude-code-policy`;
`bin/publish-bootstrap.sh` publishes them. Connector controls here are maintained through the
pinned profile and sync script described below; the bundled authentication blocks in
`fiszu-connect` remain generated and must not be edited by hand.

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

## fiszu-connect — company data connectors in Claude Code, without CCP

```bash
curl -fsSL https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main/install-fiszu-connect.sh | bash
```

This installs `fiszu-connect`, adds it to your terminal's PATH, offers to install Claude Code if needed, and connects company data after one browser sign-in with your company account.

### Connector control profile

`fiszu-connect install` first applies the pinned connector controls, then registers MCP and
signs in. The shell installer also applies controls before reporting success, including when
sign-in must be completed later in a terminal. It installs no full workstation dependencies.
Windows connector installs use WSL (the Linux path); native Windows installation is not
provided by this shell installer.

Before installing, an administrator must issue a **per-machine CUM ingest key** and provision
it as `~/.config/fiszu-connect/ingest-key` for the account running Claude (directory mode 0700,
file mode 0600). `FISZU_CONNECT_INGEST_KEY_FILE` can name another provisioned file. There is no
key enrollment API assumed here. Missing or invalid keys fail installation; the company
connector login credential is never used for ingest. `fiszu-connect otel-headers` reads that
file and emits `X-API-Key` JSON for Claude's dynamic headers helper; never paste its output
into settings. Each OS account using Claude needs its own accessible provisioned key.

`apply-controls` recursively merges the vendored profile into the OS managed settings,
preserving unrelated keys, and reads back all required values. On macOS the destination is
`/Library/Application Support/ClaudeCode/managed-settings.json`; on Linux/WSL it is
`/etc/claude-code/managed-settings.json`. Native Windows path selection is
`C:\Program Files\ClaudeCode\managed-settings.json`, but privilege elevation here supports
macOS/Linux/WSL only. Normal destinations use a sudo prompt; run installation in a terminal.
A denied prompt, malformed settings, missing key, or failed read-back fails installation.
The profile locks extra-credit commands and enables Claude OTLP log export over
`http/protobuf` to `https://claude.fiszu.com`. The helper template
`${FISZU_CONNECT} otel-headers` expands to the installed executable's quoted absolute path.
Claude supports command lines with arguments for this field ([dynamic headers documentation](https://code.claude.com/docs/en/monitoring-usage#dynamic-headers)).
Unsupported helper templates fail closed. No export intervals are changed.

Where `codex` is on PATH, the installer merges CCP's local-only requirements into
`/etc/codex/requirements.toml`: remote control disabled, only `never` approval allowed, and
remote-control/remote-model feature requirements disabled. Existing unrelated TOML is retained.
This merge requires Python 3.11+ (stdlib `tomllib`); no Codex installation is performed.
`controls-status` returns nonzero and names missing/changed controls or a missing machine key.
It reports the applied profile version stored separately from Claude's settings. It checks
configuration and key availability, not whether CUM accepted a telemetry event.

For tests, `FISZU_CONNECT_MANAGED_SETTINGS` and `FISZU_CONNECT_CODEX_REQUIREMENTS` redirect the
privileged destinations to ordinary files. They are test overrides, not enforcement paths.
The suite exercises real apply/status commands and the installer with temporary files:

```bash
./tests/run.sh
```

`profiles/PINNED` records the CCP commit, profile version and exact content SHA-256. The initial
v1 copy is explicitly marked `contract-v1` because that CCP commit does not yet contain the
profile. Its Codex requirements are taken from CCP's `policy/codex-managed-config.toml`.
The offline gate checks JSON, version and content integrity. To refresh from a committed CCP
profile, or compare directly to that file at the pinned commit:

```bash
./scripts/sync-connector-profile.sh /path/to/claude-code-policy
./scripts/sync-connector-profile.sh --check /path/to/claude-code-policy
CCP_CHECKOUT=/path/to/claude-code-policy ./tests/run.sh
```

Sync reads Git HEAD, never uncommitted source changes. Direct comparison fails when the pinned
commit has no published profile; the initial contract snapshot is checked by its digest until
it can be refreshed. The gate does not silently advance the pin to latest CCP. Profile version
and digest mismatches fail, even offline; tests also mutate the copy to prove rejection.
