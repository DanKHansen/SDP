resource "hcloud_server" "master" {
  name        = "sdp-master-01"
  image       = var.image_id
  server_type = var.server_type
  location    = var.location

  ssh_keys     = [var.ssh_key_id]
  firewall_ids = [var.firewall_id]

  network {
    network_id = var.network_id
  }

  # FIXED: Removed 'private_ip' argument. Master discovers its own IP at runtime.
  user_data = templatefile("${path.module}/cloud-init-master.tpl", {
    k3s_token       = var.k3s_token
    k3s_install_url = "https://get.k3s.io"
    k3s_version     = var.k3s_version
    # private_ip removed
  })
}