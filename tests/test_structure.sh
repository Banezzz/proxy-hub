#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly MANIFEST_REL="lib/manifest.sha256"
readonly BUILD_SCRIPT_REL="scripts/build-bundle.sh"
readonly BUNDLE_REL="dist/proxy-hub.bundle.sh"
readonly APPROVED_PATCH_REL="tests/fixtures/approved-safety.patch"
readonly XRAY_RELEASE_PATCH_REL="tests/fixtures/xray-release-management.patch"
readonly NODE_STATE_PATCH_REL="tests/fixtures/node-state-reset.patch"
readonly API_VERSION="1"
readonly -a MODULES=(
    00_security_state.sh
    10_runtime_platform_ui.sh
    15_xray_release.sh
    20_installers_restart.sh
    30_provision_network.sh
    40_config_share.sh
    50_node_commands.sh
    60_system_tools.sh
    70_ports_logs.sh
    80_timesync.sh
    90_main.sh
)

require_command git
require_command sha256sum
require_command awk
require_command dd
require_command find
require_command sort
require_command wc
git -C "$REPO_ROOT" cat-file -e "$LEGACY_BASELINE_COMMIT:proxy-hub.sh" || \
    fail "pinned historical baseline is unavailable: $LEGACY_BASELINE_COMMIT"

assert_file "$REPO_ROOT/proxy-hub.sh"
assert_file "$REPO_ROOT/$MANIFEST_REL"
assert_file "$REPO_ROOT/$BUILD_SCRIPT_REL"
assert_file "$REPO_ROOT/$BUNDLE_REL"
assert_file "$REPO_ROOT/$APPROVED_PATCH_REL"
assert_file "$REPO_ROOT/$XRAY_RELEASE_PATCH_REL"
assert_file "$REPO_ROOT/$NODE_STATE_PATCH_REL"

bash -n "$REPO_ROOT/proxy-hub.sh"
bash -n "$REPO_ROOT/$BUILD_SCRIPT_REL"
for module in "${MODULES[@]}"; do
    assert_file "$REPO_ROOT/lib/$module"
    bash -n "$REPO_ROOT/lib/$module"
    module_lines=$(wc -l <"$REPO_ROOT/lib/$module" | tr -d '[:space:]')
    ((module_lines < 1500)) || fail "module must stay below 1500 lines: $module ($module_lines)"
done
bash -n "$REPO_ROOT/$BUNDLE_REL"
pass "all loader, build, module, and bundle files parse as Bash"

