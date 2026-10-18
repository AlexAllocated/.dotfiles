import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "releases", Path(__file__).resolve().parents[1] / "scripts/updates/releases.py"
)
releases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(releases)


def package(arch, version="26.917.62051", **overrides):
    fields = {
        "Package": "chatgpt",
        "Architecture": arch,
        "Version": version,
        "Filename": f"pool/main/c/chatgpt/chatgpt_{version}_{arch}.deb",
        "SHA256": "a" * 64,
    }
    fields.update(overrides)
    return "\n".join(f"{key}: {value}" for key, value in fields.items())


class ReleaseTests(unittest.TestCase):
    def test_stable_branch_change_preserves_unstable_and_other_configuration(self):
        source = 'nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";\nother.url = "github:NixOS/nixpkgs/nixpkgs-unstable";\n# user changes\n'
        result = releases.replace_ref(source, "NixOS/nixpkgs", "nixos-26.05")
        self.assertEqual(result, source.replace("nixos-25.11", "nixos-26.05"))

    def test_no_downgrades(self):
        with self.assertRaisesRegex(ValueError, "downgrade"):
            releases.replace_ref(
                '"github:mangowm/mango/0.18.0"', "mangowm/mango", "0.17.3"
            )

    def test_beta_can_advance_to_stable(self):
        self.assertIn(
            '/v5.1.0"',
            releases.replace_ref(
                '"github:noctalia-dev/noctalia-shell/v5.0.0-beta.3"',
                "noctalia-dev/noctalia-shell",
                "v5.1.0",
            ),
        )

    def test_ambiguous_input_fails(self):
        with self.assertRaisesRegex(ValueError, "Expected one"):
            releases.replace_ref(
                '"github:mangowm/mango/0.17.1" "github:mangowm/mango/0.17.2"',
                "mangowm/mango",
                "0.17.3",
            )

    def test_missing_companion_branch_fails(self):
        with patch.object(
            releases, "refs", side_effect=[["25.11", "26.05"], ["nixos-26.05"], []]
        ):
            with self.assertRaisesRegex(ValueError, "missing nix-community"):
                releases.update_flake('"github:NixOS/nixpkgs/nixos-25.11"')

    def test_newest_desktop_and_architecture(self):
        metadata = (
            package("amd64", "26.9.1")
            + "\n\n"
            + package("amd64")
            + "\n\n"
            + package("arm64", "99.1.1")
        )
        result = releases.desktop_packages(metadata, "amd64")
        self.assertEqual(max(result, key=releases.version), "26.917.62051")

    def test_reject_bad_desktop_metadata(self):
        for override in (
            {"Filename": "../../evil.deb"},
            {"SHA256": "invalid"},
            {"Version": "invalid"},
        ):
            with self.subTest(override=override), self.assertRaises(ValueError):
                releases.desktop_packages(package("amd64", **override), "amd64")

    def test_desktop_requires_matching_architecture_versions(self):
        with patch.object(
            releases,
            "fetch",
            side_effect=[package("amd64"), package("arm64", "26.916.1")],
        ):
            with self.assertRaisesRegex(ValueError, "consistent"):
                releases.update_desktop({"version": "26.915.1"})

    def test_desktop_success_and_no_downgrade(self):
        for current in ("26.915.1", "27.1.1"):
            with patch.object(
                releases, "fetch", side_effect=[package("amd64"), package("arm64")]
            ):
                if current.startswith("27"):
                    with self.assertRaisesRegex(ValueError, "downgrade"):
                        releases.update_desktop({"version": current})
                else:
                    result = releases.update_desktop({"version": current})
                    self.assertEqual(
                        set(result["assets"]), {"x86_64-linux", "aarch64-linux"}
                    )
                    self.assertEqual(result["version"], "26.917.62051")

    def test_cargo_hashes_follow_locked_commits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "src-tauri").mkdir()
            (root / "pins").mkdir()
            (root / "src-tauri/Cargo.lock").write_text(
                '[[package]]\nname = "example"\nversion = "1.2.3"\n'
                'source = "git+https://github.com/example/lib?branch=main#'
                + "a" * 40
                + '"\n'
            )
            with patch.object(
                releases.subprocess,
                "check_output",
                side_effect=[str(root), json.dumps({"hash": "sha256-example"})],
            ) as command:
                releases.update_iloader_cargo(root)
            self.assertEqual(
                json.loads((root / "pins/iloader-cargo.json").read_text()),
                {"example-1.2.3": "sha256-example"},
            )
            target = command.call_args_list[1].args[0][3]
            self.assertIn("rev=" + "a" * 40, target)
            self.assertNotIn("branch=main", target)
            self.assertIn("submodules=1", target)

    def test_discovery_failure_does_not_write_partial_pins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "pins").mkdir()
            (root / "flake.nix").write_text("original flake")
            (root / "pins/chatgpt-desktop.json").write_text('{"version":"1.2.3"}')
            with (
                patch("sys.argv", ["releases.py", str(root)]),
                patch.object(releases, "update_flake", return_value="new flake"),
                patch.object(
                    releases,
                    "update_desktop",
                    side_effect=ValueError("metadata failed"),
                ),
            ):
                with self.assertRaisesRegex(ValueError, "metadata failed"):
                    releases.main()
            self.assertEqual((root / "flake.nix").read_text(), "original flake")
            self.assertEqual(
                (root / "pins/chatgpt-desktop.json").read_text(), '{"version":"1.2.3"}'
            )

    def test_no_nix_preserves_flake(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "pins").mkdir()
            (root / "flake.nix").write_text("original flake")
            (root / "pins/chatgpt-desktop.json").write_text('{"version":"1.2.3"}')
            with (
                patch("sys.argv", ["releases.py", str(root), "--skip-flake"]),
                patch.object(releases, "update_flake") as update_flake,
                patch.object(
                    releases, "update_desktop", return_value={"version": "1.2.4"}
                ),
            ):
                releases.main()
            update_flake.assert_not_called()
            self.assertEqual((root / "flake.nix").read_text(), "original flake")


if __name__ == "__main__":
    unittest.main()
