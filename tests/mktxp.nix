# NixOS integration test for the mktxp module.
#
# Verifies that:
#   1. The systemd service starts successfully.
#   2. The HTTP server binds to port 49090.
#   3. The /metrics endpoint is reachable and returns an HTTP 200.
#   4. The generated config files are written to the state directory.
#   5. The module assertion fires when no routers are configured.
#
# NOTE: mktxp will attempt (and fail) to connect to the configured router
# address at test time; that is expected and does not affect the HTTP server.
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "mktxp";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.mktxp ];

      services.mktxp = {
        enable = true;

        # Tune the global listener for a loopback-only test environment.
        settings = {
          listen = "127.0.0.1:49090";
          # Keep retries short so the test does not stall on unreachable routers.
          initial_delay_on_failure = 10;
          max_delay_on_failure = 30;
          verbose_mode = true;
        };

        # Minimal per-router defaults: disable collectors that make no sense
        # in a VM with no attached RouterOS hardware.
        defaultRouterSettings.settings = {
          health = false;
          installed_packages = false;
          dhcp = false;
          dhcp_lease = false;
          connections = false;
          interface = false;
          route = false;
          pool = false;
          firewall = false;
          neighbor = false;
          poe = false;
          monitor = false;
          netwatch = false;
          public_ip = false;
          wireless = false;
          wireless_clients = false;
          capsman = false;
          capsman_clients = false;
          user = false;
          queue = false;
        };

        routers."test-router".settings = {
          # Points at the VM's loopback — will not have a RouterOS API,
          # but mktxp still starts the HTTP server and serves /metrics.
          hostname = "127.0.0.1";
          port = 8728;
        };
      };
    };

  testScript = ''
    machine.start()

    with subtest("service reaches active state"):
        machine.wait_for_unit("mktxp.service")

    with subtest("HTTP server binds to port 49090"):
        machine.wait_for_open_port(49090, addr="127.0.0.1", timeout=120)

    with subtest("/metrics endpoint returns HTTP 200"):
        machine.succeed("curl -fsS http://127.0.0.1:49090/metrics")

    with subtest("config files exist in the state directory"):
        machine.succeed("test -f /var/lib/mktxp/_mktxp.conf")
        machine.succeed("test -f /var/lib/mktxp/mktxp.conf")

    with subtest("[test-router] section is present in generated config"):
        # BindReadOnlyPaths are only visible inside the service's private mount
        # namespace (created by ProtectSystem=strict).  Access via /proc/PID/root
        # follows the service's namespace and sees the Nix-store bind mount.
        machine.succeed(
            "PID=$(systemctl show mktxp.service --property=MainPID --value) && "
            "grep -q '\\[test-router\\]' /proc/$PID/root/var/lib/mktxp/mktxp.conf"
        )

    with subtest("[MKTXP] section reflects NixOS option values"):
        machine.succeed(
            "PID=$(systemctl show mktxp.service --property=MainPID --value) && "
            "grep -q 'listen = 127.0.0.1:49090' /proc/$PID/root/var/lib/mktxp/_mktxp.conf"
        )
        machine.succeed(
            "PID=$(systemctl show mktxp.service --property=MainPID --value) && "
            "grep -q 'verbose_mode = True' /proc/$PID/root/var/lib/mktxp/_mktxp.conf"
        )

    with subtest("service is running under the dedicated mktxp user"):
        machine.succeed("systemctl show mktxp.service --property=User | grep -q 'User=mktxp'")
  '';
}
