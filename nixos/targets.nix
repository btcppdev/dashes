{
  # Public services monitored through the blackbox exporter. These probes cover
  # availability, response time, HTTP status, redirects, and TLS expiry.
  publicHttp = [
    "https://btcpp.dev/"
    "https://stream.btcpp.dev/"
  ];

  # Authenticated application metrics. Tokens are generated on the monitoring
  # host during its first Prometheus start; `make metrics-tokens` prints them.
  applications = [
    {
      service = "btcpp-web";
      target = "btcpp.dev";
      tokenFile = "/var/lib/prometheus2/scrape-secrets/btcpp-web";
    }
    {
      service = "streamctl";
      target = "stream.btcpp.dev";
      tokenFile = "/var/lib/prometheus2/scrape-secrets/streamctl";
    }
  ];

  # One entry per cln-exporter listener. Use a private VPC or VPN address; the
  # endpoint contains node/channel identifiers and has no authentication.
  #
  # cln = [
  #   { node = "routing-1"; target = "10.10.0.5:9750"; }
  #   { node = "treasury-1"; target = "10.10.0.6:9750"; }
  # ];
  cln = [
    { node = "btcpp"; target = "45.55.129.100:9878"; }
  ];
}
