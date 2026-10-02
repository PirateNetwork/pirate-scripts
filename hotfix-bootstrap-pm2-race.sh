#!/usr/bin/env bash
#
# hotfix-bootstrap-pm2-race.sh - one-time remediation for a bootstrap-source
# node already deployed by deploy-seed-node.sh with ENABLE_BOOTSTRAP_NODE=1,
# predating the fix that reordered bootstrap-snapshot.sh's stop sequence.
#
# Root cause being fixed here: bootstrap-snapshot.sh used to call
# `pirate-cli stop`, wait for the process to exit, and only then call
# `pm2 stop bootstrap-node`. Since the bootstrap-node pm2 app has
# autorestart:true, there was a window after the daemon exited but before
# pm2 was told to stop where pm2 could respawn a fresh pirated against the
# same datadir - which then started writing to blocks/+chainstate/ while
# this script was mid-tar, producing an internally inconsistent published
# tarball (surfaces for clients as "ReadBlockFromDisk ... GetHash() doesn't
# match index"). bootstrap-snapshot.sh and deploy-seed-node.sh were already
# fixed in this checkout (pm2 stop now runs first, and the bootstrap-node
# pm2 app gets a generous kill_timeout so pm2's own kill signal can't
# truncate the graceful shutdown) - this script only needs to run once per
# already-deployed host to catch it up, since a fresh deploy-seed-node.sh
# run would already have the fix baked in.
#
# What it does, in order:
#   1. Pulls this checkout of pirate-scripts to pick up the fixed scripts
#      (skipped with a warning if this directory isn't a git checkout).
#   2. Patches the bootstrap-node app already in ecosystem.config.js to add
#      kill_timeout, leaving every other app and field untouched.
#   3. Deletes and re-registers just the bootstrap-node pm2 entry so the
#      new kill_timeout actually takes effect (a plain `pm2 restart`
#      wouldn't re-read it) and persists the process list.
#   4. Runs bootstrap-snapshot.sh once immediately, since whatever tarball
#      is currently published may have been built during the race and
#      needs replacing - not just relying on next week's timer.
#
# Usage:
#   sudo ./hotfix-bootstrap-pm2-race.sh
#
# Overridable via environment variables (same meaning/defaults as
# deploy-seed-node.sh/bootstrap-snapshot.sh):
#   INSTALL_DIR   Must match the deploy-seed-node.sh install (default: ~<user>/pirateseednode)
#   NODE_VERSION  Node.js version already installed via nvm (default: 24.19.0)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script manages another user's pm2 processes and must be run as root (sudo)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

INSTALL_DIR="${INSTALL_DIR:-$TARGET_HOME/pirateseednode}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
CONFIG_DIR="$INSTALL_DIR/config"
ECOSYSTEM_FILE="$CONFIG_DIR/ecosystem.config.js"
BOOTSTRAP_CONF="$INSTALL_DIR/data/pirated-bootstrap/PIRATE.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo -e "\n==> $*"; }
as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

if [[ ! -f "$BOOTSTRAP_CONF" ]]; then
  echo "$BOOTSTRAP_CONF doesn't exist - this host has no bootstrap-source node (ENABLE_BOOTSTRAP_NODE=1 was never deployed here). Nothing to do." >&2
  exit 1
fi

if [[ ! -f "$ECOSYSTEM_FILE" ]]; then
  echo "$ECOSYSTEM_FILE not found - check INSTALL_DIR ($INSTALL_DIR)." >&2
  exit 1
fi

if [[ -d "$SCRIPT_DIR/.git" ]]; then
  log "Pulling latest pirate-scripts in $SCRIPT_DIR"
  git -C "$SCRIPT_DIR" pull
else
  echo "WARNING: $SCRIPT_DIR isn't a git checkout - skipping pull. Make sure bootstrap-snapshot.sh and this script are already up to date on this host." >&2
fi

NVM_LOAD="export NVM_DIR=\"$TARGET_HOME/.nvm\"; source \"\$NVM_DIR/nvm.sh\"; nvm use $NODE_VERSION >/dev/null"

log "Adding kill_timeout to the bootstrap-node app in $ECOSYSTEM_FILE"
as_user "$NVM_LOAD; node -e \"
  const fs = require('fs');
  const p = '$ECOSYSTEM_FILE';
  const cfg = require(p);
  const app = cfg.apps.find(a => a.name === 'bootstrap-node');
  if (!app) { console.error('bootstrap-node app not found in ecosystem.config.js'); process.exit(1); }
  app.kill_timeout = 600000;
  fs.writeFileSync(p, 'module.exports = ' + JSON.stringify(cfg, null, 2) + ';\n');
\""

log "Recreating the bootstrap-node pm2 entry so it picks up the new config"
as_user "$NVM_LOAD; pm2 delete bootstrap-node" || true
as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only bootstrap-node"
as_user "$NVM_LOAD; pm2 save"

log "Running bootstrap-snapshot.sh now to replace any tarball published during the race"
"$SCRIPT_DIR/bootstrap-snapshot.sh"

log "Hotfix applied."
