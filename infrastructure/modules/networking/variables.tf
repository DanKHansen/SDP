variable "location" {
  description = "Hetzner location (e.g., hel1)"
  type        = string
}

variable "network_cidr" {
  description = "CIDR range for the private network"
  type        = string
}

variable "ssh_key_id" {
  description = "ID of the SSH key (used for reference, though not directly applied here)"
  type        = string
}

variable "admin_ip" {
  description = "IP address allowed to access SSH"
  type        = string
}