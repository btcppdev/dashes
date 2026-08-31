{ lib, ... }:
{
  # This file was populated at runtime with the networking
  # details gathered from the active system.
  networking = {
    nameservers = [ "8.8.8.8" ];
    defaultGateway = "159.203.64.1";
    defaultGateway6 = {
      address = "2604:a880:800:14::1";
      interface = "eth0";
    };
    dhcpcd.enable = false;
    usePredictableInterfaceNames = lib.mkForce false;
    interfaces = {
      eth0 = {
        ipv4.addresses = [
          {
            address = "159.203.74.87";
            prefixLength = 20;
          }
          {
            address = "10.17.0.6";
            prefixLength = 16;
          }
        ];
        ipv6.addresses = [
          {
            address = "2604:a880:800:14:0:3:6c33:7000";
            prefixLength = 64;
          }
          {
            address = "fe80::6450:64ff:fea1:dca0";
            prefixLength = 64;
          }
        ];
        ipv4.routes = [ { address = "159.203.64.1"; prefixLength = 32; } ];
        ipv6.routes = [ { address = "2604:a880:800:14::1"; prefixLength = 128; } ];
      };
      eth1 = {
        ipv4.addresses = [
          {
            address = "10.108.0.6";
            prefixLength = 20;
          }
        ];
        ipv6.addresses = [
          {
            address = "fe80::4cf:cff:fe2a:90f3";
            prefixLength = 64;
          }
        ];
      };
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="66:50:64:a1:dc:a0", NAME="eth0"
    ATTR{address}=="06:cf:0c:2a:90:f3", NAME="eth1"
  '';
}
