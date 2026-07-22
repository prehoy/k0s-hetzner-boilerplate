# Backup bucket (Terraform)

Creates the private Hetzner Object Storage bucket that holds the **pgBackRest** repository for the
Patroni cluster. That's all this module does — the backups themselves are taken by pgBackRest running
on the DB nodes, configured by `ansible/playbooks/postgres/`.

- **State is gitignored** (it holds the S3 keys) — run this module locally.
- Apply it **before** the Postgres playbook: pgBackRest's `stanza-create` needs the bucket to exist.

## One-time prerequisites

**Hetzner Object Storage credentials** — Hetzner Console → Object Storage → *Manage credentials*.
Put them in `terraform.tfvars`. Region/endpoint default to `hel1`.

The same keys go into `ansible/playbooks/postgres/secrets.yml` (vault-encrypted), which is where
pgBackRest reads them.

## Apply

```bash
cd terraform/backups
cp terraform.tfvars.example terraform.tfvars   # fill in the S3 keys
terraform init
terraform apply
```

## Restore

Restores run from the DB nodes, not from here — see
[`ansible/playbooks/postgres/README.md`](../../ansible/playbooks/postgres/README.md).
