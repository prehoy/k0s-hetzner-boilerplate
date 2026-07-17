# Postgres — Patroni cluster + pgBackRest

3-node Patroni cluster (etcd DCS) with **continuous WAL archiving** to Hetzner Object Storage.

- **Streaming replication** (Patroni) covers node failure: a dead leader is replaced in seconds.
- **WAL archiving** (pgBackRest) covers what replication faithfully copies to every replica — a
  `DROP TABLE`, a bad migration, silent corruption. Replicas are not backups.

| | |
|---|---|
| RPO | ~60s (`archive_timeout`) |
| PITR window | ~1 month (`pgbackrest_retention_full: 4` weekly fulls) |
| Full backup | Sunday 02:00 (`pgbackrest-full.timer`) |
| Incremental | Mon–Sat 02:00 (`pgbackrest-incr.timer`) |

Backups run on the **leader only** — the timers fire on all three nodes and `ExecCondition` asks
Patroni's REST API who the leader is, so this follows a failover with no reconfiguration.

## Prerequisites

1. `terraform/backups` applied — the bucket must exist before `stanza-create`.
2. `cp secrets.yml.example secrets.yml`, fill it in, `ansible-vault encrypt secrets.yml`.

```bash
ansible-playbook playbooks/postgres/playbook.yaml --ask-vault-pass
```

The playbook creates the stanza, verifies archiving reaches the repo (`pgbackrest check` forces a WAL
switch and confirms the segment lands in S3), and takes the first full backup if the repo is empty.

> **Keep `pgbackrest_cipher_pass` somewhere outside this cluster.** The repo is encrypted with it and
> it is not recoverable from the repo, the database, or Hetzner. Without it every backup is scrap.

## Checking on it

```bash
pgbackrest --stanza=infra_cluster info     # backup list + WAL archive range
pgbackrest --stanza=infra_cluster check    # forces a WAL switch, verifies it reaches the repo
systemctl list-timers 'pgbackrest-*'
```

`archive_mode` needs a **restart**, not a reload. On an already-bootstrapped cluster `bootstrap.dcs`
in `patroni.yml.j2` is ignored — apply the archive settings with `patronictl edit-config`, then
`patronictl restart infra_cluster`.

## Restore

Both paths destroy the current cluster state. Read the whole section first.

### Point-in-time (the usual case: someone dropped something)

On **every** node:

```bash
systemctl stop patroni
```

On the node you want as the new leader — pick the one that was leader, it's furthest ahead:

```bash
sudo -u postgres pgbackrest --stanza=infra_cluster --delta \
  --type=time --target="2026-07-17 14:29:00+00" --target-action=promote restore
```

Wipe the old cluster state out of the DCS, or Patroni will try to rejoin the timeline you just
abandoned:

```bash
patronictl -c /etc/patroni/config.yml remove infra_cluster
systemctl start patroni      # this node bootstraps as leader from the restored PGDATA
```

Then on the other two nodes — they re-seed from the repo via `create_replica_methods: pgbackrest`,
so this doesn't drag a full copy through the new leader:

```bash
systemctl start patroni
```

Confirm with `patronictl -c /etc/patroni/config.yml list`: one Leader, two Replicas, all on the same
timeline, `Lag in MB` at 0.

### Latest available (lost the cluster entirely)

Same, minus the `--type`/`--target` flags — `restore` defaults to the end of the archive, which is
~60s behind the moment of loss.

## Restoring a single database

pgBackRest is physical: it restores the whole cluster, not one database out of it. To pull back a
single DB, restore to a scratch instance somewhere with `--type=time`, then `pg_dump` the one
database out and load it where you want it. Slower than a logical backup, and the reason to keep this
in mind before you need it.
