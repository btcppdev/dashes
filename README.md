# dashes

A small, reproducible Prometheus + Grafana host on a DigitalOcean droplet.
Terraform/OpenTofu owns the droplet, cloud firewall, and optional DNS record;
the Nix flake owns every service and subsequent deployment.

The initial stack monitors itself, the public Bitcoin++ services, and any CLN
exporters listed in `nixos/targets.nix`:

```text
browser -> HTTPS/nginx -> Grafana (127.0.0.1:3000)
                    |                   |
                    v                   v
          Prometheus (127.0.0.1:9090)  Loki (127.0.0.1:3100)
                    |                   ^
       +------------+-------------+     |
       |                          |     +-- authenticated Alloy log pushes
 CLN/node exporters       blackbox HTTP/TLS probes
```

Only SSH, HTTP, and HTTPS are public. Grafana requires login. Prometheus, Loki,
and node_exporter are not directly reachable from the internet; nginx exposes
only Loki's authenticated push route.

## What you need

- A DigitalOcean account and API token (`doctl auth init` is convenient).
- A domain name. For automatic TLS, an A record must point at the droplet.
- An Ed25519 SSH key at `~/.ssh/id_ed25519.pub`, or a custom path in tfvars.
- Nix with flakes enabled. Everything else is available through `nix develop`.

This follows the deployment shape in `../streamer/streamctl-system`, but removes
the application-specific module, uploads, and secrets.

## One-time setup

### 1. Review the host identity

The flake is configured for:

```nix
monitoringDomain = "metrics.btcpp.dev";
acmeEmail = "inbox@btcpp.dev";
rootSshPublicKey = "ssh-ed25519 AAAA... niftynei@gmail.com";
```

Terraform reuses the matching SSH key already registered in DigitalOcean, and
that key is retained through nixos-infect. Declaring it in the flake makes
recovery and future rebuilds less surprising.

### 2. Configure the droplet

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
```

Terraform defaults to creating the `metrics.btcpp.dev` A record in the
DigitalOcean-managed `btcpp.dev` zone. If that zone is managed elsewhere, set
`dns_zone = ""` and create the record at your DNS provider after `make create`.

Restrict `ssh_source_addresses` to your public `/32` when your address is stable.
SSH is key-only either way.

### 3. Authenticate and preview

```bash
export DIGITALOCEAN_TOKEN="$(doctl auth token)"
make init
make plan
```

Inspect the plan, especially the region, size, firewall, and DNS record.

### 4. Create and convert the droplet

```bash
make create
make wait-for-nixos
make pull-host-config
```

DigitalOcean starts a fresh Ubuntu 24.04 droplet. Cloud-init downloads a pinned,
checksum-verified nixos-infect script, replaces Ubuntu with NixOS, and reboots.
This is destructive by design; never run the bootstrap against a host containing
data. Conversion normally takes 5-10 minutes.

If DNS is not managed by DigitalOcean, run `make ip` now and create:

```text
metrics.btcpp.dev  A  <the printed IPv4 address>
```

Wait until that name resolves to the droplet before deploying, because nginx
will request its Let's Encrypt certificate during activation.

### 5. Register Grafana with Bitcoin++ OAuth

Sign in to `https://btcpp.dev/dashboard/settings` as a global admin and create a
confidential OAuth application named `Grafana`. Register this exact callback:

```text
https://metrics.btcpp.dev/login/generic_oauth
```

Grant only `identity:self:read`. Copy the one-time client ID and secret, then
install them on the monitoring host without adding them to Git, the Nix store,
Terraform state, or shell history:

```bash
make oauth-credentials
```

Grafana cannot start without these credential files. Its OAuth user-info lookup
reads the signed-in person's stable ID, display name, and current roles from
Bitcoin++. Grafana admits only identities whose roles contain `global-admin`.

Generate the credential used by remote Alloy agents to push logs into Loki:

```bash
make loki-credentials
```

