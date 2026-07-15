terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.66.0"
    }
  }
}

resource "hcloud_network" "sdp_net" {
  name     = "sdp-net"
  ip_range = var.network_cidr
}

resource "hcloud_network_subnet" "sdp_subnet" {
  network_id   = hcloud_network.sdp_net.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = cidrsubnet(var.network_cidr, 8, 0)
}

resource "hcloud_firewall" "sdp_fw" {
  name = "sdp-fw"

  # SSH (Admin only)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip]
    description = "SSH Admin"
  }

  # K3s Control Plane
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.network_cidr]
    description = "K3s API"
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "2379-2380"
    source_ips = [var.network_cidr]
    description = "Etcd"
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "10250-10252"
    source_ips = [var.network_cidr]
    description = "Kubelet"
  }
  
  # Allow all outbound (default in hcloud is allow all, but explicit is better)
  # rule {
  #   direction  = "out"
  #   protocol   = "all"
  #   description = "Allow Outbound"
  # }
}

output "network_id" { value = hcloud_network.sdp_net.id }
output "firewall_id" { value = hcloud_firewall.sdp_fw.id }
output "subnet_id" { value = hcloud_network_subnet.sdp_subnet.id }
