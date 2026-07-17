terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.66.0"
    }
  }
}

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
    k3s_token        = var.k3s_token
    k3s_install_url  = "https://get.k3s.io"
    k3s_version      = var.k3s_version
    hcloud_token_b64 = base64encode(var.hcloud_token)
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

  user_data = templatefile("${path.module}/cloud-init-worker.tpl", {
    k3s_token       = var.k3s_token
    k3s_install_url = "https://get.k3s.io"
    k3s_version     = var.k3s_version
    master_ip       = hcloud_server.master.ipv4_address  # <--- BACK TO LOWERCASE
  })
}

# Outputs
output "master_public_ip" {
  value = hcloud_server.master.ipv4_address
}

output "worker_public_ips" {
  value = hcloud_server.worker[*].ipv4_address
}