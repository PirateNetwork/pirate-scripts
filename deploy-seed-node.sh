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
#   build/         TreasureChest, lightwalletd, and (if enabled) pirate-seeder
#                  source checkouts + compiled artifacts. Pull + rebuild here
#                  to update.
#   bin/           stable symlinks (pirated, pirate-cli, lightwalletd,
#                  pirate-seeder) that config files and pm2 point at, so
#                  updating build/ doesn't require touching config. Also
#                  where pirated-testnode (see "Optional test node" below)
#                  lives, when enabled.
#   bitcore-node/  the `bitcore-node create` scaffold: bitcore-node.json,
#                  package.json, and node_modules (bitcore-node-pirate,
#                  bitcore-lib-pirate, insight-api-pirate, insight-ui-pirate,
#                  all pulled via git with `bitcore-node install`).
#   bitcore-node-test/  the same, for the optional test node's bitcore-node
#                  instance - only created when ENABLE_TESTNODE=1.
#   data/          PIRATE.conf, chain data, lightwalletd cache - the only
#                  directory that needs to persist/be backed up. Holds
#                  pirated-test/ and lightwalletd-test/ subdirectories too
#                  when ENABLE_TESTNODE=1.
#
# bitcore-node-pirate itself is installed globally via npm from git (not
# cloned/built), matching how its own CLI is meant to be used: `npm install
# -g` gets you the `bitcore-node` command, then `bitcore-node create` scaffolds
# the actual instance directory.
#
# Overridable via environment variables:
#   INSTALL_DIR      Base directory for everything this script builds (default: ~<user>/pirateseednode)
#   NODE_VERSION     Node.js version installed via nvm (default: 24.19.0)
#   PIRATE_BRANCH    Branch for TreasureChest (default: master)
#   BITCORE_BRANCH   Branch for the bitcore-node-pirate/bitcore-lib-pirate/
#                     insight-api-pirate/insight-ui-pirate npm installs (default: master)
#   LWD_BRANCH       Branch to check out for lightwalletd (default: master)
#   MAKE_JOBS        Parallelism for TreasureChest's build (default: nproc)
#   NETWORK          livenet | testnet (default: livenet)
#   P2P_PORT         pirated's actual P2P port to open in the firewall (default:
#                     45452, mainnet). Pirate is built on Komodo's asset-chain
#                     framework, which derives the real P2P port (and the wire
#                     magic bytes) from a hash of fixed chain parameters at
#                     startup - NOT the commonly-quoted 7770 from chainparams.cpp's
#                     static defaults, which is dead code for this build. pirated
#                     logs the actual value once on startup (grep its own log for
#                     ">>>>>>>>>>"); confirmed 45452 on mainnet 2026-08-10, but
#                     testnet's value is unverified - override this if NETWORK=testnet.
#   RPC_PORT         pirated RPC port (default: 45453) - unaffected by the above,
#                     since this is explicitly set via PIRATE.conf's rpcport=
#                     rather than left to the same asset-chain auto-derivation.
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
#   DNSSEED_HOST     Hostname wallets/nodes will query, e.g. dnsseed.example.com.
#                     Setting this (together with DNSSEED_NS/DNSSEED_MBOX) builds
#                     and runs pirate-seeder - see "DNS seeder" below. Requires
#                     that hostname already delegated (NS record) to this VPS;
#                     leave unset to skip the DNS seeder entirely.
#   DNSSEED_NS       Nameserver hostname identifying this VPS, e.g.
#                     ns-dnsseed.example.com. Required together with DNSSEED_HOST.
#   DNSSEED_MBOX     Contact e-mail for SOA records, '@' replaced by '.'
#                     (e.g. admin.example.com). Required together with DNSSEED_HOST.
#   DNSSEED_PORT     UDP port for the DNS seeder (default: 53)
#   DNSSEED_BRANCH   Branch to check out for pirate-seeder (default: main)
#   DNSSEED_TOR_PROXY Optional ip:port of a SOCKS5 proxy (e.g. a separately-run
#                     system Tor) so the seeder can also crawl Tor peers
#   ENABLE_TESTNODE  Set to 1 to also stand up a second, independent pirated
#                     + bitcore-node + lightwalletd stack for testing, on its
#                     own asset chain - see "Optional test node" below.
#                     Requires TESTNODE_DOMAIN_NAME, TESTNODE_LWD_DOMAIN_NAME,
#                     and CERTBOT_EMAIL (or TESTNODE_CERTBOT_EMAIL) together.
#   TESTNODE_AC_NAME  Asset chain name for the test node, passed as pirated's
#                     -ac_name (default: PIRATETST). Also used for pm2/nginx
#                     labels. NOT used as this node's conf filename - see
#                     TESTNODE_CONF below for why it has to stay PIRATE.conf.
#   TESTNODE_AC_IRONWOOD Block height pirated's -ac_ironwood activates the
#                     Ironwood upgrade at on the test chain (default: 297).
#                     Unset on the live node's chain (real Pirate mainnet
#                     activation), so a low value here is what makes this a
#                     useful fast-forwarded testbed for Ironwood-era work.
#   TESTNODE_PIRATED_EXTRA_ARGS Any further -ac_* (or other) flags to pass
#                     the test node's pirated, beyond -ac_name/-ac_ironwood
#                     above (default: none)
#   TESTNODE_RPC_PORT   Test node's pirated RPC port (default: 45463)
#   TESTNODE_ZMQ_PORT   Test node's pirated zmqpub port (default: 28342)
#   TESTNODE_BITCORE_PORT Test node's bitcore-node web API port (default: 3002)
#   TESTNODE_LWD_GRPC_BIND Test node's lightwalletd gRPC bind (default:
#                     127.0.0.1:9077, matching DOMAIN_NAME's loopback-binding
#                     behavior since TESTNODE_DOMAIN_NAME is required)
#   TESTNODE_LWD_HTTP_BIND Test node's lightwalletd HTTP bind (default: 127.0.0.1:9078)
#   TESTNODE_DOMAIN_NAME Hostname for the test node's Insight UI/API. Required
#                     together with TESTNODE_LWD_DOMAIN_NAME if ENABLE_TESTNODE=1
#                     - unlike the live node's DOMAIN_NAME, this isn't optional,
#                     since the test node's whole point includes its own
#                     cert-backed endpoints.
#   TESTNODE_LWD_DOMAIN_NAME Hostname for the test node's lightwalletd gRPC service.
#   TESTNODE_CERTBOT_EMAIL Contact address for the test node's Let's Encrypt
#                     cert (default: $CERTBOT_EMAIL)
#   ENABLE_BOOTSTRAP_NODE Set to 1 to stand up a third, independent pirated
#                     instance whose only job is holding synced chain data
#                     for a bootstrap-snapshot.sh timer to tar up - see
#                     "Bootstrap-source node" below. Decoupled from the live
#                     node/bitcore/lightwalletd so a daily snapshot never
#                     causes production downtime.
#   BOOTSTRAP_RPC_PORT Bootstrap-source node's pirated RPC port (default:
#                     45483)
#   BOOTSTRAP_LISTEN  Set to 1 to let the bootstrap-source node accept
#                     inbound P2P (default: 0, outbound-only). Only turn
#                     this on if nothing else on this host is already
#                     listening on this chain's P2P port (Pirate's real
#                     port is asset-chain-derived, not independently
#                     configurable per instance - see P2P_PORT above - so a
#                     second listening mainnet instance on the SAME host as
#                     the live node WILL conflict with it).
#   BOOTSTRAP_OUTPUT_DIR Where bootstrap-snapshot.sh publishes the tarball +
#                     sha256 (default: $INSTALL_DIR/bootstrap-www)
#   BOOTSTRAP_DOMAIN_NAME Hostname for serving $BOOTSTRAP_OUTPUT_DIR over
#                     HTTPS (e.g. bootstrap1.cryptoforge.cc) - requires
#                     ENABLE_BOOTSTRAP_NODE=1 and CERTBOT_EMAIL. Leave unset
#                     to provision the bootstrap-source node without nginx/
#                     a public endpoint (e.g. if something else serves
#                     $BOOTSTRAP_OUTPUT_DIR, or it's rsynced elsewhere).
#
# nginx + real TLS (when DOMAIN_NAME/LWD_DOMAIN_NAME,
# TESTNODE_DOMAIN_NAME/TESTNODE_LWD_DOMAIN_NAME, and/or
# BOOTSTRAP_DOMAIN_NAME, are set):
#   lightwalletd and bitcore-node's web service bind to 127.0.0.1 only
#   (bitcore-node's web service can't be told to bind a specific host, so a
#   ufw rule blocks external access to it instead, when ufw is already active).
#   Each pair (live, and test if enabled) gets its own certbot cert (one SAN
#   cert per pair, one renewal entry) - not a single cert shared across both,
#   since they're independent stacks. nginx terminates TLS on :443 with one
#   server block per hostname: DOMAIN_NAME/TESTNODE_DOMAIN_NAME proxy to their
#   bitcore-node's web port (Insight UI + insight-api-pirate), LWD_DOMAIN_NAME/
#   TESTNODE_LWD_DOMAIN_NAME grpc_pass to their lightwalletd.
#
# Optional test node (when ENABLE_TESTNODE=1):
#   A second, fully independent pirated + bitcore-node + lightwalletd stack,
#   for testing against a private asset chain (TESTNODE_AC_NAME, default
#   PIRATETST) rather than real Pirate mainnet - useful for exercising
#   in-development consensus changes (e.g. Ironwood) without touching the
#   live chain. It reuses the same pirated/bitcore-node-pirate/lightwalletd
#   binaries the live node already built (asset chains are just runtime
#   flags to the same daemon, not a separate build), with its own data
#   directories, ports, credentials, and domain-backed TLS.
#   Since bitcore-node's spawn config has no field for extra CLI flags (only
#   an exec path + datadir), the test node's pirated isn't spawned directly -
#   bitcore-node's spawn.exec instead points at bin/pirated-testnode, a small
#   wrapper this script generates that execs the real pirated with
#   -ac_name/-ac_ironwood (and TESTNODE_PIRATED_EXTRA_ARGS, if set) prepended
#   to whatever args bitcore-node itself passes (-datadir, etc.). Regenerated
#   on every run so config changes take effect on next restart.
#
# DNS seeder (when DNSSEED_HOST is set):
#   pirate-seeder crawls the P2P network independently of pirated/bitcore and
#   answers DNS queries for DNSSEED_HOST with currently-good peers. It needs
#   to bind a privileged UDP port (53 by default) - rather than run it as
#   root, this script grants the built binary CAP_NET_BIND_SERVICE via
#   setcap, so pm2 can still run it as the same unprivileged user as
#   everything else. It auto-discovers this node's own I2P SAM bridge from
#   PIRATE.conf's -i2psam (not set by this script by default - I2P peers are
#   simply skipped until it is), and can crawl Tor peers via DNSSEED_TOR_PROXY.
#   The DNS delegation itself (an A + NS record at your DNS provider) has to
#   be done by hand beforehand - see pirate-seeder/README.md.
#
# Bootstrap-source node (when ENABLE_BOOTSTRAP_NODE=1):
#   A third, independent pirated instance (pm2 process "bootstrap-node"),
#   own datadir/conf/RPC port, default indexes (no addressindex/
#   timestampindex/spentindex - nothing queries this instance besides
#   bootstrap-snapshot.sh and the P2P network it syncs from), embedded Tor/
#   I2P disabled (torautostart=0, i2pdautostart=0), outbound-only by default
#   (listen=0, see BOOTSTRAP_LISTEN above). Run pirate-scripts/
#   bootstrap-snapshot.sh (separately, e.g. on a daily systemd timer via
#   its own --install-timer) to stop/tar/restart this instance and publish
#   a fresh blocks+chainstate tarball - the live node/bitcore/lightwalletd
#   are never touched by that process. Set BOOTSTRAP_DOMAIN_NAME to also
#   have this script front $BOOTSTRAP_OUTPUT_DIR with nginx + a real
#   Let's Encrypt cert.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script installs system packages and must be run as root (sudo)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

