# Hosts entries for multi-site PoC

## Changed network (home ↔ office)

When the Linux laptop gets a new LAN IP, Keycloak JDBC URLs still point at the old address until you reconcile:

```bash
bash scripts/reconcile-lab-primary-host.sh
```

Then update `/etc/hosts` below (and Windows hosts + Site B JDBC manually). The Postgres Podman container does not need a new IP — it stays on host `:5432`.

**Two IPs matter:**

| Variable | Typical value | Used for |
|----------|---------------|----------|
| `PRIMARY_HOST` | Office/home WiFi LAN IP | `/etc/hosts`, TLS SAN, **Site B JDBC** (Windows → Linux Postgres) |
| `CRC_DB_HOST` | `192.168.122.1` (virbr0) | **Site A Keycloak JDBC** (CRC pods → host Postgres) |

Do not put the office WiFi IP in Site A JDBC — CRC pods reach the host via the libvirt bridge.

---

On Linux, Windows, and any browser client, add:

```
192.168.0.114  auth.lan.local
```

| Service | URL |
|---------|-----|
| OIDC / HAProxy | **https://auth.lan.local:8443** |
| PoC SPA (Linux Node HTTPS) | **https://auth.lan.local:8444** |

Optional (direct site debug, not required for the SPA):

```
127.0.0.1      keycloak-a.apps-crc.testing    # often already set by CRC on Linux
192.168.0.102  keycloak-b.apps-crc.testing    # only if an old route name is still in use
```

After changing Keycloak CRs to `hostname: https://auth.lan.local:8443`, OpenShift routes on both CRCs use host **`auth.lan.local`**. HAProxy health checks and backends use that SNI against each CRC’s `:443`.
