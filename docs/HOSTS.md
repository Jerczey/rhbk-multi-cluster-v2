# Hosts entries for multi-site PoC
#
# On Linux, Windows, and any client browser machine, add:
#
#   192.168.0.114  auth.lan.local
#   127.0.0.1      keycloak-a.apps-crc.testing   # Linux CRC local (crc already manages this on Linux)
#   192.168.0.102  keycloak-b.apps-crc.testing   # LAN clients hitting Windows Site B directly
#
# SPA and OIDC always use: https://auth.lan.local:8443
