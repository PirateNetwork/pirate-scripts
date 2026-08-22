#!/usr/bin/env bash
#
# bootstrap-snapshot.sh - regenerate the ARRR bootstrap tarball from a
# dedicated bootstrap-source pirated instance (see deploy-seed-node.sh's
# ENABLE_BOOTSTRAP_NODE) and publish it with a sha256 alongside it.
#
# What it does, in order:
#   1. Records the bootstrap-source node's current height for logging.
#   2. Cleanly stops it (`pirate-cli stop`, then waits for the process to
#      actually exit) and stops its pm2 app so autorestart doesn't race the
#      copy - LevelDB's background compaction thread isn't gated by any
#      in-process lock, so this is the only way to guarantee blocks/+
#      chainstate/ aren't mid-write during the tar.
#   3. Tars just blocks/+chainstate/ (not the whole datadir - no wallet.dat,
#      conf, or onion/i2p keys) and computes its sha256.
#   4. Atomically publishes both into BOOTSTRAP_OUTPUT_DIR under the same
#      filenames every time (so the client needs no URL scheme change),
#      alongside a dated copy for manual rollback, and prunes dated copies
#      beyond BOOTSTRAP_KEEP.
#   5. Restarts the bootstrap-source node - via a trap, so this happens even
#      if an earlier step fails. A bug here means "next snapshot is late,"
#      never "the bootstrap-source node stays down."
#
# The live node, bitcore, lightwalletd, and pirate-seeder are never touched
# - this only ever stops/starts the dedicated bootstrap-source instance
# provisioned by deploy-seed-node.sh's ENABLE_BOOTSTRAP_NODE=1.
#
# Usage:
#   sudo ./bootstrap-snapshot.sh                  run one snapshot now
#   sudo ./bootstrap-snapshot.sh --install-timer   install+enable a daily
#                                                   systemd timer that runs
#                                                   this script (OnCalendar=
#                                                   daily, RandomizedDelaySec=
#                                                   1h so multiple seed nodes
#                                                   don't all pause at once)
#
# Overridable via environment variables (same meaning/defaults as
# deploy-seed-node.sh where shared):
#   INSTALL_DIR             Must match the deploy-seed-node.sh install (default: ~<user>/pirateseednode)
#   NODE_VERSION            Node.js version already installed via nvm (default: 24.19.0)
#   BOOTSTRAP_OUTPUT_DIR    Where the tarball + sha256 are published (default: $INSTALL_DIR/bootstrap-www)
#   BOOTSTRAP_NAME          Base filename, without extension (default: ARRR-bootstrap)
#   BOOTSTRAP_KEEP          How many dated snapshots to retain for manual rollback, besides the published copy (default: 3)
#   BOOTSTRAP_STOP_TIMEOUT  Seconds to wait for the bootstrap-source node to shut down cleanly before giving up (default: 120)
#   BOOTSTRAP_START_TIMEOUT Seconds to wait for its RPC to come back up after restart (default: 300)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script manages another user's pm2 processes and must be run as root (sudo)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

INSTALL_DIR="${INSTALL_DIR:-$TARGET_HOME/pirateseednode}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
BOOTSTRAP_OUTPUT_DIR="${BOOTSTRAP_OUTPUT_DIR:-$INSTALL_DIR/bootstrap-www}"
BOOTSTRAP_NAME="${BOOTSTRAP_NAME:-ARRR-bootstrap}"
BOOTSTRAP_KEEP="${BOOTSTRAP_KEEP:-3}"
BOOTSTRAP_STOP_TIMEOUT="${BOOTSTRAP_STOP_TIMEOUT:-120}"
BOOTSTRAP_START_TIMEOUT="${BOOTSTRAP_START_TIMEOUT:-300}"

BIN_DIR="$INSTALL_DIR/bin"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DIR="$INSTALL_DIR/config"
BOOTSTRAP_PIRATED_DATA_DIR="$DATA_DIR/pirated-bootstrap"
BOOTSTRAP_CONF="$BOOTSTRAP_PIRATED_DATA_DIR/PIRATE.conf"
ECOSYSTEM_FILE="$CONFIG_DIR/ecosystem.config.js"

log() { echo -e "\n==> $*"; }
as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

install_timer() {
  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  log "Installing systemd service + timer for $script_path"
  cat > /etc/systemd/system/pirate-bootstrap-snapshot.service <<EOF
[Unit]
Description=Regenerate the Pirate bootstrap tarball from the dedicated bootstrap-source node

[Service]
Type=oneshot
Environment=INSTALL_DIR=$INSTALL_DIR
Environment=BOOTSTRAP_OUTPUT_DIR=$BOOTSTRAP_OUTPUT_DIR
Environment=BOOTSTRAP_NAME=$BOOTSTRAP_NAME
Environment=BOOTSTRAP_KEEP=$BOOTSTRAP_KEEP
ExecStart=$script_path
EOF

  cat > /etc/systemd/system/pirate-bootstrap-snapshot.timer <<EOF
[Unit]
Description=Daily Pirate bootstrap tarball refresh

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pirate-bootstrap-snapshot.timer
  log "Installed. Check status with: systemctl status pirate-bootstrap-snapshot.timer / journalctl -u pirate-bootstrap-snapshot.service"
}

