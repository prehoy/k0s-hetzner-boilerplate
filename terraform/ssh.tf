# Drop your admin SSH public key(s) into ./ssh_keys/ and add one resource per key.
# These are uploaded to Hetzner and attached to every server (see main.tf ssh_keys = [...]).

resource "hcloud_ssh_key" "admin" {
  name       = "admin_tf_ssh"
  public_key = file("./ssh_keys/admin.pub")
}
