terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.66.0"
    }
  }
}

provider "hcloud" {
  # Token is read from HCLOUD_TOKEN environment variable
}

# Input Variables (matches dev.tfvars)
variable "location"     { type = string }
variable "network_cidr" { type = string }
variable "ssh_key_id"   { type = string }
variable "admin_ip"     { type = string }
variable "server_type"  { type = string }
variable "image"        { type = string }
variable "node_count"   { type = number }
variable "k3s_version"  { type = string }
variable "k3s_token"    { type = string }

# 1. Create Network & Firewall
module "networking" {
  source = "../../modules/networking"

  location     = var.location
  network_cidr = var.network_cidr
  admin_ip     = var.admin_ip
}

# 2. Create Compute Nodes
module "compute" {
  source = "../../modules/compute"

  location    = var.location
  network_id  = module.networking.network_id
  firewall_id = module.networking.firewall_id
  ssh_key_id  = var.ssh_key_id
  server_type = var.server_type
  image_id    = var.image
  node_count  = var.node_count
  k3s_token   = var.k3s_token
  k3s_version = var.k3s_version
}

# Outputs
output "server_public_ips" {
  value = module.compute.server_ips
}

output "server_private_ips" {
  value = module.compute.server_private_ips
}