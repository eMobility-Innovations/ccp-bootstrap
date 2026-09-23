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

Prerequisite: git (and curl on Linux). Full guide: dojo.fiszu.com/devops/installation/ikb-ccp
