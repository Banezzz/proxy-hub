#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_bwrap
require_command sha256sum

failure_tmp_base="$TEST_DIR/.tmp"
mkdir -p -- "$failure_tmp_base"
failure_tmp=$(mktemp -d "$failure_tmp_base/proxy-hub-test.loader-failures.XXXXXXXX")
register_cleanup_dir "$failure_tmp"
mkdir -p -- "$failure_tmp/cases"

bundle="$REPO_ROOT/dist/proxy-hub.bundle.sh"
assert_file "$bundle"

make_case() {
    local name="$1"
    local case_dir="$failure_tmp/cases/$name"
    mkdir -p -- "$case_dir/assets" "$case_dir/tmp"
    cp -- "$bundle" "$case_dir/assets/proxy-hub.bundle.sh"
    mkdir -p -- "$case_dir/tmp/tmp.foreign"
    printf 'keep\n' >"$case_dir/tmp/tmp.foreign/keep"
    printf '%s\n' "$case_dir"
}

assert_bootstrap_clean() {
    local case_dir="$1"
    assert_file "$case_dir/tmp/tmp.foreign/keep"
    local leftovers
    leftovers=$(find "$case_dir/tmp" -mindepth 1 -maxdepth 1 -name 'proxy-hub.bootstrap.*' -print)
    [[ -z "$leftovers" ]] || fail "bootstrap temp leaked: $leftovers"
}

refresh_local_manifest() {
    local repo_dir="$1" canonical="$1/../manifest.canonical" module digest build_id i
    local -a modules=(
        00_security_state.sh
        10_runtime_platform_ui.sh
        20_installers_restart.sh
        30_provision_network.sh
        40_config_share.sh
        50_node_commands.sh
        60_system_tools.sh
        70_ports_logs.sh
        80_timesync.sh
        90_main.sh
    )
    local -a digests=()

    : > "$canonical"
    printf 'api=1\n' >> "$canonical"
    for module in "${modules[@]}"; do
        digest=$(sha256_file "$repo_dir/lib/$module")
        digests+=("$digest")
        printf '%s\0%s\n' "$module" "$digest" >> "$canonical"
    done
    build_id=$(sha256_file "$canonical")
    {
        printf '%s\n' '# proxy-hub-manifest-v1' '# api=1'
        printf '# build-id=%s\n' "$build_id"
        for i in "${!modules[@]}"; do
            printf '%s  %s\n' "${digests[$i]}" "${modules[$i]}"
        done
        printf '%s\n' '# proxy-hub-manifest-end-v1'
    } > "$repo_dir/lib/manifest.sha256"
}

run_remote_failure() {
    local case_dir="$1"
    local mode="${2:-ok}"
    local ref="${3:-main}"
    shift 3 || true
    local stdout_file="$case_dir/stdout"
    local stderr_file="$case_dir/stderr"
    local rc=0

    bwrap \
        --ro-bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --tmpfs /root \
        --unshare-net \
        --die-with-parent \
        --ro-bind "$REPO_ROOT" /mnt \
        --bind "$case_dir" /srv \
        --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv TMPDIR /srv/tmp \
        --setenv PROXY_HUB_REF "$ref" \
        --setenv FAKE_CURL_MODE "$mode" \
        --setenv FAKE_CURL_ASSET_DIR /srv/assets \
        --setenv FAKE_CURL_LOG /srv/curl.log \
        "$@" \
        -- bash -c 'bash <(cat /mnt/proxy-hub.sh) help' \
        >"$stdout_file" 2>"$stderr_file" || rc=$?
    printf '%s\n' "$rc"
}

assert_failed_before_main() {
    local label="$1"
    local case_dir="$2"
    local rc="$3"
    assert_ne "0" "$rc" "$label must fail"
    output=$(<"$case_dir/stdout")
    assert_not_contains "$output" "VLESS TCP REALITY Vision" "$label must not source business main"
    [[ -s "$case_dir/stderr" ]] || fail "$label must explain the failure on stderr"
    assert_bootstrap_clean "$case_dir"
    pass "$label fails closed before business execution and cleans its temp directory"
}

case_dir=$(make_case curl-failure)
rc=$(run_remote_failure "$case_dir" fail main)
assert_failed_before_main "curl download failure" "$case_dir" "$rc"

