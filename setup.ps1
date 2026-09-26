# CCP setup — the ONE command for a Windows machine.
#
#   irm https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main/setup.ps1 | iex
#
# Asks for administrator ONCE (a UAC Yes), then:
#   1. makes WSL2 available (feature + package; reboots once and resumes if Windows needs it)
#   2. installs Ubuntu without its first-run prompt and creates your Linux user
#   3. runs the Linux half (setup.sh) inside it — logins open in your Windows browser
# Safe to re-run: every step checks first and skips what is already done. Re-running it is
# also the repair for anything that went wrong.
#
# Unattended / release-test knobs (environment): CCP_DISTRO (name), CCP_DISTRO_IMAGE, CCP_LINUX_USER,
# CCP_NONINTERACTIVE=1, CCP_SOURCE_TGZ,
# CCP_SETUP_SH_URL, plus the CCP_* credentials setup.sh documents.

$ErrorActionPreference = 'Stop'
$SetupUrl   = 'https://raw.githubusercontent.com/eMobility-Innovations/ccp-bootstrap/main/setup.ps1'
$SetupShUrl = if ($env:CCP_SETUP_SH_URL) { $env:CCP_SETUP_SH_URL } else { $SetupUrl -replace 'setup\.ps1$', 'setup.sh' }
$Image      = if ($env:CCP_DISTRO_IMAGE) { $env:CCP_DISTRO_IMAGE } else { 'Ubuntu-26.04' }
$Distro     = if ($env:CCP_DISTRO) { $env:CCP_DISTRO } else { $Image }
$StateDir   = Join-Path $env:LOCALAPPDATA 'ccp-setup'
$Self       = Join-Path $StateDir 'setup.ps1'
$Log        = Join-Path $StateDir 'setup.log'
$Interactive = -not $env:CCP_NONINTERACTIVE

function Say($m)  { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; Write-Host "    Log: $Log"; exit 1 }

function Test-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A piped `irm | iex` has no file to relaunch, so keep a copy of ourselves first.
function Save-Self {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        if ((Resolve-Path $PSCommandPath).Path -ne $Self) { Copy-Item $PSCommandPath $Self -Force }
    } else {
        Invoke-RestMethod $SetupUrl -OutFile $Self
    }
}

