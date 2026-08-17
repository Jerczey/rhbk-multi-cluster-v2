# Run in PowerShell on Windows Site B (Podman Desktop)
# Usage: .\start-standby.ps1
# Uses a Podman named volume so postgres UID ownership works under WSL.

$ErrorActionPreference = "Stop"

$PRIMARY_HOST = if ($env:PRIMARY_HOST) { $env:PRIMARY_HOST } else { "192.168.0.114" }
$PRIMARY_PORT = if ($env:PRIMARY_PORT) { $env:PRIMARY_PORT } else { "5432" }
$REPLICATION_USER = "replicator" # notsecret — lab role name, not a credential
$REPLICATION_PASSWORD = "ReplicatorPoC2026!" # notsecret
$POSTGRES_IMAGE = "registry.access.redhat.com/hi/postgresql:17"
$CONTAINER_NAME = "pg-standby-site-b"
$VOLUME_NAME = "pg-standby-site-b-data"
$SLOT_NAME = "site_b_standby"
$APP_NAME = "site_b_standby"
$SCRIPT_DIR = $PSScriptRoot

podman container exists $CONTAINER_NAME 2>$null
if ($LASTEXITCODE -eq 0) {
  podman stop $CONTAINER_NAME 2>$null | Out-Null
  podman rm $CONTAINER_NAME 2>$null | Out-Null
}

podman volume exists $VOLUME_NAME 2>$null
if ($LASTEXITCODE -eq 0) {
  Write-Host "Removing existing volume $VOLUME_NAME for fresh basebackup..."
  podman volume rm $VOLUME_NAME | Out-Null
}
podman volume create $VOLUME_NAME | Out-Null

Write-Host "Taking basebackup from ${PRIMARY_HOST}:${PRIMARY_PORT}..."
podman run --rm `
  --user postgres `
  -e "PGPASSWORD=$REPLICATION_PASSWORD" `
  -v "${VOLUME_NAME}:/var/lib/postgresql/data:Z" `
  $POSTGRES_IMAGE `
  pg_basebackup -h $PRIMARY_HOST -p $PRIMARY_PORT `
    -U $REPLICATION_USER -D /var/lib/postgresql/data `
    -Fp -Xs -P -R -S $SLOT_NAME

if ($LASTEXITCODE -ne 0) {
  throw "pg_basebackup failed with exit $LASTEXITCODE"
}

Write-Host "Configuring standby.signal and primary_conninfo..."
# Convert Windows path to something podman can mount
$cfgMount = ($SCRIPT_DIR -replace '\\','/')
podman run --rm `
  -e "PRIMARY_HOST=$PRIMARY_HOST" `
  -e "PRIMARY_PORT=$PRIMARY_PORT" `
  -e "REPLICATION_USER=$REPLICATION_USER" `
  -e "REPLICATION_PASSWORD=$REPLICATION_PASSWORD" `
  -e "APP_NAME=$APP_NAME" `
  -e "SLOT_NAME=$SLOT_NAME" `
  -v "${VOLUME_NAME}:/var/lib/postgresql/data:Z" `
  -v "${cfgMount}/configure-standby.sh:/configure-standby.sh:ro,Z" `
  $POSTGRES_IMAGE `
  sh -c "tr -d '\r' < /configure-standby.sh | sh"

if ($LASTEXITCODE -ne 0) {
  throw "standby config step failed with exit $LASTEXITCODE"
}

podman run -d --name $CONTAINER_NAME `
  --restart=unless-stopped `
  -v "${VOLUME_NAME}:/var/lib/postgresql/data:Z" `
  -p 5432:5432 `
  --user postgres `
  $POSTGRES_IMAGE `
  postgres -c hot_standby=on

if ($LASTEXITCODE -ne 0) {
  throw "failed to start standby container"
}

Write-Host "Standby started (volume=$VOLUME_NAME). Enable sync on primary, then verify pg_stat_replication."
