variable "location" {
  description = "Hetzner location (e.g., hel1)"
  type        = string
}

variable "network_id" {
  description = "ID of the private network to attach servers to"
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
  description = "Hetzner server type (e.g., cax11)"
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