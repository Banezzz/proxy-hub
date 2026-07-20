#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${PROXY_HUB_XRAY_TEST_SANDBOXED:-0}" != "1" ]]; then
    require_bwrap

    xray_tmp_base="$TEST_DIR/.tmp"
    mkdir -p -- "$xray_tmp_base"
    xray_tmp=$(mktemp -d "$xray_tmp_base/proxy-hub-test.xray-release.XXXXXXXX")
    register_cleanup_dir "$xray_tmp"

    bwrap \
        --ro-bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --tmpfs /root \
        --tmpfs /run \
        --unshare-net \
        --die-with-parent \
        --ro-bind "$REPO_ROOT" /mnt \
        --bind "$xray_tmp" /srv \
        --setenv PROXY_HUB_XRAY_TEST_SANDBOXED 1 \
        --setenv PROXY_HUB_TESTING 1 \
        --setenv CURRENT_LANG en \
        -- bash /mnt/tests/test_xray_release.sh
    pass "Xray release tests completed in a read-only, networkless sandbox"
    exit 0
fi

assert_file "/mnt/lib/15_xray_release.sh"
assert_file "/mnt/lib/20_installers_restart.sh"
require_command jq

export PROXY_HUB_TESTING=1
export CURRENT_LANG=en
# shellcheck source=../lib/00_security_state.sh
source /mnt/lib/00_security_state.sh
# shellcheck source=../lib/10_runtime_platform_ui.sh
source /mnt/lib/10_runtime_platform_ui.sh
# shellcheck source=../lib/15_xray_release.sh
source /mnt/lib/15_xray_release.sh
# shellcheck source=../lib/20_installers_restart.sh
source /mnt/lib/20_installers_restart.sh

assert_success_output() {
    local expected="$1"
    local label="$2"
    shift 2
    local actual rc=0

    actual=$("$@") || rc=$?
    assert_eq "0" "$rc" "$label exit status"
    assert_eq "$expected" "$actual" "$label output"
}

assert_failure() {
    local label="$1"
    shift
    local rc=0

    "$@" >/srv/failure.stdout 2>/srv/failure.stderr || rc=$?
    assert_ne "0" "$rc" "$label must fail"
}

