terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.66.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

variable "hcloud_token" { type = string }
variable "location"     { type = string }
variable "network_cidr" { type = string }
variable "ssh_key_id"   { type = string }
variable "admin_ip"     { type = string }
variable "server_type"  { type = string }
variable "image"        { type = string }

# Call the Networking Module
module "networking" {
  source = "../../modules/networking"

  location      = var.location
  network_cidr  = var.network_cidr
  ssh_key_id    = var.ssh_key_id
  admin_ip      = var.admin_ip
}

# Call the Compute Module
module "compute" {
  source = "../../modules/compute"

  location      = var.location
  network_id    = module.networking.network_id
  firewall_id   = module.networking.firewall_id
  ssh_key_id    = var.ssh_key_id
  server_type   = var.server_type
  image         = var.image
}

# Outputs
output "master_ip" { value = module.compute.master_ip }
output "worker_ips" { value = module.compute.worker_ips }
