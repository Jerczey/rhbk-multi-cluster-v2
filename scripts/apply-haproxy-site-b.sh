#!/usr/bin/env bash
# Run on Linux primary host (192.168.0.114) after Windows Site B is up.
# Retargets HAProxy site_b to Windows CRC and recreates kc-haproxy-lb.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_B_HOST="${SITE_B_HOST:-192.168.0.102}"
SITE_B_SNI="${SITE_B_SNI:-keycloak-b.apps-crc.testing}"
CFG="${ROOT}/lb/haproxy.cfg"

cp -a "${CFG}" "${CFG}.bak.$(date +%Y%m%d%H%M%S)"

SITE_B_LINE="  server site_b ${SITE_B_HOST}:443 ssl verify none sni str(${SITE_B_SNI}) check check-ssl check-sni ${SITE_B_SNI} inter 5s fall 3 rise 2"

python3 - "$CFG" "$SITE_B_LINE" <<'PY'
import sys
from pathlib import Path
cfg = Path(sys.argv[1])
site_b_line = sys.argv[2] + "\n"
text = cfg.read_text()
out = []
replaced = False
for line in text.splitlines(True):
    stripped = line.lstrip()
    if stripped.startswith("server site_b") or (
        stripped.startswith("#") and "server site_b" in stripped
    ):
        out.append(site_b_line)
        replaced = True
    else:
        out.append(line)
if not replaced:
    inserted = False
    new_out = []
    for line in out:
        new_out.append(line)
        if (not inserted) and line.lstrip().startswith("server site_a"):
            new_out.append(site_b_line)
            inserted = True
    out = new_out
cfg.write_text("".join(out))
print(cfg.read_text())
PY

bash "${ROOT}/lb/start-haproxy.sh"
echo "Verify: curl -sk https://127.0.0.1:8443/lb-check && curl -sk https://${SITE_B_HOST}:443/lb-check -H 'Host: ${SITE_B_SNI}'"
