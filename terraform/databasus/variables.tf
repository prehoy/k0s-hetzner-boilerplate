# Databasus REST API (admin user) — used by the provider to register config.
variable "databasus_baseurl" {
  type    = string
  default = "https://databasus.bo.example.com/api/v1"
}
variable "databasus_admin_email" {
  type      = string
  sensitive = true
}
variable "databasus_admin_password" {
  type      = string
  sensitive = true
}

# Hetzner Object Storage (S3-compatible). Keys come from the Hetzner Console.
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
variable "backup_bucket" {
  type    = string
  default = "db-backups"
}

# DB connection (through the swarm db-lb leader/replica router).
variable "db_host" {
  type    = string
  default = "db-lb"
}
variable "db_port" {
  type    = number
  default = 5433 # replicas — keep dumps off the primary
}
# Use a dedicated READ-ONLY backup role (pg_read_all_data), NOT the superuser.
variable "backup_user" {
  type      = string
  sensitive = true
}
variable "backup_password" {
  type      = string
  sensitive = true
}

# Schedule / retention.
variable "backup_interval" {
  type    = string
  default = "DAILY"
}
variable "backup_time_of_day" {
  type    = string
  default = "03:00"
}
variable "backup_retention_count" {
  type    = number
  default = 14
}
