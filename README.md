# RHBK / Keycloak multi-cluster v2 PoC

Dual Keycloak **26.7** clusters with preview `stateless` feature, Podman PostgreSQL **synchronous** replication, and a LAN HAProxy probing `/lb-check`.

## Current lab topology

| Component | Where | Detail |
|-----------|--------|--------|
| Site A Keycloak | Linux CRC ns `rhbk-mc` | `cluster-a`, https://keycloak-a.apps-crc.testing |
| Site B Keycloak | Windows CRC ns `rhbk-mc` (`192.168.0.102`) | `cluster-b`, https://keycloak-b.apps-crc.testing |
| Postgres primary | Podman on Linux `pg-primary-site-a` | `192.168.0.114:5432` |
| Postgres sync standby | Podman on Windows `pg-standby-site-b` | host port `5432`, `sync_state=sync` |
| External LB | Podman on Linux `kc-haproxy-lb` | https://192.168.0.114:8443 → Site A + Site B |

> **Note:** RHBK Operator catalog tops out at 26.6.x; this PoC uses **community Keycloak Operator 26.7.0** + `quay.io/keycloak/keycloak:26.7.0` because `stateless` / multi-cluster v2 requires 26.7+.

## Quick verify

```bash
curl -sk https://keycloak-a.apps-crc.testing/lb-check   # UP (from Linux / hosts → Linux CRC)
curl -sk https://keycloak-b.apps-crc.testing/lb-check   # UP (from Windows / hosts → Windows CRC)
curl -sk https://192.168.0.114:8443/lb-check            # UP (HAProxy)

podman exec pg-primary-site-a psql -U keycloak -d keycloak \
  -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
# expect: site_b_standby | 192.168.0.102 | streaming | sync
```

Admin (Site A bootstrap secret on Linux CRC):

```bash
oc get secret keycloak-initial-admin -n rhbk-mc -o jsonpath='{.data.password}' | base64 -d; echo
# user: temp-admin
```

## Scripts

| Script | Purpose |
|--------|---------|
| `postgres/primary/start-primary.sh` | Start primary Postgres |
| `postgres/standby/start-standby.sh` / `.ps1` | Site B standby (Windows uses `.ps1` + named volume) |
| `scripts/enable-sync-replication.sh` | Set `synchronous_standby_names` (Linux primary) |
| `scripts/deploy-site-a.sh` | Operator + Keycloak cluster-a |
| `scripts/deploy-site-b.sh` | Operator + Keycloak cluster-b (any CRC) |
| `scripts/apply-haproxy-site-b.sh` | Point Linux HAProxy `site_b` at Windows CRC and recreate LB |
| `scripts/promote-standby.sh` | Failover dry-run / promote |
| `lb/start-haproxy.sh` | LAN LB with `/lb-check` |

Credentials: `secrets/postgres.env`, `secrets/keycloak-admin.env` (gitignored).

## Windows Site B follow-up

See [scripts/WINDOWS-SITE-B.md](scripts/WINDOWS-SITE-B.md). After Site B is Ready on Windows, on Linux run:

```bash
./scripts/apply-haproxy-site-b.sh
```

Repo is also served at `http://192.168.0.114:8765/` when the helper HTTP server is running.

## Docs used

- `docs/Multi-cluster deployments (v2) - Keycloak.pdf`
- `docs/Concepts for multi-cluster deployments (v2) - Keycloak.pdf`
- `docs/Deploying Keycloak for HA with the Operator (v2) - Keycloak.pdf`
