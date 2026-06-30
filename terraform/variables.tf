# Fill these via terraform.tfvars / secrets.auto.tfvars (see *.example) or TF_VAR_* env vars.
# No secret has a default — terraform will prompt if one is missing.

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "domain" {
  description = "Root DNS zone managed by this stack (Cloudflare)."
  type        = string
  default     = "example.com"
}

variable "location" {
  default = "ash" # Hetzner location (ash = Ashburn / us-east). e.g. nbg1, fsn1, hel1, ash, hil, sin
}

variable "os_type" {
  default = "ubuntu-24.04"
}

