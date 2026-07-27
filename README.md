# RHBK / Keycloak multi-cluster v2 PoC

Dual Keycloak **26.7** clusters with preview `stateless` feature, Podman PostgreSQL **synchronous** replication, and a LAN HAProxy probing `/lb-check`.

## Current lab topology (running on Linux CRC)

| Component | Where | Detail |
|-----------|--------|--------|
| Site A Keycloak | CRC ns `rhbk-mc` | `cluster-a`, https://keycloak-a.apps-crc.testing |
| Site B Keycloak | CRC ns `rhbk-mc` | `cluster-b`, https://keycloak-b.apps-crc.testing |
| Postgres primary | Podman `pg-primary-site-a` | `192.168.0.114:5432` |
| Postgres sync standby | Podman `pg-standby-site-b` | host port `5433`, `sync_state=sync` |
| External LB | Podman `kc-haproxy-lb` | https://192.168.0.114:8443 → both sites |

> **Note:** RHBK Operator catalog tops out at 26.6.x; this PoC uses **community Keycloak Operator 26.7.0** + `quay.io/keycloak/keycloak:26.7.0` because `stateless` / multi-cluster v2 requires 26.7+.
>
> Site B Keycloak currently runs as a **second independent cluster on the same Linux CRC** (valid multi-cluster v2). When Windows CRC at `192.168.0.102` is ready, move Site B with `scripts/deploy-site-b.sh` and optionally relocate the Postgres standby with `postgres/standby/start-standby.ps1`.

## Quick verify

```bash
curl -sk https://keycloak-a.apps-crc.testing/lb-check   # UP
curl -sk https://keycloak-b.apps-crc.testing/lb-check   # UP
curl -sk https://192.168.0.114:8443/lb-check            # UP (HAProxy)

podman exec pg-primary-site-a psql -U keycloak -d keycloak \
  -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
# expect: site_b_standby | streaming | sync
```

Admin (Site A bootstrap secret):

```bash
oc get secret keycloak-initial-admin -n rhbk-mc -o jsonpath='{.data.password}' | base64 -d; echo
# user: temp-admin
```

## Scripts

| Script | Purpose |
|--------|---------|
| `postgres/primary/start-primary.sh` | Start primary Postgres |
| `postgres/standby/start-standby.sh` / `.ps1` | Site B standby (Windows uses `.ps1`) |
| `scripts/enable-sync-replication.sh` | Set `synchronous_standby_names` |
| `scripts/deploy-site-a.sh` | Operator + Keycloak cluster-a |
| `scripts/deploy-site-b.sh` | Operator + Keycloak cluster-b (any CRC) |
| `scripts/promote-standby.sh` | Failover dry-run / promote |
| `lb/start-haproxy.sh` | LAN LB with `/lb-check` |

Credentials: `secrets/postgres.env`, `secrets/keycloak-admin.env` (gitignored).

## Windows Site B follow-up

See [scripts/WINDOWS-SITE-B.md](scripts/WINDOWS-SITE-B.md). Repo is also served at `http://192.168.0.114:8765/` when the helper HTTP server is running.

Required on Windows: Podman, CRC, firewall allow to `192.168.0.114:5432`, then standby + `deploy-site-b.sh`.

## Docs used

- `docs/Multi-cluster deployments (v2) - Keycloak.pdf`
- `docs/Concepts for multi-cluster deployments (v2) - Keycloak.pdf`
- `docs/Deploying Keycloak for HA with the Operator (v2) - Keycloak.pdf`