case_dir=$(make_case truncated-download)
rc=$(run_remote_failure "$case_dir" truncate main)
assert_failed_before_main "truncated bundle download" "$case_dir" "$rc"

case_dir=$(make_case insecure-redirect)
rc=$(run_remote_failure "$case_dir" redirect-http main)
assert_failed_before_main "HTTPS policy rejects an HTTP redirect" "$case_dir" "$rc"

case_dir=$(make_case manifest-api)
mkdir -p -- "$case_dir/repo/lib"
cp -- "$REPO_ROOT/proxy-hub.sh" "$case_dir/repo/proxy-hub.sh"
cp -- "$REPO_ROOT/lib/manifest.sha256" "$case_dir/repo/lib/manifest.sha256"
cp -- "$REPO_ROOT"/lib/[0-9][0-9]_*.sh "$case_dir/repo/lib/"
sed -i 's/^# api=1$/# api=2/' "$case_dir/repo/lib/manifest.sha256"
rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/curl.log \
    -- bash /srv/repo/proxy-hub.sh help \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
assert_failed_before_main "unsupported local manifest API" "$case_dir" "$rc"
[[ ! -s "$case_dir/curl.log" ]] || fail "local API mismatch must not silently fall back to remote curl"

case_dir=$(make_case local-manifest-nul)
mkdir -p -- "$case_dir/repo/lib"
cp -- "$REPO_ROOT/proxy-hub.sh" "$case_dir/repo/proxy-hub.sh"
cp -- "$REPO_ROOT/lib/manifest.sha256" "$case_dir/repo/lib/manifest.sha256"
cp -- "$REPO_ROOT"/lib/[0-9][0-9]_*.sh "$case_dir/repo/lib/"
printf '\0' | dd of="$case_dir/repo/lib/manifest.sha256" bs=1 seek=32 conv=notrunc status=none
rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/curl.log \
    -- bash /srv/repo/proxy-hub.sh help \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
assert_failed_before_main "local manifest NUL" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "local manifest contains a NUL byte" "local manifest NUL error"
[[ ! -s "$case_dir/curl.log" ]] || fail "local manifest NUL must not fall back to remote curl"

case_dir=$(make_case local-manifest-missing-final-newline)
mkdir -p -- "$case_dir/repo/lib"
cp -- "$REPO_ROOT/proxy-hub.sh" "$case_dir/repo/proxy-hub.sh"
cp -- "$REPO_ROOT/lib/manifest.sha256" "$case_dir/repo/lib/manifest.sha256"
cp -- "$REPO_ROOT"/lib/[0-9][0-9]_*.sh "$case_dir/repo/lib/"
manifest_size=$(wc -c <"$case_dir/repo/lib/manifest.sha256")
truncate -s "$((manifest_size - 1))" "$case_dir/repo/lib/manifest.sha256"
rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/curl.log \
    -- bash /srv/repo/proxy-hub.sh help \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
assert_failed_before_main "local manifest missing final newline" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "local manifest is missing its final newline" \
    "local manifest final newline error"
[[ ! -s "$case_dir/curl.log" ]] || fail "invalid local manifest newline must not fall back to remote curl"

case_dir=$(make_case partial-local-footprint)
mkdir -p -- "$case_dir/repo/lib"
cp -- "$REPO_ROOT/proxy-hub.sh" "$case_dir/repo/proxy-hub.sh"
cp -- "$REPO_ROOT/lib/00_security_state.sh" "$case_dir/repo/lib/00_security_state.sh"
rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/curl.log \
    -- bash /srv/repo/proxy-hub.sh help \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
assert_failed_before_main "partial local Proxy Hub footprint" "$case_dir" "$rc"
[[ ! -s "$case_dir/curl.log" ]] || fail "partial local footprint must not silently fall back to remote curl"

case_dir=$(make_case local-runtime-assembly-write-failure)
mkdir -p -- "$case_dir/repo/lib"
cp -- "$REPO_ROOT/proxy-hub.sh" "$case_dir/repo/proxy-hub.sh"
cp -- "$REPO_ROOT/lib/manifest.sha256" "$case_dir/repo/lib/manifest.sha256"
cp -- "$REPO_ROOT"/lib/[0-9][0-9]_*.sh "$case_dir/repo/lib/"
refresh_local_manifest "$case_dir/repo"
rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CAT_FAIL_MATCH '00_security_state.sh' \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/curl.log \
    -- bash /srv/repo/proxy-hub.sh help \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
