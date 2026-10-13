# Offline, text-only checks on how CI builds and caches the FFI: the root
# Makefile's ffi-ci target and the workflows that call it. Like
# test-workflow.sh, these never run cargo, gh or a workflow. `make -n` prints
# the commands a target would run; GNU make still descends into `$(MAKE)`
# lines under -n, but only to print their commands too.
# A recipe line that joins another command to `$(MAKE)` would run that command
# for real here, which is why ffi-ci keeps its rm on a line of its own.

# The dry run of `make <target>`, saved to a scratch file whose path is printed.
_dry_run() {
    local out; out="$SCRATCH/dry-run-$1.txt"
    make -C "$REPO_ROOT" -n "$1" > "$out" 2>/dev/null
    printf '%s\n' "$out"
}

test_ffi_ci_builds_only_the_arm64_macos_slice() {
    local f; f="$(_dry_run ffi-ci)"
    assert_eq "1" "$(grep -c 'cargo build' "$f")" "make ffi-ci runs exactly one cargo build"
    assert_file_contains "$f" "target aarch64-apple-darwin" "make ffi-ci builds aarch64-apple-darwin"
    assert_file_lacks "$f" "target x86_64-apple-darwin" "make ffi-ci builds no x86_64 slice"
}

test_ffi_ci_turns_fat_lto_off() {
    assert_file_contains "$(_dry_run ffi-ci)" "CARGO_PROFILE_RELEASE_LTO=false" \
        "make ffi-ci overrides the release profile's lto"
}

# lipo bundles every static library it finds under products/macos, so a stale
# x86_64 one left by an earlier `make ffi-macos` would ride along unless the
# directory is gone before the build starts.
test_ffi_ci_clears_the_macos_products_before_building() {
    local f rm_line make_line
    f="$(_dry_run ffi-ci)"
    rm_line="$(grep -n 'rm -rf BuildSupport/products/macos$' "$f" | head -1 | cut -d: -f1)"
    make_line="$(grep -n 'ffi-macos MACOS_ARCHS=aarch64-apple-darwin' "$f" | head -1 | cut -d: -f1)"
    assert_succeeds "make ffi-ci removes BuildSupport/products/macos" test -n "$rm_line"
    assert_succeeds "make ffi-ci delegates to ffi-macos with arm64 only" test -n "$make_line"
    assert_succeeds "the removal comes before the build" test "${rm_line:-0}" -lt "${make_line:-0}"
}

test_ffi_macos_still_builds_both_macos_architectures_with_lto() {
    local f; f="$(_dry_run ffi-macos)"
    assert_file_contains "$f" "target x86_64-apple-darwin" "make ffi-macos still builds x86_64"
    assert_file_contains "$f" "target aarch64-apple-darwin" "make ffi-macos still builds arm64"
    assert_file_lacks "$f" "CARGO_PROFILE_RELEASE_LTO" "make ffi-macos keeps the release profile's lto"
}

_swift_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/swift.yml"; }

# The paths-ignore entries under trigger $1 (pull_request or push) of file $2.
_paths_ignore_of() {
    awk -v t="  $1:" '
        $0 == t { in_t = 1; next }
        in_t && /^  [a-z_]+:/ { in_t = 0 }
        in_t && /^    paths-ignore:/ { in_l = 1; next }
        in_l && /^      - / { print; next }
        in_l { in_l = 0 }
    ' "$2"
}

test_swift_workflow_also_runs_on_pushes_to_main() {
    local f; f="$SCRATCH/swift-on.txt"
    awk '/^on:/ { f = 1; next } f && /^[a-z]/ { exit } f' "$(_swift_workflow)" > "$f"
    assert_file_contains "$f" "  push:" "swift.yml also triggers on push"
    assert_file_contains "$f" "    branches: [main]" "only on pushes to main"
}

test_swift_workflow_push_and_pull_request_ignore_the_same_paths() {
    local pr push
    pr="$(_paths_ignore_of pull_request "$(_swift_workflow)")"
    push="$(_paths_ignore_of push "$(_swift_workflow)")"
    assert_succeeds "pull_request has a paths-ignore list" test -n "$pr"
    assert_eq "$pr" "$push" "push ignores exactly the paths pull_request ignores"
}

# The `if:` line of the step named $1.
_step_condition() {
    awk -v n="name: $1" 'index($0, n) { f = 1; next } f && /^ *if:/ { print; exit } f && /^ *- name:/ { exit }' "$(_swift_workflow)"
}

