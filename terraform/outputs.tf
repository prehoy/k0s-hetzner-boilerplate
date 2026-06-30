output "manager_servers_ips" {
  description = "Manager servers public IPv4 addresses"
  value = {
    for server in hcloud_server.managers :
    server.name => server.ipv4_address
  }
}

output "manager_servers_internal_ips" {
  description = "Manager servers internal IPv4 addresses"
  value = {
    for i, server in hcloud_server.managers :
    server.name => server
  }
}

output "worker_servers_ips" {
  description = "Worker servers public IPv4 addresses"
  value = {
    for server in hcloud_server.workers :
    server.name => server
  }
}

output "worker_servers_internal_ips" {
  description = "Worker servers internal IPv4 addresses"
  value = {
    for i, server in hcloud_server.workers :
    server.name => server
  }
}

output "nfs_server_ips" {
  description = "NFS servers public IPv4 addresses"
  value = {
    for server in hcloud_server.nfs :
    server.name => server.ipv4_address
  }
}

# Feed each id into prod/ansible/inventory [nfs] drbd_volume_id=<id> (NOT the legacy nfs volume).
output "nfs_drbd_volume_ids" {
  description = "DRBD backing volume ids for the NFS HA pair (nfs-drbd-0/1)"
  value = {
    for v in hcloud_volume.nfs_drbd :
    v.name => v.id
  }
}