Save the printed `LOKI_PUSH_USERNAME` and `LOKI_PUSH_PASSWORD` lines. The
command is idempotent and prints the existing credential on later runs instead
of rotating it. Install those lines as the Alloy environment file on the CLN
container. The plaintext server copy is root-only and outside the Nix store;
nginx receives only a runtime SHA-512 password hash.

### 6. Validate and deploy

```bash
make check
make deploy-dry
make deploy
make status
```

The first remote build can take several minutes. Nix will persist Prometheus
data under `/var/lib/prometheus2`, Loki logs under `/var/lib/loki`, and Grafana
state under `/var/lib/grafana`.

### 7. Log in

Open `https://metrics.btcpp.dev`. Grafana redirects to Bitcoin++ automatically;
sign in with a current `global-admin` account and approve the requested profile
scope. Password login is disabled. The provisioned Prometheus datasource and
these dashboards should already be present under the **NixOS** folder:

- **NixOS host overview** — the monitoring droplet itself.
- **Core Lightning Overview** — node, channel, liquidity, payment, Tracker,
  collector, and safety metrics from `cln-exporter`.
- **Public services** — availability, latency, HTTP status, response size, and
  TLS expiry for `btcpp.dev` and `stream.btcpp.dev`.
- **Applications** — request rate, server-error ratio, latency percentiles,
  in-flight work, busiest routes, and Go memory for btcpp-web and streamctl.
- **Streamctl Operations** — active and failed streams, measured stream egress,
  estimated per-destination bandwidth, GPU queue pressure, public-site health,
  and streamctl host resources.
- **Bitcoin++ business** — privacy-safe ticket, check-in, speaker, volunteer,
  and recording-broadcast aggregates by conference and bounded workflow state.

Grafana Explore also includes the provisioned **Loki** datasource for CLN logs.

## Normal operations

```bash
make deploy       # apply flake/config/dashboard changes
make status       # service states and health endpoints
make logs         # follow Grafana/Prometheus/nginx logs
make ssh          # root shell on the droplet
make update       # update nixpkgs; review and deploy afterward
make plan         # preview infrastructure changes
```

Prometheus retains 30 days of samples. Size and retention are deliberately
modest for a small installation. Back up `/var/lib/grafana` if dashboards or
users are edited through the UI; Prometheus history is usually treated as
rebuildable, but can also be snapshotted.

Loki retains 14 days of logs on the local filesystem. Treat those logs as
sensitive: CLN messages can contain node, peer, channel, invoice, and plugin
details. Loki's query API remains loopback-only and is reachable by users only
through the OAuth-protected Grafana datasource.

## Core Lightning logs

Run Grafana Alloy inside the CLN container and send its file source to:

```text
https://metrics.btcpp.dev/loki/api/v1/push
```

The nginx location accepts authenticated `POST` requests from any source and
proxies them to loopback-only Loki. Use the generated high-entropy credential
only for log shippers. The CLN host needs outbound HTTPS access only; do not
expose an Alloy listener.

Install the output of `make loki-credentials` at:

```text
/var/lib/alloy-secrets/loki.env
```

After Alloy begins shipping, select the **Loki** datasource in Grafana Explore
and search for critical CLN messages:

```logql
{job="cln", node="btcpp"} |= "BROKEN"
```

Keep labels bounded to values such as `job`, `node`, `service`, and `level`.
Peer IDs, channel IDs, invoice labels, and raw plugin-provided values belong in
the log body rather than labels.

## Add Core Lightning nodes

The CLN dashboard and alert rules are copied from `../contained/exporter` and
expect that exporter on port 9750. On each node, install the plugin and bind it
to the node's private/VPN address:

```text
plugin=/absolute/path/to/cln-exporter
prometheus-listen=10.x.y.z:9750
prometheus-rpc-timeout=5
prometheus-liquidity-target-percent=20
prometheus-htlc-warning-blocks=12
```

Allow TCP 9750 only from the monitoring host's private/VPN address. The endpoint
is unauthenticated and contains node, peer, channel, and account identifiers.
Never expose it openly to the internet.

