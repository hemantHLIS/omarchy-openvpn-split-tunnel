"""Unit tests for backend functions that do not touch NetworkManager."""

from importlib.machinery import SourceFileLoader
from pathlib import Path
import tempfile
import unittest
from unittest.mock import call, patch

BACKEND = Path(__file__).parents[1] / "scripts" / "openvpn-widget"
module = SourceFileLoader("openvpn_widget", str(BACKEND)).load_module()


class BackendTests(unittest.TestCase):
    def test_parse_terse_line_unescapes_colons_and_backslashes(self):
        self.assertEqual(
            module.parse_terse_line(r"uuid:Name\: office:vpn\\type"),
            ["uuid", "Name: office", "vpn\\type"],
        )

    def test_discover_returns_supported_files_in_name_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Zurich.ovpn").touch()
            (root / "amsterdam.conf").touch()
            (root / "ignore.txt").touch()
            self.assertEqual(
                [item.name for item in module.discover(root)],
                ["amsterdam.conf", "Zurich.ovpn"],
            )

    def test_config_key_is_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vpn.ovpn"
            path.touch()
            self.assertEqual(module.config_key(path), module.config_key(path.resolve()))
            self.assertEqual(len(module.config_key(path)), 64)

    def test_import_uses_name_assigned_before_first_connection(self):
        path = Path("/tmp/office.ovpn")
        state = {str(path): {"name": "Main office"}}
        imported = {"vpn-uuid": {"uuid": "vpn-uuid", "name": "office", "type": "vpn"}}

        with (
            patch.object(module, "nm_connections", side_effect=[{}, imported]),
            patch.object(module, "run") as run,
            patch.object(module, "save_state") as save_state,
        ):
            record = module.ensure_imported(path, state)

        self.assertEqual(record, {"uuid": "vpn-uuid", "name": "Main office"})
        self.assertEqual(
            run.call_args_list,
            [
                call(["nmcli", "connection", "import", "type", "openvpn", "file", str(path)]),
                call(["nmcli", "connection", "modify", "uuid", "vpn-uuid", "connection.id", "Main office"]),
            ],
        )
        save_state.assert_called_once_with(state)

    def test_ovpn_defaults_follow_route_nopull_and_routes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "office.ovpn"
            path.write_text("client\nroute-nopull\nroute 10.0.0.0 255.0.0.0\nroute 1.2.3.4 255.255.255.255 net_gateway\n")
            self.assertEqual(
                module.ovpn_routing_defaults(path),
                {"mode": "split", "routes": ["10.0.0.0/8"], "ignoreServerRoutes": True, "dnsDomains": []},
            )

    def test_ovpn_defaults_full_tunnel_with_redirect_gateway(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "office.ovpn"
            path.write_text("client\nredirect-gateway def1\n")
            self.assertEqual(module.ovpn_routing_defaults(path)["mode"], "full")

    def test_normalize_route_accepts_netmask_and_cidr(self):
        self.assertEqual(module.normalize_route("192.168.10.0 255.255.255.0"), "192.168.10.0/24")
        self.assertEqual(module.normalize_route("10.1.2.3/16"), "10.1.0.0/16")
        with self.assertRaises(module.WidgetError):
            module.normalize_route("not-a-route")

    def test_apply_split_routing_keeps_default_route(self):
        routing = {"mode": "split", "routes": ["10.0.0.0/8"], "ignoreServerRoutes": True, "dnsDomains": ["corp.lan"]}
        with patch.object(module, "run") as run:
            module.apply_routing("vpn-uuid", routing)
        command = run.call_args.args[0]
        settings = dict(zip(command[5::2], command[6::2]))
        self.assertEqual(settings["ipv4.never-default"], "yes")
        self.assertEqual(settings["ipv4.routes"], "10.0.0.0/8")
        self.assertEqual(settings["ipv4.ignore-auto-routes"], "yes")
        self.assertEqual(settings["ipv4.dns-search"], "~corp.lan")


if __name__ == "__main__":
    unittest.main()
