# Undo machine-wide KUBECONFIG (breaks oc login for yuke). Run elevated once.
#   powershell -ExecutionPolicy Bypass -File .\scripts\fix-kubeconfig-env.ps1
param(
    [string]$YukeKubeconfig = "$env:USERPROFILE\.crc\machines\crc\kubeconfig"
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run in elevated PowerShell (Administrator).'
}

# Machine KUBECONFIG was read-only ProgramData copy; oc must write on login.
[Environment]::SetEnvironmentVariable('KUBECONFIG', $null, 'Machine')
Write-Host 'Removed Machine KUBECONFIG'

# Restore yuke user kubeconfig (current admin user)
[Environment]::SetEnvironmentVariable('KUBECONFIG', $YukeKubeconfig, 'User')
Write-Host "Set User KUBECONFIG: $YukeKubeconfig"

Write-Host ''
Write-Host 'Open a NEW PowerShell window, then:'
Write-Host '  oc whoami'
Write-Host ''
Write-Host 'sitea-ssh still uses KUBECONFIG via its PowerShell profile (read-only shared copy).'
