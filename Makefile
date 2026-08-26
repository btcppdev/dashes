SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

TOFU := $(shell if command -v tofu >/dev/null 2>&1; then printf 'tofu'; elif command -v terraform >/dev/null 2>&1; then printf 'terraform'; else printf 'nix develop --command tofu'; fi)
NIXOS_REBUILD := $(shell if command -v nixos-rebuild >/dev/null 2>&1; then printf 'nixos-rebuild'; else printf 'nix develop --command nixos-rebuild'; fi)
IP := $(shell cd terraform 2>/dev/null && $(TOFU) output -raw ipv4 2>/dev/null)

.PHONY: help check-token check-ip init plan create ip wait-for-nixos \
	pull-host-config check deploy deploy-dry ssh password metrics-tokens status logs destroy update shell

help: ## Show available targets.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-21s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check-token:
	@if [ -z "$${DIGITALOCEAN_TOKEN:-}" ]; then \
		echo 'ERROR: DIGITALOCEAN_TOKEN is not set.' >&2; \
		echo 'Run: export DIGITALOCEAN_TOKEN="$$(doctl auth token)"' >&2; \
		exit 1; \
	fi

check-ip:
	@if [ -z "$(IP)" ]; then echo 'ERROR: no Terraform/OpenTofu output; run make create first.' >&2; exit 1; fi

init: ## Initialize the Terraform/OpenTofu providers.
	cd terraform && $(TOFU) init

plan: check-token ## Preview DigitalOcean infrastructure changes.
	cd terraform && $(TOFU) plan

create: check-token ## Create the droplet and start the NixOS conversion.
	cd terraform && $(TOFU) apply
	@echo 'The droplet will reboot into NixOS in roughly 5-10 minutes.'
	@echo 'Next: make wait-for-nixos'

ip: check-ip ## Print the droplet IPv4 address.
	@echo "$(IP)"

wait-for-nixos: check-ip ## Wait until the converted NixOS host accepts SSH.
	@echo "Waiting for NixOS at $(IP)..."
	@for attempt in $$(seq 1 60); do \
		if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes root@$(IP) 'test -e /etc/NIXOS' 2>/dev/null; then \
			echo 'NixOS is ready.'; exit 0; \
		fi; \
		echo "  attempt $$attempt/60"; sleep 10; \
	done; \
	echo 'Timed out after 10 minutes.' >&2; exit 1

pull-host-config: check-ip ## Pull the droplet-specific disk and network config.
	scp -o StrictHostKeyChecking=no root@$(IP):/etc/nixos/hardware-configuration.nix nixos/hardware-configuration.nix
	@if scp -o StrictHostKeyChecking=no root@$(IP):/etc/nixos/networking.nix nixos/networking.nix; then \
		echo 'Pulled networking.nix.'; \
	else \
		echo 'No generated networking.nix; retaining DHCP config.'; \
	fi

check: ## Evaluate the NixOS configuration without building it.
	nix flake check --no-build
	nix develop --command promtool check rules rules/*.yml
	nix develop --command jq empty dashboards/*.json

deploy: check-ip ## Build on the droplet and switch to this NixOS configuration.
	$(NIXOS_REBUILD) switch --flake .#dashes \
		--target-host root@$(IP) \
		--build-host root@$(IP) \
		--no-reexec

deploy-dry: check-ip ## Validate activation on the host without switching.
	$(NIXOS_REBUILD) dry-activate --flake .#dashes \
		--target-host root@$(IP) \
		--build-host root@$(IP)

ssh: check-ip ## SSH into the monitoring host.
	ssh root@$(IP)

password: check-ip ## Print the generated initial Grafana admin password.
	@ssh root@$(IP) 'cat /var/lib/grafana/secrets/admin-password'; echo

metrics-tokens: check-ip ## Print the generated application scrape tokens.
	@ssh root@$(IP) 'for token in /var/lib/prometheus2/scrape-secrets/*; do printf "%s=" "$$(basename "$$token")"; cat "$$token"; echo; done'

status: check-ip ## Show service state and local health endpoints.
	ssh root@$(IP) 'systemctl --no-pager --full status prometheus prometheus-node-exporter prometheus-blackbox-exporter grafana nginx; curl -fsS http://127.0.0.1:9090/-/healthy; curl -fsS http://127.0.0.1:3000/api/health'

logs: check-ip ## Follow logs for the monitoring services.
	ssh root@$(IP) 'journalctl -f -u prometheus -u prometheus-node-exporter -u prometheus-blackbox-exporter -u grafana -u nginx'

update: ## Update the pinned nixpkgs revision.
	nix flake update

shell: ## Enter a shell containing OpenTofu, doctl, and nixos-rebuild.
	nix develop

destroy: check-token ## Destroy the DigitalOcean resources (interactive).
	cd terraform && $(TOFU) destroy

.DEFAULT_GOAL := help