if [[ "${1:-}" == "--install-timer" ]]; then
  install_timer
  exit 0
fi

if [[ ! -f "$BOOTSTRAP_CONF" ]]; then
  echo "$BOOTSTRAP_CONF doesn't exist - this host doesn't have a bootstrap-source node. Run deploy-seed-node.sh with ENABLE_BOOTSTRAP_NODE=1 first." >&2
  exit 1
fi

NVM_LOAD="export NVM_DIR=\"$TARGET_HOME/.nvm\"; source \"\$NVM_DIR/nvm.sh\"; nvm use $NODE_VERSION >/dev/null"
PIRATE_CLI="'$BIN_DIR/pirate-cli' -conf='$BOOTSTRAP_CONF' -datadir='$BOOTSTRAP_PIRATED_DATA_DIR'"

wait_for_rpc() {
  local ready=0
  for _ in $(seq 1 $((BOOTSTRAP_START_TIMEOUT / 5))); do
    if as_user "$PIRATE_CLI getinfo" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 5
  done
  [[ "$ready" -eq 1 ]]
}

# Runs once at exit, success or failure alike, so a bug partway through
# never leaves the bootstrap-source node down until someone notices.
restart_bootstrap_node() {
  log "Restarting bootstrap-node"
  as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only bootstrap-node" || true
  if ! wait_for_rpc; then
    echo "WARNING: bootstrap-source node's pirated RPC did not respond within ${BOOTSTRAP_START_TIMEOUT}s after restart. pm2 will keep retrying it." >&2
  fi
}
trap restart_bootstrap_node EXIT

log "Recording current height before stopping"
as_user "$PIRATE_CLI getblockcount" 2>/dev/null || echo "(RPC not responding - node may already be down)"

log "Stopping bootstrap-node cleanly"
as_user "$PIRATE_CLI stop" >/dev/null 2>&1 || true

STOPPED=0
for _ in $(seq 1 $((BOOTSTRAP_STOP_TIMEOUT / 2))); do
  if ! as_user "$PIRATE_CLI getinfo" >/dev/null 2>&1 \
     && ! pgrep -f "pirated .*-datadir=$BOOTSTRAP_PIRATED_DATA_DIR" >/dev/null 2>&1; then
    STOPPED=1
    break
  fi
  sleep 2
done

if [[ "$STOPPED" -ne 1 ]]; then
  echo "bootstrap-source node did not stop within ${BOOTSTRAP_STOP_TIMEOUT}s - aborting this snapshot without touching blocks/chainstate." >&2
  exit 1
fi

as_user "$NVM_LOAD; pm2 stop bootstrap-node" || true

log "Building tarball from blocks/+chainstate/"
STAGING_DIR="$BOOTSTRAP_OUTPUT_DIR/.tmp"
as_user "mkdir -p '$STAGING_DIR'"
TIMESTAMP="$(date -u +%Y%m%d)"
STAGED_TARBALL="$STAGING_DIR/$BOOTSTRAP_NAME-$TIMESTAMP.tar.gz"
as_user "tar -czf '$STAGED_TARBALL' -C '$BOOTSTRAP_PIRATED_DATA_DIR' blocks chainstate"

log "Computing sha256"
STAGED_HASH="$STAGED_TARBALL.sha256"
as_user "sha256sum '$STAGED_TARBALL' | awk '{print \$1}' > '$STAGED_HASH'"

log "Publishing (hardlink for the dated copy, atomic rename for the canonical name - both share the same disk blocks, no double the space used)"
PUBLISHED_TARBALL="$BOOTSTRAP_OUTPUT_DIR/$BOOTSTRAP_NAME-v2.tar.gz"
PUBLISHED_HASH="$PUBLISHED_TARBALL.sha256"
DATED_TARBALL="$BOOTSTRAP_OUTPUT_DIR/$BOOTSTRAP_NAME-$TIMESTAMP.tar.gz"
DATED_HASH="$DATED_TARBALL.sha256"
as_user "ln -f '$STAGED_TARBALL' '$DATED_TARBALL'"
as_user "ln -f '$STAGED_HASH' '$DATED_HASH'"
as_user "mv -f '$STAGED_TARBALL' '$PUBLISHED_TARBALL'"
as_user "mv -f '$STAGED_HASH' '$PUBLISHED_HASH'"

log "Pruning dated snapshots beyond BOOTSTRAP_KEEP=$BOOTSTRAP_KEEP"
as_user "ls -1t '$BOOTSTRAP_OUTPUT_DIR/$BOOTSTRAP_NAME'-[0-9]*.tar.gz 2>/dev/null | tail -n +\$(($BOOTSTRAP_KEEP + 1)) | while read -r f; do rm -f \"\$f\" \"\$f.sha256\"; done"

log "Snapshot published to $PUBLISHED_TARBALL - bootstrap-node restart happens via the exit trap"
