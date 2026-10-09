#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT
#
# The order in this script is relevant, as it will make changes, run
# `systemctl daemon-reload`, start things, make other changes, reload the
# daemon again etc...
# This is intentional, because if all changes were made at once, some services
# or scripts would fail because their dependencies are not yet there at the time
# of execution.


set -euo pipefail

# sanity checks
## must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (or with sudo)." >&2
    exit 1
fi

## check if OpenCHAMI is installed
if [ ! -d /etc/openchami ]; then
    echo "ERROR: Could not find existing OpenCHAMI installation." >&2
    exit 1
fi

## check if OpenBao is set up
if [ ! -d /etc/openchami/openbao ]; then
    echo "ERROR: OpenBao does not appear to be set up. Please run openbao-setup.sh first, see https://github.com/darkmatterdawn/OpenCHAMI-openbao-integration" >&2
    exit 1
fi

## check if PCS is already set up
if [ -f /etc/containers/systemd/pcs.container ]; then
    echo "ERROR: PCS appears to be set up already. Cowardly refusing to continue, since this may break the existing installation." >&2
    exit 1
fi


# get user's confirmation to continue
FORCE=false

while getopts ":f" opt; do
  case $opt in
    f)
      FORCE=true
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

if [ "$FORCE" != true ]; then
    read -n 1 -p "WARNING: Running this script will change your existing OpenCHAMI setup. If this script fails for some reason, your OpenCHAMI setup most likely will not work anymore. Having an up-to-date backup is strongly recommended. Are you sure you want to continue? (y/N): " confirm
    echo

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "Running pcs-setup. This will take a moment..."

# preparations
BACKUP_FILENAME_EXTENSION="pcs.bak.$(date +%Y%m%d%H%M)"
PCS_IMAGE="ghcr.io/openchami/pcs:v2.12.2"
HYDRA_ADMIN_URL="http://hydra:4445"

## TEMPORARY FIX: pull OCI image before coredns is down
podman pull $PCS_IMAGE

mkdir -p /etc/openchami/pcs


# -----------------------------------------------------------------------------
# Postgres bootstrap: add PCS DB/user secret to bootstrap_openchami.sh
# -----------------------------------------------------------------------------
if [ ! -f /usr/libexec/openchami/bootstrap_openchami.sh ]; then
    echo "ERROR: /usr/libexec/openchami/bootstrap_openchami.sh not found." >&2
    exit 1
fi

cp /usr/libexec/openchami/bootstrap_openchami.sh /usr/libexec/openchami/bootstrap_openchami.sh.$BACKUP_FILENAME_EXTENSION

## add PCS postgres password generation to the fitting section of the script
LINENUM=$(grep -n 'if_not_exists "hydra_dsn' /usr/libexec/openchami/bootstrap_openchami.sh | cut -d ':' -f1 || true)
if [ -z "$LINENUM" ]; then
    echo "ERROR: Could not find hydra_dsn block in /usr/libexec/openchami/bootstrap_openchami.sh." >&2
    exit 1
fi

sed -i "${LINENUM}"'a\
\
# PCS Postgres Password\
pcs_postgres_password=$(generate_random_password)\
create_secret_if_not_exists "pcs_postgres_password" "$pcs_postgres_password"' /usr/libexec/openchami/bootstrap_openchami.sh

## extend POSTGRES_MULTIPLE_DATABASES to include pcsdb
LINENUM=$(grep -n '^POSTGRES_MULTIPLE_DATABASES' /usr/libexec/openchami/bootstrap_openchami.sh | cut -d ':' -f1 || true)
if [ -z "$LINENUM" ]; then
    echo "ERROR: Could not find POSTGRES_MULTIPLE_DATABASES in /usr/libexec/openchami/bootstrap_openchami.sh." >&2
    exit 1
fi

awk -v ln="$LINENUM" '
NR==ln {
  sub(/"$/, ",pcsdb:pcs-user:$(podman secret inspect pcs_postgres_password --showsecret | jq -r '\''.[0].SecretData'\'')\"")
}
{ print }
' /usr/libexec/openchami/bootstrap_openchami.sh > /tmp/tmp_bootstrap_openchami.sh
mv /tmp/tmp_bootstrap_openchami.sh /usr/libexec/openchami/bootstrap_openchami.sh

chmod +x /usr/libexec/openchami/bootstrap_openchami.sh

