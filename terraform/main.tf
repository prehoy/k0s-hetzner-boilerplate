terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4"
    }
  }
}


provider "hcloud" {
  token = var.hcloud_token
}
#managers 3-49, workers  50-100, db 100-149, backoffice 150, nfs  200-209, loadbalancer 210

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

#NETWORK
resource "hcloud_network" "mainNet" {
  name     = "mainNet"
  ip_range = "10.0.0.0/16"

}

#SUBNET
# network_zone is us-east: every prod server runs in ash (us-east), and Hetzner rejects attaching a
# server to a subnet in a different zone at server-create time. The subnet was eu-central historically
# (servers only attached because terraform does an explicit-IP post-create attach, which bypasses the
# zone check) — but the cluster-autoscaler hetzner provider attaches at create time, so the zone had to
# match. Re-laid to us-east 2026-06-15. See docs/RUNBOOK-node-autoscaling.md.
resource "hcloud_network_subnet" "mainSubNet" {
  network_id   = hcloud_network.mainNet.id
  type         = "cloud"
  network_zone = "us-east"
  ip_range     = "10.0.0.0/24"
}

# Dedicated subnet for Cluster-Autoscaler nodes (cas-pool). Hetzner assigns the lowest free IP in a
# subnet, which would collide with the static reservations in 10.0.0.0/24 (managers .3-.5, workers
# .50-.52, db .100-.102, nfs .200-.201, lb .210-.211, nat .150). CAS is pinned to 10.0.1.0/24 via
# subnetIPRange in HCLOUD_CLUSTER_CONFIG so autoscaled nodes only ever get 10.0.1.x. us-east, same as
# mainSubNet — must match the server location zone (ash) so the CAS provider's create-time network
# attach is accepted. Calico autodetection is cidr=10.0.0.0/16 so it covers both subnets. See
# docs/RUNBOOK-node-autoscaling.md.
resource "hcloud_network_subnet" "casSubNet" {
  network_id   = hcloud_network.mainNet.id
  type         = "cloud"
  network_zone = "us-east"
  ip_range     = "10.0.1.0/24"
}


resource "hcloud_primary_ip" "nat_ip" {
  name          = "nat-ip"
  location      = var.location
  type          = "ipv4"
  assignee_type = "server"
  auto_delete   = false
  labels = {
    "role" = "NAT"
  }
}

#BACKOFFICE
resource "hcloud_server" "backoffice_nat" {
  name        = "backoffice-nat"
  location    = var.location
  image       = var.os_type
  server_type = "cpx21"
  labels = {
    "role" = "NAT"
  }
  public_net {
    ipv6_enabled = true
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.nat_ip.id
  }
  network {
    ip         = "10.0.0.150"
    network_id = hcloud_network.mainNet.id
  }
  user_data = file("./node_setup/nat.yml")
  ssh_keys  = [hcloud_ssh_key.admin.id]
}

resource "hcloud_network_route" "nat_gateway" {
  network_id = hcloud_network.mainNet.id
  # Steady-state egress gateway = lb-0 (the keepalived master of the HA LB pair), NOT the backoffice
  # (removes the egress SPOF). On keepalived failover, /etc/keepalived/failover.sh swaps this route to
  # the new master via the Cloud API, so ignore_changes keeps `terraform apply` from reverting a live
  # failover. See staging/ansible/INFRASTRUCTURE.md "NAT Gateway (HA — on the LB pair)".
  gateway     = "10.0.0.210"
  destination = "0.0.0.0/0"

  lifecycle {
    ignore_changes = [gateway]
  }
}


# NFS HA PAIR (nfs-0 10.0.0.200 / nfs-1 10.0.0.201).
# DRBD (protocol C) synchronously replicates a dedicated nfs-drbd volume between the pair; keepalived
# owns failover. The service VIP 10.0.0.199 is a Hetzner *alias IP* moved between nodes via the Cloud
# API on keepalived master transition (`/etc/keepalived/nfs-failover.sh`) — a plain VRRP virtual_-
# ipaddress is NOT delivered on Hetzner's SDN; the alias must be registered through the API.
# alias_ips is seeded on nfs-0 here and then owned by keepalived at runtime, so ignore_changes keeps
# `terraform apply` from reverting a live failover. See prod/ansible/playbooks/nfs/nfs_ha/ and
# docs/RUNBOOK-nfs-ha.md.
resource "hcloud_server" "nfs" {
  count       = 2
  name        = "nfs-${count.index}"
  location    = var.location
  image       = var.os_type
  server_type = "cpx11"
  labels = {
    "role" = "nfs"
  }
  public_net {
    ipv6_enabled = false
    ipv4_enabled = false
  }
  user_data = file("./node_setup/private_only.yml")
  ssh_keys  = [hcloud_ssh_key.admin.id]
  network {
    ip         = "10.0.0.${count.index + 200}"
    network_id = hcloud_network.mainNet.id
    alias_ips  = count.index == 0 ? ["10.0.0.199"] : []
  }

  lifecycle {
    ignore_changes = [network] # keepalived moves the 10.0.0.199 alias IP between the pair
  }
}

