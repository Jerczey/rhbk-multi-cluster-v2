# Multi-cluster PoC SPA

Red Hat–branded SPA adapted from [`rhbk-quickstarts/js/spa`](https://github.com/redhat-developer/rhbk-quickstarts), pointed at the shared auth URL.

## Prerequisites

1. Hosts entry (see [`docs/HOSTS.md`](../../docs/HOSTS.md)):

   ```
   192.168.0.114  auth.lan.local
   ```

2. **Trust the lab certificate once:** open https://auth.lan.local:8443/lb-check in the browser and accept the warning (self-signed). Login redirects need this.

3. HAProxy + both Keycloak sites using hostname `https://auth.lan.local:8443`.

4. Confirm issuer:

   ```bash
   curl -sk https://auth.lan.local:8443/realms/poc-realm/.well-known/openid-configuration | jq .issuer
   # https://auth.lan.local:8443/realms/poc-realm
   ```

**Check auth health** uses same-origin `/api/lb-check` (Express proxies to HAProxy with the lab cert). Do not call `https://auth.lan.local:8443/lb-check` from browser JS — TLS/CORS will fail.

## Setup

```bash
cd apps/poc-spa
npm install
npm run setup-realm   # ensures poc-spa client + alice/bob on poc-realm
npm start             # http://localhost:8080
```

| User | Password | Roles |
|------|----------|--------|
| alice | alice | user |
| bob | bob | user |

## Recovery drills

### Proven: Site A down (2026-07-27)

Site A Keycloak was stopped on the Linux laptop. SPA login / session / token refresh continued to work through HAProxy → **Windows Site B**. Issuer remained `https://auth.lan.local:8443/realms/poc-realm`.

### Steps

1. Open http://localhost:8080 → **Log in** as `alice` or `bob`.
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