test_swift_workflow_runs_the_rust_tests_on_push() {
    local f; f="$SCRATCH/rust-tests-if.txt"
    _step_condition "Run Rust unit tests" > "$f"
    assert_file_contains "$f" "github.event_name == 'push'" "the Rust test step runs on pushes to main"
}

test_swift_workflow_authorizes_cargo_on_push() {
    local f; f="$SCRATCH/authorize-if.txt"
    _step_condition "Authorize cargo against the private slipstream repository" > "$f"
    assert_file_contains "$f" "github.event_name == 'push'" "cargo is authorized on pushes to main"
}

test_swift_workflow_builds_the_ffi_with_ffi_ci() {
    assert_file_contains "$(_swift_workflow)" "run: make ffi-ci" "swift.yml builds the FFI with make ffi-ci"
    assert_file_lacks "$(_swift_workflow)" "run: make ffi-macos" "swift.yml no longer builds the universal slice"
}

test_swift_workflow_installs_only_the_arm64_macos_rust_target() {
    assert_file_contains "$(_swift_workflow)" "targets: aarch64-apple-darwin" "swift.yml installs aarch64-apple-darwin"
    assert_file_lacks "$(_swift_workflow)" "x86_64-apple-darwin" "swift.yml installs no x86_64 target"
}

test_swift_workflow_cache_keys_name_the_ci_build() {
    assert_file_contains "$(_swift_workflow)" "key: ffi-xcframework-macos-arm64-nolto-" "the XCFramework key names the ffi-ci build"
    assert_file_contains "$(_swift_workflow)" "cargo-v2-" "the cargo key is bumped to v2"
    assert_file_lacks "$(_swift_workflow)" "cargo-v1-" "no v1 cargo key remains"
}

test_swift_workflow_hashes_the_root_makefile() {
    assert_file_contains "$(_swift_workflow)" "find rust Cargo.toml Cargo.lock BuildSupport Makefile -type f" \
        "the FFI source hash covers the root Makefile, where ffi-ci lives"
}

test_swift_workflow_interpolates_nothing_into_run_scripts() {
    assert_eq "" "$(_run_script_interpolations "$(_swift_workflow)")" "no \${{ }} in swift.yml reaches a run: script"
}

_codeql_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/codeql.yml"; }
_build_ffi_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/build-ffi.yml"; }

test_no_workflow_selects_xcode_16() {
    assert_eq "" "$(grep -rl 'Xcode_16' "$REPO_ROOT/.github/workflows")" "no workflow selects Xcode 16"
}

test_swift_workflow_runs_on_xcode_27() {
    assert_file_contains "$(_swift_workflow)" "runs-on: xcode-27" "swift.yml builds on the xcode-27 image"
    assert_file_contains "$(_swift_workflow)" "/Applications/Xcode_27.0.app" "swift.yml selects Xcode 27.0"
}

test_build_ffi_workflow_runs_on_xcode_27() {
    assert_file_contains "$(_build_ffi_workflow)" "runs-on: xcode-27" "build-ffi.yml builds on the xcode-27 image"
    assert_file_contains "$(_build_ffi_workflow)" "/Applications/Xcode_27.0.app" "build-ffi.yml selects Xcode 27.0"
}

# Xcode 27 ships Swift 6.4, which CodeQL's Swift extractor cannot analyze yet.
test_codeql_swift_job_uses_xcode_26_6() {
    assert_file_contains "$(_codeql_workflow)" "runner: macos-26" "CodeQL's Swift job runs on macos-26"
    assert_file_contains "$(_codeql_workflow)" "/Applications/Xcode_26.6.app" "CodeQL's Swift job selects Xcode 26.6"
}

test_no_workflow_calls_slipstream_a_private_cargo_clone() {
    assert_eq "" "$(grep -rl 'PRIVATE zodl-inc/slipstream' "$REPO_ROOT/.github/workflows")" \
        "no cache comment still describes slipstream as a private git dependency"
}

# The toolchain floats on stable. After a Rust release, a cache restored by an
# exact key hit would hold artifacts the new compiler cannot reuse, and nothing
# would ever save the rebuilt ones, so the key has to name the rustc version.
test_swift_workflow_cargo_key_includes_the_toolchain() {
    assert_file_contains "$(_swift_workflow)" "id: toolchain" "the build job's Rust setup step has an id"
    assert_file_contains "$(_swift_workflow)" 'cargo-v2-${{ steps.toolchain.outputs.cachekey }}-' \
        "the cargo cache key carries the rustc version"
}
