#!/usr/bin/env bash
#
# update-seed-node.sh - refresh a seed node already brought up by
# deploy-seed-node.sh with the latest commits, without touching nginx,
# certificates, PIRATE.conf/the test node's conf, or any chain/wallet data.
#
# What it does, in order:
#   1. Stops every pm2 process this node runs.
#   2. Pulls the latest commits on TreasureChest/lightwalletd (and
#      pirate-seeder, if deployed) on their configured branches.
#   3. Rebuilds all of them.
#   4. Completely uninstalls and reinstalls the bitcore stack: the global
#      bitcore-node-pirate npm package, and - for each bitcore-node instance
#      that exists (live, and the test node if deployed) - wipes its whole
#      scaffold directory (bitcore-node.json, package.json, node_modules)
#      and recreates it from scratch, including fresh insight-api-pirate/
#      insight-ui-pirate installs. The instance's port/datadir/exec wiring
#      is captured before the wipe and reapplied after, so nothing about
#      how it's configured changes - only the code underneath it.
#   5. Deletes and re-registers every pm2 process, waiting for each
#      pirated's RPC to come up before starting its lightwalletd.
#
# What is deployed (test node? pirate-seeder?) is detected automatically
# from what already exists under INSTALL_DIR - no need to re-pass
# ENABLE_TESTNODE/DNSSEED_HOST/etc. Deliberately does not touch: nginx
# config, certbot/TLS certificates, PIRATE.conf or the test node's conf
# (credentials + RPC/ZMQ ports stay exactly as originally deployed), or any
# data directory's contents. Also doesn't re-run apt-get - routine commits
# don't usually add new system dependencies; if one ever does, that's a
# one-off manual step, not something to run unconditionally on every update.
#
# Usage:
#   sudo ./update-seed-node.sh
#
# Overridable via environment variables (same meaning/defaults as
# deploy-seed-node.sh - only pass these if you're intentionally changing
# them, e.g. moving to a new branch):
#   INSTALL_DIR    Must match the deploy-seed-node.sh install (default: ~<user>/pirateseednode)
#   NODE_VERSION   Node.js version already installed via nvm (default: 24.19.0)
#   PIRATE_BRANCH  Branch for TreasureChest (default: dev-ironwood)
#   BITCORE_BRANCH Branch for bitcore-node-pirate/insight-api-pirate/insight-ui-pirate (default: master)
#   LWD_BRANCH     Branch for lightwalletd (default: master)
#   DNSSEED_BRANCH Branch for pirate-seeder, if deployed (default: main)
#   MAKE_JOBS      Parallelism for TreasureChest's build (default: nproc)
#   DNSSEED_PORT   UDP port pirate-seeder binds, if deployed - only matters
#                  for re-applying CAP_NET_BIND_SERVICE, lost on every
#                  rebuild (default: 53)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script rebuilds binaries and must be run as root (sudo)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

INSTALL_DIR="${INSTALL_DIR:-$TARGET_HOME/pirateseednode}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
PIRATE_BRANCH="${PIRATE_BRANCH:-dev-ironwood}"
BITCORE_BRANCH="${BITCORE_BRANCH:-master}"
LWD_BRANCH="${LWD_BRANCH:-master}"
DNSSEED_BRANCH="${DNSSEED_BRANCH:-main}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
DNSSEED_PORT="${DNSSEED_PORT:-53}"

BUILD_DIR="$INSTALL_DIR/build"
BIN_DIR="$INSTALL_DIR/bin"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DIR="$INSTALL_DIR/config"
BITCORE_NODE_DIR="$INSTALL_DIR/bitcore-node"
TESTNODE_BITCORE_NODE_DIR="$INSTALL_DIR/bitcore-node-test"

TREASURECHEST_DIR="$BUILD_DIR/TreasureChest"
LWD_BUILD_DIR="$BUILD_DIR/lightwalletd"
PIRATE_SEEDER_DIR="$BUILD_DIR/pirate-seeder"

PIRATED_DATA_DIR="$DATA_DIR/pirated"
PIRATE_CONF="$PIRATED_DATA_DIR/PIRATE.conf"
TESTNODE_PIRATED_DATA_DIR="$DATA_DIR/pirated-test"

BITCORE_NODE_JSON="$BITCORE_NODE_DIR/bitcore-node.json"
TESTNODE_BITCORE_NODE_JSON="$TESTNODE_BITCORE_NODE_DIR/bitcore-node.json"
ECOSYSTEM_FILE="$CONFIG_DIR/ecosystem.config.js"

if [[ ! -f "$BITCORE_NODE_JSON" || ! -f "$ECOSYSTEM_FILE" ]]; then
  echo "$INSTALL_DIR doesn't look like a deploy-seed-node.sh install (missing $BITCORE_NODE_JSON or $ECOSYSTEM_FILE). Check INSTALL_DIR." >&2
  exit 1
