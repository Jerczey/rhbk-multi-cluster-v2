# Build and push prebuilt optimized Keycloak image to the CRC internal registry.
# Required for startOptimized: true (see images/keycloak-optimized/Containerfile).
#
# Usage (PowerShell, CRC running, oc logged in):
#   .\scripts\build-keycloak-optimized-image.ps1
#   .\scripts\build-keycloak-optimized-image.ps1 -Push:$false   # build only
#
param(
    [string]$Namespace = "rhbk-mc",
    [string]$Tag = "26.7.0-optimized",
    [string]$Registry = "default-route-openshift-image-registry.apps-crc.testing",
    [switch]$Push = $true
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Containerfile = Join-Path $Root "images\keycloak-optimized\Containerfile"
$Context = Join-Path $Root "images\keycloak-optimized"
$Image = "${Registry}/${Namespace}/keycloak:${Tag}"

if (-not (Test-Path $Containerfile)) {
    throw "Containerfile not found: $Containerfile"
}

$oc = @(
    "$env:USERPROFILE\.crc\bin\oc\oc.exe",
    "C:\Program Files\Red Hat OpenShift Local\crc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $oc) {
    $oc = (Get-Command oc -ErrorAction SilentlyContinue).Source
}
if (-not $oc) {
    throw "oc not found; run crc oc-env and ensure oc is on PATH"
}

Write-Host "=== Build optimized Keycloak image ==="
Write-Host "image=$Image"
Write-Host "Containerfile=$Containerfile"

podman build -f $Containerfile -t $Image $Context
if ($LASTEXITCODE -ne 0) { throw "podman build failed" }

if (-not $Push) {
    Write-Host "Build complete (Push disabled)."
    exit 0
}

$env:KUBECONFIG = "$env:USERPROFILE\.crc\machines\crc\kubeconfig"
$whoami = & $oc --insecure-skip-tls-verify=true whoami 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Not logged in to OpenShift; skipping push. Run: oc login ..."
    exit 0
}

$token = & $oc --insecure-skip-tls-verify=true whoami -t 2>&1
if (-not $token) { throw "Could not get oc token for registry login" }

# Podman on Windows runs in a VM. CRC adds the registry hostname to Windows hosts as 127.0.0.1,
# but inside the VM that points at the VM itself, not the Windows host where CRC listens.
$route = (podman machine ssh "ip route show default" 2>&1 | Out-String).Trim()
if ($route -match 'default via (\S+)') {
    $gateway = $Matches[1]
    Write-Host "Routing $Registry via podman VM gateway $gateway (Windows host)"
    podman machine ssh "sudo sh -c 'grep -v $Registry /etc/hosts > /tmp/hosts.new 2>/dev/null || true; echo $gateway $Registry >> /tmp/hosts.new; cp /tmp/hosts.new /etc/hosts'" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to update /etc/hosts inside podman machine" }
} else {
    Write-Warning "Could not detect podman VM gateway; push may fail if registry resolves to 127.0.0.1 inside the VM"
}

# CRC registry uses a cluster-signed cert; Podman on Windows does not trust it by default.
$token | podman login -u $whoami --password-stdin --tls-verify=false $Registry
if ($LASTEXITCODE -ne 0) { throw "podman login to $Registry failed (try: oc login first)" }

podman push --tls-verify=false $Image
if ($LASTEXITCODE -ne 0) { throw "podman push failed" }

Write-Host "Pushed $Image"
Write-Host ""
Write-Host "Site B CR should use:"
Write-Host "  image: $Image"
Write-Host "  startOptimized: true"
