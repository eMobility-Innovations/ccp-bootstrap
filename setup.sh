#!/usr/bin/env bash
# CCP setup — the ONE command for macOS, Linux and WSL.
#
#   curl -fsSL https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main/setup.sh | bash
#
# This public half only gets you to the private policy repo: it installs git + gh, signs
# you in to GitHub (browser), clones claude-code-policy and hands over to its
# `bin/ccp-setup`, which does everything else in one pass. Re-run it any time; it is also
# the repair.
#
# Knobs (environment), for the release test and unattended use:
#   CCP_GH_TOKEN      GitHub token instead of the browser login
#   CCP_SOURCE_DIR    use this local checkout instead of cloning (development only)
#   CCP_POLICY_DIR    where the policy repo lives (default ~/Projects/claude-code-policy)
#   CCP_NONINTERACTIVE=1  never prompt; report what needs a person instead
set -uo pipefail

# THE WHOLE SCRIPT IS ONE FUNCTION, CALLED ON THE LAST LINE. Under `curl … | bash`, bash
# reads the script from the pipe AS IT RUNS; the `exec </dev/tty` below then made it read
# the REST OF THE SCRIPT from the keyboard — the run sat silent forever (korsarz2k23,
# 2026-09-24). A function body is read in full before anything in it executes.
main() {

POLICY_DIR="${CCP_POLICY_DIR:-$HOME/Projects/claude-code-policy}"
ORG_REPO="eMobility-Innovations/claude-code-policy"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*"; exit 1; }

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# `curl | bash` gives the script's stdin to the pipe; reattach the terminal so the
# logins below can talk to the person. Reattach the terminal's REAL node, never the
# /dev/tty alias: macOS kqueue refuses the alias, and `claude auth login` (Bun) died on it
# with `EINVAL: invalid argument, kqueue` (roua-macbook, 2026-09-24). /dev/tty only when
# no real node can be named.
real_tty() {
  local t; t=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
  case "$t" in ''|'?'|'??') echo /dev/tty ;; *) if [ -r "/dev/$t" ]; then echo "/dev/$t"; else echo /dev/tty; fi ;; esac
}
if [ ! -t 0 ] && [ -z "${CCP_NONINTERACTIVE:-}" ] && [ -r /dev/tty ]; then exec <"$(real_tty)"; fi

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root — it asks for privilege itself, once"

# ── one elevation, held for the whole run ─────────────────────────────────────────────
SUDO=""
if [ "$(uname -s)" = Linux ]; then
  if sudo -n true 2>/dev/null; then SUDO="sudo -n"
  elif [ -n "${CCP_NONINTERACTIVE:-}" ]; then die "needs sudo and there is nobody to ask (CCP_NONINTERACTIVE)"
  else
    say "Administrator access is needed ONCE for system packages — enter your password:"
    sudo -v || die "sudo was declined"
    SUDO="sudo"
    ( while sleep 50; do sudo -n true 2>/dev/null || exit; done ) & SUDO_KEEPALIVE=$!
    trap 'kill ${SUDO_KEEPALIVE:-} 2>/dev/null' EXIT
  fi
fi
export CCP_SUDO="$SUDO"

# On WSL, "open a browser" means the Windows desktop browser.
if is_wsl && [ -z "${BROWSER:-}" ]; then
  opener=/usr/local/bin/ccp-open-url
  if [ ! -x "$opener" ]; then
    printf '#!/bin/sh\n# Opens a URL in the Windows browser (installed by CCP setup).\nexplorer.exe "$1" >/dev/null 2>&1 || cmd.exe /c start "" "$1" >/dev/null 2>&1\nexit 0\n' \
      | $SUDO tee "$opener" >/dev/null && $SUDO chmod 0755 "$opener"
  fi
  export BROWSER="$opener"
fi

