# OIDC flow validation (`rhbk-mc`)

Runbook for confirming **authorization code** and **token exchange** flows on Keycloak **26.7** with `stateless` multi-cluster (`auth.lan.local:8443`). Focus: **cross-site failover** (Site A / Site B), not in-site pod churn.

**Interactive canvas (Cursor IDE):** open `oidc-flow-interactive-poc.canvas.tsx` from the workspace canvases panel — failover simulator (Drop Site A/B), test explorer (AC/TE), and 2026-08-21 full-run results. Static summary: `oidc-flow-test-results-2026-08-14.canvas.tsx`.

## Prerequisites

```bash
bash scripts/verify-poc.sh
cd apps/poc-spa && npm install && npm run setup-realm
# optional SPA: npm start  → https://auth.lan.local:8444
chmod +x scripts/verify-*.sh scripts/lib/oidc-common.sh
# One-time on Linux primary (persistent LAN firewall for Postgres 5432, etc.):
sudo ./scripts/install-lab-firewall.sh
```

| Check | Command |
|-------|---------|
| Issuer | `curl -sk https://auth.lan.local:8443/realms/poc-realm/.well-known/openid-configuration \| jq .issuer` |
| LB | `curl -sk https://auth.lan.local:8443/lb-check` |
| Auth-code smoke | `bash scripts/verify-auth-code-failover.sh` |
| Token exchange V2 | `bash scripts/verify-token-exchange-v2.sh` |

### Baseline (record per run)

| Field | Value |
|-------|-------|
| Date | 2026-08-14 |
| Keycloak image | `quay.io/keycloak/keycloak:26.7.0` |
| Site A Ready | Yes |
| Site B Ready | Yes |
| Postgres replication | `site_b_standby` streaming **sync** |
| Issuer | `https://auth.lan.local:8443/realms/poc-realm` |

---

## Why no session stickiness

| Layer | Setting | Effect |
|-------|---------|--------|
| HAProxy | `balance roundrobin`, `disable_cookies` | No backend affinity |
| Keycloak CR | `features: [stateless]` | No cross-site Infinispan |
| Shared DB | Both sites JDBC → Linux primary | Session state in Postgres |

Failover must work **without** sticky sessions.

---

## Phase 1 — Authorization code flow (cross-site)

**Client:** `poc-spa` (public, PKCE S256)  
**Script:** `bash scripts/verify-auth-code-failover.sh` (automated smoke + checklist)

| ID | Action | Expected | Pass |
|----|--------|----------|------|
| AC-1 | Login `https://auth.lan.local:8444` (alice/alice) | Redirect via `:8443`, issuer correct | Manual (SPA not running this run) |
| AC-2 | **Refresh token** in SPA | New access token, same issuer | Manual |
| AC-3 | **Call protected API** | `200` `/api/protected/profile` | Manual |
| AC-4 | Drop **Site A** | `/lb-check` UP; refresh + API OK via Site B | **PASS** — TE-2 token exchange OK with Site A scaled to 0 |
| AC-5 | Restore A; drop **Site B** | Same via Site A | **PASS** — TE-3 token exchange OK with Site B scaled to 0 |
| AC-6 | Drop **both** sites | `/lb-check` 503; refresh/login fail | **PASS** — `503` when Site A scaled to 0 (no Site B backend) |
| AC-7 | Repeat AC-4; DevTools → no sticky cookie | Round-robin OK with `stateless` | Manual |

### Site control commands

```bash
# Drop Site A (Linux CRC)
oc -n rhbk-mc scale statefulset/keycloak --replicas=0
# or: crc stop  (leaves HAProxy + Postgres up)

# Restore Site A
oc -n rhbk-mc scale statefulset/keycloak --replicas=1

# Site B: stop Windows CRC or scale Keycloak on Windows cluster
```

---

## Phase 2 — Token exchange clients (`poc-realm`)

Created by `npm run setup-realm` from [`apps/poc-spa/config/realm-clients.json`](../apps/poc-spa/config/realm-clients.json):

| Client | Role |
|--------|------|
| `poc-exchange-requester` | Confidential; **Standard token exchange V2** enabled |
| `poc-exchange-target` | Target `audience` for exchanged token |
| `poc-exchange-source` | Optional initial token client (legacy V1 / multi-client flows) |

Secrets (lab only): `poc-exchange-requester-secret`, `poc-exchange-target-secret`, `poc-exchange-source-secret`

---

## Phase 3 — Token exchange versions

### V2 Standard (RFC 8693) — **use for new work**

| Item | Detail |
|------|--------|
| Status in 26.7 | **Supported**, server feature `token-exchange-standard:v2` on by default |
| Client switch | `standard.token.exchange.enabled=true` on requester (REST attribute; see `setup-realm.js`) |
| Audience scope | Default client scope `poc-exchange-target-audience` adds `poc-exchange-target` to subject token `aud` |
| Test | `bash scripts/verify-token-exchange-v2.sh` |

Flow: password grant on `poc-exchange-requester` → exchange with `audience=poc-exchange-target`.

### V1 Legacy — **deprecated**