assert_failed_before_main "local runtime assembly write failure" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "failed to assemble local runtime" \
    "local assembly write error"
[[ ! -s "$case_dir/curl.log" ]] || fail "local assembly write failure must not fall back to remote curl"

case_dir=$(make_case local-complete-module-omission)
mkdir -p -- "$case_dir/repo/lib"
cp -- "$REPO_ROOT/proxy-hub.sh" "$case_dir/repo/proxy-hub.sh"
cp -- "$REPO_ROOT/lib/manifest.sha256" "$case_dir/repo/lib/manifest.sha256"
cp -- "$REPO_ROOT"/lib/[0-9][0-9]_*.sh "$case_dir/repo/lib/"
refresh_local_manifest "$case_dir/repo"
rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CAT_FAIL_MATCH '00_security_state.sh' \
    --setenv FAKE_CAT_FAIL_ACTION omit-success \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/curl.log \
    -- bash /srv/repo/proxy-hub.sh help \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
assert_failed_before_main "complete local module omission" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "assembled local runtime length mismatch" \
    "complete module omission must be caught by exact length binding"

case_dir=$(make_case remote-syntax-reconstruction-write-failure)
rc=$(run_remote_failure "$case_dir" ok main \
    --setenv FAKE_CAT_FAIL_MATCH '/runtime.body')
assert_failed_before_main "remote syntax reconstruction write failure" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "failed to reconstruct runtime bundle" \
    "remote reconstruction write error"

case_dir=$(make_case remote-syntax-reconstruction-silent-omission)
rc=$(run_remote_failure "$case_dir" ok main \
    --setenv FAKE_CAT_FAIL_MATCH '/runtime.body' \
    --setenv FAKE_CAT_FAIL_ACTION omit-success)
assert_failed_before_main "remote syntax reconstruction silent body omission" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "runtime syntax reconstruction length mismatch" \
    "silent remote body omission must be caught before syntax validation"

case_dir=$(make_case verified-runtime-fd-binding)
rc=$(run_remote_failure "$case_dir" ok main \
    --setenv FAKE_CHMOD_FAIL_MATCH '/runtime.body' \
    --setenv FAKE_CHMOD_FAIL_ACTION replace-file-success)
assert_failed_before_main "validated runtime replacement before FD binding" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "runtime changed between validation and execution" \
    "runtime FD must be bound to the validated bytes"

case_dir=$(make_case body-digest)
mapfile -t trailer < <(tail -n 6 -- "$case_dir/assets/proxy-hub.bundle.sh")
[[ "${trailer[1]}" =~ header-bytes=([0-9]+) ]] || fail "fixture has invalid header metadata"
header_bytes="${BASH_REMATCH[1]}"
printf '!' | dd of="$case_dir/assets/proxy-hub.bundle.sh" bs=1 seek="$header_bytes" conv=notrunc status=none
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "bundle body digest mismatch" "$case_dir" "$rc"

mutate_trailer_case() {
    local name="$1"
    local old="$2"
    local replacement="$3"
    local case_dir
    case_dir=$(make_case "$name")
    sed -i "s|$old|$replacement|" "$case_dir/assets/proxy-hub.bundle.sh"
    printf '%s\n' "$case_dir"
}

case_dir=$(mutate_trailer_case trailer-start 'proxy-hub-bundle-manifest-v1' 'proxy-hub-bundle-manifest-v0')
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "bundle trailer start marker mismatch" "$case_dir" "$rc"

case_dir=$(mutate_trailer_case trailer-header-bytes 'header-bytes=[0-9]*' 'header-bytes=1')
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "bundle header byte count mismatch" "$case_dir" "$rc"

