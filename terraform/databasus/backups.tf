locals {
  # Non-template databases on the Patroni cluster to back up (refresh with:
  #   psql -h <node> -U <role> -d postgres -tAc \
  #     "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres' ORDER BY 1")
  databases = [
    "app",
    "analytics",
  ]
}

resource "databasus_workspace" "main" {
  name = "main"
}

# One backup source per database — all reached through the swarm db-lb (leader/replica router),
# on :5433 (a replica) so dumps don't load the primary.
resource "databasus_database_postgresql" "db" {
  for_each = toset(local.databases)

  name            = each.key
  database        = each.key
  host            = var.db_host # "db-lb" (swarm) — follows the live leader/replica
  port            = var.db_port # 5433 = replicas
  ssl_mode        = "disable"
  username        = var.backup_user
  password        = var.backup_password
  include_schemas = [] # all schemas
  workspace_id    = databasus_workspace.main.id
}

# Schedule + retention per database, pointing at the Hetzner bucket.
resource "databasus_backup_config" "db" {
  for_each = databasus_database_postgresql.db

  database_id           = each.value.id
  storage_id            = databasus_storage_s3.hetzner.id
  interval              = var.backup_interval    # e.g. DAILY
  time_of_day           = var.backup_time_of_day # e.g. 03:00
  retention_policy_type = "COUNT"
  retention_count       = var.backup_retention_count
}