for accepted_case in \
    "26.7.11:v26.7.11" \
    "v26.7.11:v26.7.11" \
    "1.2:v1.2" \
    "1.2.3.4:v1.2.3.4" \
    "26.7.11-rc1:v26.7.11-rc1" \
    "26.7.11.preview_2:v26.7.11.preview_2" \
    "26.7.-rc1:v26.7.-rc1"; do
    raw=${accepted_case%%:*}
    expected=${accepted_case#*:}
    assert_success_output "$expected" "normalize accepted $raw" normalize_xray_version "$raw"
done
pass "valid Xray versions normalize to a single leading v"

malicious_marker=/srv/version-input-executed
invalid_versions=(
    ""
    "v"
    "1"
    "v1..2"
    "v1.2/../../tmp/pwn"
    "v1.2;touch $malicious_marker"
    "v1.2\$(touch $malicious_marker)"
    $'v1.2\n3'
    " v1.2"
    "v1.2 "
)
for raw in "${invalid_versions[@]}"; do
    assert_failure "normalize rejected unsafe value" normalize_xray_version "$raw"
    assert_not_exists "$malicious_marker"
done
pass "invalid and shell-like Xray versions fail without execution"

assert_success_output "-1" "numeric version less-than" \
    xray_compare_versions v26.3.27 v26.7.11
assert_success_output "0" "versions equal with optional v" \
    xray_compare_versions 26.7.11 v26.7.11
assert_success_output "1" "numeric component ordering" \
    xray_compare_versions v26.10.1 v26.9.99
assert_success_output "-1" "release candidate sorts before final" \
    xray_compare_versions v26.7.11-rc1 v26.7.11
assert_success_output "1" "final sorts after release candidate" \
    xray_compare_versions v26.7.11 v26.7.11-rc1
assert_success_output "-1" "release candidate numeric suffix ordering" \
    xray_compare_versions v26.7.11-rc9 v26.7.11-rc10
assert_success_output "-1" "all accepted suffix forms remain comparable" \
    xray_compare_versions v26.7.-rc1 v26.7
assert_success_output "1" "large components avoid integer overflow" \
    xray_compare_versions v999999999999999999999999.1 v99999999999999999999999.99
pass "version comparison covers numeric, prerelease, final, and huge components"

for arch_case in \
    "x86_64:64" \
    "amd64:64" \
    "aarch64:arm64-v8a" \
    "arm64:arm64-v8a" \
    "armv7l:arm32-v7a" \
    "armv7:arm32-v7a"; do
    raw=${arch_case%%:*}
    expected=${arch_case#*:}
    assert_success_output "$expected" "architecture mapping $raw" map_xray_arch "$raw"
done
assert_failure "unknown architecture" map_xray_arch sparc64
pass "supported architectures map to official Xray release names"

mkdir -p -- /srv/backup-prune
XRAY_BIN=/srv/backup-prune/xray
XRAY_BACKUP_KEEP=3
for backup_name in \
    xray.bak-v99.0-20260101-000000 \
    xray.bak-v1.0-20260201-000000 \
    xray.bak-v2.0-20260301-000000 \
    xray.bak-v3.0-20260401-000000; do
    : > "/srv/backup-prune/$backup_name"
done
: > /srv/backup-prune/xray.bak-manual
_xray_prune_backups
assert_not_exists /srv/backup-prune/xray.bak-v99.0-20260101-000000
assert_file /srv/backup-prune/xray.bak-v1.0-20260201-000000
assert_file /srv/backup-prune/xray.bak-v2.0-20260301-000000
assert_file /srv/backup-prune/xray.bak-v3.0-20260401-000000
assert_file /srv/backup-prune/xray.bak-manual
pass "managed backup pruning keeps the three newest timestamps and ignores foreign files"

XRAY_BACKUP_KEEP='PROBE[$(touch /srv/xray-backup-keep-injected)0]'
if _xray_prune_backups; then
    fail "arithmetic-like backup retention input must be rejected"
fi
assert_not_exists /srv/xray-backup-keep-injected
assert_file /srv/backup-prune/xray.bak-v1.0-20260201-000000
assert_file /srv/backup-prune/xray.bak-v2.0-20260301-000000
assert_file /srv/backup-prune/xray.bak-v3.0-20260401-000000
pass "backup retention validation rejects arithmetic expansion before pruning"
XRAY_BACKUP_KEEP=3
XRAY_BIN=/usr/local/bin/xray

cat > /srv/xray-restart.conf <<'RESTART_CONF'
RESTART_ENABLED=yes
RESTART_LABEL="6h"
RESTART_CRON="0 */6 * * *"
RESTART_SYSTEMD_CALENDAR="*-*-* 00/6:00:00"
RESTART_BACKEND="systemd-timer"
RESTART_CONF
XRAY_RESTART_CONF=/srv/xray-restart.conf
_xray_capture_restart_schedule
assert_eq 1 "$XRAY_TXN_SCHEDULE_ENABLED" "quoted restart schedule is captured"
assert_eq 6h "$XRAY_TXN_SCHEDULE_LABEL" "restart schedule label"
assert_eq '0 */6 * * *' "$XRAY_TXN_SCHEDULE_CRON" "restart cron expression"
assert_eq '*-*-* 00/6:00:00' "$XRAY_TXN_SCHEDULE_CALENDAR" "restart systemd calendar"
pass "project-written quoted restart schedules are journaled without evaluation"

cat > /srv/custom-openrc-xray <<'OPENRC_FIXTURE'
#!/sbin/openrc-run
pidfile="/run/custom-${RC_SVCNAME}.pid"
OPENRC_FIXTURE
assert_success_output /run/custom-xray.pid "custom OpenRC pidfile parsing" \
    openrc_service_pidfile xray /srv/custom-openrc-xray
pass "OpenRC custom pidfile discovery is parsed without sourcing the service script"

(
    INIT_SYSTEM=openrc
    openrc_service_pidfile() { return 1; }
    xray_list_process_ids() { printf '%s\n' "$$"; }
    pgrep() { : > /srv/openrc-pgrep.called; return 99; }
    assert_success_output "$$" "OpenRC Xray fallback PID" service_main_pid xray
    assert_not_exists /srv/openrc-pgrep.called
)
pass "OpenRC Xray PID fallback uses the proc enumerator without pgrep"

mkdir -p -- /srv/bin
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "Xray 26.7.11 (Xray, Penetrates Everything.)"' \
    > /srv/bin/xray-stdout
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%b" "startup warning\\r\\nXray 26.7.12 (Xray, Penetrates Everything.)\\r\\n" >&2' \
    > /srv/bin/xray-stderr
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "unrelated program version 26.7.13"' \
    > /srv/bin/not-xray
chmod 755 /srv/bin/xray-stdout /srv/bin/xray-stderr /srv/bin/not-xray

assert_success_output "v26.7.11" "installed version from normal stdout" \
    get_installed_xray_version /srv/bin/xray-stdout
assert_success_output "v26.7.12" "installed version from noisy CRLF stderr" \
    get_installed_xray_version /srv/bin/xray-stderr
assert_failure "non-Xray version output" get_installed_xray_version /srv/bin/not-xray
assert_failure "missing Xray binary" get_installed_xray_version /srv/bin/missing
pass "installed version parsing tolerates output placement and formatting"

digest_value=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf 'SHA2-256= %s\n' "$digest_value" > /srv/xray.zip.dgst
assert_success_output "$digest_value" "official digest parser" \
    _xray_parse_digest_file /srv/xray.zip.dgst
printf 'SHA2-256= %s\nSHA2-256= %s\n' "$digest_value" "$digest_value" > /srv/xray.zip.dgst
assert_failure "ambiguous official digest" _xray_parse_digest_file /srv/xray.zip.dgst
printf '%s\n' 'SHA2-256= not-a-digest' > /srv/xray.zip.dgst
assert_failure "malformed official digest" _xray_parse_digest_file /srv/xray.zip.dgst
pass "official SHA-256 digest parsing fails closed on malformed or ambiguous input"

XRAY_TEST_STABLE_JSON='{
  "tag_name": "v26.3.27",
  "draft": false,
  "prerelease": false,
  "published_at": "2026-07-01T00:00:00Z"
}'
XRAY_TEST_RELEASES_JSON='[
  {"tag_name":"v26.7.10","draft":false,"prerelease":true,"published_at":"2026-07-10T00:00:00Z"},
  {"tag_name":"v99.0.0","draft":true,"prerelease":true,"published_at":"2026-07-30T00:00:00Z"},
  {"tag_name":"v26.3.27","draft":false,"prerelease":false,"published_at":"2026-07-01T00:00:00Z"},
  {"tag_name":"v26.7.11","draft":false,"prerelease":true,"published_at":"2026-07-20T00:00:00Z"}
]'
XRAY_TEST_API_LOG=/srv/xray-api.log