case_dir=$(mutate_trailer_case trailer-build-id '^# build-id=[0-9a-f]*$' '# build-id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "bundle build-id mismatch" "$case_dir" "$rc"

case_dir=$(mutate_trailer_case trailer-module-count 'module-count=10' 'module-count=9')
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "bundle module count mismatch" "$case_dir" "$rc"

case_dir=$(mutate_trailer_case trailer-end 'proxy-hub-bundle-end-v1' 'proxy-hub-bundle-end-v0')
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "bundle trailer end marker mismatch" "$case_dir" "$rc"

case_dir=$(make_case trailer-extra-data)
printf '# forbidden bytes after EOF marker\n' >>"$case_dir/assets/proxy-hub.bundle.sh"
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "bytes after bundle EOF marker" "$case_dir" "$rc"

case_dir=$(make_case missing-final-newline)
bundle_size=$(wc -c <"$case_dir/assets/proxy-hub.bundle.sh")
truncate -s "$((bundle_size - 1))" "$case_dir/assets/proxy-hub.bundle.sh"
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "missing final newline" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "missing its final newline" "missing final newline error"

case_dir=$(make_case interior-nul)
mapfile -t nul_trailer < <(tail -n 6 -- "$case_dir/assets/proxy-hub.bundle.sh")
[[ "${nul_trailer[1]}" =~ header-bytes=([0-9]+) ]] || fail "fixture has invalid header metadata"
nul_offset="${BASH_REMATCH[1]}"
printf '\0' | dd of="$case_dir/assets/proxy-hub.bundle.sh" bs=1 seek="$nul_offset" conv=notrunc status=none
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "interior bundle NUL" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "contains a NUL byte" "interior NUL error"

case_dir=$(make_case local-module-nul)
mkdir -p -- "$case_dir/repo/lib"
cp -- "$REPO_ROOT/proxy-hub.sh" "$case_dir/repo/proxy-hub.sh"
cp -- "$REPO_ROOT/lib/manifest.sha256" "$case_dir/repo/lib/manifest.sha256"
cp -- "$REPO_ROOT"/lib/[0-9][0-9]_*.sh "$case_dir/repo/lib/"
printf '\0' | dd of="$case_dir/repo/lib/20_installers_restart.sh" bs=1 seek=32 conv=notrunc status=none
rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/curl.log \
    -- bash /srv/repo/proxy-hub.sh help \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
assert_failed_before_main "local module NUL" "$case_dir" "$rc"
assert_contains "$(<"$case_dir/stderr")" "contains a NUL byte" "local module NUL error"
[[ ! -s "$case_dir/curl.log" ]] || fail "local module NUL must not fall back to remote curl"

case_dir=$(make_case syntax-error)
bundle_fixture="$case_dir/assets/proxy-hub.bundle.sh"
mapfile -t trailer < <(tail -n 6 -- "$bundle_fixture")
[[ "${trailer[1]}" =~ ^#[[:space:]]header-bytes=([0-9]+)[[:space:]]header-sha256=([0-9a-f]{64})$ ]] || fail "invalid header fixture"
header_bytes="${BASH_REMATCH[1]}"
header_sha="${BASH_REMATCH[2]}"
[[ "${trailer[2]}" =~ ^#[[:space:]]body-bytes=([0-9]+)[[:space:]]body-sha256=([0-9a-f]{64})$ ]] || fail "invalid body fixture"
body_bytes="${BASH_REMATCH[1]}"
syntax_header="$case_dir/header"
syntax_body="$case_dir/body"
dd if="$bundle_fixture" of="$syntax_header" bs=1 count="$header_bytes" status=none
dd if="$bundle_fixture" of="$syntax_body" bs=1 skip="$header_bytes" count="$body_bytes" status=none
printf '\nif then\n' >>"$syntax_body"
new_body_bytes=$(wc -c <"$syntax_body" | tr -d '[:space:]')
new_body_sha=$(sha256_file "$syntax_body")
{
    cat -- "$syntax_header" "$syntax_body"
    printf '%s\n' '# proxy-hub-bundle-manifest-v1'
    printf '# header-bytes=%s header-sha256=%s\n' "$header_bytes" "$header_sha"
    printf '# body-bytes=%s body-sha256=%s\n' "$new_body_bytes" "$new_body_sha"
    printf '# build-id=%s\n' "$new_body_sha"
    printf '%s\n' '# module-count=10'
    printf '%s\n' '# proxy-hub-bundle-end-v1'
} >"$case_dir/assets/proxy-hub.bundle.sh"
rc=$(run_remote_failure "$case_dir" ok main)
assert_failed_before_main "syntax-invalid but digest-valid bundle" "$case_dir" "$rc"

case_dir=$(make_case invalid-ref)
rc=$(run_remote_failure "$case_dir" ok '../main')
assert_failed_before_main "unsafe PROXY_HUB_REF" "$case_dir" "$rc"
[[ ! -s "$case_dir/curl.log" ]] || fail "unsafe ref must be rejected before curl"

case_dir=$(make_case no-hash-tool)
rc=$(run_remote_failure "$case_dir" ok main \
    --ro-bind /dev/null /usr/bin/sha256sum \
    --ro-bind /dev/null /usr/bin/shasum \
    --ro-bind /dev/null /usr/bin/openssl)
assert_failed_before_main "missing SHA-256 implementation" "$case_dir" "$rc"

case_dir=$(make_case unwritable-temp)
rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --ro-bind "$case_dir/tmp" /var/tmp \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /var/tmp \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    -- bash -c 'bash <(cat /mnt/proxy-hub.sh) help' \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
assert_failed_before_main "unwritable bootstrap temp parent" "$case_dir" "$rc"

case_dir=$(make_case unsafe-temp-parent)
mkdir -m 0777 -- "$case_dir/unsafe-tmp"
chmod 0777 "$case_dir/unsafe-tmp"
rc=$(run_remote_failure "$case_dir" ok main --setenv TMPDIR /srv/unsafe-tmp)
assert_failed_before_main "unsafe writable bootstrap temp parent" "$case_dir" "$rc"

case_dir=$(make_case bootstrap-post-create-validation-failure)
rc=$(run_remote_failure "$case_dir" ok main \
    --setenv FAKE_CHMOD_FAIL_MATCH 'proxy-hub.bootstrap.' \
    --setenv FAKE_CHMOD_FAIL_ACTION fail)
assert_failed_before_main "bootstrap post-create validation failure" "$case_dir" "$rc"

case_dir=$(make_case bootstrap-post-create-path-replacement)
rc=$(run_remote_failure "$case_dir" ok main \
    --setenv FAKE_CHMOD_FAIL_MATCH 'proxy-hub.bootstrap.' \
    --setenv FAKE_CHMOD_FAIL_ACTION replace)
assert_ne "0" "$rc" "bootstrap replaced during post-create validation must fail"
replacement_path=$(find "$case_dir/tmp" -mindepth 1 -maxdepth 1 -type d \
    -name 'proxy-hub.bootstrap.*' ! -name '*.original' -print -quit)
[[ -n "$replacement_path" ]] || fail "bootstrap replacement directory was incorrectly removed"
assert_file "$replacement_path/keep"
assert_dir "${replacement_path}.original"
assert_file "$case_dir/tmp/tmp.foreign/keep"
pass "bootstrap child cleanup preserves a replacement with a different identity"

case_dir=$(make_case bootstrap-publication-hup)
mkdir -p -- "$case_dir/hup-bin"
cat >"$case_dir/hup-bin/mktemp" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

created_path=$(/usr/bin/mktemp "$@")
process_group=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
kill -HUP -- "-$process_group"
sleep 0.1
printf '%s\n' "$created_path"
SCRIPT
chmod 755 "$case_dir/hup-bin/mktemp"
hup_rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$case_dir" /srv \
    --setenv PATH "/srv/hup-bin:/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    -- bash -c '
        set -euo pipefail
        child_rc=0
        setsid bash -c "bash <(cat /mnt/proxy-hub.sh) help" >/srv/loader.out 2>/srv/loader.err || child_rc=$?
        [[ "$child_rc" -eq 129 ]]
        ! compgen -G "/srv/tmp/proxy-hub.bootstrap.*" >/dev/null
        [[ -f /srv/tmp/tmp.foreign/keep ]]
    ' >"$case_dir/controller.out" 2>"$case_dir/controller.err" || hup_rc=$?
if ((hup_rc != 0)); then
    sed -n '1,200p' "$case_dir/controller.err" >&2
    fail "bootstrap temp HUP publication test failed with status $hup_rc"
fi
pass "bootstrap temp publication defers HUP until path identity is cleanup-visible"
