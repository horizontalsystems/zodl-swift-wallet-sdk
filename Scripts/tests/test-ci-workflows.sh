# Offline, text-only checks on how CI builds and caches the FFI: the root
# Makefile's ffi-ci target and the workflows that call it. Like
# test-workflow.sh, these never run cargo, gh or a workflow. `make -n` prints
# the commands a target would run; GNU make still descends into `$(MAKE)`
# lines under -n, but only to print their commands too.

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