xray_github_api() {
    local url="$1"
    printf '%s\n' "$url" >> "$XRAY_TEST_API_LOG"
    case "$url" in
        */releases/latest)
            printf '%s\n' "$XRAY_TEST_STABLE_JSON"
            ;;
        */releases|*/releases\?*)
            printf '%s\n' "$XRAY_TEST_RELEASES_JSON"
            ;;
        *)
            return 64
            ;;
    esac
}

: > "$XRAY_TEST_API_LOG"
assert_success_output "v26.3.27" "stable release API selection" get_xray_stable_version
assert_eq "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
    "$(tail -n 1 "$XRAY_TEST_API_LOG")" "stable API endpoint"

: > "$XRAY_TEST_API_LOG"
assert_success_output "v26.7.11" "latest non-draft release selection" get_xray_latest_version
latest_api_url=$(tail -n 1 "$XRAY_TEST_API_LOG")
assert_contains "$latest_api_url" "/repos/XTLS/Xray-core/releases" "latest release API endpoint"
assert_not_contains "$latest_api_url" "/latest" "including-prerelease endpoint"
pass "GitHub JSON selection ignores drafts and uses publication time"

XRAY_TEST_STABLE_JSON='{"message":"API rate limit exceeded"}'
assert_failure "GitHub rate-limit response" get_xray_stable_version
XRAY_TEST_STABLE_JSON='{"tag_name":""}'
assert_failure "empty stable tag" get_xray_stable_version
XRAY_TEST_STABLE_JSON='{
  "tag_name":"v26.3.27",
  "draft":false,
  "prerelease":false,
  "published_at":"2026-07-01T00:00:00Z"
}'
XRAY_TEST_RELEASES_JSON='not-json'
assert_failure "malformed releases JSON" get_xray_latest_version
XRAY_TEST_RELEASES_JSON='[]'
assert_failure "empty releases array" get_xray_latest_version
pass "incomplete GitHub responses fail closed"

