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
#   build/   source checkouts + compiled artifacts (TreasureChest, lightwalletd,
#            bitcore-node-pirate). Pull + rebuild here to update.
#   bin/     stable symlinks (pirated, pirate-cli, lightwalletd) that config
#            files and pm2 point at, so updating build/ doesn't require
#            touching config.
#   data/    PIRATE.conf, chain data, lightwalletd cache - the only directory
#            that needs to persist/be backed up.
#
# Overridable via environment variables:
#   INSTALL_DIR      Base directory for everything this script builds (default: ~<user>/pirateseednode)
#   NODE_VERSION     Node.js version installed via nvm (default: 24.19.0)
#   PIRATE_BRANCH    Branch to check out for TreasureChest/bitcore-node-pirate/bitcore-lib-pirate (default: dev-ironwood)
#   LWD_BRANCH       Branch to check out for lightwalletd (default: dev)
#   MAKE_JOBS        Parallelism for TreasureChest's build (default: nproc)
#   NETWORK          livenet | testnet (default: livenet)
#   RPC_PORT         pirated RPC port (default: 45453)
#   ZMQ_PORT         pirated zmqpub port, shared by rawtx/hashblock (default: 28332)
#   BITCORE_PORT     bitcore-node web API port (default: 3001)
#   LWD_GRPC_BIND    lightwalletd gRPC bind address (default: 0.0.0.0:9067)
#   LWD_HTTP_BIND    lightwalletd HTTP bind address (default: 0.0.0.0:9068)
#   TLS_CERT/TLS_KEY Real TLS cert/key for lightwalletd; if unset a self-signed
#                     cert is generated on every start (fine for bring-up/testing,
#                     NOT for production - see README section on Let's Encrypt + nginx)
#   SWAP_FILE        Swapfile path (default: /swapfile)
#   SWAP_SIZE_GB     Swapfile size in GiB (default: 4, or 8 if RAM < 4GiB)
#   SKIP_SWAP        Set to 1 to skip swap provisioning entirely

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
LWD_GRPC_BIND="${LWD_GRPC_BIND:-0.0.0.0:9067}"
LWD_HTTP_BIND="${LWD_HTTP_BIND:-0.0.0.0:9068}"
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"
SWAP_FILE="${SWAP_FILE:-/swapfile}"
SKIP_SWAP="${SKIP_SWAP:-0}"

BUILD_DIR="$INSTALL_DIR/build"
BIN_DIR="$INSTALL_DIR/bin"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DIR="$INSTALL_DIR/config"

TREASURECHEST_DIR="$BUILD_DIR/TreasureChest"
LWD_BUILD_DIR="$BUILD_DIR/lightwalletd"
BITCORE_DIR="$BUILD_DIR/bitcore-node-pirate"

PIRATED_DATA_DIR="$DATA_DIR/pirated"
LWD_DATA_DIR="$DATA_DIR/lightwalletd"
PIRATE_CONF="$PIRATED_DATA_DIR/PIRATE.conf"

BITCORE_NODE_JSON="$CONFIG_DIR/bitcore-node.json"
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
as_user "cd '$TREASURECHEST_DIR' && ./zcutil/build.sh -j$MAKE_JOBS"
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

log "Cloning/updating bitcore-node-pirate ($PIRATE_BRANCH)"
if [[ -d "$BITCORE_DIR/.git" ]]; then
  as_user "git -C '$BITCORE_DIR' fetch origin '$PIRATE_BRANCH' && git -C '$BITCORE_DIR' checkout '$PIRATE_BRANCH' && git -C '$BITCORE_DIR' pull origin '$PIRATE_BRANCH'"
else
  as_user "git clone --branch '$PIRATE_BRANCH' https://github.com/piratenetwork/bitcore-node-pirate.git '$BITCORE_DIR'"
fi

log "Installing bitcore-node-pirate dependencies (npm install; pulls bitcore-lib-pirate)"
as_user "$NVM_LOAD; cd '$BITCORE_DIR' && npm install"

log "Configuring pirated (PIRATE.conf) and bitcore-node.json"
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

as_user "cat > '$BITCORE_NODE_JSON' <<EOF
{
  \"network\": \"$NETWORK\",
  \"port\": $BITCORE_PORT,
  \"services\": [\"bitcoind\", \"web\"],
  \"servicesConfig\": {
    \"bitcoind\": {
      \"spawn\": {
        \"datadir\": \"$PIRATED_DATA_DIR\",
        \"exec\": \"$BIN_DIR/pirated\"
      }
    }
  }
}
EOF"

log "Writing pm2 ecosystem file"
LWD_ARGS="--grpc-bind-addr $LWD_GRPC_BIND --http-bind-addr $LWD_HTTP_BIND --pirate-conf-path $PIRATE_CONF --data-dir $LWD_DATA_DIR"
if [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
  LWD_ARGS="$LWD_ARGS --tls-cert $TLS_CERT --tls-key $TLS_KEY"
else
  LWD_ARGS="$LWD_ARGS --gen-cert-very-insecure"
fi

as_user "cat > '$ECOSYSTEM_FILE' <<EOF
module.exports = {
  apps: [
    {
      name: 'bitcore',
      cwd: '$BITCORE_DIR',
      script: './bin/bitcore-node',
      args: 'start --config $BITCORE_NODE_JSON',
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

cat <<SUMMARY

==> Deploy complete.

  pirated + bitcore-node : pm2 process "bitcore"      (RPC on 127.0.0.1:$RPC_PORT, web API on :$BITCORE_PORT)
  lightwalletd           : pm2 process "lightwalletd" (gRPC on $LWD_GRPC_BIND, HTTP on $LWD_HTTP_BIND)

  Layout (all owned by $TARGET_USER, no sudo needed for day-to-day use):
    $BUILD_DIR   source checkouts + compiled binaries - pull/rebuild here to update
    $BIN_DIR     stable symlinks that config/pm2 point at
    $DATA_DIR    chain data, PIRATE.conf, lightwalletd cache - back this up
    $CONFIG_DIR  bitcore-node.json + pm2 ecosystem.config.js

  RPC credentials: $PIRATE_CONF (generated on first run, not printed here)

  Useful commands (as $TARGET_USER):
    pm2 status
    pm2 logs bitcore
    pm2 logs lightwalletd

  To update pirated/lightwalletd: pull + rebuild in $BUILD_DIR, then
  'pm2 restart bitcore lightwalletd' (the $BIN_DIR symlinks pick up the new
  binaries automatically - no config changes needed).

  NOTE: lightwalletd is running with a self-signed cert (--gen-cert-very-insecure)
  unless TLS_CERT/TLS_KEY were supplied. Put a real cert (e.g. via nginx + certbot)
  in front of it before exposing $LWD_GRPC_BIND / $LWD_HTTP_BIND publicly.

  Open port 7770/tcp (mainnet P2P) in your firewall so this node can serve as a
  peer, and 9067/9068 if lightwalletd should be reachable directly.
SUMMARY
