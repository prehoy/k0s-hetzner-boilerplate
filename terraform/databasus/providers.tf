provider "databasus" {
  baseurl  = var.databasus_baseurl # e.g. https://databasus.bo.dashka.io/api/v1
  email    = var.databasus_admin_email
  password = var.databasus_admin_password
}

# Hetzner Object Storage (S3-compatible) — only to create the bucket. The S3 keys are generated
# in the Hetzner Console (no Terraform resource exists for them) and passed via tfvars.
provider "minio" {
  minio_server   = replace(var.hetzner_s3_endpoint, "https://", "") # host only, e.g. hel1.your-objectstorage.com
  minio_region   = var.hetzner_s3_region                            # e.g. hel1
  minio_user     = var.hetzner_s3_access_key
  minio_password = var.hetzner_s3_secret_key
  minio_ssl      = true
}
