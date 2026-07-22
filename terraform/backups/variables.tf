# Hetzner Object Storage (S3-compatible). Keys come from the Hetzner Console.
# The same endpoint/region/bucket/keys go into ansible/playbooks/postgres/secrets.yml, which is
# where pgBackRest reads them — this module only creates the bucket.
variable "hetzner_s3_endpoint" {
  type    = string
  default = "https://hel1.your-objectstorage.com" # match your bucket's region
}
variable "hetzner_s3_region" {
  type    = string
  default = "hel1"
}
variable "hetzner_s3_access_key" {
  type      = string
  sensitive = true
}
variable "hetzner_s3_secret_key" {
  type      = string
  sensitive = true
}
# Deliberately no default. Hetzner Object Storage bucket names are GLOBALLY unique, not per-project —
# a generic name like "db-backups" is already taken and apply fails with BucketAlreadyExists. `./up
# init` derives one from your domain; if you set it by hand it must match `pgbackrest_s3_bucket` in
# ansible/playbooks/postgres/secrets.yml, which is what actually writes to it.
variable "backup_bucket" {
  type = string
}
