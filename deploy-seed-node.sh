#!/usr/bin/env bash
#
# deploy-seed-node.sh - bring up a Pirate Chain seed node on a blank Ubuntu
# 22.04/24.04 VPS: pirated (via bitcore-node-pirate) + lightwalletd, both
# supervised by pm2.
#
# Usage:
#   sudo ./deploy-seed-node.sh
#
# Re-running is safe: existing clones are updated in place instead of
# re-cloned, and existing config/credentials are left untouched.
#
# Layout (all under INSTALL_DIR, owned by the invoking user - no sudo needed
# to run, update, or restart anything after this script finishes):
#   build/         TreasureChest and lightwalletd source checkouts + compiled
#                  artifacts. Pull + rebuild here to update.
#   bin/           stable symlinks (pirated, pirate-cli, lightwalletd) that
#                  config files and pm2 point at, so updating build/ doesn't
#                  require touching config.
#   bitcore-node/  the `bitcore-node create` scaffold: bitcore-node.json,
#                  package.json, and node_modules (bitcore-node-pirate,
#                  bitcore-lib-pirate, insight-api-pirate, insight-ui-pirate,
#                  all pulled via git with `bitcore-node install`).
#   data/          PIRATE.conf, chain data, lightwalletd cache - the only
#                  directory that needs to persist/be backed up.
#
# bitcore-node-pirate itself is installed globally via npm from git (not
# cloned/built), matching how its own CLI is meant to be used: `npm install
# -g` gets you the `bitcore-node` command, then `bitcore-node create` scaffolds
# the actual instance directory.
#
# Overridable via environment variables:
#   INSTALL_DIR      Base directory for everything this script builds (default: ~<user>/pirateseednode)
#   NODE_VERSION     Node.js version installed via nvm (default: 24.19.0)
#   PIRATE_BRANCH    Branch for TreasureChest and the bitcore-node-pirate/bitcore-lib-pirate/insight-api-pirate/insight-ui-pirate npm installs (default: dev-ironwood)
#   LWD_BRANCH       Branch to check out for lightwalletd (default: dev)
#   MAKE_JOBS        Parallelism for TreasureChest's build (default: nproc)
#   NETWORK          livenet | testnet (default: livenet)
#   RPC_PORT         pirated RPC port (default: 45453)
#   ZMQ_PORT         pirated zmqpub port, shared by rawtx/hashblock (default: 28332)
#   BITCORE_PORT     bitcore-node web API port (default: 3001)
#   LWD_GRPC_BIND    lightwalletd gRPC bind address (default: 0.0.0.0:9067)
#   LWD_HTTP_BIND    lightwalletd HTTP bind address (default: 0.0.0.0:9068)
#   DOMAIN_NAME      Hostname for the Insight UI/API (bitcore-node's web
#                     service). Setting this enables nginx + a real Let's
#                     Encrypt cert - see the "nginx + real TLS" section below.
#                     Requires DNS for this hostname already pointed at this
#                     VPS and port 80/443 reachable. Leave unset to skip nginx
#                     entirely (lightwalletd falls back to a self-signed cert).
#   LWD_DOMAIN_NAME  Hostname for lightwalletd's gRPC service, on its own
#                     nginx server block. Required together with DOMAIN_NAME
#                     (separate DNS record, same VPS).
#   CERTBOT_EMAIL    Required if DOMAIN_NAME is set - contact address Let's
#                     Encrypt uses for renewal-failure notices.
#   TLS_CERT/TLS_KEY Real TLS cert/key for lightwalletd, used only when
#                     DOMAIN_NAME is unset; if neither is set a self-signed
#                     cert is generated on every start (fine for bring-up/
#                     testing, not for a publicly reachable node).
#   SWAP_FILE        Swapfile path (default: /swapfile)
#   SWAP_SIZE_GB     Swapfile size in GiB (default: 4, or 8 if RAM < 4GiB)
#   SKIP_SWAP        Set to 1 to skip swap provisioning entirely
#
# nginx + real TLS (when DOMAIN_NAME/LWD_DOMAIN_NAME are set):
#   lightwalletd and bitcore-node's web service bind to 127.0.0.1 only
#   (bitcore-node's web service can't be told to bind a specific host, so a
#   ufw rule blocks external access to it instead, when ufw is already active).
#   nginx gets one certbot cert covering both hostnames (one SAN cert, one
#   renewal entry) and terminates TLS on :443 with two separate server
#   blocks: DOMAIN_NAME proxies to bitcore-node's web port (Insight UI +
#   insight-api-pirate), LWD_DOMAIN_NAME grpc_passes to lightwalletd.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script installs system packages and must be run as root (sudo)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