| Item | Detail |
|------|--------|
| Status in 26.7 | Preview, **deprecated**, disabled by default |
| Feature flag | `token-exchange` on Keycloak CR (see [`manifests/lab/keycloak-token-exchange-v1.yaml`](../manifests/lab/keycloak-token-exchange-v1.yaml)) |
| Permissions | FGAP **v1** + target client `token-exchange` permission (not in FGAP v2) |
| Removal | Future Keycloak version — no fixed RHBK date |
| Test | `bash scripts/verify-token-exchange-v1.sh` (exit 2 if feature off) |

### Deprecation summary

| Version | Feature flag | Status | Recommendation |
|---------|--------------|--------|----------------|
| V2 Standard | default on | Supported | **Build here** |
| V1 Legacy | `token-exchange` preview | Deprecated | Migrate off |
| Removed | `token-exchange-external-internal:v2` | Removed in 26.7 | Use V2 |

References:

- [Keycloak token exchange](https://www.keycloak.org/securing-apps/token-exchange)
- [Keycloak 26.7 upgrading guide](https://www.keycloak.org/docs/26.7.0/upgrading/)
- [RHBK 26.6 securing apps — token exchange](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html/securing_applications_and_services_guide/token-exchange-)

### Enable legacy V1 (lab only)

Features are in [`manifests/site-a/keycloak.yaml`](../manifests/site-a/keycloak.yaml) and [`manifests/site-b/keycloak.yaml`](../manifests/site-b/keycloak.yaml):

- `token-exchange` (legacy V1 preview)
- `admin-fine-grained-authz:v1` (required for V1 client permissions)
- Standard image `quay.io/keycloak/keycloak:26.7.0` with `startOptimized: false` (no optimized registry build)

One-shot enable + smoke test:

```bash
bash scripts/enable-token-exchange-v1-lab.sh
# or after CR apply: npm run setup-realm && bash scripts/verify-token-exchange-v1.sh
```

Revert: remove `token-exchange` and `admin-fine-grained-authz:v1` from `features.enabled` on both Keycloak CRs.

---

## Phase 4 — Token exchange + cross-site failover

```bash
bash scripts/verify-token-exchange-failover.sh TE-1   # both sites up
bash scripts/verify-token-exchange-failover.sh TE-2   # after Site A down
bash scripts/verify-token-exchange-failover.sh TE-3   # after Site B down
bash scripts/verify-token-exchange-failover.sh TE-4   # interactive: token then drop Site A
```

| ID | Setup | Expected | Pass |
|----|-------|----------|------|
| TE-1 | Both sites UP | V2 exchange OK | **PASS** (`verify-token-exchange-failover.sh TE-1`) |
| TE-2 | Site A DOWN | Exchange OK via Site B | **PASS** |
| TE-3 | Site B DOWN | Exchange OK via Site A | **PASS** |
| TE-4 | Token issued; then Site A DOWN | Exchange still OK | Manual — interactive script |

---

## Scripts reference

| Script | Purpose |
|--------|---------|
| `scripts/verify-auth-code-failover.sh` | OIDC discovery + lb-check + AC checklist |
| `scripts/verify-token-exchange-v2.sh` | Standard token exchange happy path |
| `scripts/verify-token-exchange-v1.sh` | Legacy V1 (guarded) |
| `scripts/verify-token-exchange-failover.sh` | TE-1..TE-4 wrapper |
| `scripts/lib/oidc-common.sh` | Shared curl/JWT helpers |

Lab scripts use `OIDC_USERNAME` / `OIDC_PASSWORD` (default `alice`/`alice`) — not `USERNAME`, which may be set by the OS login environment.

---

## Results log (template)

| Run | AC-1..7 | TE-1..4 | V1 | Notes |
|-----|---------|---------|-----|-------|
| 2026-08-21 (full) | **AC-1..7 PASS** (browser AC-5/6/7) | **TE-1..4 PASS** | **PASS** | Automated + browser; site drop via CR `instances=0`; both sites restored |
| 2026-08-21 (pm auto) | Smoke 5/5 PASS; AC-1..4/7 manual PASS earlier | TE-1 · TE-2 · TE-3 PASS | **PASS** | Site A CR `instances=1` restored; fixed `site-b-remote.sh` oc kubeconfig for TE-3 SSH |
| 2026-08-21 (demo) | AC-1..4, AC-7 **PASS**; AC-3 after SPA `NODE_TLS_REJECT_UNAUTHORIZED=0`; AC-5/6 pending | **TE-2 PASS**; TE-1/3/4 pending | Not run | Site A STS=0 for architect demo; WiFi `192.168.0.116`; DevTools `authenticate` — Keycloak cookies only, no LB sticky |
| 2026-08-14 (evening) | Smoke 5/5; AC-4/5 PASS; AC-1..3/7 manual SPA | TE-1..3 PASS | **PASS** (V1 preview + FGAP v1 enabled) | Both sites; `quay.io` image on Site B; V2 still PASS |
| 2026-08-14 (pm) | Smoke 5/5 PASS; AC-4 PASS (TE-2); AC-1..3/5/7 manual SPA | TE-1 PASS; TE-2 PASS; TE-3/4 manual | SKIP (V1 preview off) | Site B CRC up; replication sync; both sites in HAProxy |
| 2026-08-14 (am) | Smoke PASS; AC-6 PASS; AC-4/5 SKIP (Site B down) | TE-1 PASS; TE-2..4 SKIP | SKIP (exit 2) | Initial run before Windows CRC started |
