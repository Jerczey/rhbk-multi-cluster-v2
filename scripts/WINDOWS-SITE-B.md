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

### PoC SPA (from Windows browser)

SPA runs on **Linux**, not on Windows CRC. After Linux `npm start` in `apps/poc-spa`:

1. Hosts: `192.168.0.114  auth.lan.local`
2. Trust https://auth.lan.local:8443/lb-check (and `:8444` if prompted)
3. Open **https://auth.lan.local:8444** — users `alice`/`alice`, `bob`/`bob`

Ensure Keycloak client `poc-spa` allows redirect URI `https://auth.lan.local:8444/*` (see [`apps/poc-spa/config/realm-clients.json`](../apps/poc-spa/config/realm-clients.json)). Details: [`apps/poc-spa/README.md`](../apps/poc-spa/README.md).

---

## Completed cutover (summary)

1. Podman + CRC installed; repo cloned from GitHub.
2. Postgres standby created with `postgres/standby/start-standby.ps1` (named volume `pg-standby-site-b-data`).
3. Linux ran `scripts/enable-sync-replication.sh` → `sync_state=sync`.
4. Keycloak Operator 26.7 + CR (`stateless`, `cluster-b`, JDBC → `192.168.0.114:5432`, hostname `https://auth.lan.local:8443`).
5. Validated as active LB backend when Linux Site A was stopped.
6. Linux HAProxy retargeted with `scripts/apply-haproxy-site-b.sh` (`site_b` → `192.168.0.102:443`).

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
oc run pgcheck --rm -i --restart=Never --image=registry.access.redhat.com/hi/postgresql:18 -- \
  env PGPASSWORD='KeycloakPoC2026!' psql -h 192.168.0.114 -U keycloak -d keycloak -c 'SELECT 1' # notsecret
```

---

## Optimized Keycloak image (faster Site B startup)

Site B uses a **prebuilt optimized image** (`startOptimized: true`) so pods skip the `kc.sh build` step on every start (~10s faster in lab; see [`docs/HPA-BENCHMARK.md`](../docs/HPA-BENCHMARK.md)).

**Containerfile:** [`images/keycloak-optimized/Containerfile`](../images/keycloak-optimized/Containerfile)

| Build-time (`kc.sh build`) | Runtime (Keycloak CR) |
|----------------------------|------------------------|
| `KC_DB=postgres`, `KC_FEATURES=stateless`, metrics, health | JDBC URL, hostname `auth.lan.local`, `cluster-b` cache name |

Build and push to the CRC internal registry (once per CRC rebuild, or when Keycloak version changes):

```powershell
# PowerShell — CRC running, oc logged in, Podman running
.\scripts\build-keycloak-optimized-image.ps1
```

CRC registry TLS is cluster-signed. The script uses `podman login --tls-verify=false` (same as `oc --insecure-skip-tls-verify`).

On Windows, Podman runs inside a VM. CRC maps the registry hostname to `127.0.0.1` on Windows, but inside the Podman VM that address is the VM itself — not the Windows host where CRC listens on `:443`. The build script fixes this automatically by pointing the registry hostname at the Podman VM gateway (the Windows host IP).

If `podman push` fails with `dial tcp 127.0.0.1:80: connect: connection refused`, re-run `.\scripts\build-keycloak-optimized-image.ps1` (it updates `/etc/hosts` in the Podman machine). Or verify from the VM:

```powershell
podman machine ssh "getent hosts default-route-openshift-image-registry.apps-crc.testing"
# should NOT be 127.0.0.1 — should be the gateway (e.g. 172.28.144.1)
podman machine ssh "curl -sk -o /dev/null -w '%{http_code}\n' https://default-route-openshift-image-registry.apps-crc.testing/v2/"
# expect 401 (registry up, auth required)
```

Manual login + push (after hosts fix above):

```powershell
$REG = "default-route-openshift-image-registry.apps-crc.testing"
oc whoami -t | podman login -u (oc whoami) --password-stdin --tls-verify=false $REG
podman push --tls-verify=false default-route-openshift-image-registry.apps-crc.testing/rhbk-mc/keycloak:26.7.0-optimized
```

A `401` from `curl -sk https://$REG/v2/` means the registry is **up** (auth required). `x509: certificate signed by unknown authority` on login means use `--tls-verify=false`, not that the registry is down.

Or Git Bash:

```bash
bash scripts/build-keycloak-optimized-image.sh
```

Image tag: `default-route-openshift-image-registry.apps-crc.testing/rhbk-mc/keycloak:26.7.0-optimized`

`deploy-site-b.sh` runs the build automatically unless `SKIP_BUILD_OPT=1`.

---

## Deploy Keycloak Site B

```bash
# Git Bash / WSL with oc pointing at Windows CRC
export APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
./scripts/deploy-site-b.sh
```

Confirm:

```bash
# On Windows host (route host is auth.lan.local):
curl -sk https://auth.lan.local/lb-check
# From Linux LAN:
curl -sk --resolve auth.lan.local:443:192.168.0.102 https://auth.lan.local/lb-check
```

---

## Hosts file (clients)

| Name | Points to |
|------|-----------|
| `auth.lan.local` | `192.168.0.114` (HAProxy `:8443` + SPA `:8444`) |
| `keycloak-a.apps-crc.testing` | Optional debug only — Linux CRC |
| `keycloak-b.apps-crc.testing` | Optional debug only — Windows CRC LAN `192.168.0.102` |

---

## Retarget Linux HAProxy

On Linux (`192.168.0.114`), after Windows Site B `/lb-check` is UP:

```bash
./scripts/apply-haproxy-site-b.sh
curl -sk https://127.0.0.1:8443/lb-check
```

`lb/haproxy.cfg` should include:

```
server site_b 192.168.0.102:443 ... sni str(auth.lan.local) ...
```