Add the nodes to `nixos/targets.nix` with stable, human-readable labels:

```nix
cln = [
  { node = "routing-1"; target = "10.10.0.5:9750"; }
  { node = "treasury-1"; target = "10.10.0.6:9750"; }
];
```

Then deploy and check the targets:

```bash
make deploy
make status
```

In Grafana, open **Core Lightning Overview** and select a node from the `node`
drop-down. Prometheus also loads `rules/cln-alerts.yml`; those rules become
visible as pending/firing alerts immediately. Delivering alerts to email,
Telegram, or another destination is a separate Alertmanager setup.

The bundled `ClnBackupPluginInactive` rule assumes the community backup plugin
is mandatory, and the Tracker rules assume Tracker is installed. Delete or
adjust those rules when that is not true for every node.

## Public service monitoring

`nixos/targets.nix` initially probes:

```nix
publicHttp = [
  "https://btcpp.dev/"
  "https://stream.btcpp.dev/"
];
```

These are external blackbox probes, so they work without modifying either app.
They tell us whether a user can reach the service, how long the request takes,
which status code it returns, and when its TLS certificate expires. Rules under
`rules/public-services-alerts.yml` flag sustained downtime, responses over three
seconds, and certificates within 14 days of expiry.

`rules/streamctl-alerts.yml` additionally flags failed streams, active streams
with effectively no egress, GPU queues stalled for over an hour, unresolved GPU
failures, an unreachable streamctl node exporter, and root-disk usage above
85%. These rules are loaded into Prometheus but still require Alertmanager for
external delivery.

Both applications now expose request and Go runtime metrics at an authenticated
`/metrics` endpoint. After the first monitoring-host deploy, print its generated
tokens:

```bash
make metrics-tokens
# btcpp-web=<hex token>
# streamctl=<hex token>
```

Configure the `btcpp-web` value as a secret App Platform environment variable:

```text
METRICS_TOKEN=<btcpp-web token>
```

Install the streamctl value on its NixOS host before or after deploying the
instrumented streamctl build:

```bash
printf '%s\n' '<streamctl token>' | ssh root@<stream-host> \
  'install -m 0400 -o streamctl -g streamctl /dev/stdin /var/lib/streamctl/metrics-token && systemctl restart streamctl'
```

The endpoints remain disabled (HTTP 404) when their token is absent. Wrong or
missing Bearer credentials receive HTTP 401. Prometheus uses separate token
files for the two services, and the **Applications** dashboard combines their
bounded route-template metrics without storing raw request paths as labels.

This first application layer covers HTTP RED signals and standard Go/process
metrics. Active streams, scheduled jobs, upload/prefetch outcomes, mail jobs,
recording automation, and database pool behavior are sensible next custom
collectors once the baseline has real traffic.

## Monitor another NixOS host

Do not expose port 9100 to the whole internet. Prefer a DigitalOcean VPC or a
WireGuard network between hosts. On the target host:

```nix
services.prometheus.exporters.node = {
  enable = true;
  listenAddress = "10.x.y.z"; # that host's private/VPN address
  enabledCollectors = [ "systemd" ];
  openFirewall = false;
};

networking.firewall.interfaces.<private-interface>.allowedTCPPorts = [ 9100 ];
```

Then add a target in `nixos/targets.nix`:

```nix
nodes = [
  { host = "dashes"; target = "127.0.0.1:9100"; }
  { host = "another-host"; target = "10.x.y.z:9100"; }
];
```

For `../streamer`, the clean long-term arrangement is to add the exporter to its
NixOS config, connect both droplets through their private network, and allow
9100 only from this monitoring droplet's private IP. Once basic host metrics are
working, application metrics, Alertmanager notifications, and Loki logs can be
added independently.

## Teardown

```bash
make destroy
```

This permanently deletes the droplet and its local Grafana/Prometheus data.
Take a backup or snapshot first if anything needs to survive.
