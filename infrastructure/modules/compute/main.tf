variable "location" {
  description = "Hetzner location (e.g., fsn1, hel1, nbg1)"
  type        = string
}

variable "network_id" {
  description = "ID of the private network"
  type        = string
}

variable "firewall_id" {
  description = "ID of the firewall to apply to servers"
  type        = string
}

variable "ssh_key_id" {
  description = "ID of the SSH key to authorize"
  type        = string
}

variable "server_type" {
  description = "Hetzner server type (e.g., cax11, cx23)"
  type        = string
}

variable "image_id" {
  description = "Operating system image name or ID (e.g., ubuntu-24.04)"
  type        = string
}

variable "k3s_token" {
  description = "Secret token for K3s cluster join"
  type        = string
  sensitive   = true
}

variable "k3s_version" {
  description = "Version of K3s to install"
  type        = string
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
    k3s_token       = var.k3s_token
    k3s_install_url = "https://get.k3s.io"
    k3s_version     = var.k3s_version
    private_ip      = hcloud_server.master.private_net.0.ip # Pass own private IP to script if needed
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

  # CRITICAL: Directly reference the Master's private IP
  user_data = templatefile("${path.module}/cloud-init-worker.tpl", {
    k3s_token       = var.k3s_token
    k3s_install_url = "https://get.k3s.io"
    k3s_version     = var.k3s_version
    master_ip       = hcloud_server.master.private_net.0.ip
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
  value = hcloud_server.master.private_net.0.ip
}

output "worker_private_ips" {
  value = hcloud_server.worker[*].private_net.0.ip
}