INSTALL_DIR="${INSTALL_DIR:-$TARGET_HOME/pirateseednode}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
PIRATE_BRANCH="${PIRATE_BRANCH:-master}"
BITCORE_BRANCH="${BITCORE_BRANCH:-master}"
LWD_BRANCH="${LWD_BRANCH:-master}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
NETWORK="${NETWORK:-livenet}"
P2P_PORT="${P2P_PORT:-45452}"
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
DNSSEED_HOST="${DNSSEED_HOST:-}"
DNSSEED_NS="${DNSSEED_NS:-}"
DNSSEED_MBOX="${DNSSEED_MBOX:-}"
DNSSEED_PORT="${DNSSEED_PORT:-53}"
DNSSEED_BRANCH="${DNSSEED_BRANCH:-main}"
DNSSEED_TOR_PROXY="${DNSSEED_TOR_PROXY:-}"
ENABLE_TESTNODE="${ENABLE_TESTNODE:-0}"
TESTNODE_AC_NAME="${TESTNODE_AC_NAME:-PIRATETST}"
TESTNODE_AC_IRONWOOD="${TESTNODE_AC_IRONWOOD:-297}"
TESTNODE_PIRATED_EXTRA_ARGS="${TESTNODE_PIRATED_EXTRA_ARGS:-}"
TESTNODE_RPC_PORT="${TESTNODE_RPC_PORT:-45463}"
TESTNODE_ZMQ_PORT="${TESTNODE_ZMQ_PORT:-28342}"
TESTNODE_BITCORE_PORT="${TESTNODE_BITCORE_PORT:-3002}"
TESTNODE_LWD_GRPC_BIND="${TESTNODE_LWD_GRPC_BIND:-127.0.0.1:9077}"
TESTNODE_LWD_HTTP_BIND="${TESTNODE_LWD_HTTP_BIND:-127.0.0.1:9078}"
TESTNODE_DOMAIN_NAME="${TESTNODE_DOMAIN_NAME:-}"
TESTNODE_LWD_DOMAIN_NAME="${TESTNODE_LWD_DOMAIN_NAME:-}"
TESTNODE_CERTBOT_EMAIL="${TESTNODE_CERTBOT_EMAIL:-$CERTBOT_EMAIL}"
ENABLE_BOOTSTRAP_NODE="${ENABLE_BOOTSTRAP_NODE:-0}"
BOOTSTRAP_RPC_PORT="${BOOTSTRAP_RPC_PORT:-45483}"
BOOTSTRAP_LISTEN="${BOOTSTRAP_LISTEN:-0}"
BOOTSTRAP_DOMAIN_NAME="${BOOTSTRAP_DOMAIN_NAME:-}"

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

