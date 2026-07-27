# Run in PowerShell on Windows Site B (Podman Desktop)
# Usage: .\start-standby.ps1

$ErrorActionPreference = "Stop"

$PRIMARY_HOST = if ($env:PRIMARY_HOST) { $env:PRIMARY_HOST } else { "192.168.0.114" }
$PRIMARY_PORT = if ($env:PRIMARY_PORT) { $env:PRIMARY_PORT } else { "5432" }
$REPLICATION_USER = "replicator"
$REPLICATION_PASSWORD = "ReplicatorPoC2026!"
$POSTGRES_IMAGE = "docker.io/library/postgres:17-alpine"
$CONTAINER_NAME = "pg-standby-site-b"
$DATA_DIR = Join-Path $PSScriptRoot "data"
$SLOT_NAME = "site_b_standby"
$APP_NAME = "site_b_standby"

New-Item -ItemType Directory -Force -Path $DATA_DIR | Out-Null

$exists = podman container exists $CONTAINER_NAME 2>$null
if ($LASTEXITCODE -eq 0) {
  podman stop $CONTAINER_NAME 2>$null
  podman rm $CONTAINER_NAME 2>$null
}

if (Test-Path (Join-Path $DATA_DIR "PG_VERSION")) {
  Write-Error "Existing data in $DATA_DIR — delete it to re-basebackup: Remove-Item -Recurse -Force $DATA_DIR\*"
}

Write-Host "Taking basebackup from $PRIMARY_HOST..."
podman run --rm `
  -e "PGPASSWORD=$REPLICATION_PASSWORD" `
  -v "${DATA_DIR}:/var/lib/postgresql/data:Z" `
  $POSTGRES_IMAGE `
  pg_basebackup -h $PRIMARY_HOST -p $PRIMARY_PORT `
    -U $REPLICATION_USER -D /var/lib/postgresql/data `
    -Fp -Xs -P -R -S $SLOT_NAME

@"
primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$REPLICATION_USER password=$REPLICATION_PASSWORD application_name=$APP_NAME'
primary_slot_name = '$SLOT_NAME'
"@ | Set-Content -Path (Join-Path $DATA_DIR "postgresql.auto.conf") -Encoding ascii

New-Item -ItemType File -Force -Path (Join-Path $DATA_DIR "standby.signal") | Out-Null

podman run -d --name $CONTAINER_NAME `
  --restart=unless-stopped `
  -v "${DATA_DIR}:/var/lib/postgresql/data:Z" `
  -p 5432:5432 `
  $POSTGRES_IMAGE

Write-Host "Standby started. On Linux primary run: scripts/enable-sync-replication.sh"
