resource "hcloud_server" "nodes" {
  count       = var.node_count
  name        = "sdp-node-${count.index}"
  server_type = var.server_type
  image       = var.image_id
  location    = var.location

  ssh_keys      = [var.ssh_key_id]
  firewall_ids  = [var.firewall_id]

  # CORRECTED: Use nested 'network' block instead of 'network_ids' argument
  network {
    network_id = var.network_id
  }

  user_data = templatefile("${path.module}/cloud-init.tpl", {
    k3s_token       = var.k3s_token
    node_index      = count.index
    k3s_install_url = "https://get.k3s.io"
    k3s_version     = var.k3s_version
  })
}

output "server_ips" {
  description = "Public IPv4 addresses of all nodes"
  value       = hcloud_server.nodes[*].ipv4_address
}

output "server_ids" {
  description = "IDs of all nodes"
  value       = hcloud_server.nodes[*].id
}