variable "location"    { type = string }
variable "network_id"  { type = string }
variable "firewall_id" { type = string }
variable "ssh_key_id"  { type = string }
variable "server_type" { type = string }
variable "image"       { type = string }

resource "hcloud_server" "master" {
  name          = "sdp-master-01"
  image         = var.image
  server_type   = var.server_type
  location      = var.location
  network_ids   = [var.network_id]
  ssh_key_ids   = [var.ssh_key_id]
  firewall_ids  = [var.firewall_id]

  # User Data: Minimal bootstrap. K3s install via Ansible post-provision.
  user_data = <<-EOT
    #!/bin/bash
    # Disable SSH if strictly private (optional)
    # systemctl stop sshd || true
  EOT
}

resource "hcloud_server" "worker" {
  count         = 2
  name          = "sdp-worker-${count.index + 1}"
  image         = var.image
  server_type   = var.server_type
  location      = var.location
  network_ids   = [var.network_id]
  ssh_key_ids   = [var.ssh_key_id]
  firewall_ids  = [var.firewall_id]

  user_data = <<-EOT
    #!/bin/bash
    # systemctl stop sshd || true
  EOT
}

output "master_ip" { value = hcloud_server.master.ipv4_address }
output "worker_ips" { value = hcloud_server.worker[*].ipv4_address }
output "master_id" { value = hcloud_server.master.id }