# Fix sitea-ssh authorized_keys when ACLs are broken. MUST run elevated.
#   powershell -ExecutionPolicy Bypass -File .\scripts\fix-sitea-ssh-authorized-keys.ps1
param(
    [string]$Username = 'sitea-ssh',
    [string]$SourcePath = 'C:\Users\Yuke\Desktop\authorized_keys'
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator first (window title must say Administrator).'
}

$dstDir = Join-Path $env:SystemDrive ('Users\{0}\.ssh' -f $Username)
$dst = Join-Path $dstDir 'authorized_keys'
$alt = Join-Path $dstDir 'authorized_keys_.txt'
$userAcct = '{0}\{1}' -f $env:COMPUTERNAME, $Username

if (-not (Test-Path $dstDir)) {
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
}

$key = $null
if (Test-Path $SourcePath) {
    $key = (Get-Content $SourcePath -Raw).Trim()
}
if (-not $key -and (Test-Path $alt)) {
    $key = (Get-Content $alt -Raw).Trim()
}
if (-not $key) {
    throw "No key found in $SourcePath or $alt"
}

Write-Host 'Step 0: stop sshd (releases file lock) ...'
$sshdSvc = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshdSvc -and $sshdSvc.Status -eq 'Running') {
    Stop-Service sshd -Force
    Start-Sleep -Seconds 2
}
Get-Process -Name sshd -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

Write-Host 'Step 1: take ownership (Administrators) ...'
& takeown.exe /F $dstDir /R /A | Out-Null
if (Test-Path $dst) {
    & takeown.exe /F $dst /A | Out-Null
}

Write-Host 'Step 2: grant Administrators write access ...'
& icacls.exe $dstDir /grant ('BUILTIN\Administrators:(OI)(CI)F') | Out-Null
if (Test-Path $dst) {
    & icacls.exe $dst /grant 'BUILTIN\Administrators:F' | Out-Null
}

Write-Host 'Step 3: write authorized_keys ...'
$tempFile = Join-Path $env:TEMP ('authorized_keys_{0}.tmp' -f $Username)
Set-Content -Path $tempFile -Value $key -Encoding ascii -NoNewline
if (Test-Path $dst) {
    try {
        Remove-Item -Path $dst -Force -ErrorAction Stop
    } catch {
        $bak = '{0}.bak' -f $dst
        Write-Host 'File locked; renaming old file to .bak ...'
        if (Test-Path $bak) { Remove-Item -Path $bak -Force -ErrorAction SilentlyContinue }
        Rename-Item -Path $dst -NewName (Split-Path $bak -Leaf) -Force
    }
}
Copy-Item -Path $tempFile -Destination $dst -Force
Remove-Item -Path $tempFile -Force

Write-Host 'Step 4: lock down ACLs for OpenSSH ...'
& icacls.exe $dstDir /inheritance:r | Out-Null
& icacls.exe $dstDir /grant:r ('{0}:(OI)(CI)F' -f $userAcct) | Out-Null
& icacls.exe $dstDir /grant 'NT AUTHORITY\SYSTEM:(OI)(CI)F' | Out-Null

& icacls.exe $dst /inheritance:r | Out-Null
& icacls.exe $dst /grant:r ('{0}:F' -f $userAcct) | Out-Null
& icacls.exe $dst /grant 'NT AUTHORITY\SYSTEM:F' | Out-Null

Write-Host 'Step 5: start sshd ...'
Set-Service sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') {
    Start-Service sshd
}

Write-Host ''
Write-Host 'Done.'
Write-Host ('  File: {0}' -f $dst)
Write-Host ('  Key:  {0}' -f (Get-Content $dst))
Write-Host ('  sshd: {0}' -f (Get-Service sshd).Status)
& icacls.exe $dst
Write-Host ''
Write-Host ('Test: ssh {0}@192.168.0.102' -f $Username)
