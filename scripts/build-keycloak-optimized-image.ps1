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

$token | podman login -u $whoami --password-stdin $Registry
if ($LASTEXITCODE -ne 0) { throw "podman login to $Registry failed" }

podman push $Image
if ($LASTEXITCODE -ne 0) { throw "podman push failed" }

Write-Host "Pushed $Image"
Write-Host ""
Write-Host "Site B CR should use:"
Write-Host "  image: $Image"
Write-Host "  startOptimized: true"