## delete the old multiple_databases secret so the bootstrap re-creates it with pcsdb
podman secret rm postgres_multiple_databases 2>/dev/null || true

## run the bootstrap to create/update secrets
/usr/libexec/openchami/bootstrap_openchami.sh

unset LINENUM


# -----------------------------------------------------------------------------
# HAProxy: expose PCS under /pcs
# -----------------------------------------------------------------------------
if [ ! -f /etc/openchami/configs/haproxy.cfg ]; then
    echo "ERROR: /etc/openchami/configs/haproxy.cfg not found." >&2
    exit 1
fi

cp /etc/openchami/configs/haproxy.cfg /etc/openchami/configs/haproxy.cfg.$BACKUP_FILENAME_EXTENSION

## add PATH_pcs acl in the correct section of the file
LINENUM=$(grep -n 'acl PATH_smd' /etc/openchami/configs/haproxy.cfg | cut -d ':' -f1 || true)
if [ -n "$LINENUM" ]; then
    sed -i "${LINENUM}"'a\
  acl PATH_pcs path_beg -i /pcs' /etc/openchami/configs/haproxy.cfg
fi

## add use_backend in the correct section of the file
LINENUM=$(grep -n 'use_backend smd' /etc/openchami/configs/haproxy.cfg | cut -d ':' -f1 || true)
if [ -n "$LINENUM" ]; then
    sed -i "${LINENUM}"'a\
  use_backend pcs if PATH_pcs' /etc/openchami/configs/haproxy.cfg
fi

## add backend pcs in the correct section of the file
LINENUM=$(grep -n 'server smd' /etc/openchami/configs/haproxy.cfg | cut -d ':' -f1 || true)
if [ -n "$LINENUM" ]; then
    ## Use head/cat/tail instead of sed's append command: sed interprets \1 in
    ## the appended text, so it would write the literal /1 instead of /\1.
    head -n "$LINENUM" /etc/openchami/configs/haproxy.cfg > /tmp/haproxy.cfg.pcs.new
    cat >> /tmp/haproxy.cfg.pcs.new <<'EOF'

backend pcs
  server pcs pcs:28007
  http-request replace-path ^/pcs/(.*) /\1
EOF
    tail -n +$((LINENUM + 1)) /etc/openchami/configs/haproxy.cfg >> /tmp/haproxy.cfg.pcs.new
    mv /tmp/haproxy.cfg.pcs.new /etc/openchami/configs/haproxy.cfg
fi

unset LINENUM


# -----------------------------------------------------------------------------
# OpenBao: policy, placeholders and token renewal for PCS
# -----------------------------------------------------------------------------

## hms-securestorage expects Kubernetes-style role/JWT files even with token auth.
echo "openchami" > /etc/openchami/pcs/cray-vault-role
echo "token-auth-placeholder" > /etc/openchami/pcs/cray-vault-jwt
chmod 644 /etc/openchami/pcs/cray-vault-role /etc/openchami/pcs/cray-vault-jwt

## write PCS OpenBao policy (read-only on credentials, can create tokens)
## Place it under /etc/openchami/openbao so the OpenBao container can read it,
## mirroring the SMD policy layout.
tee /etc/openchami/openbao/openbao-pcs-creds-policy.hcl > /dev/null << 'EOF'
path "secret/hms-creds/*" {
  capabilities = ["read", "list"]
}

path "auth/token/create" {
  capabilities = ["create", "update"]
}
EOF

## write PCS token renewal script under /etc/openchami/openbao, alongside the policy
tee /etc/openchami/openbao/openbao-pcs-token-renewal.sh > /dev/null << 'EOF'
#!/bin/bash
# Idempotent PCS OpenBao token creation/renewal.
# Creates or recreates the 'pcs_openbao_token' Podman secret when the existing
# token is missing or within 7 days of expiry, then restarts pcs.service.
set -euo pipefail

TOKEN_NAME="pcs_openbao_token"
MIN_TTL=604800  # 7 days

# --- Prerequisites ---
if ! podman secret inspect openbao_root_token &>/dev/null; then
    echo "[token-renewal] ERROR: openbao_root_token secret not found." >&2
    exit 1
fi

if ! systemctl is-active --quiet openbao.service; then
    echo "[token-renewal] ERROR: openbao.service is not running." >&2
    exit 1
fi

# --- Wait for the OpenBao container to be reachable via podman exec ---
max_attempts=5
attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
    if podman exec openbao true >/dev/null 2>&1; then
        break
    fi
    sleep 2
    attempt=$((attempt + 1))
