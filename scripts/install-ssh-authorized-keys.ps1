# Copy an authorized_keys file into a local user's .ssh folder (OpenSSH-safe ACLs).
# Run elevated:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-ssh-authorized-keys.ps1 `
#     -Username sitea-ssh -SourcePath C:\Users\Yuke\Desktop\authorized_keys
param(
    [Parameter(Mandatory = $true)]
    [string]$Username,
    [Parameter(Mandatory = $true)]
    [string]$SourcePath
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an elevated PowerShell (Run as administrator).'
}

if (-not (Test-Path $SourcePath)) {
    throw "Source not found: $SourcePath"
}

$key = (Get-Content $SourcePath -Raw).Trim()
if (-not $key) {
    throw "Source file is empty: $SourcePath"
}

$dstDir = Join-Path $env:SystemDrive ('Users\{0}\.ssh' -f $Username)
$dst = Join-Path $dstDir 'authorized_keys'
$userAcct = '{0}\{1}' -f $env:COMPUTERNAME, $Username

if (-not (Test-Path $dstDir)) {
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
}

$sshdSvc = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshdSvc -and $sshdSvc.Status -eq 'Running') {
    Stop-Service sshd -Force
    Start-Sleep -Seconds 2
}
Get-Process -Name sshd -ErrorAction SilentlyContinue | Stop-Process -Force

& takeown.exe /F $dstDir /R /A | Out-Null
if (Test-Path $dst) {
    & takeown.exe /F $dst /A | Out-Null
}
& icacls.exe $dstDir /grant 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null
if (Test-Path $dst) {
    & icacls.exe $dst /grant 'BUILTIN\Administrators:F' | Out-Null
}

$tempFile = Join-Path $env:TEMP ('authorized_keys_{0}.tmp' -f $Username)
Set-Content -Path $tempFile -Value $key -Encoding ascii -NoNewline
if (Test-Path $dst) {
    try {
        Remove-Item -Path $dst -Force -ErrorAction Stop
    } catch {
        $bak = '{0}.bak' -f $dst
        if (Test-Path $bak) { Remove-Item -Path $bak -Force -ErrorAction SilentlyContinue }
        Rename-Item -Path $dst -NewName (Split-Path $bak -Leaf) -Force
    }
}
Copy-Item -Path $tempFile -Destination $dst -Force
Remove-Item -Path $tempFile -Force

& icacls.exe $dstDir /inheritance:r | Out-Null
& icacls.exe $dstDir /grant:r ('{0}:(OI)(CI)F' -f $userAcct) | Out-Null
& icacls.exe $dstDir /grant 'NT AUTHORITY\SYSTEM:(OI)(CI)F' | Out-Null

& icacls.exe $dst /inheritance:r | Out-Null
& icacls.exe $dst /grant:r ('{0}:F' -f $userAcct) | Out-Null
& icacls.exe $dst /grant 'NT AUTHORITY\SYSTEM:F' | Out-Null

$svc = Get-Service sshd -ErrorAction SilentlyContinue
if ($svc) {
    Set-Service sshd -StartupType Automatic
    if ($svc.Status -ne 'Running') {
        Start-Service sshd
    }
}

Write-Host 'Installed authorized_keys for' $Username
Write-Host ('  {0}' -f $dst)
Write-Host ('  sshd: {0}' -f (Get-Service sshd).Status)
Write-Host ''
Write-Host 'Test from Linux (no password if key matches):'
Write-Host ('  ssh {0}@192.168.0.102' -f $Username)