# Dedicated DRBD backing volume per NFS node (replicated block device — NOT a shared volume).
# Left raw/unformatted: DRBD writes its own metadata and the filesystem lives on /dev/drbd0.
# One-time bring-up (create-md, first sync, mkfs, data restore) is in docs/RUNBOOK-nfs-ha.md.
resource "hcloud_volume" "nfs_drbd" {
  count = 2
  name  = "nfs-drbd-${count.index}"
  # 50 -> 250 GiB (2026-06-21): the 50 GiB volume hit 87% at only 7 days of HyperDX otel_logs
  # (~4 GiB/day). 30-day log retention needs ~120 GiB for logs + other NFS data; 250 leaves headroom.
  # Hetzner online-grows the block volume on apply, but DRBD + the ext4 filesystem must then be grown
  # by hand (online, no downtime) — see docs/RUNBOOK-spof-mitigations.md §5. Grow ONLY; never shrink.
  size      = 250
  server_id = hcloud_server.nfs[count.index].id
  automount = false
  format    = ""
}

# MANAGEMENT NODES
resource "hcloud_server" "managers" {
  count       = 3
  location    = var.location
  name        = "k0s-manager-${count.index}"
  image       = var.os_type
  server_type = "cpx21"
  ssh_keys    = [hcloud_ssh_key.admin.id]
  user_data   = file("./node_setup/private_only.yml")
  network {
    ip         = "10.0.0.${count.index + 3}"
    network_id = hcloud_network.mainNet.id
  }
  public_net {
    ipv6_enabled = false
    ipv4_enabled = false
  }

  labels = {
    "role" = "manager"
    "role" = "lb"
  }
}


resource "hcloud_primary_ip" "lb_ips" {
  count         = 2
  assignee_type = "server"
  type          = "ipv4"
  location      = var.location
  name          = "lb-ip-${count.index}"
  auto_delete   = true
  labels = {
    "role" = "lb"
  }
}

resource "hcloud_server" "lbs" {
  count       = 2
  location    = var.location
  name        = "lb-${count.index}"
  image       = var.os_type
  server_type = "cpx11"
  ssh_keys    = [hcloud_ssh_key.admin.id]
  network {
    ip         = "10.0.0.${count.index + 210}"
    network_id = hcloud_network.mainNet.id
    # Control-plane HA alias VIP seeded on lb-0; then owned by keepalived (moves on failover via the
    # Cloud API), so ignore drift. https://10.0.0.240:6443 -> 3 apiservers. See RUNBOOK-control-plane-lb.md.
    alias_ips = count.index == 0 ? ["10.0.0.240"] : []
  }
  public_net {
    ipv6_enabled = false
    # ipv4_enabled = false
    ipv4 = hcloud_primary_ip.lb_ips[count.index].id
  }

  labels = {
    "role" = "lb"
  }

  lifecycle {
    ignore_changes = [network] # keepalived moves the 10.0.0.240 alias between the lb pair
  }
}

resource "hcloud_floating_ip" "lb_main" {
  type      = "ipv4"
  name      = "lb-main"
  server_id = hcloud_server.lbs[0].id
}



# WORKER NODES
# Per-index server type. Right-sizing migration 2026-06-18 (see docs/PLAN-prod-worker-ccx13-migration.md):
# general pool cpx21(4GB) -> ccx13(8GB), worker-3(obs) cpx31 -> ccx13, worker-4(whisper) cpx31 ->
# ccx23(16GB, untainted so its ~10GB slack joins the general pool). Flip one index per step and
# `terraform apply -target='hcloud_server.workers[N]'` so a stray full apply can't mass-replace.
locals {
  worker_types = {
    0 = "ccx13" # general (migrated)
    1 = "ccx13" # general (migrated)
    2 = "ccx13" # general (migrated)
    3 = "cpx31" # observability (ClickHouse/Mongo/otel) — deferred (ccx13 needs destroy+recreate)
    4 = "ccx23" # whisper -> 16GB; in-place (160GB disk preserved); untaint later so ~10GB joins general pool
    5 = "ccx13" # general (added 2026-06-19 — control-plane memory relief needed more static capacity)
  }
}
resource "hcloud_server" "workers" {
  location    = var.location
  count       = 6 # 5 generals (0,1,2,5 ccx13 + 4 ccx23) + worker-3 obs; CAS min-0 for the elastic margin (worker-5 re-added 2026-06-19)
  name        = "k0s-worker-${count.index}"
  image       = var.os_type
  server_type = local.worker_types[count.index]
  ssh_keys    = [hcloud_ssh_key.admin.id]
  user_data   = file("./node_setup/private_only.yml")
  public_net {
    ipv6_enabled = false
    ipv4_enabled = false
  }

  network {
    ip         = "10.0.0.${count.index + 50}"
    network_id = hcloud_network.mainNet.id
  }
  labels = {
    "role" = "worker"
  }
}

# DB HOSTS
# 0 is master, 1 is replica, 2 is replica
resource "hcloud_server" "database_servers" {
  location    = var.location
  count       = 3
  name        = "database-server-${count.index}"
  image       = var.os_type
  server_type = "cpx21"
  ssh_keys    = [hcloud_ssh_key.admin.id]
  user_data   = file("./node_setup/private_only.yml")
  public_net {
    ipv6_enabled = false
    ipv4_enabled = false
  }

  network {
    ip         = "10.0.0.${count.index + 100}"
    network_id = hcloud_network.mainNet.id
  }
  labels = {
    "role" = "database"
  }
}