done

if [ "$attempt" -gt "$max_attempts" ]; then
    echo "[token-renewal] ERROR: OpenBao container is not accessible via podman exec after ${max_attempts} attempts." >&2
    exit 1
fi

# --- Wait for OpenBao to become unsealed ---
max_unseal_attempts=30
unseal_attempt=1
while [ "$unseal_attempt" -le "$max_unseal_attempts" ]; do
    if podman exec -e BAO_SKIP_VERIFY=true openbao bao status >/dev/null 2>&1; then
        break
    fi
    # OpenBao is still sealed, retrying in 1s
    sleep 1
    unseal_attempt=$((unseal_attempt + 1))
done

if [ "$unseal_attempt" -gt "$max_unseal_attempts" ]; then
    echo "[token-renewal] ERROR: OpenBao did not become unsealed after ${max_unseal_attempts} attempts." >&2
    exit 1
fi

root_token=$(podman secret inspect openbao_root_token --showsecret | jq -r '.[0].SecretData')

bao_exec_root() {
    podman exec -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="$root_token" openbao "$@"
}

# --- Check existing token ---
if podman secret inspect "$TOKEN_NAME" &>/dev/null; then
    existing_token=$(podman secret inspect "$TOKEN_NAME" --showsecret | jq -r '.[0].SecretData')

    if ttl=$(podman exec -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="$existing_token" openbao bao token lookup -format=json 2>/dev/null | jq -r '.data.ttl // 0'); then
        if [[ "$ttl" =~ ^[0-9]+$ ]] && [ "$ttl" -gt "$MIN_TTL" ]; then
            exit 0
        fi
    fi
fi

# --- Ensure PCS policy exists ---
bao_exec_root bao policy write pcs-creds /etc/openchami/openbao/openbao-pcs-creds-policy.hcl

# --- Create new PCS token ---
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

bao_exec_root bao token create -policy=pcs-creds -display-name=pcs -ttl=768h -format=json > "${tmpdir}/pcs-token.json"

pcs_token=$(jq -r '.auth.client_token' "${tmpdir}/pcs-token.json")

# --- Update secret ---
if podman secret inspect "$TOKEN_NAME" &>/dev/null; then
    podman secret rm "$TOKEN_NAME"
fi

printf '%s' "$pcs_token" | podman secret create "$TOKEN_NAME" -

# --- Restart PCS so it picks up the new secret ---
systemctl try-restart pcs.service
EOF

chmod +x /etc/openchami/openbao/openbao-pcs-token-renewal.sh

## write systemd service/timer for PCS token renewal
tee /etc/systemd/system/openbao-pcs-token-renewal.service > /dev/null << 'EOF'
[Unit]
Description=Renew PCS OpenBao token
PartOf=openchami.target
StartLimitIntervalSec=60
StartLimitBurst=3
Requires=openbao.service
After=openbao.service

[Service]
Type=oneshot
ExecStart=/etc/openchami/openbao/openbao-pcs-token-renewal.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
EOF

tee /etc/systemd/system/openbao-pcs-token-renewal.timer > /dev/null << 'EOF'
[Unit]
Description=Renew PCS OpenBao token daily

[Timer]
OnBootSec=5m
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF


# -----------------------------------------------------------------------------
# OpenBao container: mount whole /etc/openchami/openbao directory
# -----------------------------------------------------------------------------
## The default openbao.container mounts individual files from this directory.
## PCS needs the whole directory mounted so the policy HCL and token-renewal
## script placed there are visible inside the container, matching the SMD layout.
if [ -f /etc/containers/systemd/openbao.container ]; then
    cp /etc/containers/systemd/openbao.container /etc/containers/systemd/openbao.container.$BACKUP_FILENAME_EXTENSION

    ## remove per-file mounts under /etc/openchami/openbao/
    sed -i '/^Volume=\/etc\/openchami\/openbao\//d' /etc/containers/systemd/openbao.container

    ## add a single directory mount if not already present
    if ! grep -q '^Volume=/etc/openchami/openbao:/etc/openchami/openbao' /etc/containers/systemd/openbao.container; then
        LINENUM=$(grep -n '^Volume=openbao-certs' /etc/containers/systemd/openbao.container | cut -d ':' -f1 || true)
        if [ -n "$LINENUM" ]; then
            sed -i "${LINENUM}"'a\
Volume=/etc/openchami/openbao:/etc/openchami/openbao:ro,Z' /etc/containers/systemd/openbao.container
        fi
    fi

    ## Remember that openbao's container definition changed so we recreate it
    ## after daemon-reload. Otherwise a running openbao keeps the old per-file
    ## mounts and the newly-added PCS policy/script files are invisible inside.
    OPENBAO_CONTAINER_CHANGED=true
