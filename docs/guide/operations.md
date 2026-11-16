# Operations

This page covers running a pool from day to day: deploying a release and rolling it back, watching the
health check, metrics, and logs, upgrading, and the files to keep safe. It assumes the pool runs as the
systemd service `haysher`, as [installation](installation.md) sets it up.

## Starting and Stopping

```sh
systemctl start haysher
systemctl restart haysher
systemctl stop haysher
```

The pool reads its config once, at startup, so a config change takes a restart. Run by hand, Ctrl-C stops
it. A share credited to a pooled or hybrid pool is written to the database before the miner is answered,
and survives a crash of the pool process; every commit that moves money is synced to disk before it
returns. A found block's hex is written to `blocks/` while it is submitted, and a block that no node had
answered when the pool stopped is submitted again at the next start.

Miners reconnect by themselves after a restart.

## Deploying a New Release

[deploy.sh](../../deploy.sh) builds the release binary on your machine and updates a server that already
runs the pool as the systemd service `haysher`:

```sh
cp deploy.env.example deploy.env   # once; then set HAYSHER_HOST in it
./deploy.sh
```

It reads its settings from `deploy.env` in the repository, which git ignores, and
[deploy.env.example](../../deploy.env.example) describes each one. A variable set in the environment takes
precedence over the file, as in `HAYSHER_HOST=root@pool2.example.com ./deploy.sh`.

* `HAYSHER_HOST`: the SSH destination, `user@host`, whose user can write to the installation directory
  and restart the service. Required: without it the script stops before building.
* `HAYSHER_DIR`: the installation directory, which holds the running `haysher` binary. The default
  is `/opt/haysher`.

The script:

1. runs `cargo build --release --locked`, and warns when the build is `-dirty`, built from uncommitted
   sources;
2. uploads the binary as `haysher.new`;
3. keeps the running binary as `haysher.prev`, moves the new one into place, and restarts the service;
4. waits up to 30 seconds for the service to be active and for `http://127.0.0.1:9100/metrics` to report
   `haysher_ready 1`, and prints the running version.

The server needs `curl`, and the metrics bound on `127.0.0.1:9100`, the address the script reads. The
binary is built locally, so the server must run a compatible OS release. The first install is by hand,
since the script keeps a running binary as `haysher.prev` and fails without one.

The script does not copy the config. After changing it, copy it to the server and restart the service:

```sh
scp pool.toml root@pool.example.com:/opt/haysher/config/pool.toml
ssh root@pool.example.com systemctl restart haysher
```

### Rolling Back

If the new binary is not ready within 30 seconds, the script rolls back by itself: it prints the
service's last 20 log lines, copies `haysher.prev` back over `haysher`, restarts the service, and
exits with an error.

To roll back a release that came up ready but misbehaves, do the same by hand on the server:

```sh
cd /opt/haysher
cp -p haysher.prev haysher
systemctl restart haysher
```

Only the binary goes back; the database stays as the new release left it. A database at a newer schema
version than a binary knows is refused at startup, with an error that says so.

## The Health Check

`GET /api/v1/health`, on the portal's listener, says whether the pool is serving, for uptime monitors and
the portal's outage banner:

```sh
curl -s http://127.0.0.1:8080/api/v1/health
```

```json
{
  "status": "ok",
  "version": "v0.2.0+1a2b3c4d",
  "uptime_secs": 86400,
  "tip_height": 921000,
  "checks": { "node": "healthy", "work": true, "pooled_credit": "accepting", "payouts": null }
}
```

* `status`: `ok`; `degraded` while work continues with a fault, such as a secondary node out, pooled
  credit stopped, or payouts paused or halted; or `unavailable` while miners get no work. An
  `unavailable` answer comes with HTTP status 503, so a monitor can read the status code alone.
* `checks.node`: `starting`, `healthy`, `ibd`, `outage`, or `wrong_chain`; with secondary nodes, `healthy`
  while every node is fit and `degraded` while one is out.
