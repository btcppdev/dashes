terraform {
  required_version = ">= 1.6"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {}

data "digitalocean_ssh_keys" "account" {}

locals {
  local_ssh_key_parts = regexall("[^[:space:]]+", trimspace(file(pathexpand(var.ssh_key_path))))
  matching_ssh_keys = [
    for key in data.digitalocean_ssh_keys.account.ssh_keys : key
    if regexall("[^[:space:]]+", trimspace(key.public_key))[1] == local.local_ssh_key_parts[1]
  ]
  ssh_key_fingerprint = try(local.matching_ssh_keys[0].fingerprint, "")
}

resource "digitalocean_droplet" "dashes" {
  name     = var.droplet_name
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.size
  ssh_keys = [local.ssh_key_fingerprint]
  ipv6     = true
  tags     = ["dashes", "monitoring", "nixos"]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    nix_channel         = var.nix_channel
    nixos_infect_rev    = var.nixos_infect_rev
    nixos_infect_sha256 = var.nixos_infect_sha256
  })

  # nixos-infect replaces Ubuntu and cloud-init. Do not recreate a live host
  # merely because its bootstrap inputs changed later.
  lifecycle {
    ignore_changes = [image, user_data]

    precondition {
      condition     = length(local.matching_ssh_keys) == 1
      error_message = "ssh_key_path must match exactly one SSH key already registered in the DigitalOcean account."
    }
  }
}

resource "digitalocean_firewall" "dashes" {
  name        = "${var.droplet_name}-firewall"
  droplet_ids = [digitalocean_droplet.dashes.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_source_addresses
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# Creates metrics.btcpp.dev by default. Set dns_zone to an empty string when
# the zone is managed outside DigitalOcean and add the A record manually.
resource "digitalocean_record" "metrics" {
  count  = var.dns_zone == "" ? 0 : 1
  domain = var.dns_zone
  type   = "A"
  name   = var.dns_record
  value  = digitalocean_droplet.dashes.ipv4_address
  ttl    = 300
}

output "ipv4" {
  value = digitalocean_droplet.dashes.ipv4_address
}

output "ipv6" {
  value = digitalocean_droplet.dashes.ipv6_address
}

output "ssh_command" {
  value = "ssh root@${digitalocean_droplet.dashes.ipv4_address}"
}
