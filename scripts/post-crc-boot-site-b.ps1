# After CRC boot: wait for registry/operator, optionally prune images, restart Keycloak.
# Run when cluster API is up (sitea-ssh or yuke with oc on PATH).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\post-crc-boot-site-b.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\post-crc-boot-site-b.ps1 -PruneImages
#   powershell -ExecutionPolicy Bypass -File .\scripts\post-crc-boot-site-b.ps1 -SkipPrune -SkipKeycloak
param(
    [switch]$PruneImages,
    [switch]$SkipPrune,
    [switch]$SkipKeycloak,
    [int]$WaitMinutes = 15
)

$ErrorActionPreference = 'Stop'
$NS = 'rhbk-mc'

$oc = @(
    "$env:USERPROFILE\.crc\bin\oc\oc.exe",
    'C:\ProgramData\crc\bin\oc.exe',
    'C:\oc\oc.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $oc) { $oc = (Get-Command oc -ErrorAction SilentlyContinue).Source }
if (-not $oc) { throw 'oc not found' }

if (-not $env:KUBECONFIG) {
    $kc = 'C:\ProgramData\crc\kubeconfig'
    if (Test-Path $kc) { $env:KUBECONFIG = $kc }
    elseif (Test-Path "$env:USERPROFILE\.crc\machines\crc\kubeconfig") {
        $env:KUBECONFIG = "$env:USERPROFILE\.crc\machines\crc\kubeconfig"
    }
}

$ocArgs = @('--insecure-skip-tls-verify=true')

function Wait-CoAvailable {
    param([string]$Name, [int]$Minutes)
    Write-Host "Waiting for cluster operator $Name (up to ${Minutes}m) ..."
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        $line = & $oc @ocArgs get co $Name -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>$null
        if ($line -eq 'True') {
            Write-Host "  $Name Available"
            return $true
        }
        Start-Sleep -Seconds 15
    }
    Write-Warning "Timed out waiting for $Name"
    return $false
}

Write-Host '=== Post-CRC boot (Site B) ==='

Wait-CoAvailable -Name 'image-registry' -Minutes $WaitMinutes | Out-Null
Wait-CoAvailable -Name 'ingress' -Minutes 5 | Out-Null

$regCode = curl.exe -sk -o NUL -w '%{http_code}' 'https://default-route-openshift-image-registry.apps-crc.testing/v2/' 2>$null
Write-Host "Registry /v2 HTTP: $regCode (401 = up)"

if ($PruneImages -and -not $SkipPrune) {
    Write-Host 'Pruning unreferenced images (keeps tagged ImageStreams) ...'
    & $oc @ocArgs adm prune images --confirm --keep-tag-revisions=1 --keep-younger-than=24h 2>&1
}

if (-not $SkipKeycloak) {
    Write-Host 'Cleaning stale operator pods ...'
    & $oc @ocArgs delete pod -n $NS -l app.kubernetes.io/name=keycloak-operator `
        --field-selector=status.phase!=Running --ignore-not-found 2>$null | Out-Null

    Write-Host 'Applying Keycloak CR ...'
    $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    & $oc @ocArgs apply -f (Join-Path $root 'manifests\site-b\keycloak.yaml')

    $kcPod = 'keycloak-b-0'
    $phase = & $oc @ocArgs get pod $kcPod -n $NS -o jsonpath='{.status.phase}' 2>$null
    $reason = & $oc @ocArgs get pod $kcPod -n $NS -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>$null
    if ($phase -ne 'Running' -or $reason -match 'ImagePull|BackOff|ErrImage') {
        Write-Host "Restarting $kcPod (was $phase / $reason) ..."
        & $oc @ocArgs delete pod $kcPod -n $NS --ignore-not-found | Out-Null
    }

    Write-Host 'Waiting for keycloak-b-0 Running ...'
    & $oc @ocArgs wait --for=condition=Ready pod/$kcPod -n $NS --timeout=300s 2>&1
}

Write-Host ''
Write-Host 'Status:'
& $oc @ocArgs get pods -n $NS 2>&1
& $oc @ocArgs get imagestream -n $NS 2>&1