INSTALL_DIR="${INSTALL_DIR:-$TARGET_HOME/pirateseednode}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
PIRATE_BRANCH="${PIRATE_BRANCH:-dev-ironwood}"
LWD_BRANCH="${LWD_BRANCH:-dev}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
NETWORK="${NETWORK:-livenet}"
RPC_PORT="${RPC_PORT:-45453}"
ZMQ_PORT="${ZMQ_PORT:-28332}"
BITCORE_PORT="${BITCORE_PORT:-3001}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
LWD_DOMAIN_NAME="${LWD_DOMAIN_NAME:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
if [[ -n "$DOMAIN_NAME" ]]; then
  LWD_GRPC_BIND="${LWD_GRPC_BIND:-127.0.0.1:9067}"
  LWD_HTTP_BIND="${LWD_HTTP_BIND:-127.0.0.1:9068}"
else
  LWD_GRPC_BIND="${LWD_GRPC_BIND:-0.0.0.0:9067}"
  LWD_HTTP_BIND="${LWD_HTTP_BIND:-0.0.0.0:9068}"
fi
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"
SWAP_FILE="${SWAP_FILE:-/swapfile}"
SKIP_SWAP="${SKIP_SWAP:-0}"

if [[ -n "$DOMAIN_NAME" || -n "$LWD_DOMAIN_NAME" ]]; then
  if [[ -z "$DOMAIN_NAME" || -z "$LWD_DOMAIN_NAME" ]]; then
    echo "DOMAIN_NAME and LWD_DOMAIN_NAME must both be set to enable nginx (one subdomain for Insight, one for lightwalletd)." >&2
    exit 1
  fi
  if [[ -z "$CERTBOT_EMAIL" ]]; then
    echo "DOMAIN_NAME/LWD_DOMAIN_NAME are set but CERTBOT_EMAIL is not. Set CERTBOT_EMAIL so Let's Encrypt can reach you about renewal problems." >&2
    exit 1
  fi
fi

BUILD_DIR="$INSTALL_DIR/build"
BIN_DIR="$INSTALL_DIR/bin"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DIR="$INSTALL_DIR/config"
BITCORE_NODE_DIR="$INSTALL_DIR/bitcore-node"

TREASURECHEST_DIR="$BUILD_DIR/TreasureChest"
LWD_BUILD_DIR="$BUILD_DIR/lightwalletd"

PIRATED_DATA_DIR="$DATA_DIR/pirated"
LWD_DATA_DIR="$DATA_DIR/lightwalletd"
PIRATE_CONF="$PIRATED_DATA_DIR/PIRATE.conf"

BITCORE_NODE_JSON="$BITCORE_NODE_DIR/bitcore-node.json"
ECOSYSTEM_FILE="$CONFIG_DIR/ecosystem.config.js"

log() { echo -e "\n==> $*"; }

as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

log "Installing system build dependencies"
apt-get update
apt-get install -y \
  build-essential cmake pkg-config m4 g++-multilib autoconf libtool \
  libncurses-dev unzip git python3 python3-zmq zlib1g-dev wget \
  libcurl4-gnutls-dev bsdmainutils curl libsodium-dev bison liblz4-dev zip \
  golang-go jq openssl

if [[ -n "$DOMAIN_NAME" ]]; then
  apt-get install -y nginx certbot python3-certbot-nginx
fi

# Only ever tightens an ALREADY-active ufw (never enables it - flipping a
# firewall on for the first time over SSH risks locking the caller out).
open_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "$1" >/dev/null
  fi
}

