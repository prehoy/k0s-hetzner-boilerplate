# Cloudflare DNS-as-code for the cluster zone (var.domain) — one explicit A record per service.
# NO wildcards. Add a line per service you expose; an existing record must be `terraform import`ed
# before terraform manages it (else a duplicate A record is created):
#   terraform import 'cloudflare_record.rec["grafana"]' <zone_id>/<record_id>

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = ""
}

data "cloudflare_zone" "zone" {
  name = var.domain
}

locals {
  bo_ip = "203.0.113.10" # backoffice box (Docker Swarm mgmt stack) — set to your box's public IP
  lb_ip = "203.0.113.20" # cluster LB floating IP (app ingress / traefik) — set to your floating IP

  # host (under var.domain) => target IP. Platform records only; add your app hosts here.
  dns_records = {
    # In-cluster platform UIs (served by Traefik on the LB floating IP)
    "argocd"  = local.lb_ip # ArgoCD UI
    "grafana" = local.lb_ip # Grafana monitoring UI
    "ci"      = local.lb_ip # Woodpecker CI

    # Backoffice mgmt stack (Docker Swarm box)
    "swarmpit.bo"  = local.bo_ip # Swarmpit UI
    "databasus.bo" = local.bo_ip # DB backup manager
    "vpn.bo"       = local.bo_ip # WireGuard admin portal
    "traefik.bo"   = local.bo_ip # backoffice Traefik

    # Cross-served status pages: the gatus watching a plane runs on the OTHER plane.
    "status"    = local.bo_ip # public status page (backoffice gatus watches the cluster)
    "status.bo" = local.lb_ip # backend status page (in-cluster gatus watches the mgmt plane)
  }
}

resource "cloudflare_record" "rec" {
  for_each = local.dns_records
  zone_id  = data.cloudflare_zone.zone.id
  name     = each.key
  type     = "A"
  content  = each.value
  proxied  = false
  ttl      = 60
  comment  = "terraform: ${var.domain} DNS-as-code"
}
