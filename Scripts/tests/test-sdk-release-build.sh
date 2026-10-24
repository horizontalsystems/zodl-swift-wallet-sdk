# shellcheck shell=bash disable=SC2016
# The producer is intentionally independent of the legacy release uploader.
_sdk_release_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/sdk-release-build.yml"; }

test_sdk_release_public_only_artifact_workflow() {
    local f; f="$(_sdk_release_workflow)"
    assert_succeeds 'new artifact-only workflow exists' test -f "$f"
    [ -f "$f" ] || return
    assert_file_contains "$f" "github.repository == 'zodl-inc/zodl-swift-wallet-sdk'" 'only public SDK can execute'
    assert_file_contains "$f" 'contents: read' 'contents permission read only'
    assert_file_lacks "$f" 'contents: write' 'no release publication permission'
    assert_file_lacks "$f" 'secrets.' 'no publication credentials'
    assert_file_lacks "$f" 'prepare-release.sh' 'no legacy uploader'
    assert_file_lacks "$f" 'gh release' 'no release writes'
    assert_file_contains "$f" 'actions/upload-artifact@' 'publishes an Actions artifact'
    assert_file_contains "$f" 'sdk-release-${{ inputs.request_id }}-${{ github.run_id }}-${{ github.run_attempt }}' 'artifact identity includes request/run/attempt'
    assert_file_contains "$f" 'run-name: SDK binary ${{ inputs.request_id }}' 'run name permits uncertain dispatch reconciliation'
}

test_sdk_release_separates_tooling_and_source() {
    local f; f="$(_sdk_release_workflow)"
    assert_succeeds 'workflow exists' test -f "$f"
    [ -f "$f" ] || return
    assert_file_contains "$f" 'ref: ${{ inputs.source_sha }}' 'source checkout pins selected immutable SHA'
    assert_file_contains "$f" 'ref: ${{ github.workflow_sha }}' 'tooling checkout pins workflow SHA'
    assert_file_contains "$f" 'path: source' 'separate source checkout'
    assert_file_contains "$f" 'path: tooling' 'separate tooling checkout'
    assert_eq '2' "$(grep -c 'persist-credentials: false' "$f")" 'both checkouts omit persisted credentials'
    assert_file_contains "$f" './tooling/Scripts/ci/build-sdk-release.py' 'entrypoint comes from tooling'
    assert_file_contains "$f" 'EXPECTED_WORKFLOW_SHA: ${{ inputs.expected_workflow_sha }}' 'expected workflow identity passed as env'
    assert_eq '' "$(_run_script_interpolations "$f")" 'no inline run interpolation'
    assert_eq '' "$(grep 'uses:' "$f" | grep -vE '@[0-9a-f]{40}( |$)')" 'all actions pinned to full SHA'
}

test_sdk_release_installs_full_native_targets_and_isolates_caches() {
    local f line
    f="$(_sdk_release_workflow)"
    assert_succeeds 'workflow exists' test -f "$f"
    [ -f "$f" ] || return
    assert_file_contains "$f" 'aarch64-apple-ios,x86_64-apple-ios,aarch64-apple-ios-sim,x86_64-apple-darwin,aarch64-apple-darwin' 'all five Rust targets installed'
    assert_file_contains "$f" 'rustc +stable --version --verbose' 'complete compiler identity'
    assert_file_contains "$f" 'cargo-release-all-slices-lto-v2-' 'distinct release build namespace'
    # shellcheck disable=SC2088
    assert_file_lacks "$f" '~/.cargo/git' 'no cloned Cargo sources cached'
    while IFS= read -r line; do
        printf '%s\n' "$line" > "$SCRATCH/sdk-release-cache-key"
        assert_file_contains "$SCRATCH/sdk-release-cache-key" '${{ runner.os }}' 'cache constrains OS'
        assert_file_contains "$SCRATCH/sdk-release-cache-key" '${{ runner.arch }}' 'cache constrains architecture'
        assert_file_contains "$SCRATCH/sdk-release-cache-key" '${{ steps.xcode-cache-key.outputs.hash }}' 'cache constrains complete Xcode identity'
        assert_file_contains "$SCRATCH/sdk-release-cache-key" '${{ steps.toolchain.outputs.cachekey }}' 'cache constrains complete Rust identity'
    done < <(grep -E '^ *key:|^ *\$\{\{ runner.os' "$f")
    assert_file_contains "$f" "hashFiles('source/Cargo.lock', 'source/Cargo.toml')" 'cache keys use selected source inputs'
    assert_file_contains "$f" 'source/target' 'cache restores into source tree'
}

test_sdk_release_python_suite() {
    assert_succeeds 'producer Python suite' python3 -m unittest discover -s "$REPO_ROOT/Scripts/tests" -p test_sdk_release_build.py
}
