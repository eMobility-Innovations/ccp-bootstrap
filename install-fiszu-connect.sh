#!/usr/bin/env bash
set -euo pipefail

base_url=${FISZU_CONNECT_BASE_URL:-https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main}
installer_command='curl -fsSL https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main/install-fiszu-connect.sh | bash'
claude_install_command='curl -fsSL https://claude.ai/install.sh | bash'
tmp_file=''
trap 'if [[ -n "$tmp_file" ]]; then rm -f -- "$tmp_file"; fi' EXIT

fail() {
    local code=$1 message=$2 next=$3
    printf 'Could not finish: %s\nNext: %s\n' "$message" "$next" >&2
    exit "$code"
}

summary() {
    printf '\nInstalled fiszu-connect at %s.\n' "$bin_dir/fiszu-connect"
}

has_absolute_path_line() {
    awk -v directory="$bin_dir" '
        /^[[:space:]]*(export[[:space:]]+)?PATH=/ {
            position = index($0, directory)
            following = substr($0, position + length(directory), 1)
            if (position && (following == "" || following ~ /^[:"\047[:space:]]$/)) found = 1
        }
        END { exit !found }
    ' "$1"
}

printf '%s\n' '==> Step 1/5: checking curl and Python 3 ...'
if [[ $(uname -s) == Darwin ]]; then
    curl_hint='brew install curl'
    python_hint='xcode-select --install'
else
    curl_hint='sudo apt-get install -y curl'
    python_hint='sudo apt-get install -y python3'
fi
command -v curl >/dev/null 2>&1 || fail 1 'curl is missing.' "Run: $curl_hint; then run: $installer_command"
command -v python3 >/dev/null 2>&1 || fail 1 'Python 3 is missing.' "Run: $python_hint; then run: $installer_command"
[[ -n ${HOME:-} ]] || fail 1 'your home folder is not set.' 'Set HOME to your home folder and run the installer again.'

printf '%s\n' '==> Step 2/5: downloading fiszu-connect into your home folder ...'
bin_dir="$HOME/.local/bin"
mkdir -p "$bin_dir" || fail 1 'your bin folder could not be created.' "Check that you can write to $HOME, then run: $installer_command"
tmp_file=$(mktemp "$bin_dir/.fiszu-connect.XXXXXX") || fail 1 'a download file could not be created.' "Check that you can write to $bin_dir, then run: $installer_command"
curl -fsSL "${base_url%/}/fiszu-connect" -o "$tmp_file" || fail 1 'fiszu-connect could not be downloaded.' "Check your internet connection, then run: $installer_command"
[[ -s "$tmp_file" ]] || fail 1 'the download was empty.' "Check your internet connection, then run: $installer_command"
chmod 755 "$tmp_file" || fail 1 'the download could not be made executable.' "Check that you can write to $bin_dir, then run: $installer_command"
mv -f "$tmp_file" "$bin_dir/fiszu-connect" || fail 1 'fiszu-connect could not be saved.' "Check that you can write to $bin_dir, then run: $installer_command"
tmp_file=''

profile_dir="$HOME/.local/share/fiszu-connect/profiles"
mkdir -p "$profile_dir"
for profile_file in connector-managed-settings.json PINNED; do
    tmp_file=$(mktemp "$profile_dir/.download.XXXXXX")
    curl -fsSL "${base_url%/}/profiles/$profile_file" -o "$tmp_file" ||
        fail 1 'connector control profile could not be downloaded.' "Run: $installer_command"
    mv -f "$tmp_file" "$profile_dir/$profile_file"
    tmp_file=''
done
"$bin_dir/fiszu-connect" apply-controls ||
    fail 1 'required connector controls could not be applied.' 'Provision the machine ingest-key file, then rerun the installer in a terminal for sudo approval.'

printf '%s\n' '==> Step 3/5: making fiszu-connect available in your terminal ...'
case ":${PATH:-}:" in
    *":$bin_dir:"*) printf '%s\n' 'Your bin folder is already on PATH.' ;;
    *)
        case "${SHELL:-}" in
            */bash) rc_file="$HOME/.bashrc" ;;
            */zsh) rc_file="$HOME/.zshrc" ;;
            *) rc_file="$HOME/.profile" ;;
        esac
        if [[ ! -f "$rc_file" ]] || ! {
            grep -Fq '# added by install-fiszu-connect' "$rc_file" ||
            grep -Eq "^[[:space:]]*(export[[:space:]]+)?PATH=.*(\\\$HOME|\\\$\\{HOME\\}|~)/\\.local/bin([:\"'[:space:]]|$)" "$rc_file" ||
            has_absolute_path_line "$rc_file"
        }; then
            printf '\n%s\n' "export PATH=\"\$HOME/.local/bin:\$PATH\"  # added by install-fiszu-connect" >> "$rc_file" ||
                fail 1 'your terminal settings could not be updated.' "Check that you can write to $rc_file, then run: $installer_command"
        fi
        export PATH="$bin_dir:${PATH:-}"
        printf 'Open a new terminal afterwards, or run: source "%s"\n' "$rc_file"
        ;;
esac

has_tty=false
if [[ -r /dev/tty ]] && (exec </dev/tty >/dev/tty) 2>/dev/null; then has_tty=true; fi

printf '%s\n' '==> Step 4/5: checking Claude Code ...'
if ! command -v claude >/dev/null 2>&1 && [[ ! -x "$bin_dir/claude" ]]; then
    answer=n
    if "$has_tty"; then
        printf '%s ' "Claude Code is not installed. Install it now with Anthropic's official installer? [Y/n]" >/dev/tty ||
            fail 1 'the terminal could not be opened.' "Run: $claude_install_command; then run: fiszu-connect install"
        IFS= read -r answer </dev/tty || answer=n
    fi
    case "$answer" in
        ''|[Yy]|[Yy][Ee][Ss])
            printf '%s\n' "Installing Claude Code with Anthropic's official installer ..."
            if curl -fsSL https://claude.ai/install.sh | bash; then
                export PATH="$bin_dir:$PATH"
            else
                install_exit=$?
                fail "$install_exit" 'Claude Code could not be installed.' "Run: $claude_install_command; then run: fiszu-connect install"
            fi
            command -v claude >/dev/null 2>&1 ||
                fail 1 'Claude Code is still missing after its installer finished.' "Run: $claude_install_command; then open a new terminal and run: fiszu-connect install"
            ;;
        *)
            printf '%s\n' '==> Step 5/5: leaving sign-in for a terminal ...'
            summary
            printf 'Next: install Claude Code in a terminal:\n%s\nThen open a new terminal and run: fiszu-connect install\n' "$claude_install_command"
            exit 0
            ;;
    esac
fi

printf '%s\n' '==> Step 5/5: connecting fiszu to Claude Code ...'
if ! "$has_tty"; then
    summary
    printf '%s\n' "Next: run \`fiszu-connect install\` in a terminal."
    exit 0
fi
if "$bin_dir/fiszu-connect" install </dev/tty; then
    summary
    printf '%s\n' 'Connected fiszu to Claude Code for your account. Open Claude Code to use the company connectors.'
else
    connect_exit=$?
    fail "$connect_exit" 'fiszu-connect could not finish connecting.' "Run \`fiszu-connect install\` in a terminal to try again."
fi