fi

HAS_TESTNODE=0
[[ -f "$TESTNODE_BITCORE_NODE_JSON" ]] && HAS_TESTNODE=1
HAS_DNSSEED=0
[[ -d "$PIRATE_SEEDER_DIR/.git" ]] && HAS_DNSSEED=1

# The test node's conf filename depends on its -ac_name (default PIRATETST,
# but could've been overridden at deploy time) - rather than requiring that
# as an env var here too, just find the one .conf file the wrapper script
# was pointed at.
TESTNODE_CONF=""
if [[ "$HAS_TESTNODE" == "1" ]]; then
  TESTNODE_CONF=$(ls "$TESTNODE_PIRATED_DATA_DIR"/*.conf 2>/dev/null | head -1)
fi

log() { echo -e "\n==> $*"; }
as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

NVM_LOAD="export NVM_DIR=\"$TARGET_HOME/.nvm\"; source \"\$NVM_DIR/nvm.sh\"; nvm use $NODE_VERSION >/dev/null"

PM2_APPS=(bitcore lightwalletd)
[[ "$HAS_TESTNODE" == "1" ]] && PM2_APPS+=(bitcore-test lightwalletd-test)
[[ "$HAS_DNSSEED" == "1" ]] && PM2_APPS+=(pirate-seeder)

log "Detected: test node $([[ $HAS_TESTNODE == 1 ]] && echo yes || echo no), pirate-seeder $([[ $HAS_DNSSEED == 1 ]] && echo yes || echo no)"
log "Stopping pm2 services: ${PM2_APPS[*]}"
as_user "$NVM_LOAD; pm2 stop ${PM2_APPS[*]}" || true

log "Pulling TreasureChest ($PIRATE_BRANCH)"
as_user "git -C '$TREASURECHEST_DIR' fetch origin '$PIRATE_BRANCH' && git -C '$TREASURECHEST_DIR' checkout '$PIRATE_BRANCH' && git -C '$TREASURECHEST_DIR' pull origin '$PIRATE_BRANCH'"

log "Pulling lightwalletd ($LWD_BRANCH)"
as_user "git -C '$LWD_BUILD_DIR' fetch origin '$LWD_BRANCH' && git -C '$LWD_BUILD_DIR' checkout '$LWD_BRANCH' && git -C '$LWD_BUILD_DIR' pull origin '$LWD_BRANCH'"

if [[ "$HAS_DNSSEED" == "1" ]]; then
  log "Pulling pirate-seeder ($DNSSEED_BRANCH)"
  as_user "git -C '$PIRATE_SEEDER_DIR' fetch origin '$DNSSEED_BRANCH' && git -C '$PIRATE_SEEDER_DIR' checkout '$DNSSEED_BRANCH' && git -C '$PIRATE_SEEDER_DIR' pull origin '$DNSSEED_BRANCH'"
fi

log "Rebuilding TreasureChest (pirated/pirate-cli) - this takes a while"
as_user "cd '$TREASURECHEST_DIR' && CONFIGURE_FLAGS='--enable-tests=no' ./zcutil/build.sh -j$MAKE_JOBS"
as_user "cd '$TREASURECHEST_DIR' && ./zcutil/fetch-params.sh"
as_user "cd '$TREASURECHEST_DIR/src' && make install prefix='$TREASURECHEST_DIR/artifacts'"
# $BIN_DIR/pirated, pirate-cli etc. are stable symlinks already pointing at
# these paths from the original deploy - the rebuilt binaries are picked up
# automatically, nothing to re-link.

log "Rebuilding lightwalletd"
as_user "cd '$LWD_BUILD_DIR' && CGO_ENABLED=0 go build -a -ldflags '-extldflags \"-static\"' -o lightwalletd ."

if [[ "$HAS_DNSSEED" == "1" ]]; then
  log "Rebuilding pirate-seeder"
  as_user "cd '$PIRATE_SEEDER_DIR' && make -j$MAKE_JOBS"
  if [[ "$DNSSEED_PORT" -lt 1024 ]]; then
    # Capabilities live on the binary's extended attributes and are lost on
    # every rebuild - must be re-applied here too.
    setcap 'cap_net_bind_service=+ep' "$PIRATE_SEEDER_DIR/pirate-seeder"
  fi
fi

log "Uninstalling bitcore-node-pirate"
as_user "$NVM_LOAD; npm uninstall -g bitcore-node-pirate" || true
log "Reinstalling bitcore-node-pirate ($BITCORE_BRANCH)"
as_user "$NVM_LOAD; npm install -g 'git+https://github.com/piratenetwork/bitcore-node-pirate.git#$BITCORE_BRANCH'"
BITCORE_NODE_BIN=$(as_user "$NVM_LOAD; command -v bitcore-node")

# Wipes and re-scaffolds one bitcore-node instance from scratch, forcing a
# genuinely fresh install (unlike deploy-seed-node.sh's own idempotent
# "skip if already installed" guards, which would never pick up new commits
# on an existing deploy). port is captured from the doomed file before the
# wipe so it doesn't need to be re-supplied as an env var; datadir/exec are
# fixed convention (same paths deploy-seed-node.sh itself always uses), not
# something that varies deploy to deploy.
reinstall_bitcore_instance() {
  local json_path="$1" dir_path="$2" datadir="$3" exec_path="$4" label="$5"
  log "Reinstalling the $label bitcore-node instance ($dir_path)"

  local port
  port=$(jq -r '.port' "$json_path")

  as_user "rm -rf '$dir_path'"
  as_user "$NVM_LOAD; bitcore-node create -d '$datadir' '$dir_path'"
  as_user "$NVM_LOAD; node -e \"
    const fs = require('fs');
    const p = '$json_path';
    const c = JSON.parse(fs.readFileSync(p, 'utf8'));
    c.port = $port;
    c.servicesConfig.bitcoind.spawn.datadir = '$datadir';
    c.servicesConfig.bitcoind.spawn.exec = '$exec_path';
    fs.writeFileSync(p, JSON.stringify(c, null, 2));
  \""
  as_user "$NVM_LOAD; cd '$dir_path' && bitcore-node install 'git+https://github.com/piratenetwork/insight-api-pirate.git#$BITCORE_BRANCH'"
  as_user "$NVM_LOAD; cd '$dir_path' && bitcore-node install 'git+https://github.com/piratenetwork/insight-ui-pirate.git#$BITCORE_BRANCH'"
}

reinstall_bitcore_instance "$BITCORE_NODE_JSON" "$BITCORE_NODE_DIR" "$PIRATED_DATA_DIR" "$BIN_DIR/pirated" "live"
if [[ "$HAS_TESTNODE" == "1" ]]; then
  reinstall_bitcore_instance "$TESTNODE_BITCORE_NODE_JSON" "$TESTNODE_BITCORE_NODE_DIR" "$TESTNODE_PIRATED_DATA_DIR" "$BIN_DIR/pirated-testnode" "test node"
fi

# Rewrites ecosystem.config.js from its own current contents (introspected
# via require(), not reconstructed from env vars) so cwd/args for every app
# are preserved byte-for-byte - only each bitcore-flavored app's script path
# is refreshed, in case the global npm bin path changed on reinstall.
log "Regenerating $ECOSYSTEM_FILE"
as_user "$NVM_LOAD; node -e \"
  const fs = require('fs');
  const path = '$ECOSYSTEM_FILE';
  const cfg = require(path);
  for (const app of cfg.apps) {
    if (app.name === 'bitcore' || app.name === 'bitcore-test') app.script = '$BITCORE_NODE_BIN';
  }
  fs.writeFileSync(path, 'module.exports = ' + JSON.stringify(cfg, null, 2) + ';\n');
\""

log "Deleting old pm2 process entries: ${PM2_APPS[*]}"
as_user "$NVM_LOAD; pm2 delete ${PM2_APPS[*]}" || true

wait_for_rpc() {
  local conf="$1" datadir="$2" label="$3"
  local ready=0
  for _ in $(seq 1 60); do
    if as_user "'$BIN_DIR/pirate-cli' -conf='$conf' -datadir='$datadir' getinfo" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 5
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "WARNING: $label pirated RPC did not respond within 5 minutes. Continuing anyway; pm2 will keep retrying it." >&2
  fi
}

log "Starting bitcore under pm2 and waiting for pirated RPC to come up"
as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only bitcore"
wait_for_rpc "$PIRATE_CONF" "$PIRATED_DATA_DIR" "live node's"

log "Starting lightwalletd under pm2"
as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only lightwalletd"

if [[ "$HAS_TESTNODE" == "1" ]]; then
  log "Starting bitcore-test under pm2 and waiting for the test node's pirated RPC to come up"
  as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only bitcore-test"
  wait_for_rpc "$TESTNODE_CONF" "$TESTNODE_PIRATED_DATA_DIR" "test node's"

  log "Starting lightwalletd-test under pm2"
  as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only lightwalletd-test"
fi

if [[ "$HAS_DNSSEED" == "1" ]]; then
  log "Starting pirate-seeder under pm2"
  as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only pirate-seeder"
fi

log "Persisting pm2 process list"
as_user "$NVM_LOAD; pm2 save"

log "Update complete. pm2 status:"
as_user "$NVM_LOAD; pm2 status"
