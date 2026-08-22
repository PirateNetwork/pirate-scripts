# pirate-scripts

Deployment/ops tooling for Pirate Chain seed-node infrastructure. Each
script is self-documenting - see its own header comment for the full list
of overridable environment variables.

- `deploy-seed-node.sh` - brings up a seed node on a blank VPS: pirated
  (via bitcore-node-pirate) + lightwalletd, both under pm2. Optionally also
  a DNS seeder (`DNSSEED_HOST`), a second pirated instance for testing
  in-development consensus changes (`ENABLE_TESTNODE=1`), and a third,
  independent pirated instance dedicated to holding synced chain data for
  bootstrap snapshots (`ENABLE_BOOTSTRAP_NODE=1`, optionally served over
  HTTPS via `BOOTSTRAP_DOMAIN_NAME`). Safe to re-run against an existing
  install.
- `update-seed-node.sh` - pulls + rebuilds everything `deploy-seed-node.sh`
  already set up on a host (detected automatically - test node? DNS seeder?
  bootstrap-source node?) without touching nginx, TLS certs, conf files, or
  any chain/wallet data.
- `bootstrap-snapshot.sh` - regenerates the ARRR bootstrap tarball from a
  host's dedicated bootstrap-source node (`ENABLE_BOOTSTRAP_NODE=1` above)
  and publishes it with a sha256 alongside it. Cleanly stops just that one
  instance for the copy (LevelDB isn't safe to copy hot) and always
  restarts it afterward, even on failure - the live node, bitcore,
  lightwalletd, and pirate-seeder are never touched. Run
  `sudo ./bootstrap-snapshot.sh --install-timer` once to set up a daily
  systemd timer instead of running it by hand.

For a seed node to actually contribute fresh bootstrap tarballs, deploy it
with `ENABLE_BOOTSTRAP_NODE=1` and (to serve it publicly)
`BOOTSTRAP_DOMAIN_NAME`/`CERTBOT_EMAIL`, then install the timer:

```
sudo ./deploy-seed-node.sh   # with ENABLE_BOOTSTRAP_NODE=1, BOOTSTRAP_DOMAIN_NAME=..., CERTBOT_EMAIL=...
sudo ./bootstrap-snapshot.sh --install-timer
```

Redundancy across multiple bootstrap hosts (so no single host is a single
point of failure for new installs) is just running the above on more than
one VPS with different `BOOTSTRAP_DOMAIN_NAME` values.
