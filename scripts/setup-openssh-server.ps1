# Install and configure OpenSSH Server on Windows Site B for Linux (Site A) access.
# Run in elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\scripts\setup-openssh-server.ps1
#
# Defaults: allow SSH from Site A (192.168.0.114) only.
param(
    [string[]]$AllowedRemoteHosts = @('192.168.0.114'),
    [int]$Port = 22,
    [switch]$AllowAllLan
)

$ErrorActionPreference = 'Stop'

function Require-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'Run this script in an elevated PowerShell (Run as administrator).'
    }
}

function Initialize-SshdConfig {
    param(
        [string]$OpenSshDir,
        [string]$SshDataDir,
        [string]$SshdConfig,
        [string]$SshdConfigDefault
    )

    $sshdExe = Join-Path $OpenSshDir 'sshd.exe'
    if (-not (Test-Path $sshdExe)) {
        throw "OpenSSH Server binaries not found in $OpenSshDir"
    }

    if (-not (Test-Path $SshDataDir)) {
        Write-Host "Creating $SshDataDir ..."
        New-Item -ItemType Directory -Path $SshDataDir -Force | Out-Null
    }

    if (-not (Test-Path $SshdConfig)) {
        if (-not (Test-Path $SshdConfigDefault)) {
            $msg = 'Missing {0}; OpenSSH install looks incomplete.' -f $SshdConfigDefault
            throw $msg
        }
        Write-Host "Creating $SshdConfig from default template ..."
        Copy-Item -Path $SshdConfigDefault -Destination $SshdConfig
    }

    $hostKeys = @(Get-ChildItem -Path $SshDataDir -Filter 'ssh_host_*_key' -ErrorAction SilentlyContinue)
    if ($hostKeys.Count -eq 0) {
        Write-Host 'Generating SSH host keys ...'
        $keygen = Join-Path $OpenSshDir 'ssh-keygen.exe'
        & $keygen -A | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "ssh-keygen -A failed (exit $LASTEXITCODE)"
        }
    }
}

function Repair-SshdPermissions {
    param([string]$SshDataDir)

    # OpenSSH 9.4+ refuses to start if ssh/ or ssh/logs/ grant write to non-admin users.
    $logsDir = Join-Path $SshDataDir 'logs'
    $dirSddl = 'O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;AU)'

    foreach ($dir in @($SshDataDir, $logsDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Write-Host ('Setting directory ACL on {0} ...' -f $dir)
        $acl = Get-Acl -Path $dir
        $acl.SetSecurityDescriptorSddlForm($dirSddl)
        Set-Acl -Path $dir -AclObject $acl
    }

    $adminKeys = Join-Path $SshDataDir 'administrators_authorized_keys'
    if (-not (Test-Path $adminKeys)) {
        New-Item -ItemType File -Path $adminKeys -Force | Out-Null
    }
    Write-Host 'Setting administrators_authorized_keys ACL ...'
    & icacls $adminKeys /inheritance:r | Out-Null
    & icacls $adminKeys /grant:r 'NT AUTHORITY\SYSTEM:(F)' | Out-Null
    & icacls $adminKeys /grant 'BUILTIN\Administrators:(F)' | Out-Null

    $privateKeys = @(Get-ChildItem -Path $SshDataDir -File | Where-Object {
            $_.Name -match '^ssh_host_.*_key$'
        })
    foreach ($key in $privateKeys) {
        Write-Host ('Repairing host key {0} ...' -f $key.Name)
        & takeown /F $key.FullName /A | Out-Null
        & icacls $key.FullName /inheritance:r | Out-Null
        & icacls $key.FullName /grant:r 'NT AUTHORITY\SYSTEM:(F)' | Out-Null
        & icacls $key.FullName /grant 'BUILTIN\Administrators:(F)' | Out-Null
        & icacls $key.FullName /setowner 'NT AUTHORITY\SYSTEM' | Out-Null
    }
}

function Start-SshdService {
    param(
        [string]$OpenSshDir,
        [string]$SshdConfig
    )

    $sshdExe = Join-Path $OpenSshDir 'sshd.exe'
    & $sshdExe -t -f $SshdConfig
    if ($LASTEXITCODE -ne 0) {
        throw 'sshd_config validation failed (sshd -t)'
    }

    Get-Process -Name sshd -ErrorAction SilentlyContinue | Stop-Process -Force

    Set-Service -Name sshd -StartupType Automatic
    $svc = Get-Service sshd
    if ($svc.Status -eq 'Running') {
        Restart-Service sshd
    } else {
        Start-Service sshd
    }

    $svc = Get-Service sshd
    if ($svc.Status -ne 'Running') {
        $hint = 'Check C:\ProgramData\ssh\logs ACL (only SYSTEM+Admins may write). Re-run this script as admin.'
        throw ('sshd service did not reach Running state. {0}' -f $hint)
    }
    Write-Host ('sshd service: {0}' -f $svc.Status)
}

Require-Admin

Write-Host '=== OpenSSH Server setup (Site B) ==='

$cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' }
Write-Host "OpenSSH.Server capability: $($cap.State)"
if ($cap.State -ne 'Installed') {
    Write-Host 'Installing OpenSSH Server (may take a few minutes) ...'
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}

$openSshDir = Join-Path $env:WINDIR 'System32\OpenSSH'
$sshDataDir = Join-Path $env:ProgramData 'ssh'
$sshdConfig = Join-Path $sshDataDir 'sshd_config'
$sshdConfigDefault = Join-Path $openSshDir 'sshd_config_default'

Initialize-SshdConfig -OpenSshDir $openSshDir -SshDataDir $sshDataDir `
    -SshdConfig $sshdConfig -SshdConfigDefault $sshdConfigDefault

Repair-SshdPermissions -SshDataDir $sshDataDir
Start-SshdService -OpenSshDir $openSshDir -SshdConfig $sshdConfig

$shellKey = 'HKLM:\SOFTWARE\OpenSSH'
if (-not (Test-Path $shellKey)) {
    New-Item -Path $shellKey -Force | Out-Null
}
$defaultShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Set-ItemProperty -Path $shellKey -Name DefaultShell -Value $defaultShell -Type String -Force

if ($AllowAllLan) {
    $remote = @('LocalSubnet')
} else {
    $remote = $AllowedRemoteHosts
}

$ruleName = 'OpenSSH Server (sshd) - PoC Site A'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Name 'OpenSSH-PoC-SiteA' -DisplayName $ruleName `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
    -LocalPort $Port -RemoteAddress $remote -Profile Any | Out-Null
Write-Host ('Firewall: TCP {0} allowed from {1}' -f $Port, ($remote -join ', '))

$defaultRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($defaultRule) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled:$false
}

Write-Host ''
Write-Host 'Listening:'
$portFilter = ':{0} ' -f $Port
netstat -an | findstr $portFilter | findstr LISTENING

Write-Host ''
Write-Host 'From Linux Site A (192.168.0.114):'
Write-Host ('  ssh {0}@192.168.0.102' -f $env:USERNAME)
Write-Host ''
Write-Host 'Optional: copy your public key from Linux, then on Windows:'
$sshDir = Join-Path $env:USERPROFILE '.ssh'
$authKeys = Join-Path $sshDir 'authorized_keys'
Write-Host ('  mkdir {0} -Force' -f $sshDir)
Write-Host ('  notepad {0}' -f $authKeys)
Write-Host '  (paste Linux id_ed25519.pub or id_rsa.pub, one line per key)'
