{
  description = "Prometheus and Grafana on a DigitalOcean NixOS droplet";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      monitoringDomain = "metrics.btcpp.dev";
      acmeEmail = "inbox@btcpp.dev";

      # The key installed by Terraform survives nixos-infect. Adding it here as
      # well makes SSH access fully declarative. Leave null to rely on that key.
      rootSshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDY8YVy1Y6QezGvJaKU3RKz+dSUFS2ieYW+1r5HFr6oL niftynei@gmail.com";
    in
    {
      nixosConfigurations.dashes = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit monitoringDomain acmeEmail rootSshPublicKey;
        };
        modules = [ ./nixos/configuration.nix ];
      };

      devShells = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" ]
        (system:
          let
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          in
          {
            default = pkgs.mkShell {
              packages = with pkgs; [
                doctl
                gnumake
                jq
                nixos-rebuild
                opentofu
                prometheus.cli
              ];
            };
          });
    };
}
