# Multi-cluster PoC SPA

Red Hat–branded SPA adapted from [`rhbk-quickstarts/js/spa`](https://github.com/redhat-developer/rhbk-quickstarts), pointed at the shared auth URL.

Runs as **Node on the Linux Site A host**. Windows browsers open the Linux HTTPS URL over the LAN (no SPA deploy on Windows CRC).

## Start on Linux

```bash
# hosts (Linux + Windows clients): 192.168.0.114 auth.lan.local
cd apps/poc-spa
npm install
npm run setup-realm   # ensures poc-spa client + alice/bob on poc-realm
npm start
```

| URL | Who |
|-----|-----|
| http://localhost:8080 | Linux host only |
| **https://auth.lan.local:8444** | Windows / any LAN browser (preferred) |
| https://192.168.0.114:8444 | Same SPA via IP (also allowed) |

| User | Password | Roles |
|------|----------|--------|
| alice | alice | user |
| bob | bob | user |

`npm start` serves HTTP on `:8080` and HTTPS on `:8444` using `secrets/tls.crt` / `secrets/tls.key` (lab cert). Open firewall `8444/tcp` on Linux for Windows access.

### Keycloak client redirect URIs

Client `poc-spa` must allow:

- `https://auth.lan.local:8444/*` (preferred from Windows)
- `https://192.168.0.114:8444/*`
- `http://localhost:8080/*` for local Node on the Linux machine
- optionally `http://192.168.0.114:8080/*` (HTTP to a LAN IP lacks Web Crypto; prefer HTTPS)

If the realm was created earlier without these, add them in Keycloak Admin (Clients → poc-spa → Valid redirect URIs / Web origins), or re-run `npm run setup-realm`.

## Prerequisites

1. Hosts entry (see [`docs/HOSTS.md`](../../docs/HOSTS.md)):

   ```
   192.168.0.114  auth.lan.local
   ```

2. **Trust the lab certificate once:** open https://auth.lan.local:8443/lb-check in the browser and accept the warning (self-signed). Also accept the cert for https://auth.lan.local:8444 if prompted.

3. Do **not** use `http://192.168.0.114:8080` from Windows — browsers block Web Crypto / PKCE on plain HTTP to an IP. Use **https://auth.lan.local:8444**.

4. HAProxy + Keycloak sites using hostname `https://auth.lan.local:8443`.

5. Confirm issuer:

   ```bash
   curl -sk https://auth.lan.local:8443/realms/poc-realm/.well-known/openid-configuration | jq .issuer
   # https://auth.lan.local:8443/realms/poc-realm
   ```

**Check auth health** uses same-origin `/api/lb-check` (Express proxies to HAProxy with the lab cert). Do not call `https://auth.lan.local:8443/lb-check` from browser JS — TLS/CORS will fail.

`public/vendor/keycloak.js` is vendored so the static tree does not require `node_modules` in the browser path.

## Recovery drills

### Proven: Site A down (2026-07-27 / 2026-07-29)

Site A Keycloak was stopped (and later full `crc stop` with Podman Postgres + HAProxy still up). SPA login / session / token refresh continued through HAProxy → **Windows Site B**. Issuer remained `https://auth.lan.local:8443/realms/poc-realm`.

### Steps

1. Open https://auth.lan.local:8444 (or http://localhost:8080 on Linux) → **Log in** as `alice` or `bob`.
2. Confirm **Issuer** shows `https://auth.lan.local:8443/realms/poc-realm`.
3. Click **Check auth health** → expect Auth LB UP.
4. **Site A down** (Linux), for example:

   ```bash
   oc scale statefulset keycloak -n rhbk-mc --replicas=0
   # or platform failure: crc stop  (leave pg-primary-site-a + kc-haproxy-lb running)
   ```

   In the SPA click **Refresh token** → expect success via Site B.
5. Restore Site A (`crc start` / `--replicas=1` or wait for pod recreate).
6. **Site B down** (Windows): stop Keycloak there, then **Refresh token** again (Site A must be up).
7. **Re-login:** Log out → Log in again through the LB.

Success criteria: refresh works with either site down (the other up); issuer never changes; re-login works after logout.
