{ config, lib, pkgs, monitoringDomain, acmeEmail, rootSshPublicKey, ... }:

let
  grafanaSecretsDir = "/var/lib/grafana/secrets";
  grafanaOAuthCredentialsDir = "/var/lib/dashes-secrets/grafana-oauth";
  targets = import ./targets.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ./networking.nix
  ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };
  boot.tmp.cleanOnBoot = true;

  networking = {
    hostName = "dashes";
    useDHCP = lib.mkDefault true;
    firewall.allowedTCPPorts = [ 22 80 443 ];
  };
  time.timeZone = "America/Chicago";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys =
    lib.optional (rootSshPublicKey != null) rootSshPublicKey;

  # Prometheus is deliberately not exposed through nginx or the firewall.
  services.prometheus = {
    enable = true;
    # Scrape bearer tokens are generated on the host and intentionally absent
    # from the Nix store, so build-time validation can only check syntax.
    checkConfig = "syntax-only";
    listenAddress = "127.0.0.1";
    port = 9090;
    retentionTime = "30d";
    globalConfig.scrape_interval = "15s";
    ruleFiles = [
      ../rules/cln-alerts.yml
      ../rules/applications-alerts.yml
      ../rules/public-services-alerts.yml
    ];
    scrapeConfigs = [
      {
        job_name = "prometheus";
        static_configs = [{ targets = [ "127.0.0.1:9090" ]; }];
      }
      {
        job_name = "node";
        static_configs = [{
          targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
          labels.instance = "dashes";
        }];
      }
      {
        job_name = "cln";
        scrape_interval = "15s";
        scrape_timeout = "10s";
        static_configs = map
          (node: {
            targets = [ node.target ];
            labels.node = node.node;
          })
          targets.cln;
      }
      {
        job_name = "http-probes";
        metrics_path = "/probe";
        params.module = [ "http_2xx" ];
        static_configs = [{ targets = targets.publicHttp; }];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
          }
        ];
      }
    ] ++ map
      (application: {
        job_name = "application-${application.service}";
        scheme = "https";
        metrics_path = "/metrics";
        authorization = {
          type = "Bearer";
          credentials_file = application.tokenFile;
        };
        static_configs = [{
          targets = [ application.target ];
          labels.service = application.service;
        }];
      })
      targets.applications;
  };

  # Generate independent persistent scrape tokens without putting them in the
  # Nix store. Copy each value to the corresponding application configuration.
  systemd.services.prometheus.preStart = lib.mkBefore ''
    ${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/prometheus2/scrape-secrets
    ${lib.concatMapStringsSep "\n" (application: ''
      if [ ! -s ${lib.escapeShellArg application.tokenFile} ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > ${lib.escapeShellArg application.tokenFile}
      fi
      ${pkgs.coreutils}/bin/chmod 0600 ${lib.escapeShellArg application.tokenFile}
    '') targets.applications}
  '';

  # This exporter is loopback-only. Remote machines should expose their own
  # exporter over a private VPC, WireGuard, or an SSH tunnel.
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    enabledCollectors = [ "systemd" ];
    openFirewall = false;
  };

  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    configFile = ./blackbox.yml;
    openFirewall = false;
  };

  services.grafana = {
    enable = true;
    openFirewall = false;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3000;
        domain = monitoringDomain;
        root_url = "https://${monitoringDomain}/";
        enforce_domain = true;
      };
      security = {
        admin_user = "admin";
        admin_password = "$__file{${grafanaSecretsDir}/admin-password}";
        secret_key = "$__file{${grafanaSecretsDir}/secret-key}";
        cookie_secure = true;
      };
      analytics.reporting_enabled = false;
      users.allow_sign_up = false;
      auth = {
        disable_login_form = true;
        # Generic OAuth does not persist an auth ID. Permit Grafana to relink
        # returning users by the synthetic, provider-controlled email derived
        # from the stable Bitcoin++ person ID.
        oauth_allow_insecure_email_lookup = true;
        login_maximum_inactive_lifetime_duration = "30m";
        login_maximum_lifetime_duration = "1h";
      };
      "auth.basic".enabled = false;
      "auth.generic_oauth" = {
        enabled = true;
        name = "Bitcoin++";
        icon = "signin";
        allow_sign_up = true;
        auto_login = true;
        client_id = "$__file{/run/credentials/grafana.service/oauth-client-id}";
        client_secret = "$__file{/run/credentials/grafana.service/oauth-client-secret}";
        auth_url = "https://btcpp.dev/oauth/authorize";
        token_url = "https://btcpp.dev/oauth/token";
        api_url = "https://btcpp.dev/api/v1/me/identity";
        auth_style = "InHeader";
        scopes = "identity:self:read";
        use_pkce = true;
        login_attribute_path = "data.id";
        name_attribute_path = "data.name";
        # Grafana otherwise unconditionally probes api_url + "/emails" when
        # the identity response has no email.  Keep the OAuth scope minimal
        # and derive a stable, unique internal address from the person ID.
        email_attribute_path = "join('', [data.id, '@metrics.btcpp.dev'])";
        groups_attribute_path = "data.roles";
        allowed_groups = "global-admin";
        role_attribute_path = "contains(data.roles, 'global-admin') && 'Admin' || 'None'";
        role_attribute_strict = true;
        skip_org_role_sync = false;
      };
    };
    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        prune = true;
        datasources = [{
          name = "Prometheus";
          uid = "prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://127.0.0.1:9090";
          isDefault = true;
          editable = false;
        }];
      };
      dashboards.settings = {
        apiVersion = 1;
        providers = [{
          name = "NixOS";
          folder = "NixOS";
          type = "file";
          disableDeletion = true;
          editable = false;
          options.path = ../dashboards;
        }];
      };
    };
  };

  # Keep OAuth credentials outside both the Nix store and Terraform state.
  # systemd exposes these root-owned files read-only to the Grafana service.
  systemd.services.grafana.serviceConfig.LoadCredential = [
    "oauth-client-id:${grafanaOAuthCredentialsDir}/client-id"
    "oauth-client-secret:${grafanaOAuthCredentialsDir}/client-secret"
  ];

  # Generate persistent secrets on first start. They never enter the Nix store.
  systemd.services.grafana.preStart = lib.mkBefore ''
    ${pkgs.coreutils}/bin/install -d -m 0700 ${grafanaSecretsDir}
    if [ ! -s ${grafanaSecretsDir}/admin-password ]; then
      ${pkgs.openssl}/bin/openssl rand -base64 48 | ${pkgs.coreutils}/bin/tr -d '\n' > ${grafanaSecretsDir}/admin-password
    fi
    if [ ! -s ${grafanaSecretsDir}/secret-key ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${grafanaSecretsDir}/secret-key
    fi
    ${pkgs.coreutils}/bin/chmod 0600 ${grafanaSecretsDir}/admin-password ${grafanaSecretsDir}/secret-key
  '';

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts.${monitoringDomain} = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
      };
    };
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = acmeEmail;
  };

  environment.systemPackages = with pkgs; [ htop tmux ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  system.stateVersion = "26.05";
}