function Invoke-Elevated {
    Say 'Administrator access is needed ONCE - approve the Windows prompt (Yes).'
    $envPass = (Get-ChildItem env: | Where-Object Name -like 'CCP_*' |
        ForEach-Object { "`$env:$($_.Name)='$($_.Value -replace "'", "''")';" }) -join ' '
    $cmd = "$envPass & '$Self'"
    try {
        $p = Start-Process powershell -Verb RunAs -PassThru -Wait `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', $cmd
    } catch { Die 'The administrator prompt was declined. Run the command again and choose Yes.' }
    exit $p.ExitCode
}

# WSL2 needs the VirtualMachinePlatform feature and the WSL package. Returns $true when
# Windows must reboot before WSL can start.
function Enable-Wsl {
    $reboot = $false
    # ONLY VirtualMachinePlatform. The legacy Microsoft-Windows-Subsystem-Linux component
    # is WSL1's; the Store WSL package runs WSL2 without it (measured on winccptestserver
    # 2026-09-23: Ubuntu-26.04 ran with that feature Disabled). Enabling it anyway cost a
    # reboot for nothing.
    foreach ($f in @('VirtualMachinePlatform')) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
        if ($state -ne 'Enabled') {
            Say "Enabling Windows feature $f"
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
            if ($r.RestartNeeded) { $reboot = $true }
        }
    }
    if (-not $reboot) {
        # The Store WSL package (wsl --version works) — install or update it.
        & wsl.exe --version *> $null
        if ($LASTEXITCODE -ne 0) {
            Say 'Installing the WSL package'
            & wsl.exe --install --no-distribution   # bare, never piped: see the distro install below
        }
        else { & wsl.exe --update *> $null }
    }
    return $reboot
}

# RESUME AFTER THE REBOOT IS A LOGON SCHEDULED TASK, NOT RunOnce. MEASURED on a fresh Win11
# profile (VM ccp-win11, 2026-09-25): HKCU\...\RunOnce did not exist, so the old
# Set-ItemProperty threw under ErrorActionPreference=Stop and setup died BEFORE the restart
# (resume-proof: "NO REBOOT HAPPENED"). The old value also carried every CCP_* variable
# inline (hundreds of characters; Windows documents a 260-character limit for a RunOnce
# entry) and would have started unelevated. With this task the same VM rebooted and a
# second run started by itself (resume-proof: "RESUMED"). A task registered from this
# elevated session runs at the user's next logon with highest privileges and no prompt; the
# CCP_* values ride in a file only this user can read, loaded and deleted by the resumed run.
$ResumeTask = 'ccp-setup-resume'
$ResumeEnv  = Join-Path $StateDir 'resume.env.json'

function Request-RebootAndResume {
    $vars = @{}
    Get-ChildItem env: | Where-Object Name -like 'CCP_*' | ForEach-Object { $vars[$_.Name] = $_.Value }
    $vars | ConvertTo-Json | Set-Content -Path $ResumeEnv -Encoding UTF8
    & icacls.exe $ResumeEnv /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    $user   = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$Self`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Warn 'Windows must restart once to finish enabling WSL. Setup continues by itself after you log back in.'
    if ($Interactive) { Read-Host 'Press Enter to restart now (Ctrl+C to restart later yourself)' | Out-Null }
    Restart-Computer -Force
    exit 0
}

# The resumed run: take the carried CCP_* values back, then remove every trace of the resume.
function Resume-FromReboot {
    if (Test-Path $ResumeEnv) {
        (Get-Content -Raw $ResumeEnv | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { Set-Item -Path "env:$($_.Name)" -Value $_.Value }
        Remove-Item -Force $ResumeEnv
        Say 'Resumed after the restart.'
    }
    Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-WslDistros {
    # wsl.exe writes UTF-16; decode it so names compare as text.
    $prev = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [Text.Encoding]::Unicode; (& wsl.exe -l -q) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } }
    finally { [Console]::OutputEncoding = $prev }
}

function Get-LinuxUserName {
    if ($env:CCP_LINUX_USER) { return $env:CCP_LINUX_USER }
    $suggest = ($env:USERNAME.ToLower() -replace '[^a-z0-9_-]', '')
    if ($suggest -notmatch '^[a-z_]') { $suggest = "u$suggest" }
    if ($Interactive) {
        $a = Read-Host "Linux user name [$suggest]"
        if ($a) { $suggest = $a.ToLower() }
    }
    return $suggest
}

function WslRoot([string]$script) {
    # Root inside WSL comes from THIS elevated Windows session - no sudo password, no dialog.
    $script = $script -replace "`r", ''
    $script | & wsl.exe -d $Distro -u root -- bash -s
    if ($LASTEXITCODE -ne 0) { Die "A root step inside $Distro failed (exit $LASTEXITCODE)." }
}

# ── main ─────────────────────────────────────────────────────────────────────────────
Save-Self
Start-Transcript -Path $Log -Append | Out-Null
$t0 = Get-Date
Say "CCP setup on $env:COMPUTERNAME - one command, one administrator prompt"

if (-not (Test-Admin)) { Invoke-Elevated }

Resume-FromReboot
if (Enable-Wsl) { Request-RebootAndResume }
# A RunOnce left by an older setup.ps1 would start a second, unelevated copy at next logon.
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ccp-setup' -ErrorAction SilentlyContinue

# The distro comes from Microsoft's own manifest, downloaded and hash-checked HERE, then
# `wsl --import`ed. NOT `wsl --install <distro>`: measured on winccptestserver 2026-09-23 it
# hung indefinitely in 3 of 6 non-interactive runs (piped, redirected, and once called
# bare), with no output and no timeout. Import is deterministic, needs no Store and no
# first-run prompt, and the verified image is cached so a re-run downloads nothing.
function Install-Distro {
    $manifest = Invoke-RestMethod 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
    $entry = $manifest.ModernDistributions.PSObject.Properties.Value |
        ForEach-Object { $_ } | Where-Object Name -eq $Image | Select-Object -First 1
    if (-not $entry) { Die "No '$Image' in Microsoft's WSL distribution manifest." }
    $src = if ([Environment]::Is64BitOperatingSystem -and $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $entry.Arm64Url } else { $entry.Amd64Url }
    $cache = Join-Path $StateDir 'images'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $file = Join-Path $cache ([IO.Path]::GetFileName($src.Url))
    $ok = (Test-Path $file) -and ((Get-FileHash $file -Algorithm SHA256).Hash -eq $src.Sha256.ToUpper())
    if (-not $ok) {
        Say "Downloading $Image"
        & curl.exe -fsSL --retry 3 -o $file $src.Url
        if ($LASTEXITCODE -ne 0) { Die "Could not download $($src.Url)" }
        if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $src.Sha256.ToUpper()) {
            Remove-Item $file -Force; Die "The $Image image failed its SHA-256 check - refused."
        }
    }
    $dir = Join-Path $StateDir "distros\$Distro"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Say "Importing $Distro"
    & wsl.exe --import $Distro $dir $file --version 2
    if ($LASTEXITCODE -ne 0) { Die "wsl --import of $Distro failed (exit $LASTEXITCODE)." }
}

if ((Get-WslDistros) -notcontains $Distro) {
    Install-Distro
    if ((Get-WslDistros) -notcontains $Distro) { Die "$Distro did not install." }
}

# Reuse the distro's existing default user (an upgrade of a machine already in use);
# otherwise create one.
$existing = (& wsl.exe -d $Distro -u root -- sh -c "getent passwd 1000 | cut -d: -f1") -join ''
$LinuxUser = if ($existing) { $existing.Trim() } else { Get-LinuxUserName }
Say "Linux user: $LinuxUser"

# WSL-only rationale for NOPASSWD: anyone who can run this Windows account can already
# `wsl -u root`, so a sudo password inside WSL guards nothing - it only produces prompts
# that cannot render over SSH or in a scheduled run.
WslRoot @"
set -e
id -u '$LinuxUser' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo '$LinuxUser'
passwd -l '$LinuxUser' >/dev/null 2>&1 || true
printf '%s ALL=(ALL) NOPASSWD:ALL\n' '$LinuxUser' > /etc/sudoers.d/ccp-wsl-user
chmod 0440 /etc/sudoers.d/ccp-wsl-user
visudo -cf /etc/sudoers.d/ccp-wsl-user >/dev/null
touch /etc/wsl.conf
python3 - '$LinuxUser' <<'PY'
import configparser, sys
p = '/etc/wsl.conf'; c = configparser.ConfigParser(); c.optionxform = str; c.read(p)
for sect, key, val in (('boot', 'systemd', 'true'), ('user', 'default', sys.argv[1])):
    if not c.has_section(sect): c.add_section(sect)
    c[sect][key] = val
with open(p, 'w') as fh: c.write(fh)
PY
loginctl enable-linger '$LinuxUser' 2>/dev/null || true
"@
& wsl.exe --manage $Distro --set-default-user $LinuxUser *> $null
& wsl.exe --set-default $Distro | Out-Null
& wsl.exe --terminate $Distro | Out-Null   # re-read wsl.conf (systemd, default user)

Say 'Handing over to the Linux half (setup.sh)'
$envPass = (Get-ChildItem env: | Where-Object Name -like 'CCP_*' |
    ForEach-Object { "$($_.Name)='$($_.Value -replace "'", "'\''")'" }) -join ' '
# Release test / development: CCP_SOURCE_TGZ is a Windows path to a tarball of an
# unpublished branch. It is unpacked where setup.sh would have cloned the repo, and
# CCP_SOURCE_DIR tells setup.sh to use it instead of GitHub.
if ($env:CCP_SOURCE_TGZ) {
    $dest = '$HOME/Projects/claude-code-policy'
    & wsl.exe -d $Distro -u $LinuxUser -- bash -c "mkdir -p $dest && tar xzf `"`$(wslpath -a '$($env:CCP_SOURCE_TGZ)')`" -C $dest && echo `$HOME"
    $env:CCP_SOURCE_DIR = "/home/$LinuxUser/Projects/claude-code-policy"
    $envPass = (Get-ChildItem env: | Where-Object Name -like 'CCP_*' |
        ForEach-Object { "$($_.Name)='$($_.Value -replace "'", "'\''")'" }) -join ' '
}
# CCP_SOURCE_DIR: run the setup.sh inside that checkout instead of fetching the published one.
$fetch = if ($env:CCP_SOURCE_DIR) { "cp '$($env:CCP_SOURCE_DIR)/bootstrap/setup.sh' /tmp/ccp-setup.sh" }
         else { "curl -fsSL '$SetupShUrl' -o /tmp/ccp-setup.sh" }
& wsl.exe -d $Distro -u $LinuxUser --cd '~' -- bash -lc "export $envPass CCP_FROM_WINDOWS=1; $fetch && bash /tmp/ccp-setup.sh"
$rc = $LASTEXITCODE

$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
if ($rc -eq 0) { Say "Done in $mins min. Open 'Ubuntu' (or run: wsl) and start claude." }
else { Warn "Setup finished with outstanding items after $mins min - re-run the same command to retry. Log: $Log" }
Stop-Transcript | Out-Null
exit $rc
