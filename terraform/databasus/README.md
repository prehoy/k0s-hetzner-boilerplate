# Databasus backups (Terraform)

Declares DB backups managed by **Databasus** (running on the backoffice Swarm) as IaC: a Hetzner
Object Storage bucket + one backup config per database, scheduled to that bucket.

- All databases reach Databasus through the swarm **`db-lb`** (Patroni leader/replica router) on
  `:5433` (replicas — keeps dumps off the primary). See `backoffice/stacks/db_lb/`.
- **State is gitignored** (it holds DB/S3/admin secrets) — run this module locally.

## One-time prerequisites

1. **Hetzner Object Storage credentials** — Hetzner Console → Object Storage → *Manage credentials*.
   Put them in `terraform.tfvars`. Region/endpoint default `hel1`.
2. **Read-only backup role** on Patroni (NOT the superuser) — on the leader:
   ```sql
   CREATE ROLE databasus_backup LOGIN PASSWORD '<pick-one>';
   GRANT pg_read_all_data TO databasus_backup;   -- read on all DBs/tables/schemas
   ```
   Same password in `terraform.tfvars` (`backup_user`/`backup_password`). Patroni replicates it
   cluster-wide.
3. **Databasus admin** — the single `admin` user. Reset its password headlessly with:
   ```bash
   docker exec -w /app <databasus-cid> ./main -email admin -new-password '<pw>'
   ```
   Use it for the provider (`databasus_admin_*`).
4. **Image pinned** to a version matching provider `~> 0.8.1` in `backoffice/stacks/databasus/stack.yml`.
5. **`db_lb` + Databasus up** — the provider live-checks each DB through `db-lb:5433` on apply.

## Apply

```bash
cd terraform/databasus
cp terraform.tfvars.example terraform.tfvars   # fill in the secrets
terraform init
terraform apply
```

Creates: the bucket, a Databasus workspace + S3 storage, and a Postgres source + daily backup
config (14-day retention) for each database in `local.databases`.

## Maintaining the database list

`local.databases` in `backups.tf`. When DBs are added/removed, refresh it:
```bash
psql -h <node> -U databasus_backup -d postgres -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres' ORDER BY 1"
```
