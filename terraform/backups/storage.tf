# Hetzner Object Storage bucket holding the pgBackRest repository (S3-compatible), via the MinIO
# provider. Credentials (access/secret) come from the Hetzner Console (Object Storage -> Manage
# credentials) — there is no Terraform resource for them — and are passed via tfvars.
#
# The contents are written by pgBackRest on the Patroni nodes, not by Terraform: this module only
# creates the bucket. See ansible/playbooks/postgres/.
resource "minio_s3_bucket" "backups" {
  bucket         = var.backup_bucket
  acl            = "private" # backups must never be world-readable
  object_locking = false
}
