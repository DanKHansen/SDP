terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.66.0"
    }
  }
}
resource "hcloud_network" "sdp_net" {
  name     = "sdp-dev-net"
  ip_range = var.network_cidr
}

resource "hcloud_network_subnet" "sdp_subnet" {
  network_id   = hcloud_network.sdp_net.id
  ip_range     = cidrsubnet(var.network_cidr, 8, 0)
  network_zone = "eu-central"
  type         = "cloud"
}

resource "hcloud_firewall" "sdp_fw" {
  name = "sdp-dev-fw"

  # SSH from admin IP only
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip]
  }

  # All TCP within private network
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "1-65535"
    source_ips = [var.network_cidr]
  }

  # All UDP within private network
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "1-65535"
    source_ips = [var.network_cidr]
  }

  # ICMP within private network
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = [var.network_cidr]
  }

  # K3s API from anywhere (lab only, tighten for production)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = ["0.0.0.0/0"]
  }

  # All outbound TCP
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "1-65535"
    destination_ips = ["0.0.0.0/0"]
  }

  # All outbound UDP
  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "1-65535"
    destination_ips = ["0.0.0.0/0"]
  }

  # All outbound ICMP
  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0"]
  }
}

output "network_id" {
  value = hcloud_network.sdp_net.id
}

output "firewall_id" {
  value = hcloud_firewall.sdp_fw.id
}