# Restore the valid fixtures for resolution tests.
XRAY_TEST_STABLE_JSON='{
  "tag_name":"v26.3.27",
  "draft":false,
  "prerelease":false,
  "published_at":"2026-07-01T00:00:00Z"
}'
XRAY_TEST_RELEASES_JSON='[
  {"tag_name":"v26.3.27","draft":false,"prerelease":false,"published_at":"2026-07-01T00:00:00Z"},
  {"tag_name":"v26.7.11","draft":false,"prerelease":true,"published_at":"2026-07-20T00:00:00Z"}
]'

: > "$XRAY_TEST_API_LOG"
resolved=$(
    unset XRAY_VERSION XRAY_CHANNEL xray_version xray_channel
    XRAY_VERSION=v26.8.1
    xray_version=v26.8.0
    XRAY_CHANNEL=stable
    xray_channel=prerelease
    resolve_xray_target_version
)
assert_eq "v26.8.1" "$resolved" "uppercase fixed version precedence"
assert_eq "" "$(<"$XRAY_TEST_API_LOG")" "fixed version must not query GitHub"

: > "$XRAY_TEST_API_LOG"
resolved=$(
    unset XRAY_VERSION XRAY_CHANNEL xray_version xray_channel
    xray_version=26.8.0
    XRAY_CHANNEL=stable
    resolve_xray_target_version
)
assert_eq "v26.8.0" "$resolved" "lowercase fixed version compatibility"
assert_eq "" "$(<"$XRAY_TEST_API_LOG")" "lowercase fixed version must not query GitHub"

resolved=$(
    unset XRAY_VERSION XRAY_CHANNEL xray_version xray_channel
    XRAY_CHANNEL=prerelease
    xray_channel=stable
    resolve_xray_target_version
)
assert_eq "v26.7.11" "$resolved" "uppercase channel precedence"

resolved=$(
    unset XRAY_VERSION XRAY_CHANNEL xray_version xray_channel
    xray_channel=prerelease
    resolve_xray_target_version
)
assert_eq "v26.7.11" "$resolved" "lowercase channel compatibility"

resolved=$(
    unset XRAY_VERSION XRAY_CHANNEL xray_version xray_channel
    resolve_xray_target_version
)
assert_eq "v26.3.27" "$resolved" "default stable channel"

