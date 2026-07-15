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
  name = "sdp-dev-fw"

  # Allow SSH from your admin IP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip]
  }

  # Allow TCP traffic within the private network (K3s API, etcd, flannel, etc.)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "1-65535"
    source_ips = [var.network_cidr]
  }

  # Allow UDP traffic within the private network (DNS, Flannel VXLAN)
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "1-65535"
    source_ips = [var.network_cidr]
  }

  # Allow ICMP (Ping) within the private network
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = [var.network_cidr]
  }

  # Allow all outbound traffic
  rule {
    direction  = "out"
    protocol   = "tcp"
    port       = "1-65535"
    destination_ips = ["0.0.0.0/0"]
  }

  rule {
    direction  = "out"
    protocol   = "udp"
    port       = "1-65535"
    destination_ips = ["0.0.0.0/0"]
  }

  rule {
    direction  = "out"
    protocol   = "icmp"
    destination_ips = ["0.0.0.0/0"]
  }
}

output "network_id" { value = hcloud_network.sdp_net.id }
output "firewall_id" { value = hcloud_firewall.sdp_fw.id }
output "subnet_id" { value = hcloud_network_subnet.sdp_subnet.id }
