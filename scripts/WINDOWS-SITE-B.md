# Windows Site B setup checklist (192.168.0.102)

## Prerequisites
1. Install Podman Desktop (or Podman) and confirm: `podman run hello-world`
2. Install CRC for Windows, start it, `crc oc-env` then `oc login -u kubeadmin ...`
3. Allow inbound TCP 5432 from 192.168.0.114 (Windows Defender Firewall) for later promote/testing
4. Copy this repo folder to Windows (USB, scp, or shared folder), especially:
   - `postgres/standby/`
   - `manifests/`
   - `scripts/deploy-site-b.sh`
   - `secrets/` (tls + postgres.env)

## Postgres standby
From `postgres/standby` in PowerShell:

```powershell
.\start-standby.ps1
```

Then on Linux primary:

```bash
./scripts/enable-sync-replication.sh
```

Verify on Linux:

```bash
podman exec pg-primary-site-a psql -U keycloak -d keycloak \
  -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
```

Expect `sync_state = sync` for `site_b_standby`.

## Prove CRC → Linux Postgres

```bash
oc run pgcheck --rm -i --restart=Never --image=docker.io/library/postgres:17-alpine -- \
  env PGPASSWORD='KeycloakPoC2026!' psql -h 192.168.0.114 -U keycloak -d keycloak -c 'SELECT 1'
```

## Deploy Keycloak Site B

```bash
# Git Bash / WSL with oc pointing at Windows CRC
export APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
./scripts/deploy-site-b.sh
```

## Hosts file (clients)
Add Windows CRC apps domain / router IP similar to Linux `apps-crc.testing`.