if [[ -n "$DNSSEED_HOST" || -n "$DNSSEED_NS" || -n "$DNSSEED_MBOX" ]]; then
  if [[ -z "$DNSSEED_HOST" || -z "$DNSSEED_NS" || -z "$DNSSEED_MBOX" ]]; then
    echo "DNSSEED_HOST, DNSSEED_NS, and DNSSEED_MBOX must all be set together to run the DNS seeder." >&2
    exit 1
  fi
fi

if [[ "$ENABLE_TESTNODE" == "1" ]]; then
  if [[ -z "$TESTNODE_DOMAIN_NAME" || -z "$TESTNODE_LWD_DOMAIN_NAME" ]]; then
    echo "ENABLE_TESTNODE=1 requires TESTNODE_DOMAIN_NAME and TESTNODE_LWD_DOMAIN_NAME (the test node's own cert-backed hostnames)." >&2
    exit 1
  fi
  if [[ -z "$TESTNODE_CERTBOT_EMAIL" ]]; then
    echo "ENABLE_TESTNODE=1 requires CERTBOT_EMAIL or TESTNODE_CERTBOT_EMAIL, so Let's Encrypt can reach you about renewal problems." >&2
    exit 1
  fi
fi

if [[ -n "$BOOTSTRAP_DOMAIN_NAME" ]]; then
  if [[ "$ENABLE_BOOTSTRAP_NODE" != "1" ]]; then
    echo "BOOTSTRAP_DOMAIN_NAME requires ENABLE_BOOTSTRAP_NODE=1 - no point provisioning a domain for a snapshot directory nothing ever populates." >&2
    exit 1
  fi
  if [[ -z "$CERTBOT_EMAIL" ]]; then
    echo "BOOTSTRAP_DOMAIN_NAME is set but CERTBOT_EMAIL is not. Set CERTBOT_EMAIL so Let's Encrypt can reach you about renewal problems." >&2
    exit 1
  fi
fi

BUILD_DIR="$INSTALL_DIR/build"
BIN_DIR="$INSTALL_DIR/bin"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DIR="$INSTALL_DIR/config"
BITCORE_NODE_DIR="$INSTALL_DIR/bitcore-node"
TESTNODE_BITCORE_NODE_DIR="$INSTALL_DIR/bitcore-node-test"

TREASURECHEST_DIR="$BUILD_DIR/TreasureChest"
TREASURECHEST_ARTIFACTS_BIN="$TREASURECHEST_DIR/artifacts/bin"
LWD_BUILD_DIR="$BUILD_DIR/lightwalletd"
PIRATE_SEEDER_DIR="$BUILD_DIR/pirate-seeder"

PIRATED_DATA_DIR="$DATA_DIR/pirated"
LWD_DATA_DIR="$DATA_DIR/lightwalletd"
PIRATE_SEEDER_DATA_DIR="$DATA_DIR/pirate-seeder"
PIRATE_CONF="$PIRATED_DATA_DIR/PIRATE.conf"

TESTNODE_PIRATED_DATA_DIR="$DATA_DIR/pirated-test"
TESTNODE_LWD_DATA_DIR="$DATA_DIR/lightwalletd-test"
# Must be named exactly PIRATE.conf, not "$TESTNODE_AC_NAME.conf" - pirated
# itself doesn't care (the wrapper script below passes -conf explicitly, so
# pirated's own <datadir>/<ac_name>.conf discovery is moot), but
# bitcore-node-pirate's bitcoind service hardcodes
# `path.resolve(spawn.datadir, './PIRATE.conf')` (lib/services/bitcoind.js)
# with no awareness of -ac_name at all. If this file were named anything
# else, bitcore-node-pirate would silently auto-create its own PIRATE.conf
# here with hardcoded default credentials (rpcuser=bitcoin/rpcpassword=
# local321) that don't match what pirated was actually launched with,
# and it would never successfully authenticate to its own pirated.
TESTNODE_CONF="$TESTNODE_PIRATED_DATA_DIR/PIRATE.conf"

BOOTSTRAP_PIRATED_DATA_DIR="$DATA_DIR/pirated-bootstrap"
BOOTSTRAP_CONF="$BOOTSTRAP_PIRATED_DATA_DIR/PIRATE.conf"
BOOTSTRAP_OUTPUT_DIR="${BOOTSTRAP_OUTPUT_DIR:-$INSTALL_DIR/bootstrap-www}"

BITCORE_NODE_JSON="$BITCORE_NODE_DIR/bitcore-node.json"
TESTNODE_BITCORE_NODE_JSON="$TESTNODE_BITCORE_NODE_DIR/bitcore-node.json"
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

if [[ -n "$DOMAIN_NAME" || -n "$TESTNODE_DOMAIN_NAME" || -n "$BOOTSTRAP_DOMAIN_NAME" ]]; then
  apt-get install -y nginx certbot python3-certbot-nginx
fi

if [[ -n "$DNSSEED_HOST" ]]; then
  # TreasureChest vendors its own OpenSSL via ./depends, but pirate-seeder
  # links the system one directly, plus libevent for its crawler/DNS server.
  apt-get install -y libssl-dev libevent-dev libcap2-bin
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
if [[ "$ENABLE_TESTNODE" == "1" ]]; then
  as_user "mkdir -p '$TESTNODE_PIRATED_DATA_DIR' '$TESTNODE_LWD_DATA_DIR'"
