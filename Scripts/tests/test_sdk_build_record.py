"""Native artifacts-command integration with real Git and external process doubles."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ["clean-ffi", "ffi-all", "configure-local-ffi", "build", "test-offline"]
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
    if target == "configure-local-ffi":
        (root / "LocalPackages").mkdir(exist_ok=True)
    if os.environ.get("MUTATE_STAGE") == target:
        (root / "Cargo.toml").write_text("mutated source")
    if target == "test-offline" and os.environ.get("FAIL_RECORD_WRITE"):
        (root / "BuildSupport/products/sdk-build-record.json").mkdir()
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
        broken = os.environ.get("BROKEN_PRODUCT")
        framework = product / "ios-arm64/libzcashlc.framework"
        if broken == "header":
            (framework / "Headers/zcashlc.h").write_text("")
        if broken == "module":
            (framework / "Modules/module.modulemap").write_text("module wrong {}")
        if broken == "plist":
            (framework / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "999"}))
        if os.environ.get("WRONG_ARCH"):
            (product / "ios-arm64/libzcashlc.framework/libzcashlc").write_text("x86_64")
        if os.environ.get("MUTATE_SOURCE") == target:
            (root / "Cargo.toml").write_text("changed by build")
        if os.environ.get("CHANGE_COMMIT"):
            subprocess = __import__("subprocess")
            subprocess.run(["git", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "changed"], check=True)
elif name == "lipo":
    print(pathlib.Path(sys.argv[-1]).read_text())
else:
    print(name + " fixture compiler identity\\ncomplete compiler/build details")
'''
GH_DOUBLE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["auth", "status"]:
    sys.exit(0)
if args[:2] == ["release", "view"]:
    if not os.environ.get("RELEASE_EXISTS"):
        sys.exit(1)
    if "--json" in args:
        print("false" if os.environ.get("PUBLISHED") else "true")
    sys.exit(0)
if args[:2] == ["release", "upload"]:
    if os.environ.get("FAIL_RECORD_UPLOAD") and any("sdk-build-record.json" in a for a in args):
        sys.exit(9)
    sys.exit(0)
if args[:2] in (["release", "create"], ["release", "edit"]):
    if os.environ.get("FAIL_UPLOAD"):
        sys.exit(9)
    sys.exit(0)
sys.exit(10)
'''

class NativeRecordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.log = self.root / "make.jsonl"
        self.ghlog = self.root / "gh.jsonl"
        for tool in ("make", "lipo", "swift", "cargo", "rustc", "xcodebuild", "gh"):
            path = self.tools / tool
            path.write_text(GH_DOUBLE if tool == "gh" else NATIVE_DOUBLE)
            path.chmod(0o755)
        for relative in ("Scripts/prepare-release.sh", "Scripts/lib/release-lib.sh", "Scripts/ci/sdk_build_record.py"):
            source = ROOT / relative
            if source.exists():
                target = self.source / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(source, target)
        (self.source / "BuildSupport").mkdir()
        (self.source / "Cargo.toml").write_text('[package]\nname = "libzcashlc"\nversion = "5.0.0"\n')
        (self.source / "Cargo.lock").write_text('version = 3\n\n[[package]]\nname = "libzcashlc"\nversion = "5.0.0"\n')
        (self.source / "BuildSupport/platform-Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "libzcashlc", "CFBundleExecutable": "libzcashlc",
            "CFBundleShortVersionString": "5.0.0", "CFBundleVersion": "42"}))
        (self.source / ".gitignore").write_text("BuildSupport/products/\nLocalPackages/\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.commit()
        self.head = self.git("rev-parse", "HEAD")
        self.tree = self.git("rev-parse", "HEAD^{tree}")
        self.products = self.source / "BuildSupport/products"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.source, text=True).strip()

    def commit(self):
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "fixture")

    def artifacts(self, *flags, record=True, expected_source=None, **env):
        environment = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "ZODL_SDK_")) and k != "GH_REPO"}
        environment.update(PATH=str(self.tools) + os.pathsep + environment["PATH"], NATIVE_LOG=str(self.log), GH_LOG=str(self.ghlog))
        if record:
            environment["ZODL_SDK_BUILD_RECORD"] = "1"
        if expected_source:
            environment["ZODL_SDK_EXPECTED_SOURCE"] = expected_source
        environment.update(env)
        return subprocess.run(["bash", "Scripts/prepare-release.sh", "artifacts", *flags, "5.0.0"], cwd=self.source, env=environment, text=True, capture_output=True)

    def make_calls(self):
        return [json.loads(line)["argv"][1:] for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def gh_calls(self):
        return [json.loads(line) for line in self.ghlog.read_text().splitlines()] if self.ghlog.exists() else []

    def record(self):
        path = self.products / "sdk-build-record.json"
        self.assertTrue(path.is_file(), "native build must produce sdk-build-record.json")
        return json.loads(path.read_text())

    def assert_no_release_write(self):
        self.assertFalse(any(c[:2] in (["release", "create"], ["release", "upload"], ["release", "edit"]) for c in self.gh_calls()))

    def test_expected_source_mismatch_stops_before_native_make(self):
        result = self.artifacts(expected_source="f" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])
        self.assert_no_release_write()

    def test_native_record_binds_actual_archive_and_source(self):
        result = self.artifacts(expected_source=self.head, ZODL_SDK_REQUEST_ID="c" * 32)
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = self.record()
        self.assertEqual(proof["source_commit"], self.head)
        self.assertEqual(proof["source_tree"], self.tree)
        self.assertEqual(proof["kind"], "zodl-sdk-native-build")
        self.assertEqual(proof["schema_version"], 1)
        archive = self.products / "libzcashlc.xcframework.zip"
        self.assertEqual(proof["artifact"], dict(name=archive.name, size=archive.stat().st_size, sha256=hashlib.sha256(archive.read_bytes()).hexdigest()))
        self.assertEqual(self.make_calls(), [[target] for target in TARGETS])
        self.assertEqual(proof["commands"], [["make", target] for target in TARGETS])
        self.assertEqual(proof["component_versions"], dict(cargo="5.0.0", lock="5.0.0", plist_short="5.0.0", plist_build="42"))
        self.assertEqual(len(proof["slices"]), 3)
        self.assertEqual(proof["execution"], dict(backend="local", request_id="c"*32, workflow=None))
        self.assertTrue(all(proof["toolchains"].values()))
        self.assertFalse((self.source / "LocalPackages").exists())
        self.assertTrue(any(c[:2] == ["release", "upload"] and any("sdk-build-record.json" in a for a in c) for c in self.gh_calls()))
        self.assertTrue((self.products / "release.env").is_file())

    def test_mutation_after_every_native_stage_stops_before_upload(self):
        for stage in TARGETS:
            with self.subTest(stage=stage):
                result = self.artifacts(MUTATE_STAGE=stage)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_release_write()
                self.git("checkout", "--", "Cargo.toml")
                self.log.unlink(missing_ok=True)

    def test_commit_movement_stops_before_upload(self):
        result = self.artifacts(CHANGE_COMMIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_incomplete_slice_is_rejected(self):
        result = self.artifacts(MISSING_SLICE="ios-arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_binary_architecture_is_verified(self):
        result = self.artifacts(WRONG_ARCH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_symlink_product_is_rejected(self):
        result = self.artifacts(SYMLINK_PRODUCT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_component_version_mismatch_stops_before_make(self):
        (self.source / "Cargo.lock").write_text('[[package]]\nname = "libzcashlc"\nversion = "4.0.0"\n')
        self.commit()
        result = self.artifacts()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])

    def test_proof_refuses_verification_bypass(self):
        for flag in ("--skip-verify", "--dry-run"):
            with self.subTest(flag=flag):
                result = self.artifacts(flag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.make_calls(), [])

    def test_failed_record_upload_does_not_write_completion(self):
        result = self.artifacts(FAIL_RECORD_UPLOAD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.products / "release.env").exists())

    def test_failed_archive_upload_does_not_write_completion(self):
        result = self.artifacts(FAIL_UPLOAD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.products / "release.env").exists())

    def test_failed_native_stage_does_not_upload(self):
        result = self.artifacts(FAIL_TARGET="test-offline")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_actions_identity_and_private_storage(self):
        repo = "owner/sdk-private"
        result = self.artifacts(GITHUB_ACTIONS="true", GITHUB_REPOSITORY=repo, GITHUB_SHA=self.head,
            GITHUB_WORKFLOW_REF=repo+"/.github/workflows/build-ffi.yml@refs/heads/candidate/5.0.0",
            GITHUB_WORKFLOW_SHA=self.head, GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = self.record()
        self.assertEqual(proof["repository"], repo)
        self.assertEqual(proof["execution"]["workflow"], dict(path=".github/workflows/build-ffi.yml", ref=repo+"/.github/workflows/build-ffi.yml@refs/heads/candidate/5.0.0", sha=self.head, run_id=123, run_attempt=2))
        self.assertEqual(proof["execution"]["backend"], "github-actions")

    def test_actions_checkout_must_match_dispatch_sha(self):
        result = self.artifacts(GITHUB_ACTIONS="true", GITHUB_REPOSITORY="owner/sdk", GITHUB_SHA="f"*40)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])

    def test_invalid_request_identity_stops_before_make(self):
        result = self.artifacts(ZODL_SDK_REQUEST_ID="not-hex")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])

    def test_existing_local_packages_is_retained(self):
        (self.source / "LocalPackages").mkdir()
        result = self.artifacts()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.source / "LocalPackages").exists())

    def test_legacy_skip_verify_and_default_repository(self):
        result = self.artifacts("--skip-verify", record=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.make_calls(), [["clean-ffi"], ["ffi-all"]])
        self.assertFalse((self.products / "sdk-build-record.json").exists())
        self.assertTrue(any("zodl-inc/zodl-swift-wallet-sdk" in c for c in self.gh_calls()))

    def test_fork_storage_remains_supported(self):
        result = self.artifacts(GH_REPO="developer/sdk")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.record()["repository"], "developer/sdk")

    def test_published_release_cannot_be_overwritten(self):
        result = self.artifacts("--force-overwrite-existing-release", RELEASE_EXISTS="1", PUBLISHED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])
        self.assert_no_release_write()

    def test_manual_force_retains_draft_replacement(self):
        result = self.artifacts("--force-overwrite-existing-release", RELEASE_EXISTS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[:2] == ["release", "upload"] and "--clobber" in c for c in self.gh_calls()))

    def test_dirty_source_stops_before_make(self):
        (self.source / "Cargo.toml").write_text("dirty")
        result = self.artifacts()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])
        self.assert_no_release_write()

    def test_stale_product_must_not_survive_clean(self):
        (self.products / "libzcashlc.xcframework").mkdir(parents=True)
        result = self.artifacts(KEEP_STALE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [["clean-ffi"]])
        self.assert_no_release_write()

    def test_failed_record_write_stops_before_upload(self):
        result = self.artifacts(FAIL_RECORD_WRITE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.products / "release.env").exists())
        self.assert_no_release_write()

    def test_broken_framework_files_stop_before_upload(self):
        for broken in ("header", "module", "plist"):
            with self.subTest(broken=broken):
                result = self.artifacts(BROKEN_PRODUCT=broken)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_release_write()

    def test_archive_must_match_verified_product(self):
        zip_tool = self.tools / "zip"
        zip_tool.write_text("#!/usr/bin/env python3\nimport subprocess, sys, zipfile\nsubprocess.run(['/usr/bin/zip', *sys.argv[1:]], check=True)\nwith zipfile.ZipFile(sys.argv[2], 'a') as bundle:\n    bundle.writestr('unexpected.txt', 'unrelated bytes')\n")
        zip_tool.chmod(0o755)
        result = self.artifacts()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_duplicate_producer_removed(self):
        for path in (".github/workflows/sdk-release-build.yml", "Scripts/ci/build-sdk-release.py", "Scripts/ci/sdk_release_build.py"):
            self.assertFalse((ROOT / path).exists(), path)

if __name__ == "__main__":
    unittest.main()
