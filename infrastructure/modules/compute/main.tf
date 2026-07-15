# ---------------------------------------------------------------------------
# Master Node: K3s Server
# ---------------------------------------------------------------------------
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

  user_data = templatefile("${path.module}/cloud-init-master.tpl", {
    k3s_token       = var.k3s_token
    k3s_install_url = "https://get.k3s.io"
    k3s_version     = var.k3s_version
  })
}

# ---------------------------------------------------------------------------
# Worker Nodes: K3s Agents
# ---------------------------------------------------------------------------
resource "hcloud_server" "worker" {
  count       = 2
  name        = "sdp-worker-${count.index + 1}"
  image       = var.image_id
  server_type = var.server_type
  location    = var.location

  ssh_keys     = [var.ssh_key_id]
  firewall_ids = [var.firewall_id]

  network {
    network_id = var.network_id
  }

  # Use PUBLIC IP for join (allowed by firewall rule 6443 from 0.0.0.0/0)
  user_data = templatefile("${path.module}/cloud-init-worker.tpl", {
    k3s_token       = var.k3s_token
    k3s_install_url = "https://get.k3s.io"
    k3s_version     = var.k3s_version
    master_ip       = hcloud_server.master.ipv4_address
  })
}

# Outputs
output "master_public_ip" {
  value = hcloud_server.master.ipv4_address
}

output "worker_public_ips" {
  value = hcloud_server.worker[*].ipv4_address
}

output "master_private_ip" {
  value = hcloud_server.master.private_net[0].ip
}

output "worker_private_ips" {
  value = hcloud_server.worker[*].private_net[0].ip
}