fi
if [[ "$ENABLE_BOOTSTRAP_NODE" == "1" ]]; then
  as_user "mkdir -p '$BOOTSTRAP_PIRATED_DATA_DIR'"
  if [[ -n "$BOOTSTRAP_DOMAIN_NAME" ]]; then
    as_user "mkdir -p '$BOOTSTRAP_OUTPUT_DIR'"
  fi
fi
# $BITCORE_NODE_DIR/$TESTNODE_BITCORE_NODE_DIR are intentionally not created
# here - `bitcore-node create` below refuses to run if its target directory
# already exists.

open_firewall_port "$P2P_PORT/tcp"

if [[ -n "$DNSSEED_HOST" ]]; then
  open_firewall_port "$DNSSEED_PORT/udp"
fi

# BOOTSTRAP_LISTEN=1 uses this same $P2P_PORT (Pirate's real P2P port is
# asset-chain-derived, not independently settable per instance - see
# P2P_PORT above), already opened unconditionally right above; nothing
# further to open here, just note two listening mainnet instances on the
# same host WILL conflict binding it.

if [[ -n "$DOMAIN_NAME" || -n "$TESTNODE_DOMAIN_NAME" || -n "$BOOTSTRAP_DOMAIN_NAME" ]]; then
  open_firewall_port 80/tcp
  open_firewall_port 443/tcp
  # bitcore-node's web service always binds all interfaces (no host option),
  # so it can't be restricted to loopback like lightwalletd - block it at the
  # firewall instead. lightwalletd's own ports already default to loopback
  # above when DOMAIN_NAME/TESTNODE_DOMAIN_NAME are set, but deny them too as
  # defense in depth.
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    if [[ -n "$DOMAIN_NAME" ]]; then
      ufw deny "$BITCORE_PORT/tcp" >/dev/null
      ufw deny "${LWD_GRPC_BIND##*:}/tcp" >/dev/null
      ufw deny "${LWD_HTTP_BIND##*:}/tcp" >/dev/null
    fi
    if [[ -n "$TESTNODE_DOMAIN_NAME" ]]; then
      ufw deny "$TESTNODE_BITCORE_PORT/tcp" >/dev/null
      ufw deny "${TESTNODE_LWD_GRPC_BIND##*:}/tcp" >/dev/null
      ufw deny "${TESTNODE_LWD_HTTP_BIND##*:}/tcp" >/dev/null
    fi
  fi

  WEBROOT_DIR=/var/www/certbot
  mkdir -p "$WEBROOT_DIR"
  NGINX_SITE=/etc/nginx/sites-available/pirate-seed-node
  LWD_GRPC_PORT="${LWD_GRPC_BIND##*:}"
  TESTNODE_LWD_GRPC_PORT="${TESTNODE_LWD_GRPC_BIND##*:}"

  ALL_HOSTNAMES=""
  [[ -n "$DOMAIN_NAME" ]] && ALL_HOSTNAMES="$ALL_HOSTNAMES $DOMAIN_NAME $LWD_DOMAIN_NAME"
  [[ -n "$TESTNODE_DOMAIN_NAME" ]] && ALL_HOSTNAMES="$ALL_HOSTNAMES $TESTNODE_DOMAIN_NAME $TESTNODE_LWD_DOMAIN_NAME"
  [[ -n "$BOOTSTRAP_DOMAIN_NAME" ]] && ALL_HOSTNAMES="$ALL_HOSTNAMES $BOOTSTRAP_DOMAIN_NAME"
  ALL_HOSTNAMES="${ALL_HOSTNAMES# }"

  log "Writing initial nginx config for$ALL_HOSTNAMES (HTTP only, for the ACME challenge)"
  cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $ALL_HOSTNAMES;

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
  systemctl enable nginx >/dev/null 2>&1 || true
  # `enable --now`/`start` are no-ops on an already-running nginx, which would
  # silently leave the OLD config (e.g. the default site) loaded - reload if
  # it's already up, start it only if it genuinely isn't.
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl start nginx
  fi

  # Each pair gets its own cert/renewal entry - independent stacks, not one
  # shared SAN cert across live+test.
  if [[ -n "$DOMAIN_NAME" ]]; then
    CERT_DIR="/etc/letsencrypt/live/$DOMAIN_NAME"
    if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
      log "Obtaining Let's Encrypt certificate for $DOMAIN_NAME + $LWD_DOMAIN_NAME"
      certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN_NAME" -d "$LWD_DOMAIN_NAME" \
        --non-interactive --agree-tos -m "$CERTBOT_EMAIL"
    else
      log "Certificate covering $DOMAIN_NAME/$LWD_DOMAIN_NAME already exists, skipping issuance"
    fi
  fi
  if [[ -n "$TESTNODE_DOMAIN_NAME" ]]; then
    TESTNODE_CERT_DIR="/etc/letsencrypt/live/$TESTNODE_DOMAIN_NAME"
    if [[ ! -f "$TESTNODE_CERT_DIR/fullchain.pem" ]]; then
      log "Obtaining Let's Encrypt certificate for $TESTNODE_DOMAIN_NAME + $TESTNODE_LWD_DOMAIN_NAME"
      certbot certonly --webroot -w "$WEBROOT_DIR" -d "$TESTNODE_DOMAIN_NAME" -d "$TESTNODE_LWD_DOMAIN_NAME" \
        --non-interactive --agree-tos -m "$TESTNODE_CERTBOT_EMAIL"
    else
      log "Certificate covering $TESTNODE_DOMAIN_NAME/$TESTNODE_LWD_DOMAIN_NAME already exists, skipping issuance"
    fi
  fi
  if [[ -n "$BOOTSTRAP_DOMAIN_NAME" ]]; then
    BOOTSTRAP_CERT_DIR="/etc/letsencrypt/live/$BOOTSTRAP_DOMAIN_NAME"
    if [[ ! -f "$BOOTSTRAP_CERT_DIR/fullchain.pem" ]]; then
      log "Obtaining Let's Encrypt certificate for $BOOTSTRAP_DOMAIN_NAME"
      certbot certonly --webroot -w "$WEBROOT_DIR" -d "$BOOTSTRAP_DOMAIN_NAME" \
        --non-interactive --agree-tos -m "$CERTBOT_EMAIL"
    else
      log "Certificate covering $BOOTSTRAP_DOMAIN_NAME already exists, skipping issuance"
    fi

    # nginx (typically www-data) needs traversal permission on every
    # directory in the path down to $BOOTSTRAP_OUTPUT_DIR, which otherwise
    # sits under $TARGET_USER's home dir - home directories commonly default
    # to not being world-traversable.
    chmod o+rx "$TARGET_HOME" "$INSTALL_DIR" "$BOOTSTRAP_OUTPUT_DIR"
  fi

  LIVE_TLS_BLOCKS=""
  if [[ -n "$DOMAIN_NAME" ]]; then
    LIVE_TLS_BLOCKS=$(cat <<EOF

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
)
  fi

  TEST_TLS_BLOCKS=""
  if [[ -n "$TESTNODE_DOMAIN_NAME" ]]; then
    TEST_TLS_BLOCKS=$(cat <<EOF

# Test node ($TESTNODE_AC_NAME): Insight UI + insight-api-pirate
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $TESTNODE_DOMAIN_NAME;

    ssl_certificate     $TESTNODE_CERT_DIR/fullchain.pem;
    ssl_certificate_key $TESTNODE_CERT_DIR/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$TESTNODE_BITCORE_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# Test node ($TESTNODE_AC_NAME): lightwalletd's gRPC service
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $TESTNODE_LWD_DOMAIN_NAME;

    ssl_certificate     $TESTNODE_CERT_DIR/fullchain.pem;
    ssl_certificate_key $TESTNODE_CERT_DIR/privkey.pem;

    location / {
        grpc_pass grpc://127.0.0.1:$TESTNODE_LWD_GRPC_PORT;
    }
}
EOF
)
  fi

  BOOTSTRAP_TLS_BLOCKS=""
  if [[ -n "$BOOTSTRAP_DOMAIN_NAME" ]]; then
    BOOTSTRAP_TLS_BLOCKS=$(cat <<EOF

# Bootstrap-source node: serves \$BOOTSTRAP_OUTPUT_DIR (tarball + sha256),
# refreshed by pirate-scripts/bootstrap-snapshot.sh
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $BOOTSTRAP_DOMAIN_NAME;

    ssl_certificate     $BOOTSTRAP_CERT_DIR/fullchain.pem;
    ssl_certificate_key $BOOTSTRAP_CERT_DIR/privkey.pem;

    root $BOOTSTRAP_OUTPUT_DIR;
    autoindex off;
}
EOF
)
  fi

  log "Writing final nginx config (TLS termination + reverse proxy)"
  cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $ALL_HOSTNAMES;

    location /.well-known/acme-challenge/ {
        root $WEBROOT_DIR;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
$LIVE_TLS_BLOCKS
$TEST_TLS_BLOCKS
$BOOTSTRAP_TLS_BLOCKS
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

# `make install prefix=...` (rather than a bare `make install`, which would
# default to /usr/local) stages every CLI binary into artifacts/bin/ - the
# same layout zcutil/build-zip.sh and build-deb.sh already expect. This also
# runs install-exec-hook (wired in automatically by automake as part of
# `install`), which copies the depends-built tor/i2pd binaries in under their
# pirate-* names and strips them (and pirate-networking) in place there;
# pirated verifies each sibling's SHA256 against a hash baked in at build
# time from that same stripped form, so skipping the strip would make it
# refuse to start them. Silently a no-op for tor/i2pd if embedded onion
# routing was configured off - only pirated/pirate-cli/etc. get installed.
log "Installing TreasureChest binaries into $TREASURECHEST_ARTIFACTS_BIN"
as_user "cd '$TREASURECHEST_DIR/src' && make install prefix='$TREASURECHEST_DIR/artifacts'"

log "Cloning/updating lightwalletd ($LWD_BRANCH)"
if [[ -d "$LWD_BUILD_DIR/.git" ]]; then
  as_user "git -C '$LWD_BUILD_DIR' fetch origin '$LWD_BRANCH' && git -C '$LWD_BUILD_DIR' checkout '$LWD_BRANCH' && git -C '$LWD_BUILD_DIR' pull origin '$LWD_BRANCH'"
else
  as_user "git clone --branch '$LWD_BRANCH' https://github.com/PirateNetwork/lightwalletd '$LWD_BUILD_DIR'"
fi

log "Building lightwalletd"
as_user "cd '$LWD_BUILD_DIR' && CGO_ENABLED=0 go build -a -ldflags '-extldflags \"-static\"' -o lightwalletd ."

log "Linking built binaries into $BIN_DIR"
as_user "ln -sf '$TREASURECHEST_ARTIFACTS_BIN/pirated' '$BIN_DIR/pirated'"
as_user "ln -sf '$TREASURECHEST_ARTIFACTS_BIN/pirate-cli' '$BIN_DIR/pirate-cli'"
as_user "ln -sf '$LWD_BUILD_DIR/lightwalletd' '$BIN_DIR/lightwalletd'"
# pirated finds these by resolving its own real installed path (artifacts/bin/,
# see the `make install` step above) and looking for siblings there, so this
# symlink is only for visibility/consistency in $BIN_DIR, not what makes
# embedded Tor/I2P work.
for extra_bin in pirate-networking pirate-tor pirate-i2pd pirate-tx wallet-utility; do
  if [[ -f "$TREASURECHEST_ARTIFACTS_BIN/$extra_bin" ]]; then
    as_user "ln -sf '$TREASURECHEST_ARTIFACTS_BIN/$extra_bin' '$BIN_DIR/$extra_bin'"
  fi
done

if [[ -n "$DNSSEED_HOST" ]]; then
  log "Cloning/updating pirate-seeder ($DNSSEED_BRANCH)"
  if [[ -d "$PIRATE_SEEDER_DIR/.git" ]]; then
    as_user "git -C '$PIRATE_SEEDER_DIR' fetch origin '$DNSSEED_BRANCH' && git -C '$PIRATE_SEEDER_DIR' checkout '$DNSSEED_BRANCH' && git -C '$PIRATE_SEEDER_DIR' pull origin '$DNSSEED_BRANCH'"
  else
    as_user "git clone --branch '$DNSSEED_BRANCH' https://github.com/PirateNetwork/pirate-seeder.git '$PIRATE_SEEDER_DIR'"
  fi

  log "Building pirate-seeder"
  as_user "cd '$PIRATE_SEEDER_DIR' && make -j$MAKE_JOBS"
  as_user "ln -sf '$PIRATE_SEEDER_DIR/pirate-seeder' '$BIN_DIR/pirate-seeder'"
  as_user "mkdir -p '$PIRATE_SEEDER_DATA_DIR'"

  # Binding UDP/$DNSSEED_PORT (53 by default) needs CAP_NET_BIND_SERVICE.
  # Grant it on the binary itself rather than running as root, consistent
  # with everything else here running as $TARGET_USER under pm2. Capabilities
  # live on the file's extended attributes and are lost every time the
  # binary is rebuilt, so this has to be re-applied on every run of this
  # script, not just the first.
  if [[ "$DNSSEED_PORT" -lt 1024 ]]; then
    setcap 'cap_net_bind_service=+ep' "$PIRATE_SEEDER_DIR/pirate-seeder"
  fi
fi

log "Installing bitcore-node-pirate globally via npm ($BITCORE_BRANCH)"
as_user "$NVM_LOAD; npm install -g 'git+https://github.com/piratenetwork/bitcore-node-pirate.git#$BITCORE_BRANCH'"

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

if [[ "$ENABLE_TESTNODE" == "1" ]]; then
  log "Configuring the test node's pirated ($TESTNODE_CONF)"
  if [[ ! -f "$TESTNODE_CONF" ]]; then
    TESTNODE_RPC_USER="pirate_$(openssl rand -hex 6)"
    TESTNODE_RPC_PASSWORD=$(openssl rand -hex 24)
    as_user "cat > '$TESTNODE_CONF' <<EOF
server=1
listen=1
maxconnections=256
rpcuser=$TESTNODE_RPC_USER
rpcpassword=$TESTNODE_RPC_PASSWORD
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=$TESTNODE_RPC_PORT
rpcworkqueue=128
experimentalfeatures=1
txindex=1
addressindex=1
timestampindex=1
spentindex=1
zmqpubrawtx=tcp://127.0.0.1:$TESTNODE_ZMQ_PORT
zmqpubhashblock=tcp://127.0.0.1:$TESTNODE_ZMQ_PORT
EOF"
  else
    log "$TESTNODE_CONF already exists, leaving credentials untouched"
  fi

  # bitcore-node's spawn config has no field for extra CLI flags (only an
  # exec path + datadir), so -ac_name/-ac_ironwood can't be set via
  # bitcore-node.json directly - this wrapper injects them ahead of whatever
  # args bitcore-node itself passes (-datadir, etc.), forwarded via "$@".
  # -conf is passed explicitly too rather than relying on pirated's default
  # <datadir>/<ac_name>.conf discovery. Regenerated every run (no secrets
  # live here) so config changes take effect on next restart.
  log "Writing pirated-testnode wrapper script"
  as_user "cat > '$BIN_DIR/pirated-testnode' <<EOF
#!/usr/bin/env bash
# Regenerated by deploy-seed-node.sh on every run - do not edit directly.
exec '$BIN_DIR/pirated' --ac_name=$TESTNODE_AC_NAME --ac_ironwood=$TESTNODE_AC_IRONWOOD --conf='$TESTNODE_CONF' $TESTNODE_PIRATED_EXTRA_ARGS \"\\\$@\"
EOF"
  as_user "chmod +x '$BIN_DIR/pirated-testnode'"
fi

if [[ "$ENABLE_BOOTSTRAP_NODE" == "1" ]]; then
  log "Configuring the bootstrap-source node's pirated ($BOOTSTRAP_CONF)"
  if [[ ! -f "$BOOTSTRAP_CONF" ]]; then
    BOOTSTRAP_RPC_USER="pirate_$(openssl rand -hex 6)"
    BOOTSTRAP_RPC_PASSWORD=$(openssl rand -hex 24)
    as_user "cat > '$BOOTSTRAP_CONF' <<EOF
server=1
listen=$BOOTSTRAP_LISTEN
maxconnections=256
rpcuser=$BOOTSTRAP_RPC_USER
rpcpassword=$BOOTSTRAP_RPC_PASSWORD
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=$BOOTSTRAP_RPC_PORT
rpcworkqueue=128
torautostart=0
i2pdautostart=0
# addressindex/timestampindex/spentindex intentionally left at their
# defaults (off) - nothing but bootstrap-snapshot.sh and the P2P network
# query this instance. Note txindex is unconditionally on regardless of
# this file's contents in this fork (see src/main.cpp's fTxIndex).
EOF"
  else
    log "$BOOTSTRAP_CONF already exists, leaving credentials untouched"
  fi
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

log "Installing insight-api/insight-ui services ($BITCORE_BRANCH)"
if [[ ! -d "$BITCORE_NODE_DIR/node_modules/insight-api-pirate" ]]; then
  as_user "$NVM_LOAD; cd '$BITCORE_NODE_DIR' && bitcore-node install 'git+https://github.com/piratenetwork/insight-api-pirate.git#$BITCORE_BRANCH'"
else
  log "insight-api-pirate already installed, skipping"
fi
if [[ ! -d "$BITCORE_NODE_DIR/node_modules/insight-ui-pirate" ]]; then
  as_user "$NVM_LOAD; cd '$BITCORE_NODE_DIR' && bitcore-node install 'git+https://github.com/piratenetwork/insight-ui-pirate.git#$BITCORE_BRANCH'"
else
  log "insight-ui-pirate already installed, skipping"
fi

if [[ "$ENABLE_TESTNODE" == "1" ]]; then
  log "Scaffolding the test node's bitcore-node instance directory"
  if [[ ! -f "$TESTNODE_BITCORE_NODE_JSON" ]]; then
    as_user "$NVM_LOAD; bitcore-node create -d '$TESTNODE_PIRATED_DATA_DIR' '$TESTNODE_BITCORE_NODE_DIR'"
  else
    log "$TESTNODE_BITCORE_NODE_JSON already exists, leaving it as-is"
  fi

  # Same as the live node's patch above, except exec points at the
  # pirated-testnode wrapper (not pirated directly) so -ac_name/-ac_ironwood
  # get injected.
  as_user "$NVM_LOAD; node -e \"
    const fs = require('fs');
    const p = '$TESTNODE_BITCORE_NODE_JSON';
    const c = JSON.parse(fs.readFileSync(p, 'utf8'));
    c.port = $TESTNODE_BITCORE_PORT;
    c.servicesConfig.bitcoind.spawn.datadir = '$TESTNODE_PIRATED_DATA_DIR';
    c.servicesConfig.bitcoind.spawn.exec = '$BIN_DIR/pirated-testnode';
    fs.writeFileSync(p, JSON.stringify(c, null, 2));
  \""

  log "Installing insight-api/insight-ui services for the test node ($BITCORE_BRANCH)"
  if [[ ! -d "$TESTNODE_BITCORE_NODE_DIR/node_modules/insight-api-pirate" ]]; then
    as_user "$NVM_LOAD; cd '$TESTNODE_BITCORE_NODE_DIR' && bitcore-node install 'git+https://github.com/piratenetwork/insight-api-pirate.git#$BITCORE_BRANCH'"
  else
    log "insight-api-pirate already installed for the test node, skipping"
  fi
  if [[ ! -d "$TESTNODE_BITCORE_NODE_DIR/node_modules/insight-ui-pirate" ]]; then
    as_user "$NVM_LOAD; cd '$TESTNODE_BITCORE_NODE_DIR' && bitcore-node install 'git+https://github.com/piratenetwork/insight-ui-pirate.git#$BITCORE_BRANCH'"
  else
    log "insight-ui-pirate already installed for the test node, skipping"
  fi
fi

BITCORE_NODE_BIN=$(as_user "$NVM_LOAD; command -v bitcore-node")

log "Writing pm2 ecosystem file"
# --log-file defaults to ./server.log (relative to lightwalletd's cwd, which
# both the live and test lightwalletd pm2 apps set to $BIN_DIR) - left
# unset, both instances would write to the exact same $BIN_DIR/server.log.
# Point each at its own data dir instead.
# --tor-enable/--i2p-enable publish lightwalletd itself as a Tor hidden
# service / I2P destination, over the same embedded Tor/i2pd daemons
# pirated already runs - --pirate-conf-path only fills in non-default
# control/SAM addresses once these are on, it doesn't turn them on.
LWD_ARGS="--grpc-bind-addr $LWD_GRPC_BIND --http-bind-addr $LWD_HTTP_BIND --pirate-conf-path $PIRATE_CONF --data-dir $LWD_DATA_DIR --log-file $LWD_DATA_DIR/server.log --tor-enable --i2p-enable"
if [[ -n "$DOMAIN_NAME" ]]; then
  # nginx terminates TLS and is the only thing that can reach these
  # loopback-bound ports, so plaintext here is safe.
  LWD_ARGS="$LWD_ARGS --no-tls-very-insecure"
elif [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
  LWD_ARGS="$LWD_ARGS --tls-cert $TLS_CERT --tls-key $TLS_KEY"
else
  LWD_ARGS="$LWD_ARGS --gen-cert-very-insecure"
fi

TESTNODE_APPS_JS=""
if [[ "$ENABLE_TESTNODE" == "1" ]]; then
  # TESTNODE_DOMAIN_NAME is required whenever ENABLE_TESTNODE=1 (validated
  # above), so this is always the nginx-terminates-TLS case - no self-signed
  # fallback branch needed here, unlike the live node's LWD_ARGS above.
  TESTNODE_LWD_ARGS="--grpc-bind-addr $TESTNODE_LWD_GRPC_BIND --http-bind-addr $TESTNODE_LWD_HTTP_BIND --pirate-conf-path $TESTNODE_CONF --data-dir $TESTNODE_LWD_DATA_DIR --log-file $TESTNODE_LWD_DATA_DIR/server.log --no-tls-very-insecure --tor-enable --i2p-enable"
  TESTNODE_APPS_JS=",
    {
      name: 'bitcore-test',
      cwd: '$TESTNODE_BITCORE_NODE_DIR',
      script: '$BITCORE_NODE_BIN',
      args: 'start --config $TESTNODE_BITCORE_NODE_DIR',
      interpreter: 'node',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000
    },
    {
      name: 'lightwalletd-test',
      cwd: '$BIN_DIR',
      script: './lightwalletd',
      args: '$TESTNODE_LWD_ARGS',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000
    }"
fi

DNSSEED_APP_JS=""
if [[ -n "$DNSSEED_HOST" ]]; then
  DNSSEED_ARGS="-h $DNSSEED_HOST -n $DNSSEED_NS -m $DNSSEED_MBOX -p $DNSSEED_PORT --db $PIRATE_SEEDER_DATA_DIR/dnsseed.dat --pirate-conf $PIRATE_CONF"
  [[ -n "$DNSSEED_TOR_PROXY" ]] && DNSSEED_ARGS="$DNSSEED_ARGS -o $DNSSEED_TOR_PROXY"
  [[ "$NETWORK" == "testnet" ]] && DNSSEED_ARGS="$DNSSEED_ARGS --testnet"
  DNSSEED_APP_JS=",
    {
      name: 'pirate-seeder',
      cwd: '$PIRATE_SEEDER_DATA_DIR',
      script: '$BIN_DIR/pirate-seeder',
      args: '$DNSSEED_ARGS',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000
    }"
fi

BOOTSTRAP_APP_JS=""
if [[ "$ENABLE_BOOTSTRAP_NODE" == "1" ]]; then
  BOOTSTRAP_APP_JS=",
    {
      name: 'bootstrap-node',
      cwd: '$BOOTSTRAP_PIRATED_DATA_DIR',
      script: '$BIN_DIR/pirated',
      args: '-conf=$BOOTSTRAP_CONF -datadir=$BOOTSTRAP_PIRATED_DATA_DIR',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000
    }"
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
    }$TESTNODE_APPS_JS$DNSSEED_APP_JS$BOOTSTRAP_APP_JS
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

if [[ "$ENABLE_TESTNODE" == "1" ]]; then
  log "Starting bitcore-test under pm2 and waiting for the test node's pirated RPC to come up"
  as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only bitcore-test"

  TESTNODE_RPC_READY=0
  for _ in $(seq 1 60); do
    if as_user "'$BIN_DIR/pirate-cli' -conf='$TESTNODE_CONF' -datadir='$TESTNODE_PIRATED_DATA_DIR' getinfo" >/dev/null 2>&1; then
      TESTNODE_RPC_READY=1
      break
    fi
    sleep 5
  done

  if [[ "$TESTNODE_RPC_READY" -ne 1 ]]; then
    echo "WARNING: test node's pirated RPC did not respond within 5 minutes. Starting lightwalletd-test anyway; pm2 will keep retrying it." >&2
  fi

  log "Starting lightwalletd-test under pm2"
  as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only lightwalletd-test"
fi

if [[ -n "$DNSSEED_HOST" ]]; then
  log "Starting pirate-seeder under pm2"
  as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only pirate-seeder"
fi

if [[ "$ENABLE_BOOTSTRAP_NODE" == "1" ]]; then
  log "Starting bootstrap-node under pm2 and waiting for its pirated RPC to come up"
  as_user "$NVM_LOAD; pm2 start '$ECOSYSTEM_FILE' --only bootstrap-node"

  BOOTSTRAP_RPC_READY=0
  for _ in $(seq 1 60); do
    if as_user "'$BIN_DIR/pirate-cli' -conf='$BOOTSTRAP_CONF' -datadir='$BOOTSTRAP_PIRATED_DATA_DIR' getinfo" >/dev/null 2>&1; then
      BOOTSTRAP_RPC_READY=1
      break
    fi
    sleep 5
  done

  if [[ "$BOOTSTRAP_RPC_READY" -ne 1 ]]; then
    echo "WARNING: bootstrap-source node's pirated RPC did not respond within 5 minutes. pm2 will keep retrying it." >&2
  fi
fi

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

if [[ "$ENABLE_TESTNODE" == "1" ]]; then
  TESTNODE_INFO="
  Test node ($TESTNODE_AC_NAME, -ac_ironwood=$TESTNODE_AC_IRONWOOD):
    pirated + bitcore-node : pm2 process \"bitcore-test\"      (RPC on 127.0.0.1:$TESTNODE_RPC_PORT, web API + Insight on :$TESTNODE_BITCORE_PORT)
    lightwalletd           : pm2 process \"lightwalletd-test\" (gRPC on $TESTNODE_LWD_GRPC_BIND, HTTP on $TESTNODE_LWD_HTTP_BIND)
    Insight UI:        https://$TESTNODE_DOMAIN_NAME/
    Insight API:       https://$TESTNODE_DOMAIN_NAME/insight-api-pirate/
    lightwalletd gRPC: $TESTNODE_LWD_DOMAIN_NAME:443
    Conf/data: $TESTNODE_CONF, $TESTNODE_PIRATED_DATA_DIR, $TESTNODE_LWD_DATA_DIR
    Wrapper:   $BIN_DIR/pirated-testnode (injects -ac_name/-ac_ironwood into
               pirated's args; regenerated every run of this script, so
               changing TESTNODE_AC_NAME/TESTNODE_AC_IRONWOOD/
               TESTNODE_PIRATED_EXTRA_ARGS and re-running takes effect on
               the next 'pm2 restart bitcore-test')
    This is a private asset chain, not real Pirate mainnet - pirated's actual
    P2P port is asset-chain-derived (same caveat as P2P_PORT above) and isn't
    opened in the firewall automatically; open it yourself if you want this
    chain reachable by other $TESTNODE_AC_NAME peers."
else
  TESTNODE_INFO="
  Test node: not running. Set ENABLE_TESTNODE=1 (with TESTNODE_DOMAIN_NAME,
  TESTNODE_LWD_DOMAIN_NAME, and CERTBOT_EMAIL/TESTNODE_CERTBOT_EMAIL) and
  re-run this script to add one."
fi

if [[ -n "$DNSSEED_HOST" ]]; then
  DNSSEED_INFO="
  pirate-seeder          : pm2 process \"pirate-seeder\" (UDP $DNSSEED_PORT)

  DNS seed hostname: $DNSSEED_HOST (nameserver: $DNSSEED_NS)
  This only works once your DNS provider has these two records pointed at
  this VPS - see pirate-seeder/README.md if you haven't set them up yet:
    A  $DNSSEED_NS  -> this VPS's public IP (must NOT be proxied/CDN'd)
    NS $DNSSEED_HOST -> $DNSSEED_NS
  Verify from another machine once those propagate:
    dig NS $DNSSEED_HOST   (should show $DNSSEED_NS)
    dig A  $DNSSEED_HOST   (should return live peer IPs)"
