# Multi-cluster PoC SPA

Red Hat–branded SPA adapted from [`rhbk-quickstarts/js/spa`](https://github.com/redhat-developer/rhbk-quickstarts), pointed at the shared auth URL.

## Prerequisites

1. Hosts entry (see [`docs/HOSTS.md`](../../docs/HOSTS.md)):

   ```
   192.168.0.114  auth.lan.local
   ```

2. HAProxy + both Keycloak sites using hostname `https://auth.lan.local:8443`  
   (Site A applied on Linux; **Windows must apply** [`manifests/site-b/keycloak.yaml`](../../manifests/site-b/keycloak.yaml) and recreate its route.)

3. Confirm issuer:

   ```bash
   curl -sk https://auth.lan.local:8443/realms/poc-realm/.well-known/openid-configuration | jq .issuer
   # https://auth.lan.local:8443/realms/poc-realm
   ```

## Setup

```bash
cd apps/poc-spa
npm install
npm run setup-realm   # creates poc-spa client + alice/admin on poc-realm
npm start             # http://localhost:8080
```

| User | Password | Roles |
|------|----------|--------|
| alice | alice | user |
| admin | admin | user, admin |

## Recovery drills

1. Open http://localhost:8080 → **Log in** as `alice`.
2. Confirm **Issuer** shows `https://auth.lan.local:8443/realms/poc-realm`.
3. Click **Check auth health** → expect Auth LB UP.
4. **Site A down** (Linux):

   ```bash
   oc delete pod keycloak-0 -n rhbk-mc
   ```

   In the SPA click **Refresh token** → expect success while Site B serves the LB.
5. Wait for Site A pod Ready again.
6. **Site B down** (Windows CRC): scale/stop Keycloak on Windows, then **Refresh token** again.
7. **Re-login:** Log out → Log in again through the LB.

Success: refresh works with either site down (the other up); issuer never changes; re-login works after logout.