* `checks.work`: whether miners get work now.
* `checks.pooled_credit`: `accepting`, or `stopped` once a share journal commit has failed, after which
  pooled and hybrid shares are refused until a restart; `null` when no pool shares its blocks.
* `checks.payouts`: `starting`, `running`, `deferred`, `paused`, `halted`, or `locked` while a batch waits
  for an encrypted payout wallet's unlock; `null` without `[payouts]`.
* `checks.nodes`: with secondary nodes, how many are fit of how many are configured, never which.

The check reads memory alone and never carries error text, which could name internal hosts or paths.
The detail is in the metrics and the log. [API reference](api.md) lists the rest of `/api/v1`.

## Prometheus Metrics

The pool serves Prometheus metrics at `/metrics` on `[metrics] bind`, such as `127.0.0.1:9100`. Keep it on
loopback, and scrape it from a Prometheus on the same host or through a tunnel:

```sh
curl -s http://127.0.0.1:9100/metrics | grep haysher_
```

No series carries a worker or an address label; per-worker figures are the portal's. The main series:

| Series | Labels | What it reports |
| --- | --- | --- |
| `haysher_ready` | | 1 once every listener is bound. |
| `haysher_node_state` | `node`, `state` | 1 for each node's state: `starting`, `healthy`, `ibd`, `refused`, `hung`, `failed`, or `wrong_chain`. |
| `haysher_node_standing` | `node`, `standing` | 1 for each node's standing in the fleet: `fit`, a soft fault (`recovering`, `stuck`, `isolated`), or a hard fault. |
| `haysher_node_tip_height` | `node` | Each node's tip height. |
| `haysher_node_lag_blocks` | `node` | Blocks each node is behind the fleet's most-work tip. |
| `haysher_node_chainwork_log2` | `node` | log2 of the work of each node's chain. |
| `haysher_node_rpc_seconds` | `node` | How long each node's last `getblockchaininfo` took. |
| `haysher_node_selected` | `node` | 1 for the node the current work comes from. |
| `haysher_node_source_changes_total` | `from`, `to` | Moves of template sourcing from one node to another. |
| `haysher_tip_height` | | The height of the tip the current template builds on. |
| `haysher_tip` | `hash` | That tip's hash, as a label on a series of value 1. |
| `haysher_template_age_seconds` | | Seconds since the node made the current template. |
| `haysher_workers_connected` | `pool`, `transport` | Workers with a connection open, a series for each configured pool. |
| `haysher_shares_accepted_total` | `pool`, `transport` | Shares accepted. |
| `haysher_shares_rejected_total` | `pool`, `transport`, `class` | Shares refused: `stale`, `duplicate`, `low_difficulty`, `bad_version`, `unauthorized`, or `invalid`. |
| `haysher_share_response_seconds` | `pool`, `transport` | Histogram: from a share read to its answer written. |
| `haysher_block_submission_seconds` | | Histogram: from a found block's submission to the first node's success. |
| `haysher_node_submission_seconds` | `node`, `answer` | Histogram: each node's answer to a found block, `success`, `reject`, or `unanswered`. |
| `haysher_journal_commit_seconds` | | Histogram: how long a share journal commit took. |
| `haysher_journal_failed` | | 1 once a journal commit failed: pooled and hybrid shares are refused until a restart. |
| `haysher_journal_unsynced_seconds` | | How long the oldest journal commit not yet synced to disk has waited. |
| `haysher_accounting_backlog_blocks` | | Blocks with a pool output recorded and not yet allocated. |
| `haysher_liabilities_sats` | | What miners are owed: every pending, available, and reserved balance. |
| `haysher_group_member_up` | `member` | 1 while a `[group]` member counts in the group's totals. |
| `haysher_backup_last_seconds` | | Unix seconds when the last database snapshot was written, with `[backup]`. |
| `haysher_backups_failed_total` | | Database snapshots that failed. |

