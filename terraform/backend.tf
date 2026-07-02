# State backend. Default is local state (terraform.tfstate, gitignored).
# For a real deployment use a remote backend so state isn't trapped on one laptop.
# Example: Hetzner Object Storage (S3-compatible) — uncomment and fill in.
#
# terraform {
#   backend "s3" {
#     bucket                      = "my-tfstate"
#     key                         = "infra/terraform.tfstate"
#     region                      = "hel1"
#     endpoints                   = { s3 = "https://hel1.your-objectstorage.com" }
#     skip_credentials_validation = true
#     skip_region_validation      = true
#     skip_requesting_account_id  = true
#     skip_s3_checksum            = true
#     use_path_style              = true
#   }
# }
