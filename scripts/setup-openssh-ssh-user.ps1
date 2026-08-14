# Create a local Windows user for SSH from Linux Site A.
# Uses net.exe (works on all Windows editions; no Get-LocalUser module).
#
# Run elevated:
#   powershell -ExecutionPolicy Bypass -File .\scripts\setup-openssh-ssh-user.ps1 -Username sitea-ssh
param(
    [string]$Username = 'sitea-ssh',
    [string]$Password = '',
    [string]$FullName = 'Site A SSH access (PoC)'
)

$ErrorActionPreference = 'Stop'

function Require-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script in an elevated PowerShell (Run as administrator).'
    }
}

function Test-NetUserExists {
    param([string]$Name)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $null = & net.exe user $Name 2>&1
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-NetUser {
    param([string[]]$NetArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & net.exe @NetArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        $text = ($out | Out-String).Trim()
        throw "net.exe failed: $text"
    }
}

Require-Admin

if ([string]::IsNullOrWhiteSpace($Password)) {
    $secure = Read-Host 'Enter password for SSH user' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

if ($Password.Length -lt 8) {
    throw 'Password must be at least 8 characters.'
}

if (Test-NetUserExists -Name $Username) {
    Write-Host "User $Username already exists; updating password ..."
    Invoke-NetUser -NetArgs @('user', $Username, $Password)
} else {
    Write-Host "Creating local user $Username ..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & net.exe user $Username $Password /add `
            ("/fullname:{0}" -f $FullName) /passwordchg:no /expires:never 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        $text = ($out | Out-String)
        if ($text -match 'ya existe|already exists|1378') {
            Write-Host "User $Username already exists; updating password ..."
            Invoke-NetUser -NetArgs @('user', $Username, $Password)
        } else {
            throw "net.exe failed: $($text.Trim())"
        }
    } else {
        Invoke-NetUser -NetArgs @('localgroup', 'Users', $Username, '/add')
    }
}

$sshDir = Join-Path $env:ProgramData 'ssh'
$sshdConfig = Join-Path $sshDir 'sshd_config'
if (Test-Path $sshdConfig) {
    $cfg = Get-Content $sshdConfig -Raw
    if ($cfg -notmatch '(?m)^PasswordAuthentication\s+yes') {
        Write-Host 'Enabling PasswordAuthentication in sshd_config ...'
        Add-Content -Path $sshdConfig -Value ''
        Add-Content -Path $sshdConfig -Value 'PasswordAuthentication yes'
        Restart-Service sshd
    }
}

$profileDir = Join-Path $env:SystemDrive ('Users\{0}' -f $Username)
$dotSsh = Join-Path $profileDir '.ssh'
$authKeys = Join-Path $dotSsh 'authorized_keys'
if (-not (Test-Path $dotSsh)) {
    New-Item -ItemType Directory -Path $dotSsh -Force | Out-Null
}
if (-not (Test-Path $authKeys)) {
    New-Item -ItemType File -Path $authKeys -Force | Out-Null
}
$principal = '{0}\{1}' -f $env:COMPUTERNAME, $Username
& icacls $dotSsh /inheritance:r | Out-Null
& icacls $dotSsh /grant:r ('{0}:(F)' -f $principal) | Out-Null
& icacls $dotSsh /grant 'NT AUTHORITY\SYSTEM:(F)' | Out-Null
& icacls $authKeys /inheritance:r | Out-Null
& icacls $authKeys /grant:r ('{0}:(F)' -f $principal) | Out-Null

Write-Host ''
Write-Host 'SSH user ready.'
Write-Host ('  From Linux: ssh {0}@192.168.0.102' -f $Username)
Write-Host '  Use the password you just set (not your Windows PIN).'
Write-Host ''
Write-Host 'Optional: add an SSH public key for passwordless login:'
Write-Host ('  notepad {0}' -f $authKeys)