`transport` is `V1` or `V2-native`. The payout series, `haysher_payouts_paused`,
`haysher_payouts_deferred`, `haysher_payouts_halted`, `haysher_payouts_locked`,
`haysher_fee_reserve_sats`,
`haysher_wallet_held_sats`, `haysher_wallet_covers_liabilities`,
`haysher_payout_batches_unconfirmed`, and `haysher_payout_batch_oldest_unconfirmed_seconds`,
report the payout worker, which runs only with `[payouts]`. Each series has a `# HELP` line in the
endpoint's output.

## Logs

The pool logs to standard output, so under systemd the journal holds the log:

```sh
journalctl -u haysher -f            # follow it
journalctl -u haysher -n 200        # the last 200 lines
journalctl -u haysher --since today
```

The level is `info` unless `RUST_LOG` sets another, such as `Environment=RUST_LOG=debug` in the unit. Lines
worth knowing:

* `SV2 authority key`: the key Stratum V2 miners pin, logged at each start.
* `ready`: every listener is bound.
* `block recorded as found`: a node accepted a block, with its hash and the node's answer.

Run by hand with [mainnet.sh](../../mainnet.sh), the log goes to the terminal and to a new file in
`data/main/logs/` on each run.

## Upgrading

Before upgrading, read [CHANGELOG.md](../../CHANGELOG.md) from your version to the new one. Config keys
are renamed or removed between releases, and since every table refuses keys it does not know, an old
config stops the new binary at startup with the key it names. Update the config with the binary.

The database upgrades itself: at startup the pool applies the numbered migrations it lacks, logging
`database migrated`. A database written by a newer binary is refused.

