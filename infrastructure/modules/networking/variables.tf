variable "location" {
  description = "Hetzner location (e.g., hel1)"
  type        = string
}

variable "network_cidr" {
  description = "CIDR range for the private network"
  type        = string
}

variable "admin_ip" {
  description = "IP address allowed to access SSH"
  type        = string
}
# Note: ssh_key_id removed as it is not used in the networking module