fi
unset LINENUM


# -----------------------------------------------------------------------------
# PCS quadlet containers (pcs-init and pcs)
# -----------------------------------------------------------------------------
tee /etc/containers/systemd/pcs-init.container > /dev/null << EOF
[Unit]
Description=OpenCHAMI pcs-init
PartOf=openchami.target
Requires=postgres.service
After=postgres.service

[Container]
ContainerName=pcs-init
HostName=pcs-init
Image=${PCS_IMAGE}

Environment=STORAGE=POSTGRES
Environment=POSTGRES_HOST=postgres
Environment=POSTGRES_PORT=5432
Environment=POSTGRES_DBNAME=pcsdb
Environment=POSTGRES_USER=pcs-user
Environment=POSTGRES_INSECURE=true

Secret=pcs_postgres_password,type=env,target=POSTGRES_PASSWORD

Network=openchami-internal.network

PodmanArgs=--http-proxy=false

Exec=power-control init-postgres

[Service]
Restart=on-failure
Type=oneshot
RemainAfterExit=yes
EOF

tee /etc/containers/systemd/pcs.container > /dev/null << EOF
[Unit]
Description=OpenCHAMI pcs
PartOf=openchami.target

Requires=pcs-init.service
After=pcs-init.service

Wants=smd.service
After=smd.service

Wants=hydra-gen-jwks.service
After=hydra-gen-jwks.service

# Do not start until OpenBao is ready:
Wants=openbao.service openbao-pcs-token-renewal.service
After=openbao.service openbao-pcs-token-renewal.service

[Container]
ContainerName=pcs
HostName=pcs
Image=${PCS_IMAGE}

EnvironmentFile=/etc/openchami/configs/openchami.env

Environment=STORAGE=POSTGRES
Environment=POSTGRES_HOST=postgres
Environment=POSTGRES_PORT=5432
Environment=POSTGRES_DBNAME=pcsdb
Environment=POSTGRES_USER=pcs-user
Environment=POSTGRES_INSECURE=true

# Real OpenBao vault (not fake vault)
Environment=VAULT_ENABLED=true
Environment=VAULT_KEYPATH=secret/hms-creds
Environment=VAULT_ADDR=https://openbao:8200
Environment=VAULT_CACERT=/etc/openchami/certs/openbao/ca.crt

# hms-securestorage Kubernetes-style auth placeholders
Environment=CRAY_VAULT_ROLE_FILE=/etc/openchami/pcs/cray-vault-role
Environment=CRAY_VAULT_JWT_FILE=/etc/openchami/pcs/cray-vault-jwt
Environment=CRAY_VAULT_AUTH_PATH=auth/token/create

Environment=OAUTH2_CLIENT_ID=pcs
Environment=OAUTH2_TOKEN_URL=http://hydra:4444/oauth2/token
Environment=OAUTH2_SCOPES=smd.read,smd.write

Environment=LOG_LEVEL=INFO

Environment=SMS_SERVER=http://smd:27779
Environment=PCS_JWKS_URL=http://opaal:3333/keys

Secret=pcs_postgres_password,type=env,target=POSTGRES_PASSWORD
Secret=pcs_oauth2_secret,type=env,target=OAUTH2_CLIENT_SECRET
Secret=pcs_openbao_token,type=env,target=VAULT_TOKEN

# Volumes for configs and OpenBao auth files/certs
Volume=/etc/openchami/configs/:/etc/openchami/configs:Z
Volume=/etc/openchami/pcs/cray-vault-role:/etc/openchami/pcs/cray-vault-role:ro,Z
Volume=/etc/openchami/pcs/cray-vault-jwt:/etc/openchami/pcs/cray-vault-jwt:ro,Z
Volume=openbao-certs:/etc/openchami/certs/openbao:ro,Z

Network=openchami-internal.network
Network=openchami-jwt-internal.network
Network=openchami-external.network

PodmanArgs=--http-proxy=false

Exec=power-control

[Service]
Restart=always
RestartSec=5
EOF


