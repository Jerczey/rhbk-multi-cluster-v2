#!/bin/sh
set -eu
CONF=/var/lib/postgresql/data/postgresql.auto.conf
touch /var/lib/postgresql/data/standby.signal
# Keep pg_basebackup -R settings but force application_name for sync matching
cat > "$CONF" <<EOF
primary_conninfo = 'host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=${REPLICATION_USER} password=${REPLICATION_PASSWORD} application_name=${APP_NAME}'
primary_slot_name = '${SLOT_NAME}'
EOF
chown -R postgres:postgres /var/lib/postgresql/data
chmod 700 /var/lib/postgresql/data
ls -la /var/lib/postgresql/data/PG_VERSION /var/lib/postgresql/data/standby.signal
cat "$CONF"
