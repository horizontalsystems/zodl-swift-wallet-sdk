#!/usr/bin/env python3
"""Build a public, immutable SDK source checkout into an Actions artifact bundle."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from xml.parsers.expat import ExpatError

PUBLIC_REPOSITORY = "zodl-inc/zodl-swift-wallet-sdk"
WORKFLOW_PATH = ".github/workflows/sdk-release-build.yml"
CARGO_BUILD = "CARGO_BUILD=RUSTUP_TOOLCHAIN=stable $(if $(MACOSX_DEPLOYMENT_TARGET),MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) )$(if $(IPHONEOS_DEPLOYMENT_TARGET),IPHONEOS_DEPLOYMENT_TARGET=$(IPHONEOS_DEPLOYMENT_TARGET) )cargo build --locked --manifest-path ../Cargo.toml --release"
TARGETS = ("clean-ffi", "ffi-all", "configure-local-ffi", "build", "test-offline")
SLICES = {
    "ios-arm64": ("ios", None, {"arm64"}),
    "ios-arm64_x86_64-simulator": ("ios", "simulator", {"arm64", "x86_64"}),
    "macos-arm64_x86_64": ("macos", None, {"arm64", "x86_64"}),
}
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


class BuildError(ValueError):
    """A request or build cannot produce verified release evidence."""


def run(args: list[str], cwd: Path, *, capture: bool = True) -> str:
    """Native build output streams to the job log; identity output is captured."""
    try:
        result = subprocess.run(args, cwd=cwd, text=True, check=False,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None)
    except OSError as error:
        raise BuildError("could not execute " + args[0]) from error
    if result.returncode:
        # Captured Git output can include credential-bearing URLs, so never echo it.
        raise BuildError("command failed: " + args[0] + " " + args[1] + " (exit " + str(result.returncode) + ")")
    return result.stdout.strip() if capture else ""


def canonical_version(value: str) -> str:
    match = SEMVER.fullmatch(value) if isinstance(value, str) else None
    if not match or (match[4] and any(part.isdigit() and len(part) > 1 and part[0] == "0" for part in match[4].split("."))):
        raise BuildError("invalid canonical SDK semantic version")
    return value


def validate_request(request: dict) -> None:
    required = {"source_sha", "release_version", "mode", "request_id", "expected_workflow_sha", "repository",
                "workflow_ref", "workflow_sha", "run_id", "run_attempt", "server_url"}
    if not isinstance(request, dict) or set(request) != required:
        raise BuildError("missing or unexpected build request fields")
    for key, length in (("source_sha", 40), ("expected_workflow_sha", 40), ("workflow_sha", 40), ("request_id", 32)):
        if not isinstance(request[key], str) or not re.fullmatch("[0-9a-f]{" + str(length) + "}", request[key]):
            raise BuildError("invalid " + key)
    canonical_version(request["release_version"])
    if request["mode"] not in ("existing-tag", "source-and-binary"):
        raise BuildError("invalid release mode")
    if request["repository"] != PUBLIC_REPOSITORY or request["server_url"] != "https://github.com":
        raise BuildError("build requires the public SDK repository on github.com")
    if request["expected_workflow_sha"] != request["workflow_sha"]:
        raise BuildError("workflow SHA differs from expected workflow")
    prefix = PUBLIC_REPOSITORY + "/" + WORKFLOW_PATH + "@"
    ref = request["workflow_ref"]
    if not isinstance(ref, str) or not ref.startswith(prefix):
        raise BuildError("unexpected workflow repository or path")
    selected_ref = ref[len(prefix):]
    if not re.fullmatch(r"refs/(?:heads|tags)/[A-Za-z0-9_./-]+", selected_ref) or any(
            bad in selected_ref for bad in ("..", "//", "/.", ".lock/")) or selected_ref.endswith(("/", ".", ".lock")):
        raise BuildError("invalid workflow ref")
    for key in ("run_id", "run_attempt"):
        if type(request[key]) is not int or request[key] <= 0:
            raise BuildError("invalid " + key)


def real_path(path: Path) -> Path:
    path = path.absolute()
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise BuildError("source/output paths must not contain symlinks")
    return path.resolve()


def verify_source(source: Path, commit: str, tree: str) -> None:
    if run(["git", "rev-parse", "HEAD"], source) != commit or run(["git", "rev-parse", "HEAD^{tree}"], source) != tree:
        raise BuildError("source commit/tree changed during build")
    if run(["git", "status", "--porcelain", "--untracked-files=normal"], source):
        raise BuildError("source checkout must be clean")


def read_plist(path: Path) -> dict:
    try:
        value = plistlib.loads(path.read_bytes())
        if not isinstance(value, dict):
            raise ValueError("expected dictionary")
        return value
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise BuildError("missing or malformed plist: " + path.name) from error


def table_value(text: str, table: str, key: str) -> str:
    matches = list(re.finditer(r"(?m)^\[" + re.escape(table) + r"\]\s*$", text))
    if len(matches) != 1:
        raise BuildError("ambiguous Cargo table")
    start = matches[0].end()
    end = re.search(r"(?m)^\[", text[start:])
    block = text[start:start + end.start()] if end else text[start:]
    values = re.findall(r'(?m)^' + key + r'\s*=\s*"([^"\n]+)"\s*(?:#.*)?$', block)
    if len(values) != 1:
        raise BuildError("missing or ambiguous Cargo field")
    return values[0]


def component_versions(source: Path) -> dict:
    try:
        cargo = (source / "Cargo.toml").read_text()
        if table_value(cargo, "package", "name") != "libzcashlc":
            raise BuildError("unexpected Cargo package identity")
        cargo_version = canonical_version(table_value(cargo, "package", "version"))
        lock = (source / "Cargo.lock").read_text()
        roots = []
        for block in re.findall(r"(?ms)^\[\[package\]\]\s*\n(?:(?!^\[).)*", lock):
            names = re.findall(r'(?m)^name\s*=\s*"([^"\n]+)"\s*$', block)
            if "libzcashlc" in names:
                versions = re.findall(r'(?m)^version\s*=\s*"([^"\n]+)"\s*$', block)
                if names != ["libzcashlc"] or len(versions) != 1 or re.search(r"(?m)^(source|checksum)\s*=", block):
                    raise BuildError("ambiguous Cargo.lock root package")
                roots.append(versions[0])
        if roots != [cargo_version]:
            raise BuildError("Cargo.lock root version differs from Cargo package")
        plist = read_plist(source / "BuildSupport/platform-Info.plist")
        if plist.get("CFBundleIdentifier") != "libzcashlc" or plist.get("CFBundleExecutable") != "libzcashlc":
            raise BuildError("unexpected platform plist identity")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if not isinstance(plist.get(key), str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", plist[key]):
                raise BuildError("invalid platform plist version")
        return {"cargo": cargo_version, "lock": roots[0], "plist_short": plist["CFBundleShortVersionString"], "plist_build": plist["CFBundleVersion"]}
    except OSError as error:
        raise BuildError("missing native component metadata") from error


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_slices(product: Path, versions: dict, source: Path) -> list[dict]:
    if product.is_symlink() or not product.is_dir() or any(path.is_symlink() for path in product.rglob("*")):
        raise BuildError("native product must be a real tree without symlinks")
    info = read_plist(product / "Info.plist")
    libraries = info.get("AvailableLibraries")
    if info.get("XCFrameworkFormatVersion") != "1.0" or info.get("CFBundlePackageType") != "XFWK" or not isinstance(libraries, list) or len(libraries) != 3:
        raise BuildError("invalid full XCFramework manifest")
    verified = []
    seen = set()
    for item in libraries:
        if not isinstance(item, dict):
            raise BuildError("invalid XCFramework slice")
        identifier = item.get("LibraryIdentifier")
        if not isinstance(identifier, str) or identifier not in SLICES or identifier in seen:
            raise BuildError("unexpected or duplicate XCFramework slice")
        seen.add(identifier)
        platform, variant, architectures = SLICES[identifier]
        actual_arches = item.get("SupportedArchitectures")
        if item.get("SupportedPlatform") != platform or item.get("SupportedPlatformVariant") != variant or item.get("LibraryPath") != "libzcashlc.framework" or not isinstance(actual_arches, list) or not all(isinstance(arch, str) for arch in actual_arches) or set(actual_arches) != architectures or len(actual_arches) != len(architectures):
            raise BuildError("invalid XCFramework slice metadata")
        framework = product / identifier / "libzcashlc.framework"
        for name in ("libzcashlc", "Headers/zcashlc.h", "Modules/module.modulemap", "Info.plist"):
            path = framework / name
            if not path.is_file() or path.stat().st_size == 0:
                raise BuildError("missing/nonempty framework binary, headers or modules")
        actual = run(["lipo", "-archs", str(framework / "libzcashlc")], source).split()
        if set(actual) != architectures or len(actual) != len(architectures):
            raise BuildError("actual binary architectures do not match full slice")
        module = (framework / "Modules/module.modulemap").read_text()
        if not re.search(r"\bmodule\s+libzcashlc\b", module) or "zcashlc.h" not in module:
            raise BuildError("invalid libzcashlc module map")
        plist = read_plist(framework / "Info.plist")
        if plist.get("CFBundleIdentifier") != "libzcashlc" or plist.get("CFBundleExecutable") != "libzcashlc" or plist.get("CFBundleShortVersionString") != versions["plist_short"] or plist.get("CFBundleVersion") != versions["plist_build"]:
            raise BuildError("framework plist differs from immutable source metadata")
        verified.append({"identifier": identifier, "platform": platform, "variant": variant,
                         "architectures": sorted(actual), "binary_sha256": sha256(framework / "libzcashlc")})
    return verified


def build_release(source: Path, output: Path, request: dict) -> dict:
    """Verify and build selected public source; publish the complete bundle atomically."""
    validate_request(request)
    source = real_path(source)
    output = real_path(output)
    tooling = Path(__file__).resolve()
    if source == output or source in output.parents or output in source.parents:
        raise BuildError("output must be outside the source checkout")
    if source in tooling.parents:
        raise BuildError("runner tooling must be outside the selected source checkout")
    if not source.is_dir() or (output.exists() and (not output.is_dir() or any(output.iterdir()))):
        raise BuildError("source must exist and output must be new or empty")
    if Path(run(["git", "rev-parse", "--show-toplevel"], source)).resolve() != source:
        raise BuildError("source must be the repository root")
    origin = run(["git", "remote", "get-url", "--all", "origin"], source)
    if origin not in ("https://github.com/" + PUBLIC_REPOSITORY, "https://github.com/" + PUBLIC_REPOSITORY + ".git",
                      "git@github.com:" + PUBLIC_REPOSITORY + ".git"):
        raise BuildError("source origin must be the public SDK repository")
    tree = run(["git", "rev-parse", "HEAD^{tree}"], source)
    verify_source(source, request["source_sha"], tree)
    components = component_versions(source)
    if request["mode"] == "source-and-binary":
        core = re.split(r"[-+]", request["release_version"], maxsplit=1)[0]
        if components != {"cargo": request["release_version"], "lock": request["release_version"], "plist_short": core, "plist_build": core}:
            raise BuildError("source-and-binary requires an already prepared immutable component version")
    product = source / "BuildSupport/products/libzcashlc.xcframework"
    commands = [["make", target, CARGO_BUILD] for target in TARGETS]
    for command in commands:
        print("Running " + command[0] + " " + command[1], flush=True)
        run(command, source, capture=False)
        verify_source(source, request["source_sha"], tree)
        if command[1] == "clean-ffi" and (product.exists() or product.is_symlink()):
            raise BuildError("stale native product survived clean-ffi")
    slices = verify_slices(product, components, source)
    toolchain = {
        "swift": run(["swift", "--version"], source),
        "cargo": run(["cargo", "+stable", "--version", "--verbose"], source),
        "rustc": run(["rustc", "+stable", "--version", "--verbose"], source),
        "xcode": run(["xcodebuild", "-version", "-skipMacroValidation", "-derivedDataPath", str(source / "DerivedData")], source),
    }
    if not all(toolchain.values()):
        raise BuildError("missing compiler identity")
    verify_source(source, request["source_sha"], tree)
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".sdk-release-", dir=output.parent))
    try:
        artifact = staging / "libzcashlc.xcframework.zip"
        with zipfile.ZipFile(artifact, "x", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(product.rglob("*")):
                if path.is_symlink() or not (path.is_file() or path.is_dir()):
                    raise BuildError("unsupported native product entry")
                if path.is_file():
                    archive.write(path, str(path.relative_to(product.parent)))
        digest = sha256(artifact)
        proof = {
            "schema_version": 1, "kind": "zodl-sdk-ci-build", "repository": request["repository"],
            "request_id": request["request_id"], "mode": request["mode"], "release_version": request["release_version"],
            "source": {"commit": request["source_sha"], "tree": tree},
            "workflow": {"path": WORKFLOW_PATH, "ref": request["workflow_ref"], "sha": request["workflow_sha"]},
            "run": {"id": request["run_id"], "attempt": request["run_attempt"], "url": "https://github.com/" + PUBLIC_REPOSITORY + "/actions/runs/" + str(request["run_id"])},
            "component_versions": components, "commands": commands, "slices": slices,
            "artifact": {"file": artifact.name, "size": artifact.stat().st_size, "sha256": digest}, "toolchain": toolchain,
        }
        (staging / (artifact.name + ".sha256")).write_text(digest + "  " + artifact.name + "\n")
        (staging / "build-provenance.json").write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n")
        verify_source(source, request["source_sha"], tree)
        if output.exists():
            output.rmdir()
        staging.rename(output)
        return proof
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args(argv)
    try:
        fields = {"source_sha": "SOURCE_SHA", "release_version": "RELEASE_VERSION", "mode": "MODE", "request_id": "REQUEST_ID",
                  "expected_workflow_sha": "EXPECTED_WORKFLOW_SHA", "repository": "GITHUB_REPOSITORY", "workflow_ref": "GITHUB_WORKFLOW_REF",
                  "workflow_sha": "GITHUB_WORKFLOW_SHA", "run_id": "GITHUB_RUN_ID", "run_attempt": "GITHUB_RUN_ATTEMPT", "server_url": "GITHUB_SERVER_URL"}
        request = {key: os.environ.get(value, "") for key, value in fields.items()}
        for key in ("run_id", "run_attempt"):
            if not re.fullmatch(r"[1-9][0-9]*", request[key]):
                raise BuildError("invalid GitHub run identity")
            request[key] = int(request[key])
        build_release(args.source, args.output, request)
        return 0
    except (BuildError, OSError, UnicodeError) as error:
        print("SDK release build failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
