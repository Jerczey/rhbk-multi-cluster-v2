# Multi-cluster PoC SPA

Red Hat–branded SPA adapted from [`rhbk-quickstarts/js/spa`](https://github.com/redhat-developer/rhbk-quickstarts), pointed at the shared auth URL.

## Deploy on CRC (recommended — no host npm)

Serves static assets from an **nginx** pod via OpenShift Route. Requires `oc` logged into Site B CRC and namespace `rhbk-mc`.

```bash
# hosts: 192.168.0.114 auth.lan.local   (see docs/HOSTS.md)
./scripts/deploy-poc-spa.sh
# open https://poc-spa.apps-crc.testing
```

| User | Password | Roles |
|------|----------|--------|
| alice | alice | user |
| bob | bob | user |

### Keycloak client redirect URIs

Client `poc-spa` must allow:

- `https://auth.lan.local:8444/*` (LAN HTTPS SPA — preferred from Windows)
- `https://192.168.0.114:8444/*`
- `http://localhost:8080/*` for local Node on the same machine
- optionally `http://192.168.0.114:8080/*` (HTTP to IP lacks Web Crypto; prefer HTTPS)

If the realm was created earlier without these, add them in Keycloak Admin (Clients → poc-spa → Valid redirect URIs / Web origins), or re-run realm setup from a machine that has Node (below).

CRC must not be under **DiskPressure** or the pod stays Pending.

## Prerequisites

1. Hosts entry (see [`docs/HOSTS.md`](../../docs/HOSTS.md)):

   ```
   192.168.0.114  auth.lan.local
   ```

2. **Trust the lab certificate once:** open https://auth.lan.local:8443/lb-check in the browser and accept the warning (self-signed). Login redirects need this.

   From **Windows** (or any non-localhost browser), do **not** use `http://192.168.0.114:8080` — browsers block Web Crypto / PKCE on plain HTTP to an IP. Use instead:

   ```
   https://192.168.0.114:8444
   ```

   Accept the same lab cert if prompted. `http://localhost:8080` on the Linux host itself is fine.

3. HAProxy + both Keycloak sites using hostname `https://auth.lan.local:8443`.

4. Confirm issuer:

   ```bash
   curl -sk https://auth.lan.local:8443/realms/poc-realm/.well-known/openid-configuration | jq .issuer
   # https://auth.lan.local:8443/realms/poc-realm
   ```

**Check auth health** uses same-origin `/api/lb-check` (nginx or Express proxies to HAProxy with the lab cert). Do not call `https://auth.lan.local:8443/lb-check` from browser JS — TLS/CORS will fail.

## Optional: local Node (not required on Windows)

```bash
cd apps/poc-spa
npm install
npm run setup-realm   # ensures poc-spa client + alice/bob on poc-realm (needs Node once)
npm start             # http://localhost:8080
```

`public/vendor/keycloak.js` is vendored so the cluster path does not need `node_modules`. Local `npm start` serves the same `public/` tree and provides `/api/lb-check`.

## Recovery drills

### Proven: Site A down (2026-07-27)

Site A Keycloak was stopped on the Linux laptop. SPA login / session / token refresh continued to work through HAProxy → **Windows Site B**. Issuer remained `https://auth.lan.local:8443/realms/poc-realm`.

### Steps

1. Open https://poc-spa.apps-crc.testing (or http://localhost:8080) → **Log in** as `alice` or `bob`.
2. Confirm **Issuer** shows `https://auth.lan.local:8443/realms/poc-realm`.
3. Click **Check auth health** → expect Auth LB UP.
4. **Site A down** (Linux), for example:

   ```bash
   oc scale statefulset keycloak -n rhbk-mc --replicas=0
   # or: oc delete pod keycloak-0 -n rhbk-mc
   ```

   In the SPA click **Refresh token** → expect success via Site B.
5. Restore Site A (`--replicas=1` or wait for pod recreate).
6. **Site B down** (Windows): stop Keycloak there, then **Refresh token** again (Site A must be up).
7. **Re-login:** Log out → Log in again through the LB.

Success criteria: refresh works with either site down (the other up); issuer never changes; re-login works after logout.