if [[ "$SKIP_SWAP" != "1" ]]; then
  EXISTING_SWAP_KB=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
  if [[ "$EXISTING_SWAP_KB" -gt 0 ]]; then
    log "Swap already present ($((EXISTING_SWAP_KB / 1024)) MiB), skipping swap provisioning"
  else
    MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    MEM_TOTAL_GB=$((MEM_TOTAL_KB / 1024 / 1024))
    if [[ -n "${SWAP_SIZE_GB:-}" ]]; then
      SWAP_SIZE="$SWAP_SIZE_GB"
    elif [[ "$MEM_TOTAL_GB" -lt 4 ]]; then
      SWAP_SIZE=8
    else
      SWAP_SIZE=4
    fi

    log "No swap detected (RAM: ${MEM_TOTAL_GB}GiB). Provisioning ${SWAP_SIZE}GiB swapfile at $SWAP_FILE"
    if ! fallocate -l "${SWAP_SIZE}G" "$SWAP_FILE" 2>/dev/null; then
      dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_SIZE * 1024)) status=progress
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    grep -qF "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

    cat > /etc/sysctl.d/60-pirate-swap.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    sysctl -p /etc/sysctl.d/60-pirate-swap.conf >/dev/null
  fi
fi

log "Creating $INSTALL_DIR layout (owned by $TARGET_USER, no sudo needed to run or update)"
as_user "mkdir -p '$BUILD_DIR' '$BIN_DIR' '$CONFIG_DIR' '$PIRATED_DATA_DIR' '$LWD_DATA_DIR'"
# $BITCORE_NODE_DIR is intentionally not created here - `bitcore-node create`
# below refuses to run if its target directory already exists.

open_firewall_port 7770/tcp