# -----------------------------------------------------------------------------
# SMD container: add external network so SMD can reach BMCs for discovery
# -----------------------------------------------------------------------------
cp /etc/containers/systemd/smd.container /etc/containers/systemd/smd.container.$BACKUP_FILENAME_EXTENSION

if ! grep -q 'Network=openchami-external.network' /etc/containers/systemd/smd.container; then
    LINENUM=$(grep -n '^Network=' /etc/containers/systemd/smd.container | tail -n1 | cut -d ':' -f1 || true)
    if [ -n "$LINENUM" ]; then
        sed -i "${LINENUM}"'a\
Network=openchami-external.network' /etc/containers/systemd/smd.container
    fi
fi
unset LINENUM


## fixed in a656abb https://github.com/OpenCHAMI/power-control/commit/a656abb075898035ec56f5e4b577715fdff48507
# -----------------------------------------------------------------------------
# openchami.env: disable SMD JWKS auth (PCS currently omits bearer token on
# reservation lock requests)
# -----------------------------------------------------------------------------
#cp /etc/openchami/configs/openchami.env /etc/openchami/configs/openchami.env.$BACKUP_FILENAME_EXTENSION

#sed -i '/SMD_JWK/ s/^/#/' /etc/openchami/configs/openchami.env


# -----------------------------------------------------------------------------
# ochami config.yaml: register /pcs path
# -----------------------------------------------------------------------------
cp /etc/ochami/config.yaml /etc/ochami/config.yaml.$BACKUP_FILENAME_EXTENSION

## NOTE: this assumes 'enable-auth' appears in config.yaml. Adjust manually if
## the layout differs.
if grep -q 'enable-auth' /etc/ochami/config.yaml; then
    sed -i '/enable-auth/ a\
        pcs:\
          uri: /pcs' /etc/ochami/config.yaml
else
    echo "WARNING: 'enable-auth' not found in /etc/ochami/config.yaml; please add the pcs: /pcs mapping manually." >&2
fi


# -----------------------------------------------------------------------------
# Apply changes and bring up services
# -----------------------------------------------------------------------------
systemctl daemon-reload

## Need to restart openbao.container to enable changed volume mounts before
## running futher commands. Using '--ignore-dependencies' because otherwise,
## openbao-init would also restart and trigger other things down the line...
if [ "${OPENBAO_CONTAINER_CHANGED:-false}" = true ]; then
    systemctl restart --ignore-dependencies openbao.service
fi

## start the core OpenCHAMI stack (postgres, openbao, smd, haproxy, hydra, ...)
systemctl start openchami.target

## wait for postgres to accept connections
max_pg_attempts=60
pg_attempt=1
while [ "$pg_attempt" -le "$max_pg_attempts" ]; do
    if podman exec postgres pg_isready -U "$(awk -F= '/^POSTGRES_USER=/{print $2}' /etc/openchami/configs/openchami.env)" >/dev/null 2>&1; then
        # postgres is ready
        break
    fi
    sleep 2
    pg_attempt=$((pg_attempt + 1))
done

if [ "$pg_attempt" -gt "$max_pg_attempts" ]; then
    echo "ERROR: postgres did not become ready after ${max_pg_attempts} attempts." >&2
    exit 1
fi
unset pg_attempt max_pg_attempts

## create PCS database and user
PCS_DB='pcsdb'
PCS_USER='pcs-user'
PCS_PASS="$(podman secret inspect pcs_postgres_password --showsecret | jq -r '.[0].SecretData')"
PG_SUPERUSER="$(awk -F= '/^POSTGRES_USER=/{print $2}' /etc/openchami/configs/openchami.env)"
PG_SUPERPASS="$(podman secret inspect postgres_password --showsecret | jq -r '.[0].SecretData')"

podman exec -e PGPASSWORD="$PG_SUPERPASS" -i postgres \
  psql -U "$PG_SUPERUSER" -d postgres <<SQL
CREATE USER "$PCS_USER" WITH PASSWORD '$PCS_PASS';
CREATE DATABASE $PCS_DB OWNER "$PCS_USER";
GRANT ALL PRIVILEGES ON DATABASE $PCS_DB TO "$PCS_USER";
SQL

podman exec -e PGPASSWORD="$PG_SUPERPASS" -i postgres \
  psql -U "$PG_SUPERUSER" -d "$PCS_DB" <<SQL
ALTER SCHEMA public OWNER TO "$PCS_USER";
GRANT ALL ON SCHEMA public TO "$PCS_USER";
SQL