expected_lib_entries=(manifest.sha256 "${MODULES[@]}")
mapfile -t expected_lib_entries < <(printf '%s\n' "${expected_lib_entries[@]}" | LC_ALL=C sort)
mapfile -t actual_lib_entries < <(find "$REPO_ROOT/lib" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
(( ${#actual_lib_entries[@]} <= 12 )) || \
    fail "lib top-level file count exceeds 12: ${#actual_lib_entries[@]}"
assert_eq "${#expected_lib_entries[@]}" "${#actual_lib_entries[@]}" "complete lib inventory count"
for i in "${!expected_lib_entries[@]}"; do
    assert_eq "${expected_lib_entries[$i]}" "${actual_lib_entries[$i]}" "complete lib inventory entry $i"
done
pass "module line limits and complete lib top-level inventory are valid"

mapfile -t manifest_lines <"$REPO_ROOT/$MANIFEST_REL"
assert_eq "15" "${#manifest_lines[@]}" "manifest must have exactly 15 lines"
assert_eq "# proxy-hub-manifest-v1" "${manifest_lines[0]}" "manifest start marker"
assert_eq "# api=$API_VERSION" "${manifest_lines[1]}" "manifest API"
[[ "${manifest_lines[2]}" =~ ^#[[:space:]]build-id=([0-9a-f]{64})$ ]] || fail "invalid manifest build-id line"
manifest_build_id="${BASH_REMATCH[1]}"
assert_eq "# proxy-hub-manifest-end-v1" "${manifest_lines[14]}" "manifest end marker"

manifest_stream="$TEST_DIR/.tmp"
mkdir -p -- "$manifest_stream"
structure_tmp=$(mktemp -d "$manifest_stream/proxy-hub-test.structure.XXXXXXXX")
register_cleanup_dir "$structure_tmp"
manifest_build_input="$structure_tmp/manifest-build-input"
: >"$manifest_build_input"
printf 'api=%s\n' "$API_VERSION" >>"$manifest_build_input"

for i in "${!MODULES[@]}"; do
    line="${manifest_lines[$((i + 3))]}"
    [[ "$line" =~ ^([0-9a-f]{64})[[:space:]][[:space:]]([^/[:space:]]+)$ ]] || \
        fail "invalid manifest module line $((i + 4)): $line"
    recorded_digest="${BASH_REMATCH[1]}"
    recorded_name="${BASH_REMATCH[2]}"
    assert_eq "${MODULES[$i]}" "$recorded_name" "manifest module order at index $i"
    actual_digest=$(sha256_file "$REPO_ROOT/lib/$recorded_name")
    assert_eq "$actual_digest" "$recorded_digest" "manifest digest for $recorded_name"
    printf '%s\0%s\n' "$recorded_name" "$recorded_digest" >>"$manifest_build_input"
done

computed_build_id=$(sha256_file "$manifest_build_input")
assert_eq "$computed_build_id" "$manifest_build_id" "manifest build-id"
pass "manifest order, module digests, and build-id are valid"

copy_build_inputs() {
    local destination="$1"
    mkdir -p -- "$destination/lib" "$destination/scripts" "$destination/dist" "$destination/tests/fixtures"
    cp -- "$REPO_ROOT/proxy-hub.sh" "$destination/proxy-hub.sh"
    cp -- "$REPO_ROOT/$BUILD_SCRIPT_REL" "$destination/$BUILD_SCRIPT_REL"
    cp -- "$REPO_ROOT/$APPROVED_PATCH_REL" "$destination/$APPROVED_PATCH_REL"
    cp -- "$REPO_ROOT/$XRAY_RELEASE_PATCH_REL" "$destination/$XRAY_RELEASE_PATCH_REL"
    cp -- "$REPO_ROOT/$NODE_STATE_PATCH_REL" "$destination/$NODE_STATE_PATCH_REL"
    local module
    for module in "${MODULES[@]}"; do
        cp -- "$REPO_ROOT/lib/$module" "$destination/lib/$module"
    done
}

build_a="$structure_tmp/build-a"
build_b="$structure_tmp/build-b"
copy_build_inputs "$build_a"
copy_build_inputs "$build_b"
(
    cd -- "$build_a"
    bash "$BUILD_SCRIPT_REL"
)
(
    cd -- "$build_b"
    bash "$BUILD_SCRIPT_REL"
)

cmp -s -- "$build_a/$MANIFEST_REL" "$build_b/$MANIFEST_REL" || fail "manifest build is not deterministic"
cmp -s -- "$build_a/$BUNDLE_REL" "$build_b/$BUNDLE_REL" || fail "bundle build is not deterministic"
cmp -s -- "$build_a/$MANIFEST_REL" "$REPO_ROOT/$MANIFEST_REL" || fail "checked-in manifest is stale"
cmp -s -- "$build_a/$BUNDLE_REL" "$REPO_ROOT/$BUNDLE_REL" || fail "checked-in bundle is stale"
pass "bundle build is deterministic and checked-in artifacts are current"

# The release lock covers source snapshotting through disposal of both artifact
# transaction directories.  Hold generation A immediately after its complete
# snapshot, mutate the source tree to generation B, and start a second publisher.
# The second process must fail closed instead of assembling or publishing a pair
# concurrently with the first one.
release_a_expected="$structure_tmp/release-generation-a"
release_b_expected="$structure_tmp/release-generation-b"
release_shared="$structure_tmp/release-shared"
copy_build_inputs "$release_a_expected"
copy_build_inputs "$release_b_expected"
copy_build_inputs "$release_shared"
printf '\n# release-lock-generation-a\n' >>"$release_a_expected/lib/80_timesync.sh"
printf '\n# release-lock-generation-b\n' >>"$release_b_expected/lib/80_timesync.sh"
cp -- "$release_a_expected/lib/80_timesync.sh" "$release_shared/lib/80_timesync.sh"
bash "$release_a_expected/$BUILD_SCRIPT_REL" >"$structure_tmp/release-a-expected.stdout"
bash "$release_b_expected/$BUILD_SCRIPT_REL" >"$structure_tmp/release-b-expected.stdout"
release_a_manifest_sha=$(sha256_file "$release_a_expected/$MANIFEST_REL")
release_a_bundle_sha=$(sha256_file "$release_a_expected/$BUNDLE_REL")
release_b_manifest_sha=$(sha256_file "$release_b_expected/$MANIFEST_REL")
release_b_bundle_sha=$(sha256_file "$release_b_expected/$BUNDLE_REL")
assert_ne "$release_a_manifest_sha" "$release_b_manifest_sha" "release generations must differ"
assert_ne "$release_a_bundle_sha" "$release_b_bundle_sha" "release bundles must differ"

release_ready="$structure_tmp/release-concurrent.ready"
release_continue="$structure_tmp/release-concurrent.continue"
release_first_rc=0
release_second_rc=0
PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
FAKE_CHMOD_PAUSE_MATCH='proxy-hub.bundle.sh' \
FAKE_CHMOD_READY_FILE="$release_ready" \
FAKE_CHMOD_RELEASE_FILE="$release_continue" \
bash "$release_shared/$BUILD_SCRIPT_REL" \
    >"$structure_tmp/release-first.stdout" 2>"$structure_tmp/release-first.stderr" &
release_first_pid=$!
for _ in $(seq 1 200); do
    [[ -e "$release_ready" ]] && break
    sleep 0.02
done
[[ -e "$release_ready" ]] || fail "first concurrent publisher did not finish its source snapshot"
[[ -L "$release_shared/.proxy-hub.release.lock" ]] || fail "first publisher did not publish its release lock"
cp -- "$release_b_expected/lib/80_timesync.sh" "$release_shared/lib/80_timesync.sh"
bash "$release_shared/$BUILD_SCRIPT_REL" \
    >"$structure_tmp/release-second.stdout" 2>"$structure_tmp/release-second.stderr" || release_second_rc=$?
assert_ne "0" "$release_second_rc" "second concurrent publisher must fail closed"
assert_contains "$(<"$structure_tmp/release-second.stderr")" "holds the release lock" \
    "second concurrent publisher lock diagnostic"
: >"$release_continue"
wait "$release_first_pid" || release_first_rc=$?
assert_eq "0" "$release_first_rc" "first concurrent publisher exit status"
actual_release_manifest_sha=$(sha256_file "$release_shared/$MANIFEST_REL")
actual_release_bundle_sha=$(sha256_file "$release_shared/$BUNDLE_REL")
if [[ "$actual_release_manifest_sha" == "$release_a_manifest_sha" ]]; then
    assert_eq "$release_a_bundle_sha" "$actual_release_bundle_sha" \
        "concurrent publication must keep the generation-A pair coherent"
elif [[ "$actual_release_manifest_sha" == "$release_b_manifest_sha" ]]; then
    assert_eq "$release_b_bundle_sha" "$actual_release_bundle_sha" \
        "concurrent publication must keep the generation-B pair coherent"
else
    fail "concurrent publication produced a manifest from neither source generation"
fi
[[ ! -e "$release_shared/.proxy-hub.release.lock" && ! -L "$release_shared/.proxy-hub.release.lock" ]] || \
    fail "successful publisher leaked its release lock"
pass "concurrent publishers cannot mix manifest and bundle source generations"

stale_release_build="$structure_tmp/release-stale"
copy_build_inputs "$stale_release_build"
ln -s -- "proxy-hub-release-v1:${EUID}:999999999:1:stale-fixture" \
    "$stale_release_build/.proxy-hub.release.lock"
bash "$stale_release_build/$BUILD_SCRIPT_REL" >"$structure_tmp/release-stale.stdout"
[[ ! -e "$stale_release_build/.proxy-hub.release.lock" && \
   ! -L "$stale_release_build/.proxy-hub.release.lock" ]] || \
    fail "builder did not reclaim and release an identity-bound stale lock"
pass "builder reclaims only a stale lock with parseable dead process identity"

replaced_release_build="$structure_tmp/release-replaced"
copy_build_inputs "$replaced_release_build"
printf '%s\n' 'old replacement manifest' >"$replaced_release_build/$MANIFEST_REL"
printf '%s\n' 'old replacement bundle' >"$replaced_release_build/$BUNDLE_REL"
replaced_release_manifest_sha=$(sha256_file "$replaced_release_build/$MANIFEST_REL")
replaced_release_bundle_sha=$(sha256_file "$replaced_release_build/$BUNDLE_REL")
replaced_release_ready="$structure_tmp/release-replaced.ready"
replaced_release_continue="$structure_tmp/release-replaced.continue"
replaced_release_rc=0
PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
FAKE_CHMOD_PAUSE_MATCH='proxy-hub.bundle.sh' \
FAKE_CHMOD_READY_FILE="$replaced_release_ready" \
FAKE_CHMOD_RELEASE_FILE="$replaced_release_continue" \
bash "$replaced_release_build/$BUILD_SCRIPT_REL" \
    >"$structure_tmp/release-replaced.stdout" 2>"$structure_tmp/release-replaced.stderr" &
replaced_release_pid=$!
for _ in $(seq 1 200); do
    [[ -e "$replaced_release_ready" ]] && break
    sleep 0.02
done
[[ -e "$replaced_release_ready" ]] || fail "replacement publisher did not reach the pause hook"
mv -- "$replaced_release_build/.proxy-hub.release.lock" \
    "$replaced_release_build/.proxy-hub.release.lock.original"
ln -s -- "proxy-hub-release-v1:${EUID}:$$:1:replacement-fixture" \
    "$replaced_release_build/.proxy-hub.release.lock"
: >"$replaced_release_continue"
wait "$replaced_release_pid" || replaced_release_rc=$?
assert_ne "0" "$replaced_release_rc" "publisher with a replaced release lock must fail closed"
assert_eq "$replaced_release_manifest_sha" "$(sha256_file "$replaced_release_build/$MANIFEST_REL")" \
    "release-lock replacement must not publish manifest"
assert_eq "$replaced_release_bundle_sha" "$(sha256_file "$replaced_release_build/$BUNDLE_REL")" \
    "release-lock replacement must not publish bundle"
assert_eq "proxy-hub-release-v1:${EUID}:$$:1:replacement-fixture" \
    "$(readlink -- "$replaced_release_build/.proxy-hub.release.lock")" \
    "builder must preserve a same-UID replacement lock"
rm -f -- "$replaced_release_build/.proxy-hub.release.lock" \
    "$replaced_release_build/.proxy-hub.release.lock.original"
pass "builder fails closed without deleting a same-UID release-lock replacement"

nul_build="$structure_tmp/build-nul"
copy_build_inputs "$nul_build"
printf '\0' | dd of="$nul_build/lib/20_installers_restart.sh" bs=1 seek=32 conv=notrunc status=none
nul_build_rc=0
bash "$nul_build/$BUILD_SCRIPT_REL" >"$nul_build/stdout" 2>"$nul_build/stderr" || nul_build_rc=$?
assert_ne "0" "$nul_build_rc" "builder must reject a NUL-containing module"
assert_contains "$(<"$nul_build/stderr")" "contains a NUL byte" "builder NUL rejection"
assert_not_exists "$nul_build/.proxy-hub.release.lock"
pass "builder rejects NUL-containing module input before publishing"

validation_build="$structure_tmp/build-post-create-validation-failure"
copy_build_inputs "$validation_build"
validation_tmp="$structure_tmp/validation-tmp"
mkdir -m 700 -- "$validation_tmp"
validation_rc=0
PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
TMPDIR="$validation_tmp" \
FAKE_CHMOD_FAIL_MATCH='proxy-hub.build.' \
FAKE_CHMOD_FAIL_ACTION=fail \
bash "$validation_build/$BUILD_SCRIPT_REL" \
    >"$structure_tmp/validation.stdout" 2>"$structure_tmp/validation.stderr" || validation_rc=$?
assert_ne "0" "$validation_rc" "builder post-create validation failure must fail"
validation_leftovers=$(find "$validation_tmp" -mindepth 1 -maxdepth 1 \
    -name 'proxy-hub.build.*' -print)
[[ -z "$validation_leftovers" ]] || \
    fail "builder leaked unpublished build staging: $validation_leftovers"
pass "builder cleans identity-bound build staging after post-create validation failure"

txn_validation_build="$structure_tmp/build-transaction-validation-failure"
copy_build_inputs "$txn_validation_build"
txn_validation_tmp="$structure_tmp/transaction-validation-tmp"
mkdir -m 700 -- "$txn_validation_tmp"
txn_validation_rc=0
PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
TMPDIR="$txn_validation_tmp" \
FAKE_CHMOD_FAIL_MATCH='.proxy-hub.manifest.txn.' \
FAKE_CHMOD_FAIL_ACTION=fail \
bash "$txn_validation_build/$BUILD_SCRIPT_REL" \
    >"$structure_tmp/txn-validation.stdout" 2>"$structure_tmp/txn-validation.stderr" || txn_validation_rc=$?
assert_ne "0" "$txn_validation_rc" "transaction post-create validation failure must fail"
txn_validation_leftovers=$(find "$txn_validation_build/lib" -mindepth 1 -maxdepth 1 \
    -name '.proxy-hub.manifest.txn.*' -print)
[[ -z "$txn_validation_leftovers" ]] || \
    fail "builder leaked unpublished transaction staging: $txn_validation_leftovers"
txn_build_leftovers=$(find "$txn_validation_tmp" -mindepth 1 -maxdepth 1 \
    -name 'proxy-hub.build.*' -print)
[[ -z "$txn_build_leftovers" ]] || \
    fail "builder leaked build staging after transaction validation failure: $txn_build_leftovers"
pass "builder cleans identity-bound transaction staging after post-create validation failure"

replacement_validation_build="$structure_tmp/build-post-create-path-replacement"
copy_build_inputs "$replacement_validation_build"
replacement_validation_tmp="$structure_tmp/replacement-validation-tmp"
mkdir -m 700 -- "$replacement_validation_tmp"
replacement_validation_rc=0
PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
TMPDIR="$replacement_validation_tmp" \
FAKE_CHMOD_FAIL_MATCH='proxy-hub.build.' \
FAKE_CHMOD_FAIL_ACTION=replace \
bash "$replacement_validation_build/$BUILD_SCRIPT_REL" \
    >"$structure_tmp/replacement-validation.stdout" \
    2>"$structure_tmp/replacement-validation.stderr" || replacement_validation_rc=$?
assert_ne "0" "$replacement_validation_rc" "replaced build staging validation must fail"
replacement_validation_path=$(find "$replacement_validation_tmp" -mindepth 1 -maxdepth 1 \
    -type d -name 'proxy-hub.build.*' ! -name '*.original' -print -quit)
[[ -n "$replacement_validation_path" ]] || \
    fail "builder child cleanup incorrectly removed replacement staging"
assert_file "$replacement_validation_path/keep"
assert_dir "${replacement_validation_path}.original"
pass "builder child cleanup preserves a replacement with a different identity"

replacement_build="$structure_tmp/build-replacement"
copy_build_inputs "$replacement_build"
cp -- "$REPO_ROOT/$MANIFEST_REL" "$replacement_build/$MANIFEST_REL"
cp -- "$REPO_ROOT/$BUNDLE_REL" "$replacement_build/$BUNDLE_REL"
replacement_manifest_before=$(sha256_file "$replacement_build/$MANIFEST_REL")
replacement_bundle_before=$(sha256_file "$replacement_build/$BUNDLE_REL")
replacement_tmp="$structure_tmp/replacement-tmp"
mkdir -m 700 -- "$replacement_tmp"
replacement_ready="$structure_tmp/replacement.ready"
replacement_release="$structure_tmp/replacement.release"
replacement_build_rc=0
(
    PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
    TMPDIR="$replacement_tmp" \
    FAKE_SED_READY_FILE="$replacement_ready" \
    FAKE_SED_RELEASE_FILE="$replacement_release" \
    bash "$replacement_build/$BUILD_SCRIPT_REL"
) >"$structure_tmp/replacement.stdout" 2>"$structure_tmp/replacement.stderr" &
replacement_pid=$!
for _ in $(seq 1 100); do
    [[ -e "$replacement_ready" ]] && break
    sleep 0.02
done
[[ -e "$replacement_ready" ]] || fail "replacement builder did not reach the staging hook"
replacement_stage=$(find "$replacement_tmp" -mindepth 1 -maxdepth 1 -type d -name 'proxy-hub.build.*' -print -quit)
[[ -n "$replacement_stage" ]] || fail "replacement builder staging directory not found"
mv -- "$replacement_stage" "${replacement_stage}.original"
mkdir -m 700 -- "$replacement_stage"
printf 'replacement\n' >"$replacement_stage/keep"
: >"$replacement_release"
wait "$replacement_pid" || replacement_build_rc=$?
assert_ne "0" "$replacement_build_rc" "builder must reject a replaced staging directory"
assert_file "$replacement_stage/keep"
assert_dir "${replacement_stage}.original"
assert_eq "$replacement_manifest_before" "$(sha256_file "$replacement_build/$MANIFEST_REL")" \
    "manifest must not publish from a replaced staging directory"
assert_eq "$replacement_bundle_before" "$(sha256_file "$replacement_build/$BUNDLE_REL")" \
    "bundle must not publish from a replaced staging directory"
pass "builder refuses publish and cleanup after staging directory replacement"

signal_build="$structure_tmp/build-publication-signal"
copy_build_inputs "$signal_build"
cp -- "$REPO_ROOT/$MANIFEST_REL" "$signal_build/$MANIFEST_REL"
cp -- "$REPO_ROOT/$BUNDLE_REL" "$signal_build/$BUNDLE_REL"
signal_manifest_before=$(sha256_file "$signal_build/$MANIFEST_REL")
signal_bundle_before=$(sha256_file "$signal_build/$BUNDLE_REL")
signal_tmp="$structure_tmp/signal-tmp"
mkdir -m 700 -- "$signal_tmp"
signal_build_rc=0
setsid env \
    PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
    TMPDIR="$signal_tmp" \
    FAKE_MKTEMP_SIGNAL=1 \
    bash "$signal_build/$BUILD_SCRIPT_REL" \
    >"$structure_tmp/signal-build.stdout" 2>"$structure_tmp/signal-build.stderr" || signal_build_rc=$?
assert_eq "143" "$signal_build_rc" "builder signal during temp publication"
signal_leftovers=$(find "$signal_tmp" -mindepth 1 -maxdepth 1 -name 'proxy-hub.build.*' -print)
[[ -z "$signal_leftovers" ]] || fail "builder leaked staging after publication signal: $signal_leftovers"
assert_not_exists "$signal_build/.proxy-hub.release.lock"
assert_eq "$signal_manifest_before" "$(sha256_file "$signal_build/$MANIFEST_REL")" \
    "publication signal must not replace manifest"
assert_eq "$signal_bundle_before" "$(sha256_file "$signal_build/$BUNDLE_REL")" \
    "publication signal must not replace bundle"
pass "builder temp publication defers TERM until staging identity is cleanup-visible"

run_transaction_fault_case() {
    local stage="$1" action="$2" expected_rc="$3"
    local case_name="transaction-${stage}-${action,,}"
    local fault_build="$structure_tmp/$case_name"
    local fault_tmp="$structure_tmp/$case_name-tmp"
    local fault_marker="$structure_tmp/$case_name.marker"
    local fault_rc=0 leftovers

    copy_build_inputs "$fault_build"
    mkdir -m 700 -- "$fault_tmp"
    printf '%s\n' "old manifest $case_name" >"$fault_build/$MANIFEST_REL"
    printf '%s\n' "old bundle $case_name" >"$fault_build/$BUNDLE_REL"
    local old_manifest_sha old_bundle_sha
    old_manifest_sha=$(sha256_file "$fault_build/$MANIFEST_REL")
    old_bundle_sha=$(sha256_file "$fault_build/$BUNDLE_REL")

    setsid env \
        PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
        TMPDIR="$fault_tmp" \
        FAKE_BUILD_MV_STAGE="$stage" \
        FAKE_BUILD_MV_ACTION="$action" \
        FAKE_BUILD_MV_MARKER="$fault_marker" \
        bash "$fault_build/$BUILD_SCRIPT_REL" \
        >"$structure_tmp/$case_name.stdout" 2>"$structure_tmp/$case_name.stderr" || fault_rc=$?

    assert_eq "$expected_rc" "$fault_rc" "$case_name exit status"
    assert_file "$fault_marker"
    assert_eq "$old_manifest_sha" "$(sha256_file "$fault_build/$MANIFEST_REL")" \
        "$case_name must restore the previous manifest bytes"
    assert_eq "$old_bundle_sha" "$(sha256_file "$fault_build/$BUNDLE_REL")" \
        "$case_name must restore the previous bundle bytes"
    leftovers=$(find "$fault_build/lib" "$fault_build/dist" -mindepth 1 -maxdepth 1 \
        \( -name '.proxy-hub.manifest.txn.*' -o -name '.proxy-hub.bundle.txn.*' \) -print)
    [[ -z "$leftovers" ]] || fail "$case_name leaked transaction staging: $leftovers"
    leftovers=$(find "$fault_tmp" -mindepth 1 -maxdepth 1 -name 'proxy-hub.build.*' -print)
    [[ -z "$leftovers" ]] || fail "$case_name leaked build staging: $leftovers"
    assert_not_exists "$fault_build/.proxy-hub.release.lock"
}

run_transaction_fault_case manifest fail 1
run_transaction_fault_case bundle fail 1
run_transaction_fault_case manifest TERM 143
run_transaction_fault_case bundle TERM 143
run_transaction_fault_case manifest HUP 129
run_transaction_fault_case bundle INT 130
pass "manifest and bundle publish as a rollback-capable two-artifact transaction"

run_uncertain_transaction_case() {
    local action="$1" case_name="transaction-uncertain-$1"
    local fault_build="$structure_tmp/$case_name"
    local fault_tmp="$structure_tmp/$case_name-tmp"
    local fault_marker="$structure_tmp/$case_name.marker"
    local fault_rc=0 retry_rc=0 lock_payload displaced_txn

    copy_build_inputs "$fault_build"
    mkdir -m 700 -- "$fault_tmp"
    printf '%s\n' "old manifest $case_name" >"$fault_build/$MANIFEST_REL"
    printf '%s\n' "old bundle $case_name" >"$fault_build/$BUNDLE_REL"

    PATH="$REPO_ROOT/tests/fixtures/fake-bin:$PATH" \
    TMPDIR="$fault_tmp" \
    FAKE_BUILD_MV_STAGE=bundle \
    FAKE_BUILD_MV_ACTION="$action" \
    FAKE_BUILD_MV_MARKER="$fault_marker" \
    bash "$fault_build/$BUILD_SCRIPT_REL" \
        >"$structure_tmp/$case_name.stdout" 2>"$structure_tmp/$case_name.stderr" || fault_rc=$?

    assert_ne "0" "$fault_rc" "$case_name must fail"
    assert_file "$fault_marker"
    [[ -L "$fault_build/.proxy-hub.release.lock" ]] || \
        fail "$case_name must retain the identity-bound release lock"
    lock_payload=$(readlink -- "$fault_build/.proxy-hub.release.lock")
    [[ "$lock_payload" == proxy-hub-release-uncertain-v1:* ]] || \
        fail "$case_name retained lock is not marked uncertain: $lock_payload"
    assert_contains "$(<"$structure_tmp/$case_name.stderr")" "retaining identity-bound release lock" \
        "$case_name retention diagnostic"
    displaced_txn=$(find "$fault_build/lib" -mindepth 1 -maxdepth 1 -type d \
        -name '.proxy-hub.manifest.txn.*.identity-replaced' -print -quit)
    [[ -n "$displaced_txn" ]] || fail "$case_name must preserve the displaced transaction backup"

    bash "$fault_build/$BUILD_SCRIPT_REL" \
        >"$structure_tmp/$case_name-retry.stdout" \
        2>"$structure_tmp/$case_name-retry.stderr" || retry_rc=$?
    assert_ne "0" "$retry_rc" "$case_name retry must fail closed"
    assert_contains "$(<"$structure_tmp/$case_name-retry.stderr")" \
        "uncertain release lock; manual recovery is required" "$case_name retry diagnostic"
    assert_eq "$lock_payload" "$(readlink -- "$fault_build/.proxy-hub.release.lock")" \
        "$case_name retry must preserve the uncertain lock"
}

run_uncertain_transaction_case replace-manifest-txn-fail
run_uncertain_transaction_case replace-manifest-txn
pass "unverified rollback or transaction disposal retains a non-reclaimable release lock"

bundle="$REPO_ROOT/$BUNDLE_REL"
mapfile -t trailer_lines < <(tail -n 6 -- "$bundle")
assert_eq "6" "${#trailer_lines[@]}" "bundle trailer line count"
assert_eq "# proxy-hub-bundle-manifest-v1" "${trailer_lines[0]}" "bundle trailer start"
[[ "${trailer_lines[1]}" =~ ^#[[:space:]]header-bytes=([0-9]+)[[:space:]]header-sha256=([0-9a-f]{64})$ ]] || fail "invalid bundle header metadata"
header_bytes="${BASH_REMATCH[1]}"
header_digest="${BASH_REMATCH[2]}"
[[ "${trailer_lines[2]}" =~ ^#[[:space:]]body-bytes=([0-9]+)[[:space:]]body-sha256=([0-9a-f]{64})$ ]] || fail "invalid bundle body metadata"
body_bytes="${BASH_REMATCH[1]}"
body_digest="${BASH_REMATCH[2]}"
[[ "${trailer_lines[3]}" =~ ^#[[:space:]]build-id=([0-9a-f]{64})$ ]] || fail "invalid bundle build-id"
bundle_build_id="${BASH_REMATCH[1]}"
assert_eq "# module-count=${#MODULES[@]}" "${trailer_lines[4]}" "bundle module count"
assert_eq "# proxy-hub-bundle-end-v1" "${trailer_lines[5]}" "bundle trailer end"
assert_eq "$body_digest" "$bundle_build_id" "bundle build-id must equal body digest"

trailer_file="$structure_tmp/trailer"
tail -n 6 -- "$bundle" >"$trailer_file"
bundle_size=$(wc -c <"$bundle")
trailer_bytes=$(wc -c <"$trailer_file")
assert_eq "$bundle_size" "$((header_bytes + body_bytes + trailer_bytes))" "bundle byte segments must cover the file exactly"

header_file="$structure_tmp/header"
body_file="$structure_tmp/body"
dd if="$bundle" of="$header_file" bs=1 count="$header_bytes" status=none
dd if="$bundle" of="$body_file" bs=1 skip="$header_bytes" count="$body_bytes" status=none
assert_eq "$header_digest" "$(sha256_file "$header_file")" "bundle header digest"
assert_eq "$body_digest" "$(sha256_file "$body_file")" "bundle body digest"
pass "bundle trailer, byte lengths, digests, build-id, and module count are valid"

baseline_dir="$structure_tmp/baseline"
mkdir -p -- "$baseline_dir"
git -C "$REPO_ROOT" show "$LEGACY_BASELINE_COMMIT:proxy-hub.sh" >"$baseline_dir/proxy-hub.sh"
(
    cd -- "$baseline_dir"
    git apply --unidiff-zero --whitespace=nowarn "$REPO_ROOT/$APPROVED_PATCH_REL"
    git apply --unidiff-zero --whitespace=nowarn "$REPO_ROOT/$XRAY_RELEASE_PATCH_REL"
    git apply --unidiff-zero --whitespace=nowarn "$REPO_ROOT/$NODE_STATE_PATCH_REL"
)

full_bundle="$structure_tmp/full-bundle"
head -n -6 -- "$bundle" >"$full_bundle"
if ! cmp -s -- "$baseline_dir/proxy-hub.sh" "$full_bundle"; then
    diff -u -- "$baseline_dir/proxy-hub.sh" "$full_bundle" | sed -n '1,200p' >&2 || true
    fail "bundle content differs from the pinned baseline plus approved safety, Xray release, and node-state patches"
fi
pass "complete bundle equals the pinned baseline plus approved safety, Xray release, and node-state patches"
