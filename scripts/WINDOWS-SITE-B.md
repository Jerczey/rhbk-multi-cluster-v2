# Windows Site B — runbook and status

**Host:** Windows 11 at `192.168.0.102`  
**Role:** Keycloak `cluster-b` + Podman Postgres **sync standby**  
**Status (2026-07-27):** Site B is live with shared hostname **`auth.lan.local`**, Postgres standby in **sync**, and has **served traffic while Site A was stopped** (SPA failover drill passed).

For the full dual-site story, see the root [README.md](../README.md).

---

## Shared hostname (auth.lan.local)

Both sites use public URL `https://auth.lan.local:8443`. If rebuilding Windows Site B:

```bash
git pull
oc apply -f manifests/site-b/keycloak.yaml
oc -n rhbk-mc wait --for=condition=Ready keycloaks.k8s.keycloak.org/keycloak-b --timeout=300s
oc -n rhbk-mc get route   # expect host auth.lan.local
```

Hosts:

```
192.168.0.114  auth.lan.local
```

On Linux: `./scripts/apply-haproxy-site-b.sh`

### PoC SPA (pod — no npm on Windows)

```bash
./scripts/deploy-poc-spa.sh
# open https://poc-spa.apps-crc.testing
```

Ensure Keycloak client `poc-spa` allows redirect URI `https://poc-spa.apps-crc.testing/*` (see [`apps/poc-spa/config/realm-clients.json`](../apps/poc-spa/config/realm-clients.json)). Details: [`apps/poc-spa/README.md`](../apps/poc-spa/README.md).


---

## Completed cutover (summary)

1. Podman + CRC installed; repo cloned from GitHub.
2. Postgres standby created with `postgres/standby/start-standby.ps1` (named volume `pg-standby-site-b-data`).
3. Linux ran `scripts/enable-sync-replication.sh` → `sync_state=sync`.
4. Keycloak Operator 26.7 + CR (`stateless`, `cluster-b`, JDBC → `192.168.0.114:5432`, hostname `https://auth.lan.local:8443`).
5. Validated as active LB backend when Linux Site A was stopped.
5. Linux HAProxy retargeted with `scripts/apply-haproxy-site-b.sh` (`site_b` → `192.168.0.102:443`).

---

## Prerequisites (if rebuilding)

1. Install Podman Desktop (or Podman) and confirm: `podman run hello-world`
2. Install CRC for Windows, start it, `crc oc-env`, then `oc login -u kubeadmin ...`
3. Allow inbound TCP **5432** from `192.168.0.114` (Windows Defender Firewall) for promote/testing
4. Clone or pull: https://github.com/Jerczey/rhbk-multi-cluster-v2  
   Copy `secrets/postgres.env.example` → `secrets/postgres.env` (and TLS if needed)

Optional: LAN file share from Linux `http://192.168.0.114:8765/` when the helper is running.

---

## Postgres standby

From `postgres/standby` in PowerShell:

```powershell
.\start-standby.ps1
```

Uses Podman named volume `pg-standby-site-b-data` (Windows bind mounts break postgres UID ownership). Helpers: `configure-standby.sh`.

Then on **Linux** primary:

```bash
./scripts/enable-sync-replication.sh
```

Verify on Linux:

```bash
podman exec pg-primary-site-a psql -U keycloak -d keycloak \
  -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
```

Expect: `site_b_standby | 192.168.0.102 | streaming | sync`.

---

## Prove CRC → Linux Postgres

```bash
oc run pgcheck --rm -i --restart=Never --image=docker.io/library/postgres:17-alpine -- \
  env PGPASSWORD='KeycloakPoC2026!' psql -h 192.168.0.114 -U keycloak -d keycloak -c 'SELECT 1'
```

---

## Deploy Keycloak Site B

```bash
# Git Bash / WSL with oc pointing at Windows CRC
export APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
./scripts/deploy-site-b.sh
```

Confirm:

```bash
curl -sk https://keycloak-b.apps-crc.testing/lb-check   # on Windows host
# From Linux LAN:
curl -sk --resolve keycloak-b.apps-crc.testing:443:192.168.0.102 \
  https://keycloak-b.apps-crc.testing/lb-check
```

---

## Hosts file (clients)

| Name | Points to |
|------|-----------|
| `keycloak-a.apps-crc.testing` | Linux CRC / Site A path |
| `keycloak-b.apps-crc.testing` | Windows CRC — LAN clients use `192.168.0.102` (`crc ip` is often `127.0.0.1` **on** the Windows host itself) |

---

## Retarget Linux HAProxy

On Linux (`192.168.0.114`), after Windows Site B `/lb-check` is UP:

```bash
./scripts/apply-haproxy-site-b.sh
curl -sk https://127.0.0.1:8443/lb-check
```

`lb/haproxy.cfg` should include:

```
server site_b 192.168.0.102:443 ... sni str(keycloak-b.apps-crc.testing) ...
```
