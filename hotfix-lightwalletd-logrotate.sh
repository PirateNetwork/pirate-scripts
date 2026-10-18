#!/usr/bin/env bash
#
# hotfix-lightwalletd-logrotate.sh - one-time remediation for a seed node
# already deployed by deploy-seed-node.sh before it installed a logrotate
# config for lightwalletd's own log file(s).
#
# Root cause being fixed here: lightwalletd writes directly to its
# --log-file via a plain O_APPEND handle and never reopens it (no
# SIGHUP/log-reopen support). pm2-logrotate only rotates pm2's own captured
# stdout/stderr, not a file the child process opened itself - so
# server.log grows forever until disk fills. deploy-seed-node.sh was
# already fixed to install an OS-level logrotate config on fresh deploys -
# this script only needs to run once per already-deployed host to catch
# it up.
#
# What it does, in order:
#   1. Installs /etc/logrotate.d/pirate-lightwalletd, covering the live
#      lightwalletd's server.log and the test node's, if deployed. Uses
#      copytruncate, not a rename+create rotation: since lightwalletd
#      never reopens its log handle, a renamed/recreated file wouldn't
#      help - lightwalletd would just keep appending to the same inode
#      under its new name, and the live path would stay empty forever.
#      copytruncate truncates the file lightwalletd already has open, in
#      place, so it keeps writing to the same path from offset 0.
#   2. Forces an immediate rotation, since the whole point of running this
#      is reclaiming disk now, not waiting for logrotate's next scheduled
#      cron.daily pass.
#
# Usage:
#   sudo ./hotfix-lightwalletd-logrotate.sh
#
# Overridable via environment variables (same meaning/defaults as
# deploy-seed-node.sh):
#   INSTALL_DIR      Must match the deploy-seed-node.sh install (default: ~<user>/pirateseednode)
#   ENABLE_TESTNODE  Set to 1 if this host also runs lightwalletd-test (default: auto-detected)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script writes to /etc/logrotate.d and must be run as root (sudo)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_GROUP=$(id -gn "$TARGET_USER")

INSTALL_DIR="${INSTALL_DIR:-$TARGET_HOME/pirateseednode}"
DATA_DIR="$INSTALL_DIR/data"
LWD_DATA_DIR="$DATA_DIR/lightwalletd"
TESTNODE_LWD_DATA_DIR="$DATA_DIR/lightwalletd-test"

log() { echo -e "\n==> $*"; }

if [[ ! -d "$LWD_DATA_DIR" ]]; then
  echo "$LWD_DATA_DIR doesn't exist - check INSTALL_DIR ($INSTALL_DIR)." >&2
  exit 1
fi

if [[ -z "${ENABLE_TESTNODE:-}" ]]; then
  if [[ -d "$TESTNODE_LWD_DATA_DIR" ]]; then
    ENABLE_TESTNODE=1
  else
    ENABLE_TESTNODE=0
  fi
fi

log "Installing /etc/logrotate.d/pirate-lightwalletd"
# su is required, not cosmetic: $LWD_DATA_DIR is owned/writable by
# $TARGET_USER (pirated/lightwalletd run as that user, not root), so
# logrotate - invoked as root via cron - refuses to touch anything under it
# as an insecure-permissions safety check unless told whose UID/GID to
# assume for the actual rotation.
LWD_LOGROTATE_STANZA="su $TARGET_USER $TARGET_GROUP
$LWD_DATA_DIR/server.log {
  size 100M
  rotate 5
  compress
  missingok
  notifempty
  copytruncate
}"
if [[ "$ENABLE_TESTNODE" == "1" ]]; then
  LWD_LOGROTATE_STANZA="$LWD_LOGROTATE_STANZA
$TESTNODE_LWD_DATA_DIR/server.log {
  size 100M
  rotate 5
  compress
  missingok
  notifempty
  copytruncate
}"
fi
cat > /etc/logrotate.d/pirate-lightwalletd <<EOF
$LWD_LOGROTATE_STANZA
EOF

log "Forcing an immediate rotation to reclaim disk now"
logrotate -f /etc/logrotate.d/pirate-lightwalletd

log "Hotfix applied. $(du -h "$LWD_DATA_DIR/server.log" 2>/dev/null | cut -f1) now in the live server.log; old content moved to server.log.1.gz."