# ── git + gh: the minimum to reach the private repo ──────────────────────────────────
install_base_linux() {
  local need=()
  command -v git  >/dev/null || need+=(git)
  command -v curl >/dev/null || need+=(curl)
  command -v python3 >/dev/null || need+=(python3)
  if ! command -v gh >/dev/null; then
    if command -v apt-get >/dev/null; then
      # GitHub's own apt repo: distro gh packages lag badly on LTS.
      $SUDO install -d -m 0755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    fi
    need+=(gh)
  fi
  [ ${#need[@]} -eq 0 ] && return 0
  say "Installing ${need[*]}"
  if command -v apt-get >/dev/null; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null
  elif command -v dnf >/dev/null; then $SUDO dnf install -y -q "${need[@]}"
  elif command -v pacman >/dev/null; then $SUDO pacman -S --noconfirm --needed "${need[@]/gh/github-cli}"
  else die "no supported package manager — install ${need[*]} and re-run"
  fi
}

install_base_darwin() {
  if ! command -v brew >/dev/null; then
    say "Installing Homebrew (it will ask for your password once)"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || die "Homebrew install failed"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
  fi
  local need=()
  command -v git >/dev/null || need+=(git)
  command -v gh  >/dev/null || need+=(gh)
  [ ${#need[@]} -eq 0 ] || { say "Installing ${need[*]}"; brew install -q "${need[@]}"; }
}

case "$(uname -s)" in
  Linux)  install_base_linux ;;
  Darwin) install_base_darwin ;;
  *) die "unsupported OS $(uname -s) — on Windows use setup.ps1" ;;
esac

# ── GitHub sign-in ────────────────────────────────────────────────────────────────────
# CCP_SOURCE_DIR replaces the CLONE of the policy repo, never the sign-in: the private repos
# the installer pulls next still need a GitHub credential. Skipping the whole block for a
# source dir left the release test's CCP_GH_TOKEN unused, so every private-dep row stayed ❌
# (release-e2e 802ebe16, winccptestserver, 2026-09-25).
if ! gh auth status -h github.com >/dev/null 2>&1; then
  if [ -n "${CCP_GH_TOKEN:-}" ]; then
    printf '%s' "$CCP_GH_TOKEN" | gh auth login -h github.com --git-protocol https --with-token \
      || die "the GitHub token was refused"
  elif [ -n "${CCP_SOURCE_DIR:-}" ]; then
    warn "not signed in to GitHub — the private repos will be reported, not pulled"
  elif [ -n "${CCP_NONINTERACTIVE:-}" ]; then
    die "not signed in to GitHub and nobody to ask (set CCP_GH_TOKEN)"
  else
    say "Sign in to GitHub — a browser opens; paste the one-time code shown here."
    gh auth login -h github.com --git-protocol https --web --skip-ssh-key \
      || die "GitHub sign-in did not complete — re-run this command"
  fi
fi
gh auth status -h github.com >/dev/null 2>&1 && { gh auth setup-git -h github.com >/dev/null 2>&1 || true; }

# ── the policy repo ───────────────────────────────────────────────────────────────────
RUNTIME_DIR="$HOME/.claude/policy-runtime"

# Which existing checkout to hand over to: the first of the person's clone and the runtime
# clone (the one install.sh keeps on trunk) that is on `main` and fast-forwards to it.
# A machine that stopped converging usually has its clone dirty, branched or behind —
# handing over to it anyway ran stale code, or died on "ccp-setup missing".
pick_policy_dir() {
  local d
  for d in "$POLICY_DIR" "$RUNTIME_DIR"; do
    [ -d "$d/.git" ] || continue
    if [ "$(git -C "$d" symbolic-ref --short -q HEAD)" != main ] \
       || ! git -C "$d" pull --ff-only -q origin main 2>/dev/null; then
      warn "$d is not on main or will not fast-forward — trying the next checkout" >&2
      continue
    fi
    [ -x "$d/bin/ccp-setup" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

if [ -n "${CCP_SOURCE_DIR:-}" ]; then
  POLICY_DIR="$CCP_SOURCE_DIR"
elif picked="$(pick_policy_dir)"; then
  POLICY_DIR="$picked"
elif [ -e "$POLICY_DIR" ]; then
  die "$POLICY_DIR cannot be brought to trunk (dirty, on a branch, or diverged).
    Move it aside and re-run this command — a fresh clone is made:  mv $POLICY_DIR $POLICY_DIR.old"
else
  say "Cloning the policy repo to $POLICY_DIR"
  mkdir -p "$(dirname "$POLICY_DIR")"
  gh repo clone "$ORG_REPO" "$POLICY_DIR" -- -q 2>/dev/null \
    || die "could not clone $ORG_REPO — your GitHub account needs access to eMobility-Innovations (ask Patryk Radek)"
fi

[ -x "$POLICY_DIR/bin/ccp-setup" ] || die "$POLICY_DIR/bin/ccp-setup missing — is the checkout current?"
exec "$POLICY_DIR/bin/ccp-setup"
}

main "$@"
