# Equivalent of "crc oc-env" for sitea-ssh (shared paths; Yuke's .crc is not readable).
# Run elevated:
#   powershell -ExecutionPolicy Bypass -File .\scripts\setup-sitea-ssh-oc-path.ps1
param(
    [string]$Username = 'sitea-ssh',
    [string]$SharedBin = 'C:\ProgramData\crc\bin',
    [string]$SharedKubeconfig = 'C:\ProgramData\crc\kubeconfig',
    [string]$CrcInstallDir = 'C:\Program Files\Red Hat OpenShift Local'
)

$ErrorActionPreference = 'Stop'

function Require-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run in elevated PowerShell (Administrator).'
    }
}

function Get-CrcOcEnvOcDir {
    $crcExe = Join-Path $CrcInstallDir 'crc.exe'
    if (-not (Test-Path $crcExe)) {
        $crcCmd = Get-Command crc -ErrorAction SilentlyContinue
        if ($crcCmd) { $crcExe = $crcCmd.Source } else { throw 'crc.exe not found' }
    }
    $lines = & $crcExe oc-env --shell powershell 2>&1
    $pathLine = $lines | Where-Object { $_ -match '^\$Env:PATH\s*=' } | Select-Object -First 1
    if (-not $pathLine) {
        throw 'Could not parse crc oc-env output'
    }
    if ($pathLine -match '=\s*"([^";]+)') {
        return $Matches[1].Trim()
    }
    throw "Unexpected crc oc-env line: $pathLine"
}

function Publish-ReadableFile {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$UsersRight = 'RX'
    )
    $destDir = Split-Path $Destination -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -Path $Source -Destination $Destination -Force
    & icacls.exe $destDir /inheritance:r | Out-Null
    & icacls.exe $destDir /grant 'NT AUTHORITY\SYSTEM:(OI)(CI)F' | Out-Null
    & icacls.exe $destDir /grant 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null
    & icacls.exe $destDir /grant ('BUILTIN\Users:(OI)(CI){0}' -f $UsersRight) | Out-Null
    & icacls.exe $Destination /inheritance:r | Out-Null
    & icacls.exe $Destination /grant 'NT AUTHORITY\SYSTEM:F' | Out-Null
    & icacls.exe $Destination /grant 'BUILTIN\Administrators:F' | Out-Null
    & icacls.exe $Destination /grant ('BUILTIN\Users:{0}' -f $UsersRight) | Out-Null
}

function Add-MachinePathEntry {
    param([string]$Entry)
    if (-not $Entry) { return }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($machinePath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
    if ($parts -notcontains $Entry) {
        $parts += $Entry
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Machine')
        Write-Host "Added to Machine PATH: $Entry"
    } else {
        Write-Host "Machine PATH already contains: $Entry"
    }
}

Require-Admin

Write-Host '=== crc oc-env equivalent for sitea-ssh ==='

$sourceOcDir = Get-CrcOcEnvOcDir
$sourceOc = Join-Path $sourceOcDir 'oc.exe'
if (-not (Test-Path $sourceOc)) {
    throw "oc.exe not found at $sourceOc (from crc oc-env)"
}
Write-Host "crc oc-env points to: $sourceOcDir"

if (-not (Test-Path $SharedBin)) {
    New-Item -ItemType Directory -Path $SharedBin -Force | Out-Null
}
$sharedOc = Join-Path $SharedBin 'oc.exe'
Publish-ReadableFile -Source $sourceOc -Destination $sharedOc
Write-Host "Published oc.exe: $sharedOc"

$sourceKube = Join-Path $env:USERPROFILE '.crc\machines\crc\kubeconfig'
if (Test-Path $sourceKube) {
    Publish-ReadableFile -Source $sourceKube -Destination $SharedKubeconfig -UsersRight 'R'
    Write-Host "Published kubeconfig (read-only): $SharedKubeconfig"
    Write-Host 'Note: KUBECONFIG is set only in sitea-ssh PowerShell profile, not Machine-wide.'
} else {
    Write-Warning "kubeconfig not found: $sourceKube"
}

Add-MachinePathEntry -Entry $SharedBin
if (Test-Path $CrcInstallDir) {
    Add-MachinePathEntry -Entry $CrcInstallDir
}

$profileDir = Join-Path $env:SystemDrive ("Users\{0}\Documents\WindowsPowerShell" -f $Username)
$profileFile = Join-Path $profileDir 'Microsoft.PowerShell_profile.ps1'
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

# Same effect as:  crc oc-env | Invoke-Expression  (+ KUBECONFIG for CRC)
$profileContent = @(
    '# Auto-generated: crc oc-env equivalent for SSH sessions'
    ('$env:Path = ''{0};'' + $env:Path' -f $SharedBin)
    ('$env:KUBECONFIG = ''{0}''' -f $SharedKubeconfig)
    ('$env:Path = ''{0};'' + $env:Path' -f $CrcInstallDir)
    ''
    'function Use-CrcOcEnv {'
    ('    $env:Path = ''{0};'' + $env:Path' -f $SharedBin)
    ('    $env:KUBECONFIG = ''{0}''' -f $SharedKubeconfig)
    ('    $env:Path = ''{0};'' + $env:Path' -f $CrcInstallDir)
    '}'
)
Set-Content -Path $profileFile -Value $profileContent -Encoding ascii

$userAcct = '{0}\{1}' -f $env:COMPUTERNAME, $Username
& icacls.exe $profileDir /grant ('{0}:(OI)(CI)M' -f $userAcct) | Out-Null
& icacls.exe $profileFile /grant ('{0}:F' -f $userAcct) | Out-Null

Write-Host ''
Write-Host 'Done. New SSH session as' $Username ':'
Write-Host '  oc version --client'
Write-Host '  oc whoami'
Write-Host '  crc status'
Write-Host ''
Write-Host 'Re-run this script after crc update if oc path changes.'
