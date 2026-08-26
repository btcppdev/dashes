variable "droplet_name" {
  type    = string
  default = "dashes"
}

variable "region" {
  type    = string
  default = "nyc3"
}

variable "size" {
  type        = string
  default     = "s-1vcpu-2gb"
  description = "Adequate for a small Prometheus/Grafana installation monitoring a few hosts."
}

variable "ssh_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "ssh_source_addresses" {
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
  description = "CIDRs allowed to SSH. Restrict this to your public IP when practical."
}

variable "dns_zone" {
  type        = string
  default     = "btcpp.dev"
  description = "DigitalOcean-managed DNS zone. Set to an empty string to disable record creation."
}

variable "dns_record" {
  type        = string
  default     = "metrics"
  description = "Record name within dns_zone."
}

variable "nix_channel" {
  type    = string
  default = "nixos-26.05"
}

variable "nixos_infect_rev" {
  type    = string
  default = "40f62a680bb0e8f2f607d79abfaaecd99d59401c"
}

variable "nixos_infect_sha256" {
  type    = string
  default = "4354bd68773b41da65c0e815202c43c8549713b3ed3ff6381c71fbc0b0a840ab"
}