assert_failure "invalid configured channel" bash -c '
    set -euo pipefail
    export PROXY_HUB_TESTING=1 CURRENT_LANG=en
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/15_xray_release.sh
    xray_github_api() { printf "%s\n" "unexpected network call" >>/srv/invalid-api.log; }
    unset XRAY_VERSION xray_version xray_channel
    XRAY_CHANNEL=nightly
    resolve_xray_target_version
'
assert_not_exists /srv/invalid-api.log
pass "version and channel resolution honor case-compatible precedence"

assert_success_output "noop" "channel same-version no-op" \
    xray_update_decision v26.7.11 v26.7.11 channel
assert_success_output "reinstall" "explicit same-version reinstall" \
    xray_update_decision v26.7.11 v26.7.11 version
assert_success_output "upgrade" "channel upgrade" \
    xray_update_decision v26.3.27 v26.7.11 channel
assert_success_output "refuse" "channel cannot silently downgrade" \
    xray_update_decision v26.7.11 v26.3.27 channel
assert_success_output "downgrade" "explicit version may downgrade" \
    xray_update_decision v26.7.11 v26.3.27 version
pass "update decisions distinguish no-op, reinstall, upgrade, and explicit downgrade"

XRAY_BIN=/srv/bin/xray-stdout
xray_github_api() { return 1; }
status_output=$(cmd_xray_version 2>/srv/version-status.stderr)
assert_contains "$status_output" "Current installed:        v26.7.11" \
    "local version remains visible when GitHub is unavailable"
assert_contains "$status_output" "Latest stable:            Unavailable" \
    "stable query failure is isolated"
assert_contains "$status_output" "Latest incl. prerelease:  Unavailable" \
    "release-list query failure is isolated"
pass "version status preserves local information across independent API failures"

installer_source=$(</mnt/lib/20_installers_restart.sh)
assert_contains "$installer_source" '# proxy-hub-managed: xray-service-v1' \
    "Xray service definitions carry a managed marker"
assert_contains "$installer_source" 'mv -f -T -- "$source" "$target"' \
    "managed definitions publish through a same-directory rename"
assert_contains "$installer_source" '# proxy-hub-managed: xray-restart-helper-v1' \
    "scheduled restarts use a fixed managed helper"
assert_contains "$installer_source" 'exec 9>>"$lock"' \
    "scheduled helper append-opens the lifecycle lock"
assert_contains "$installer_source" 'ExecStart=$XRAY_RESTART_HELPER' \
    "systemd timer invokes only the managed helper"
assert_not_contains "$installer_source" 'flock_bin -n $XRAY_LIFECYCLE_LOCK' \
    "scheduled paths do not use unchecked path-based flock"
publish_dir=/srv/managed-definition
mkdir -p "$publish_dir"
printf '%s\n' old > "$publish_dir/target"
printf '%s\n' new > "$publish_dir/stage"
_xray_publish_managed_definition "$publish_dir/stage" "$publish_dir/target" 0755
assert_eq new "$(<"$publish_dir/target")" "managed definition atomic publication content"
assert_eq 755 "$(stat -c '%a' "$publish_dir/target")" "managed definition atomic publication mode"
assert_not_exists "$publish_dir/stage"

printf '%s\n' '#!/bin/sh' 'legacy body' > "$publish_dir/legacy"
cp "$publish_dir/legacy" "$publish_dir/canonical"
printf '%s\n' '# custom definition' > "$publish_dir/custom"
assert_failure "custom service definition is preserved" \
    _xray_definition_should_publish "$publish_dir/custom" "$publish_dir/canonical" "$publish_dir/legacy"
head -n 1 "$publish_dir/legacy" > "$publish_dir/legacy-prefix"
_xray_definition_should_publish \
    "$publish_dir/legacy-prefix" "$publish_dir/canonical" "$publish_dir/legacy" || \
    fail "legacy managed definition prefix was not repairable"
pass "service definitions and scheduled restarts share atomic publication and validated FD locking"

pass "Xray release management unit contract"
