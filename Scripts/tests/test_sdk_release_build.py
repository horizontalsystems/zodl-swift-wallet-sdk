"""Offline CI producer integration tests with real Git and native process doubles."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/ci/sdk_release_build.py"
PUBLIC = "zodl-inc/zodl-swift-wallet-sdk"
WORKFLOW_SHA = "b" * 40
REQUEST_ID = "c" * 32
CARGO_BUILD = "CARGO_BUILD=RUSTUP_TOOLCHAIN=stable $(if $(MACOSX_DEPLOYMENT_TARGET),MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) )$(if $(IPHONEOS_DEPLOYMENT_TARGET),IPHONEOS_DEPLOYMENT_TARGET=$(IPHONEOS_DEPLOYMENT_TARGET) )cargo build --locked --manifest-path ../Cargo.toml --release"
TARGETS = ["clean-ffi", "ffi-all", "configure-local-ffi", "build", "test-offline"]
SLICES = {
    "ios-arm64": ("ios", None, ["arm64"]),
    "ios-arm64_x86_64-simulator": ("ios", "simulator", ["arm64", "x86_64"]),
    "macos-arm64_x86_64": ("macos", None, ["arm64", "x86_64"]),
}

NATIVE_DOUBLE = '''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path.cwd()
if name == "make":
    with open(os.environ["NATIVE_LOG"], "a") as log:
        log.write(json.dumps({"cwd": str(root), "argv": sys.argv}) + "\\n")
    target = sys.argv[1]
    if os.environ.get("FAIL_TARGET") == target:
        print("native step failed", file=sys.stderr)
        sys.exit(9)
    product = root / "BuildSupport/products/libzcashlc.xcframework"
    if target == "clean-ffi":
        if not os.environ.get("KEEP_STALE"):
            shutil.rmtree(product, ignore_errors=True)
    if target == "ffi-all":
        slices = {
            "ios-arm64": ("ios", None, ["arm64"]),
            "ios-arm64_x86_64-simulator": ("ios", "simulator", ["arm64", "x86_64"]),
            "macos-arm64_x86_64": ("macos", None, ["arm64", "x86_64"]),
        }
        libraries = []
        for identifier, (platform, variant, arches) in slices.items():
            if os.environ.get("MISSING_SLICE") == identifier:
                continue
            framework = product / identifier / "libzcashlc.framework"
            (framework / "Headers").mkdir(parents=True)
            (framework / "Modules").mkdir()
            (framework / "libzcashlc").write_text(" ".join(arches))
            (framework / "Headers/zcashlc.h").write_text("void fixture(void);\\n")
            (framework / "Modules/module.modulemap").write_text('module libzcashlc { header "zcashlc.h" }\\n')
            shutil.copyfile(root / "BuildSupport/platform-Info.plist", framework / "Info.plist")
            libraries.append(dict(LibraryIdentifier=identifier, LibraryPath="libzcashlc.framework",
                                  SupportedPlatform=platform, SupportedArchitectures=arches))
            if variant:
                libraries[-1]["SupportedPlatformVariant"] = variant
        (product / "Info.plist").write_bytes(plistlib.dumps(dict(
            XCFrameworkFormatVersion="1.0", CFBundlePackageType="XFWK", AvailableLibraries=libraries)))
        if os.environ.get("SYMLINK_PRODUCT"):
            (product / "extra").symlink_to(root / "Cargo.toml")
        if os.environ.get("WRONG_ARCH"):
            (product / "ios-arm64/libzcashlc.framework/libzcashlc").write_text("x86_64")
        if os.environ.get("MUTATE_SOURCE"):
            (root / "Cargo.toml").write_text("changed by build")
        if os.environ.get("CHANGE_COMMIT"):
            subprocess = __import__("subprocess")
            subprocess.run(["git", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "changed"], check=True)
elif name == "lipo":
    print(pathlib.Path(sys.argv[-1]).read_text())
else:
    print(name + " fixture compiler identity\\ncomplete compiler/build details")
'''


class ProducerTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(RUNNER.is_file(), "missing artifact-only CI producer")
        spec = importlib.util.spec_from_file_location("sdk_release_build", RUNNER)
        self.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runner)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        self.output = self.root / "bundle"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for tool in ("make", "lipo", "swift", "cargo", "rustc", "xcodebuild"):
            path = self.tools / tool
            path.write_text(NATIVE_DOUBLE)
            path.chmod(0o755)
        self.log = self.root / "commands.jsonl"
        self.environment = {"PATH": str(self.tools) + os.pathsep + os.environ["PATH"], "NATIVE_LOG": str(self.log)}
        self.patch = patch.dict(os.environ, self.environment)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.git("init", "-q")
        self.git("config", "user.name", "Producer Tests")
        self.git("config", "user.email", "producer@example.invalid")
        self.git("remote", "add", "origin", "https://github.com/" + PUBLIC + ".git")
        (self.source / "BuildSupport").mkdir()
        (self.source / "Cargo.toml").write_text('[package]\nname = "libzcashlc"\nversion = "5.0.0"\n')
        (self.source / "Cargo.lock").write_text('version = 3\n\n[[package]]\nname = "libzcashlc"\nversion = "5.0.0"\n')
        (self.source / "BuildSupport/platform-Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "libzcashlc", "CFBundleExecutable": "libzcashlc",
            "CFBundleShortVersionString": "5.0.0", "CFBundleVersion": "42"}))
        (self.source / "Makefile").write_text("fixture\n")
        (self.source / ".gitignore").write_text("BuildSupport/products/\nLocalPackages/\n")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "source")
        self.sha = self.git("rev-parse", "HEAD")
        self.tree = self.git("rev-parse", "HEAD^{tree}")
        self.git("-c", "tag.gpgsign=false", "tag", "6.0.0")
        self.request = dict(source_sha=self.sha, release_version="6.0.0", mode="existing-tag",
                            request_id=REQUEST_ID, expected_workflow_sha=WORKFLOW_SHA,
                            repository=PUBLIC, workflow_ref=PUBLIC + "/.github/workflows/sdk-release-build.yml@refs/heads/main",
                            workflow_sha=WORKFLOW_SHA, run_id=12345, run_attempt=2, server_url="https://github.com")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.source, text=True).strip()

    def build(self, **changes):
        return self.runner.build_release(self.source, self.output, dict(self.request, **changes))

    def reject(self, **changes):
        with self.assertRaises(self.runner.BuildError):
            self.build(**changes)
        self.assertFalse((self.output / "build-provenance.json").exists())

    def test_existing_tag_keeps_native_version(self):
        result = self.build()
        self.assertEqual(self.sha, result["source"]["commit"])
        self.assertEqual(self.tree, result["source"]["tree"])
        self.assertEqual(dict(cargo="5.0.0", lock="5.0.0", plist_short="5.0.0", plist_build="42"), result["component_versions"])
        self.assertEqual(self.tree, self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual("", self.git("status", "--porcelain"))

    def test_full_locked_recipe(self):
        result = self.build()
        commands = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(TARGETS, [item["argv"][1] for item in commands])
        self.assertTrue(all("--locked" in item["argv"][2] for item in commands))
        self.assertTrue(all(item["cwd"] == str(self.source) for item in commands))
        self.assertEqual([["make", target, CARGO_BUILD] for target in TARGETS], result["commands"])

    def test_real_make_preserves_source_deployment_targets(self):
        fixture = self.root / "make-fixture"
        fixture.mkdir()
        (fixture / "BuildSupport").mkdir()
        (fixture / "Makefile").write_text("all:\n\t$(MAKE) -C BuildSupport all\n")
        cargo = self.tools / "cargo"
        cargo.write_text("#!/usr/bin/env python3\nimport json, os, sys\nprint(json.dumps({key: os.environ.get(key) for key in ('MACOSX_DEPLOYMENT_TARGET', 'IPHONEOS_DEPLOYMENT_TARGET')}))\nassert '--locked' in sys.argv\n")
        cargo.chmod(0o755)
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET", "MAKEFLAGS", "MFLAGS")}
        for macos, ios in (("14.0", "16.0"), ("10.15", "13.0"), (None, None)):
            with self.subTest(macos=macos, ios=ios):
                declarations = "" if macos is None else "MACOSX_DEPLOYMENT_TARGET = " + macos + "\nIPHONEOS_DEPLOYMENT_TARGET = " + ios + "\n"
                (fixture / "BuildSupport/Makefile").write_text(declarations + "all:\n\t$(CARGO_BUILD)\n")
                result = subprocess.run(["/usr/bin/make", "--no-print-directory", "all", self.runner.CARGO_BUILD],
                                        cwd=fixture, env=environment, capture_output=True, text=True)
                self.assertEqual(0, result.returncode, result.stderr)
                observed = json.loads(result.stdout.splitlines()[-1])
                self.assertEqual({"MACOSX_DEPLOYMENT_TARGET": macos, "IPHONEOS_DEPLOYMENT_TARGET": ios}, observed)
                if macos is None:
                    self.assertNotIn("MACOSX_DEPLOYMENT_TARGET=", result.stdout)
                    self.assertNotIn("IPHONEOS_DEPLOYMENT_TARGET=", result.stdout)

    def test_complete_bundle_and_wire_evidence(self):
        result = self.build()
        self.assertEqual({"libzcashlc.xcframework.zip", "libzcashlc.xcframework.zip.sha256", "build-provenance.json"}, {p.name for p in self.output.iterdir()})
        self.assertEqual(result, json.loads((self.output / "build-provenance.json").read_text()))
        self.assertEqual(1, result["schema_version"])
        self.assertEqual("zodl-sdk-ci-build", result["kind"])
        for name in ("repository", "request_id", "mode", "release_version"):
            self.assertEqual(self.request[name], result[name])
        self.assertEqual(dict(path=".github/workflows/sdk-release-build.yml", ref=self.request["workflow_ref"], sha=WORKFLOW_SHA), result["workflow"])
        self.assertEqual(dict(id=12345, attempt=2, url="https://github.com/" + PUBLIC + "/actions/runs/12345"), result["run"])
        artifact = self.output / result["artifact"]["file"]
        self.assertEqual(artifact.stat().st_size, result["artifact"]["size"])
        self.assertEqual(hashlib.sha256(artifact.read_bytes()).hexdigest(), result["artifact"]["sha256"])
        self.assertEqual(result["artifact"]["sha256"] + "  libzcashlc.xcframework.zip\n", (self.output / "libzcashlc.xcframework.zip.sha256").read_text())
        self.assertEqual(set(SLICES), {s["identifier"] for s in result["slices"]})
        self.assertEqual(5, sum(len(s["architectures"]) for s in result["slices"]))
        with zipfile.ZipFile(artifact) as archive:
            for item in result["slices"]:
                platform, variant, arches = SLICES[item["identifier"]]
                self.assertEqual((platform, variant, arches), (item["platform"], item["variant"], item["architectures"]))
                binary = archive.read("libzcashlc.xcframework/" + item["identifier"] + "/libzcashlc.framework/libzcashlc")
                self.assertEqual(hashlib.sha256(binary).hexdigest(), item["binary_sha256"])
        self.assertTrue(all("fixture compiler identity" in result["toolchain"][key] for key in ("swift", "cargo", "rustc", "xcode")))

    def test_wrong_source_sha_rejected(self):
        self.reject(source_sha="a" * 40)
        self.assertFalse(self.log.exists())

    def test_wrong_repo_rejected(self):
        self.reject(repository=PUBLIC + "-private")

    def test_nonpublic_source_origin_rejected(self):
        self.git("remote", "set-url", "origin", "https://github.com/" + PUBLIC + "-private.git")
        self.reject()

    def test_wrong_workflow_sha_rejected(self):
        self.reject(expected_workflow_sha="a" * 40)

    def test_wrong_workflow_path_or_ref_rejected(self):
        for value in (PUBLIC + "/.github/workflows/build-ffi.yml@refs/heads/main", PUBLIC + "-private/.github/workflows/sdk-release-build.yml@refs/heads/main", "garbage"):
            with self.subTest(value=value):
                self.reject(workflow_ref=value)

    def test_malformed_request_rejected_before_native_commands(self):
        for field, value in (("source_sha", "A" * 40), ("release_version", "v6.0.0"), ("release_version", "6.0"), ("release_version", "6.0.0-01"),
                             ("mode", "release"), ("request_id", "../bad"), ("request_id", "C" * 32),
                             ("workflow_sha", "no"), ("run_id", 0), ("run_attempt", "01"), ("run_id", True), ("run_attempt", False), ("server_url", "https://example.com")):
            with self.subTest(field=field, value=value):
                self.reject(**{field: value})
        self.assertFalse(self.log.exists())

    def test_native_failure_has_no_bundle(self):
        for target in TARGETS:
            with self.subTest(target=target), patch.dict(os.environ, {"FAIL_TARGET": target}):
                self.reject()

    def test_dirty_tracked_source_rejected(self):
        (self.source / "Cargo.toml").write_text("dirty")
        self.reject()
        self.assertFalse(self.log.exists())

    def test_staged_and_untracked_source_rejected(self):
        (self.source / "extra").write_text("extra")
        self.reject()
        self.git("add", "extra")
        self.reject()

    def test_native_source_mutation_rejected(self):
        with patch.dict(os.environ, {"MUTATE_SOURCE": "1"}):
            self.reject()

    def test_native_commit_mutation_rejected(self):
        with patch.dict(os.environ, {"CHANGE_COMMIT": "1"}):
            self.reject()

    def test_missing_slice_rejected(self):
        with patch.dict(os.environ, {"MISSING_SLICE": "macos-arm64_x86_64"}):
            self.reject()

    def test_actual_binary_architectures_verified(self):
        with patch.dict(os.environ, {"WRONG_ARCH": "1"}):
            self.reject()

    def test_product_symlink_rejected(self):
        with patch.dict(os.environ, {"SYMLINK_PRODUCT": "1"}):
            self.reject()

    def test_stale_product_must_be_removed(self):
        (self.source / "BuildSupport/products/libzcashlc.xcframework").mkdir(parents=True)
        with patch.dict(os.environ, {"KEEP_STALE": "1"}):
            self.reject()

    def test_unsafe_output_paths_rejected(self):
        for path in (self.source, self.source / "bundle", self.root):
            with self.subTest(path=path), self.assertRaises(self.runner.BuildError):
                self.runner.build_release(self.source, path, self.request)
        link = self.root / "link"
        link.symlink_to(self.root / "unused")
        with self.assertRaises(self.runner.BuildError):
            self.runner.build_release(self.source, link, self.request)
        self.output.mkdir()
        (self.output / "existing").write_text("preserve")
        self.reject()
        self.assertEqual("preserve", (self.output / "existing").read_text())

    def test_source_symlink_rejected(self):
        link = self.root / "linked-source"
        link.symlink_to(self.source)
        with self.assertRaises(self.runner.BuildError):
            self.runner.build_release(link, self.output, self.request)

    def test_source_and_binary_requires_prepared_native_versions(self):
        self.reject(mode="source-and-binary")

    def test_source_and_binary_builds_prepared_commit_without_rewriting(self):
        cargo = self.source / "Cargo.toml"
        lock = self.source / "Cargo.lock"
        cargo.write_text(cargo.read_text().replace("5.0.0", "6.0.0"))
        lock.write_text(lock.read_text().replace("5.0.0", "6.0.0"))
        path = self.source / "BuildSupport/platform-Info.plist"
        value = plistlib.loads(path.read_bytes())
        value["CFBundleShortVersionString"] = value["CFBundleVersion"] = "6.0.0"
        path.write_bytes(plistlib.dumps(value))
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "prepared")
        prepared = self.git("rev-parse", "HEAD")
        result = self.build(mode="source-and-binary", source_sha=prepared)
        self.assertEqual(prepared, result["source"]["commit"])
        self.assertEqual("6.0.0", result["component_versions"]["cargo"])
        self.assertEqual("", self.git("status", "--porcelain"))

    def test_cli_reads_env_and_is_separate_from_selected_source(self):
        environment = dict(os.environ, SOURCE_SHA=self.sha, RELEASE_VERSION="6.0.0", MODE="existing-tag",
                           REQUEST_ID=REQUEST_ID, EXPECTED_WORKFLOW_SHA=WORKFLOW_SHA,
                           GITHUB_REPOSITORY=PUBLIC, GITHUB_WORKFLOW_REF=self.request["workflow_ref"],
                           GITHUB_WORKFLOW_SHA=WORKFLOW_SHA, GITHUB_RUN_ID="12345", GITHUB_RUN_ATTEMPT="2",
                           GITHUB_SERVER_URL="https://github.com")
        entry = ROOT / "Scripts/ci/build-sdk-release.py"
        result = subprocess.run([sys.executable, str(entry), str(self.source), str(self.output)], cwd=self.root,
                                env=environment, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue((self.output / "build-provenance.json").is_file())
        self.assertFalse((self.source / "Scripts/ci/sdk_release_build.py").exists())

    def test_cli_errors_are_nonzero_and_no_bundle(self):
        self.assertEqual(1, self.runner.main([str(self.source), str(self.output)]))
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