else
  DNSSEED_INFO="
  DNS seeder: not running. Set DNSSEED_HOST, DNSSEED_NS, and DNSSEED_MBOX
  and re-run this script to add one (needs its own DNS delegation - see
  pirate-seeder/README.md)."
fi

if [[ "$ENABLE_BOOTSTRAP_NODE" == "1" ]]; then
  BOOTSTRAP_INFO="
  Bootstrap-source node: pm2 process \"bootstrap-node\" (RPC on 127.0.0.1:$BOOTSTRAP_RPC_PORT)
    Conf/data: $BOOTSTRAP_CONF, $BOOTSTRAP_PIRATED_DATA_DIR
    Default indexes, embedded Tor/I2P disabled, listen=$BOOTSTRAP_LISTEN.
    Independent of the live node/bitcore/lightwalletd - run
    pirate-scripts/bootstrap-snapshot.sh (its own --install-timer sets up a
    daily systemd timer) to stop/tar/restart this instance and publish
    \$BOOTSTRAP_OUTPUT_DIR ($BOOTSTRAP_OUTPUT_DIR).$([ -n "$BOOTSTRAP_DOMAIN_NAME" ] && echo "
    Served at: https://$BOOTSTRAP_DOMAIN_NAME/")"
else
  BOOTSTRAP_INFO="
  Bootstrap-source node: not running. Set ENABLE_BOOTSTRAP_NODE=1 (and
  optionally BOOTSTRAP_DOMAIN_NAME/CERTBOT_EMAIL to serve it over HTTPS)
  and re-run this script to add one."
fi

cat <<SUMMARY

==> Deploy complete.

  pirated + bitcore-node : pm2 process "bitcore"      (RPC on 127.0.0.1:$RPC_PORT, web API + Insight on :$BITCORE_PORT)
  lightwalletd           : pm2 process "lightwalletd" (gRPC on $LWD_GRPC_BIND, HTTP on $LWD_HTTP_BIND)

$ACCESS_INFO
$TESTNODE_INFO
$DNSSEED_INFO
$BOOTSTRAP_INFO

  Layout (all owned by $TARGET_USER, no sudo needed for day-to-day use):
    $BUILD_DIR        TreasureChest/lightwalletd/pirate-seeder source + compiled binaries - pull/rebuild here to update
    $BIN_DIR          stable symlinks that config/pm2 point at (and pirated-testnode, if ENABLE_TESTNODE=1)
    $BITCORE_NODE_DIR bitcore-node.json + node_modules (bitcore-node-pirate, insight-api-pirate, insight-ui-pirate)
    $TESTNODE_BITCORE_NODE_DIR  same, for the test node (if ENABLE_TESTNODE=1)
    $DATA_DIR         chain data, PIRATE.conf, lightwalletd cache, dnsseed.dat, the test node's own data/conf, and the bootstrap-source node's data/conf - back this up
    $CONFIG_DIR       pm2 ecosystem.config.js
    $BOOTSTRAP_OUTPUT_DIR  bootstrap-snapshot.sh's published tarball + sha256 (if ENABLE_BOOTSTRAP_NODE=1) - regenerable, no need to back up

  RPC credentials: $PIRATE_CONF (generated on first run, not printed here)

  Useful commands (as $TARGET_USER):
    pm2 status
    pm2 logs bitcore
    pm2 logs lightwalletd
    pm2 logs bitcore-test
    pm2 logs lightwalletd-test
    pm2 logs pirate-seeder
    pm2 logs bootstrap-node

  To update pirated/lightwalletd/pirate-seeder: pull + rebuild in $BUILD_DIR,
  then 'pm2 restart bitcore lightwalletd bitcore-test lightwalletd-test
  pirate-seeder bootstrap-node' (the $BIN_DIR symlinks pick up the new
  binaries automatically - no config changes needed; pirated-testnode wraps
  the same symlink). If
  DNSSEED_PORT is below 1024, re-run this script instead of restarting
  manually after rebuilding pirate-seeder - the CAP_NET_BIND_SERVICE grant is
  lost every time the binary is replaced and this script is what re-applies it.

  To update bitcore-node-pirate itself: re-run 'npm install -g
  git+https://github.com/piratenetwork/bitcore-node-pirate.git#$BITCORE_BRANCH'
  then 'pm2 restart bitcore'. To update insight-api-pirate/insight-ui-pirate,
  re-run the same 'bitcore-node install git+...#$BITCORE_BRANCH' command for
  each from within $BITCORE_NODE_DIR, then 'pm2 restart bitcore'.

  Port $P2P_PORT/tcp (P2P) was opened in ufw if it's active; open it manually
  otherwise so this node can serve as a peer.
SUMMARY