unset PCS_DB PCS_USER PCS_PASS PG_SUPERUSER PG_SUPERPASS


# -----------------------------------------------------------------------------
# Hydra: create PCS OAuth2 client
# -----------------------------------------------------------------------------
max_hydra_attempts=60
hydra_attempt=1
while [ "$hydra_attempt" -le "$max_hydra_attempts" ]; do
    if podman run --rm --network openchami-jwt-internal docker.io/alpine/curl \
        -sf "${HYDRA_ADMIN_URL}/health/ready" >/dev/null 2>&1; then
        # Hydra admin API is ready
        break
    fi
    sleep 2
    hydra_attempt=$((hydra_attempt + 1))
done

if [ "$hydra_attempt" -gt "$max_hydra_attempts" ]; then
    echo "ERROR: Hydra admin API did not become ready after ${max_hydra_attempts} attempts." >&2
    exit 1
fi
unset hydra_attempt max_hydra_attempts

# The combination piped tr, fold and head for some reason returns the exit
# code 141, which would trigger the 'set -e' to kill the script. Therefore,
# the '|| true' at the end.
PCS_HYDRA_PW=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1) || true

# since the 'true' thing will never make the above command fail, check here:
if [ -z "${PCS_HYDRA_PW:-}" ]; then
    echo "ERROR: Failed to generate PCS Hydra client secret." >&2
    exit 1
fi

podman run --rm --network openchami-jwt-internal docker.io/alpine/curl \
    -s -X POST "${HYDRA_ADMIN_URL}/admin/clients" \
    -H "Content-Type: application/json" \
    -d "{
      \"client_id\": \"pcs\",
      \"client_secret\": \"${PCS_HYDRA_PW}\",
      \"grant_types\": [\"client_credentials\"],
      \"token_endpoint_auth_method\": \"client_secret_basic\",
      \"scope\": \"smd.read smd.write\"
    }"

printf '%s' "$PCS_HYDRA_PW" | podman secret create pcs_oauth2_secret -

unset PCS_HYDRA_PW


# -----------------------------------------------------------------------------
# Initialize PCS postgres schema and create first OpenBao token
# -----------------------------------------------------------------------------
systemctl start openbao-pcs-token-renewal.service
systemctl enable --quiet --now openbao-pcs-token-renewal.timer

systemctl start pcs-init.service


# -----------------------------------------------------------------------------
# Add PCS to haproxy and openchami.target, then start it
# -----------------------------------------------------------------------------
cp /etc/containers/systemd/haproxy.container /etc/containers/systemd/haproxy.container.$BACKUP_FILENAME_EXTENSION

sed -i '/Wants=/ s/$/ pcs.service/' /etc/containers/systemd/haproxy.container
sed -i '/After=/ s/$/ pcs.service/' /etc/containers/systemd/haproxy.container

cp /etc/systemd/system/openchami.target /etc/systemd/system/openchami.target.$BACKUP_FILENAME_EXTENSION

sed -i '/^Wants=/ s/$/ pcs.service/' /etc/systemd/system/openchami.target
sed -i '/^After=/ s/$/ pcs.service/' /etc/systemd/system/openchami.target

systemctl daemon-reload
systemctl start openchami.target

## make sure haproxy has loaded the new /pcs backend
systemctl try-restart haproxy.service


# -----------------------------------------------------------------------------
# Final verification
# -----------------------------------------------------------------------------
# Wait up to 2 minutes for pcs.service to be up and healthy before checking the
# rest of openchami.target. pcs.service may still be activating when we get here.
max_pcs_attempts=24
pcs_attempt=1
while [ "$pcs_attempt" -le "$max_pcs_attempts" ]; do
    if systemctl is-active --quiet pcs.service; then
        # pcs.service is active and healthy
        break
    fi
    # pcs.service is still activating, retrying in 5s
    sleep 5
    pcs_attempt=$((pcs_attempt + 1))
done

if [ "$pcs_attempt" -gt "$max_pcs_attempts" ]; then
    echo "ERROR: pcs.service did not become active within 2 minutes. Check 'systemctl status pcs.service' and 'podman logs pcs'." >&2
    exit 1
fi
unset pcs_attempt max_pcs_attempts


if ! systemctl is-active --quiet haproxy.service; then
    echo "ERROR: haproxy.service is not active after restart. Check 'systemctl status haproxy.service'." >&2
    exit 1
fi

