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

Uses Podman named volume `pg-standby-site-b-data` (Windows bind mounts break postgres UID ownership).

Then on Linux primary (or remotely as DB superuser):

```bash
./scripts/enable-sync-replication.sh
# or: ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (site_b_standby)'; SELECT pg_reload_conf();
```

Verify on Linux / via psql to primary:

```bash
podman exec pg-primary-site-a psql -U keycloak -d keycloak \
  -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
```

Expect `site_b_standby | 192.168.0.102 | streaming | sync`.

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
- `keycloak-a.apps-crc.testing` → Linux CRC router / host that serves Site A
- `keycloak-b.apps-crc.testing` → Windows CRC (`crc ip` is often `127.0.0.1` on the Windows host itself; LAN clients use `192.168.0.102`)

## Retarget Linux HAProxy
On Linux (`192.168.0.114`), after Windows Site B `/lb-check` is UP:

```bash
./scripts/apply-haproxy-site-b.sh
curl -sk https://127.0.0.1:8443/lb-check
```

`lb/haproxy.cfg` should have:

```
server site_b 192.168.0.102:443 ... sni str(keycloak-b.apps-crc.testing) ...
```
