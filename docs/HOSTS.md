# Hosts entries for multi-site PoC

On Linux, Windows, and any browser client, add:

```
192.168.0.114  auth.lan.local
```

SPA and OIDC always use: **https://auth.lan.local:8443**

Optional (direct site debug, not required for the SPA):

```
127.0.0.1      keycloak-a.apps-crc.testing    # often already set by CRC on Linux
192.168.0.102  keycloak-b.apps-crc.testing    # only if an old route name is still in use
```

After changing Keycloak CRs to `hostname: https://auth.lan.local:8443`, OpenShift routes on both CRCs use host **`auth.lan.local`**. HAProxy health checks and backends use that SNI against each CRC’s `:443`.