if [[ -n "$DOMAIN_NAME" ]]; then
  open_firewall_port 80/tcp
  open_firewall_port 443/tcp
  # bitcore-node's web service always binds all interfaces (no host option),
  # so it can't be restricted to loopback like lightwalletd - block it at the
  # firewall instead. lightwalletd's own ports already default to loopback
  # above when DOMAIN_NAME is set, but deny them too as defense in depth.
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw deny "$BITCORE_PORT/tcp" >/dev/null
    ufw deny "${LWD_GRPC_BIND##*:}/tcp" >/dev/null
    ufw deny "${LWD_HTTP_BIND##*:}/tcp" >/dev/null
  fi

  WEBROOT_DIR=/var/www/certbot
  mkdir -p "$WEBROOT_DIR"
  CERT_DIR="/etc/letsencrypt/live/$DOMAIN_NAME"
  NGINX_SITE=/etc/nginx/sites-available/pirate-seed-node
  LWD_GRPC_PORT="${LWD_GRPC_BIND##*:}"

  log "Writing initial nginx config for $DOMAIN_NAME / $LWD_DOMAIN_NAME (HTTP only, for the ACME challenge)"
  cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME $LWD_DOMAIN_NAME;

    location /.well-known/acme-challenge/ {
        root $WEBROOT_DIR;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/pirate-seed-node
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx >/dev/null 2>&1 || systemctl restart nginx

  if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
    log "Obtaining Let's Encrypt certificate for $DOMAIN_NAME + $LWD_DOMAIN_NAME"
    certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN_NAME" -d "$LWD_DOMAIN_NAME" \
      --non-interactive --agree-tos -m "$CERTBOT_EMAIL"
  else
    log "Certificate covering $DOMAIN_NAME/$LWD_DOMAIN_NAME already exists, skipping issuance"
  fi

  log "Writing final nginx config (TLS termination + reverse proxy, two server blocks)"
  cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME $LWD_DOMAIN_NAME;

    location /.well-known/acme-challenge/ {
        root $WEBROOT_DIR;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Insight UI + insight-api-pirate, served by bitcore-node's web service
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$BITCORE_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# lightwalletd's gRPC service
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $LWD_DOMAIN_NAME;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    location / {
        grpc_pass grpc://127.0.0.1:$LWD_GRPC_PORT;
    }
}
EOF
  nginx -t
  systemctl reload nginx
  # The certbot apt package installs its own renewal timer (certbot.timer);
  # nothing further to schedule here.
fi

log "Installing nvm and Node.js $NODE_VERSION for $TARGET_USER"
if [[ ! -s "$TARGET_HOME/.nvm/nvm.sh" ]]; then
  as_user 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
fi
as_user "
  export NVM_DIR=\"$TARGET_HOME/.nvm\"
  source \"\$NVM_DIR/nvm.sh\"
  nvm install $NODE_VERSION
  nvm alias default $NODE_VERSION
"

# Re-usable snippet: put node/npm/pm2 for $NODE_VERSION on PATH inside as_user calls.
NVM_LOAD="export NVM_DIR=\"$TARGET_HOME/.nvm\"; source \"\$NVM_DIR/nvm.sh\"; nvm use $NODE_VERSION >/dev/null"

log "Installing pm2 and pm2-logrotate"
as_user "$NVM_LOAD; npm install -g pm2"
as_user "$NVM_LOAD; pm2 install pm2-logrotate"

log "Cloning/updating TreasureChest ($PIRATE_BRANCH)"
if [[ -d "$TREASURECHEST_DIR/.git" ]]; then
  as_user "git -C '$TREASURECHEST_DIR' fetch origin '$PIRATE_BRANCH' && git -C '$TREASURECHEST_DIR' checkout '$PIRATE_BRANCH' && git -C '$TREASURECHEST_DIR' pull origin '$PIRATE_BRANCH'"
else
  as_user "git clone --branch '$PIRATE_BRANCH' https://github.com/PirateNetwork/pirate.git '$TREASURECHEST_DIR'"
fi

log "Building TreasureChest (pirated/pirate-cli) - this takes a while"
# A seed node has no use for the pirate-gtest binary, and building it here
# is fragile: zcutil/build.sh's own --disable-tests flag doesn't actually
# disable tests (it sets --enable-tests=yes), so skip it via configure directly.
as_user "cd '$TREASURECHEST_DIR' && CONFIGURE_FLAGS='--enable-tests=no' ./zcutil/build.sh -j$MAKE_JOBS"
as_user "cd '$TREASURECHEST_DIR' && ./zcutil/fetch-params.sh"

log "Cloning/updating lightwalletd ($LWD_BRANCH)"
if [[ -d "$LWD_BUILD_DIR/.git" ]]; then
  as_user "git -C '$LWD_BUILD_DIR' fetch origin '$LWD_BRANCH' && git -C '$LWD_BUILD_DIR' checkout '$LWD_BRANCH' && git -C '$LWD_BUILD_DIR' pull origin '$LWD_BRANCH'"
else
  as_user "git clone --branch '$LWD_BRANCH' https://github.com/PirateNetwork/lightwalletd '$LWD_BUILD_DIR'"
fi

log "Building lightwalletd"
as_user "cd '$LWD_BUILD_DIR' && CGO_ENABLED=0 go build -a -ldflags '-extldflags \"-static\"' -o lightwalletd ."

log "Linking built binaries into $BIN_DIR"
as_user "ln -sf '$TREASURECHEST_DIR/src/pirated' '$BIN_DIR/pirated'"
as_user "ln -sf '$TREASURECHEST_DIR/src/pirate-cli' '$BIN_DIR/pirate-cli'"
as_user "ln -sf '$LWD_BUILD_DIR/lightwalletd' '$BIN_DIR/lightwalletd'"

log "Installing bitcore-node-pirate globally via npm ($PIRATE_BRANCH)"
as_user "$NVM_LOAD; npm install -g 'git+https://github.com/piratenetwork/bitcore-node-pirate.git#$PIRATE_BRANCH'"

log "Configuring pirated (PIRATE.conf)"
if [[ ! -f "$PIRATE_CONF" ]]; then
  RPC_USER="pirate_$(openssl rand -hex 6)"
  RPC_PASSWORD=$(openssl rand -hex 24)
  TESTNET_LINE=""
  [[ "$NETWORK" == "testnet" ]] && TESTNET_LINE="testnet=1"
  as_user "cat > '$PIRATE_CONF' <<EOF
server=1
listen=1
maxconnections=256
rpcuser=$RPC_USER
rpcpassword=$RPC_PASSWORD
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=$RPC_PORT
rpcworkqueue=128
experimentalfeatures=1
txindex=1
addressindex=1
timestampindex=1
spentindex=1
zmqpubrawtx=tcp://127.0.0.1:$ZMQ_PORT
zmqpubhashblock=tcp://127.0.0.1:$ZMQ_PORT
$TESTNET_LINE
EOF"
else
  log "PIRATE.conf already exists, leaving credentials untouched"
fi

log "Scaffolding bitcore-node instance directory"
if [[ ! -f "$BITCORE_NODE_JSON" ]]; then
  CREATE_NETWORK_FLAG=""
  [[ "$NETWORK" == "testnet" ]] && CREATE_NETWORK_FLAG="--testnet"
  as_user "$NVM_LOAD; bitcore-node create -d '$PIRATED_DATA_DIR' $CREATE_NETWORK_FLAG '$BITCORE_NODE_DIR'"
else
  log "$BITCORE_NODE_JSON already exists, leaving it as-is"
fi

# `create` defaults port to 3001 and exec to a bin/pirated placeholder inside
# its own node_modules install; point both at what this script actually built.
as_user "$NVM_LOAD; node -e \"
  const fs = require('fs');
  const p = '$BITCORE_NODE_JSON';
  const c = JSON.parse(fs.readFileSync(p, 'utf8'));
  c.port = $BITCORE_PORT;
  c.servicesConfig.bitcoind.spawn.datadir = '$PIRATED_DATA_DIR';
  c.servicesConfig.bitcoind.spawn.exec = '$BIN_DIR/pirated';
  fs.writeFileSync(p, JSON.stringify(c, null, 2));
\""

log "Installing insight-api/insight-ui services ($PIRATE_BRANCH)"
if [[ ! -d "$BITCORE_NODE_DIR/node_modules/insight-api-pirate" ]]; then
  as_user "$NVM_LOAD; cd '$BITCORE_NODE_DIR' && bitcore-node install 'git+https://github.com/piratenetwork/insight-api-pirate.git#$PIRATE_BRANCH'"
else
  log "insight-api-pirate already installed, skipping"
fi
if [[ ! -d "$BITCORE_NODE_DIR/node_modules/insight-ui-pirate" ]]; then
  as_user "$NVM_LOAD; cd '$BITCORE_NODE_DIR' && bitcore-node install 'git+https://github.com/piratenetwork/insight-ui-pirate.git#$PIRATE_BRANCH'"
else
  log "insight-ui-pirate already installed, skipping"
fi

BITCORE_NODE_BIN=$(as_user "$NVM_LOAD; command -v bitcore-node")

log "Writing pm2 ecosystem file"
LWD_ARGS="--grpc-bind-addr $LWD_GRPC_BIND --http-bind-addr $LWD_HTTP_BIND --pirate-conf-path $PIRATE_CONF --data-dir $LWD_DATA_DIR"
if [[ -n "$DOMAIN_NAME" ]]; then
  # nginx terminates TLS and is the only thing that can reach these
  # loopback-bound ports, so plaintext here is safe.
  LWD_ARGS="$LWD_ARGS --no-tls-very-insecure"
elif [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
  LWD_ARGS="$LWD_ARGS --tls-cert $TLS_CERT --tls-key $TLS_KEY"
else
  LWD_ARGS="$LWD_ARGS --gen-cert-very-insecure"
fi

as_user "cat > '$ECOSYSTEM_FILE' <<EOF
module.exports = {
  apps: [
    {
      name: 'bitcore',
      cwd: '$BITCORE_NODE_DIR',
      script: '$BITCORE_NODE_BIN',
      args: 'start --config $BITCORE_NODE_DIR',
      interpreter: 'node',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000
    },
    {
      name: 'lightwalletd',
      cwd: '$BIN_DIR',
      script: './lightwalletd',
      args: '$LWD_ARGS',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000
    }
  ]
};
EOF"

log "Starting bitcore under pm2 and waiting for pirated RPC to come up"
as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only bitcore"

RPC_READY=0
for _ in $(seq 1 60); do
  if as_user "'$BIN_DIR/pirate-cli' -conf='$PIRATE_CONF' -datadir='$PIRATED_DATA_DIR' getinfo" >/dev/null 2>&1; then
    RPC_READY=1
    break
  fi
  sleep 5
done

if [[ "$RPC_READY" -ne 1 ]]; then
  echo "WARNING: pirated RPC did not respond within 5 minutes. Starting lightwalletd anyway; pm2 will keep retrying it." >&2
fi

log "Starting lightwalletd under pm2"
as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only lightwalletd"

log "Persisting pm2 process list and enabling pm2 on boot"
as_user "$NVM_LOAD; pm2 save"
STARTUP_CMD=$(as_user "$NVM_LOAD; pm2 startup systemd -u $TARGET_USER --hp $TARGET_HOME" | grep '^sudo ' || true)
if [[ -n "$STARTUP_CMD" ]]; then
  eval "$STARTUP_CMD"
fi

if [[ -n "$DOMAIN_NAME" ]]; then
  ACCESS_INFO="  Insight UI:        https://$DOMAIN_NAME/
  Insight API:       https://$DOMAIN_NAME/insight-api-pirate/
  lightwalletd gRPC: $LWD_DOMAIN_NAME:443

  TLS is terminated by nginx using one certbot cert covering both hostnames
  (auto-renewed by the certbot.timer systemd unit). bitcore-node's web port
  ($BITCORE_PORT) and lightwalletd ($LWD_GRPC_BIND, $LWD_HTTP_BIND) are not
  meant to be reached directly - lightwalletd is loopback-bound and
  bitcore-node's port is blocked at the firewall when ufw is active."
else
  ACCESS_INFO="  Insight UI:  http://<host>:$BITCORE_PORT/
  Insight API: http://<host>:$BITCORE_PORT/insight-api-pirate/

  NOTE: lightwalletd is running with a self-signed cert (--gen-cert-very-insecure)
  unless TLS_CERT/TLS_KEY were supplied, and both it and bitcore-node's web
  port are directly reachable with no TLS in front of them. Set DOMAIN_NAME,
  LWD_DOMAIN_NAME, and CERTBOT_EMAIL and re-run this script to put nginx +
  a real Let's Encrypt cert in front of both instead."
fi

cat <<SUMMARY

==> Deploy complete.

  pirated + bitcore-node : pm2 process "bitcore"      (RPC on 127.0.0.1:$RPC_PORT, web API + Insight on :$BITCORE_PORT)
  lightwalletd           : pm2 process "lightwalletd" (gRPC on $LWD_GRPC_BIND, HTTP on $LWD_HTTP_BIND)

$ACCESS_INFO

  Layout (all owned by $TARGET_USER, no sudo needed for day-to-day use):
    $BUILD_DIR        TreasureChest/lightwalletd source + compiled binaries - pull/rebuild here to update
    $BIN_DIR          stable symlinks that config/pm2 point at
    $BITCORE_NODE_DIR bitcore-node.json + node_modules (bitcore-node-pirate, insight-api-pirate, insight-ui-pirate)
    $DATA_DIR         chain data, PIRATE.conf, lightwalletd cache - back this up
    $CONFIG_DIR       pm2 ecosystem.config.js

  RPC credentials: $PIRATE_CONF (generated on first run, not printed here)

  Useful commands (as $TARGET_USER):
    pm2 status
    pm2 logs bitcore
    pm2 logs lightwalletd

  To update pirated/lightwalletd: pull + rebuild in $BUILD_DIR, then
  'pm2 restart bitcore lightwalletd' (the $BIN_DIR symlinks pick up the new
  binaries automatically - no config changes needed).

  To update bitcore-node-pirate itself: re-run 'npm install -g
  git+https://github.com/piratenetwork/bitcore-node-pirate.git#$PIRATE_BRANCH'
  then 'pm2 restart bitcore'. To update insight-api-pirate/insight-ui-pirate,
  re-run the same 'bitcore-node install git+...#$PIRATE_BRANCH' command for
  each from within $BITCORE_NODE_DIR, then 'pm2 restart bitcore'.

  Port 7770/tcp (mainnet P2P) was opened in ufw if it's active; open it
  manually otherwise so this node can serve as a peer.
SUMMARY