Today the schema is a single migration, which a release edits in place when the schema changes, so the pool
applies nothing to a database it already created. Such a release's changelog entry gives the SQL that brings
an existing database to the new shape: stop the pool, take a [snapshot](#snapshots), apply it with the
`sqlite3` shell, then start the new binary. Never delete the database to upgrade: it holds the pool's blocks,
worker history, miners' balances, and balance tokens.

## Files to Keep Safe

Everything the pool keeps is in its data directory, `data_dir`:

| File | What it is | If it is lost |
| --- | --- | --- |
| `handle.key` | The secret behind the portal's worker and fleet links. | Every link changes, and every bookmark stops working. |
| `sv2-authority.key` | The Stratum V2 authority key. | A new one is made; every V2 miner must pin the new public key. Replace it on purpose by [rotating](#rotating-the-authority-key) it. |
| `haysher.sqlite3` | The database, in WAL mode, with `-wal` and `-shm` files beside it. | Found blocks, worker history, balances, and balance tokens are gone. |
| `blocks/` | Each found block's hex, by hash. | The pool can no longer resubmit a block no node answered. |

The pool makes both keys on first run, with mode 600, and refuses to start when anyone else can read one.
Neither can be recovered once lost: they can only be replaced. Keep the config, and any
`rpc_password_file`, beside them.

With `[backup]`, the pool keeps snapshots of the database itself ([Snapshots](#snapshots)). Without it, take
a copy while the pool runs with SQLite's own `.backup` command, such as
`sqlite3 haysher.sqlite3 ".backup /path/to/copy.sqlite3"`, which copies a consistent snapshot. A plain
`cp` of a running database can copy a torn one.

## Snapshots

With [`[backup]`](configuration.md#backup), the pool writes a snapshot of its database when it starts,
every `interval_secs`, and at once after a block with a pool output is allocated or a payout batch is
broadcast. Each is a whole database, `haysher-<Unix milliseconds>.sqlite3` in `backups/` under the data
directory, written under a hidden name and renamed into place, so a copy never takes half of one. The newest
`keep` are kept. A snapshot that fails is logged, `cannot snapshot the database`, and counted in
`haysher_backups_failed_total`; mining carries on.

A snapshot on the pool's own disk is lost with it, so copy them to another host. Pulling them from that host
keeps the pool's host from reaching the copies: a key that may only read the snapshot directory, limited in
the pool host's `authorized_keys` with rsync's `rrsync -ro`, and an `rsync` without `--delete` on a timer,
skipping hidden files. [deploy/backup-pull.service](../../deploy/backup-pull.service) and its timer are one
such pull. Keep the keys apart from the snapshots ([Files to keep safe](#files-to-keep-safe)).

To restore a snapshot:

```sh
systemctl stop haysher
cd /opt/haysher/data
mkdir replaced
mv haysher.sqlite3* replaced/
cp /path/to/haysher-<newest>.sqlite3 haysher.sqlite3
chown haysher:haysher haysher.sqlite3
systemctl start haysher
```

Keep `handle.key` and `sv2-authority.key`. The shares accepted after the snapshot are lost. With
`[payouts]`, startup reconciliation compares the restored books with the payout wallet and the chain, and
halts payouts until they agree, so no batch is paid twice.

## The Payout Wallet

With [`[payouts]`](configuration.md#payouts), the pool pays from a wallet on the node. Encrypted, nothing on
the host can spend from it while it is locked, and each batch waits for you to unlock it. Two scripts in the
repository manage an encrypted payout wallet from your own machine. Each passes the passphrase to the node's
`bitcoin-cli` over SSH on standard input, so it never reaches a command line, the process list, a file, or
the shell history.

[payout-wallet.sh](../../payout-wallet.sh) creates the wallet, once. It reads a new passphrase twice, of 12
characters or more, creates an encrypted descriptor wallet that the node loads whenever it starts, and prints
a new address of it for `pool_wallet`. It then copies the wallet's backup to your machine, checks it by
checksum, and removes it from the host. It refuses to run when the local backup file already exists.

[unlock.sh](../../unlock.sh) signs a waiting batch. It reads the health check: when `payouts` reads
`locked`, it asks for the passphrase, unlocks the wallet for at most 300 seconds, or the seconds given, as
in `./unlock.sh 600`, and waits for the batch to be signed. It then locks the wallet again and prints the
batch's txid. When no batch waits, it asks before unlocking.

Both read their settings from `deploy.env`, as `deploy.sh` does, with the environment taking precedence:

* `HAYSHER_HOST`: the SSH destination of the host that runs the node. Required.
* `HAYSHER_REMOTE`: the command that runs one shell command on that host; `ssh $HAYSHER_HOST` by
  default.
* `HAYSHER_BITCOIN_CLI`: the command that runs `bitcoin-cli` on the host, as a user that can reach the
  node's RPC; `bitcoin-cli` by default.
* `HAYSHER_WALLET`: the wallet's name, `[payouts] wallet`; `payouts` by default.
* `HAYSHER_HEALTH_URL`: for `unlock.sh`, the pool's health check, such as
  `https://pool.example.com/api/v1/health`. Required.
* `HAYSHER_HOST_BACKUP`: for `payout-wallet.sh`, where the node writes the backup, a path on the host
  its user can write. Required.
* `HAYSHER_WALLET_BACKUP`: for `payout-wallet.sh`, where your machine keeps the backup;
  `~/haysher-keys/<wallet>-wallet.dat` by default.

Keep the passphrase and the backup apart, and both off the host: together they spend the wallet, and without
the passphrase the backup spends nothing.

## When Payouts Pause

Payouts pause when a block leaves the chain after balances it credited were already reserved for a batch or
paid. The pool cannot take that money back without debiting someone else, so it leaves the credits standing
and stops paying: `checks.payouts` reads `paused`, `haysher_payouts_paused` is 1, and the log says
which block. Mining, the journal, and balances carry on; no new batch is reserved and no unconfirmed one is
taken forward.

The pool wallet then holds less than the books say miners are owed, by what that block's credits paid
out. Decide how to cover it, for example by sending the difference to the payout wallet, then lift the
pause:

```sh
sudo -u haysher /opt/haysher/haysher payouts resume --config /opt/haysher/config/pool.toml
```

It prints each pause it lifts. A running pool resumes at its next payout interval, with no restart. If the
same block leaves the chain again, payouts pause again.

A `halted` state is different: the pool's books disagree with the wallet or the chain at startup. Find the
cause in the log, fix it, and restart; the check runs again at every start.

## Rotating the Authority Key

Every Stratum V2 miner pins the pool's authority key, and a pinned miner accepts that one key alone. Each
miner's owner updates its pin by hand when the key changes. Rotate it when it may have leaked. The pool
shows the next key on the overview ahead of the switch, so miners can prepare:

1. Make the next key, `sv2-authority.next.key` in the data directory, mode 600, as the user the pool runs as.
   It prints the next key's public key; run again, it keeps the key and prints it again:

   ```sh
   haysher authority next --config /path/to/config.toml
   ```

2. Keep a copy of it with the current key's, off the host.
3. Set `authority_switch` in `[public]` to the day it takes over, `YYYY-MM-DD`, at least two weeks ahead, and
   restart the pool. The overview, and `next_authority_key` in `GET /api/v1/pool`, show the next key and the
   day under the current one. Tell your miners wherever they follow the pool.
4. On that day, stop the pool, keep the old key as `sv2-authority.key.old`, move `sv2-authority.next.key` over
   `sv2-authority.key`, remove `authority_switch`, and start the pool. The overview and its V2 URLs now carry
   the new key.

From the switch on, a V2 miner pinned to the old key is refused, and the log names it as one that may not
trust the pool's authority key, until its owner enters the new key or V2 URL. A miner pinned to the new key
before the switch is refused until it. Stratum V1 miners are not affected.

## The Country Database

With `[geo]`, the stats page reads a country database, such as DB-IP's IP to Country Lite, published
monthly. [deploy/geo-update.sh](../../deploy/geo-update.sh) fetches the current month's file into
`/opt/haysher/geo` and replaces it in one rename, leaving the last good copy when a fetch fails. Run
it monthly from a systemd timer or cron. The pool checks the file hourly and reopens it when it changes,
so an update needs no restart. A missing file stops the pool at startup, so fetch it once by hand before
setting `[geo]`.

## Templates in `deploy/`

[deploy/](../../deploy/) holds templates for running a pool on a host of your own. Each says where it goes in
its first lines; replace its example names and placeholders, such as `pool.example.com` and `<pool-host>`,
with your own.

| File | What it is |
| --- | --- |
| [haysher.service](../../deploy/haysher.service) | The pool's systemd unit, as [installation](installation.md#running-as-a-systemd-service) gives it. |
| [backup-pull.service](../../deploy/backup-pull.service), [backup-pull.timer](../../deploy/backup-pull.timer) | On another host, a pull of the [snapshots](#snapshots) every 5 minutes. |
| [cloudflared.yml](../../deploy/cloudflared.yml) | A Cloudflare Tunnel to the portal, so the host opens no web port. |
| [config.alloy](../../deploy/config.alloy), [alloy.conf](../../deploy/alloy.conf) | Grafana Alloy, pushing the pool's and the host's metrics to a Grafana Cloud stack. |
| [alerts.yaml](../../deploy/alerts.yaml), [dashboard.json](../../deploy/dashboard.json) | Alert rules and a dashboard for that stack, which [grafana-push.py](../../deploy/grafana-push.py) writes to it. |
| [geo-update.sh](../../deploy/geo-update.sh) | A monthly fetch of the [country database](#the-country-database). |

## Not Built In Yet

* Copies off the host. The pool snapshots its database with `[backup]`, but copying the snapshots and
  the keys elsewhere is up to you ([Snapshots](#snapshots)).
* Monitoring and alerting of its own. The pool serves the health check and the metrics; watching them, and
  telling you when something is wrong, is up to a monitor and a Prometheus of your own, such as the Grafana
  Cloud templates [above](#templates-in-deploy).
* HTTPS for the portal, which serves plain HTTP; a reverse proxy in front of it provides TLS.
