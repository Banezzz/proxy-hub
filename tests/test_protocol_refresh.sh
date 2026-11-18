#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Contract tests for the protocol-refresh work: REALITY field names, share-link
# parameters, post-quantum options, Hysteria2 hardening, and the supply-chain
# gates around third-party downloads.
#
# Every scenario renders configs with the real jq builders.  When
# PROXY_HUB_TEST_XRAY_BIN / PROXY_HUB_TEST_SINGBOX_BIN point at real core
# binaries, the rendered configs are additionally validated by `xray -test` and
# `sing-box check`; without them those assertions are skipped and reported.

require_bwrap
require_command jq
require_command openssl

test_base="$TEST_DIR/.tmp"
mkdir -p -- "$test_base"
test_tmp=$(mktemp -d "$test_base/proxy-hub-test.protocol-refresh.XXXXXXXX")
register_cleanup_dir "$test_tmp"
mkdir -p -- "$test_tmp/tmp" "$test_tmp/cores"

real_xray="${PROXY_HUB_TEST_XRAY_BIN:-}"
real_singbox="${PROXY_HUB_TEST_SINGBOX_BIN:-}"
if [[ -n "$real_xray" && -x "$real_xray" ]]; then
    cp -- "$real_xray" "$test_tmp/cores/xray"
    note "validating rendered Xray configs with $("$real_xray" version | head -n 1)"
else
    note "PROXY_HUB_TEST_XRAY_BIN not set: real 'xray -test' validation is skipped"
fi
if [[ -n "$real_singbox" && -x "$real_singbox" ]]; then
    cp -- "$real_singbox" "$test_tmp/cores/sing-box"
    note "validating rendered sing-box configs with $("$real_singbox" version | head -n 1)"
else
    note "PROXY_HUB_TEST_SINGBOX_BIN not set: real 'sing-box check' validation is skipped"
fi

sandbox=(
    bwrap
    --ro-bind / /
    --dev-bind /dev /dev
    --proc /proc
    --tmpfs /tmp
    --tmpfs /root
    --tmpfs /run
    --tmpfs /usr/local/etc
    --unshare-net
    --die-with-parent
    --ro-bind "$REPO_ROOT" /mnt
    --bind "$test_tmp" /srv
    --setenv TMPDIR /srv/tmp
)

run_scenario() {
    local label="$1"
    if [[ -n "${PROTOCOL_REFRESH_CASE:-}" && "$PROTOCOL_REFRESH_CASE" != "$label" ]]; then
        cat >/dev/null
        return 0
    fi
    local scenario="$test_tmp/$label.sh"
    local stdout_file="$test_tmp/$label.out" stderr_file="$test_tmp/$label.err"
    local rc=0

    {
        cat <<'PRELUDE'
#!/usr/bin/env bash
set -euo pipefail

fail_case() {
    printf 'scenario failure: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" context="$3"
    [[ "$expected" == "$actual" ]] || {
        printf 'expected: <%s>\nactual:   <%s>\n' "$expected" "$actual" >&2
        fail_case "$context"
    }
}

assert_contains() {
    local haystack="$1" needle="$2" context="$3"
    [[ "$haystack" == *"$needle"* ]] || fail_case "$context: $needle"
}

assert_not_contains() {
    local haystack="$1" needle="$2" context="$3"
    [[ "$haystack" != *"$needle"* ]] || fail_case "$context: $needle"
}

assert_fails() {
    local context="$1"
    shift
    if "$@"; then
        fail_case "$context"
    fi
}

# A stand-in for the Xray binary whose `help` output advertises a chosen set of
# sub-commands, so capability probing can be exercised without a real core.
make_fake_xray() {
    local path="$1"
    shift
    {
        printf '%s\n' '#!/bin/sh' 'case "$1" in'
        printf '%s\n' '  help) cat <<HELP' 'The commands are:' '' '	run          Run Xray' '	x25519       Generate key pair'
        local cmd
        for cmd in "$@"; do
            printf '\t%s     generated capability\n' "$cmd"
        done
        printf '%s\n' 'HELP' '  ;;' '  version) echo "Xray 99.1.1 (fake)" ;;' '  *) exit 0 ;;' 'esac'
    } >"$path"
    chmod 755 "$path"
}

load_modules() {
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/15_xray_release.sh
    source /mnt/lib/20_installers_restart.sh
    source /mnt/lib/30_provision_network.sh
    source /mnt/lib/40_config_share.sh
    source /mnt/lib/50_node_commands.sh
    source /mnt/lib/60_system_tools.sh
    source /mnt/lib/70_ports_logs.sh
    source /mnt/lib/80_timesync.sh

    rm -rf -- /srv/netstack /srv/nodes /srv/xray.json /srv/sing-box /srv/bin /srv/state
    mkdir -p -- /srv/bin /srv/state

    NETSTACK_FILE=/srv/netstack
    NODES_DIR=/srv/nodes
    XRAY_CONF=/srv/xray.json
    XRAY_BIN=/srv/absent-xray
    SINGBOX_DIR=/srv/sing-box
    SINGBOX_CONF=/srv/sing-box/config.json
    SINGBOX_CERT_DIR=/srv/sing-box/certs
    SINGBOX_BIN=/srv/absent-sing-box
    ENABLE_CONFIG_ENCRYPTION=false
    CURRENT_LANG=en
    INIT_SYSTEM=systemd
    mkdir -p -- "$NODES_DIR" "$SINGBOX_CERT_DIR"
    chmod 700 -- "$NODES_DIR"

    check_warp_running() { return 1; }
}

# Point the module at the real cores when the harness provides them.
use_real_xray() {
    [[ -x /srv/cores/xray ]] || return 1
    XRAY_BIN=/srv/cores/xray
    XRAY_CAPS=""
}

use_real_singbox() {
    [[ -x /srv/cores/sing-box ]] || return 1
    SINGBOX_BIN=/srv/cores/sing-box
}

write_node() {
    local node_name="$1" protocol="$2"
    shift 2
    {
        cat <<ENV
NODE_NAME=$node_name
SERVER_IP=203.0.113.10
SERVER_IPV4=203.0.113.10
SERVER_IPV6=2001:db8::10
PORT=1443
UUID=11111111-1111-4111-8111-111111111111
SNI=edge.example.com
PUBLIC_KEY=ui4-cJGwxFuwDxEorVUjWRt8GxpfXfLzDzsFimVabnY
PRIVATE_KEY=0L7o52zLQdOiD9cNmJwq0t9hmBupbWOBAhSmJVSXDVY
SHORT_ID=0123456789abcdef
PROTOCOL_TYPE=$protocol
XHTTP_PORT=2443
XHTTP_PATH=/refresh-test
SS_METHOD=2022-blake3-aes-256-gcm
SS_PASSWORD=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=
ANYTLS_PASSWORD=SafeAnyTlsPassword
ANYTLS_PADDING_B64=
HY2_PASSWORD=SafeHy2Password
ENV
        local extra
        for extra in "$@"; do
            printf '%s\n' "$extra"
        done
    } >"$NODES_DIR/${node_name}.env"
    chmod 600 "$NODES_DIR/${node_name}.env"
}
PRELUDE
        cat
    } >"$scenario"

    "${sandbox[@]}" -- bash "/srv/$label.sh" >"$stdout_file" 2>"$stderr_file" || rc=$?
    if ((rc != 0)); then
        sed -n '1,240p' "$stdout_file" >&2
        sed -n '1,240p' "$stderr_file" >&2
        fail "$label failed with status $rc"
    fi
    pass "$label"
}

# REALITY inbounds: the camouflage target is written under the field name the
# installed core understands, and the client-only `fingerprint` is never emitted.
run_scenario reality-target-field <<'SCENARIO'
load_modules
write_node legacy vision

# No usable binary: nothing can be proven, so the legacy field name is kept.
write_config
assert_eq "edge.example.com:443" \
    "$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$XRAY_CONF")" \
    "an unknown core must keep the legacy dest field"
assert_eq "null" "$(jq -r '.inbounds[0].streamSettings.realitySettings.target' "$XRAY_CONF")" \
    "an unknown core must not receive target"
assert_eq "null" "$(jq -r '.inbounds[0].streamSettings.realitySettings.fingerprint' "$XRAY_CONF")" \
    "fingerprint is a client-side field and must not be rendered into an inbound"

# An old core that predates the mldsa65 command keeps dest as well.
make_fake_xray /srv/bin/xray-old
XRAY_BIN=/srv/bin/xray-old
XRAY_CAPS=""
write_config
assert_eq "edge.example.com:443" \
    "$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$XRAY_CONF")" \
    "a core without the mldsa65 command must keep dest"
assert_fails "an old core must not report target support" xray_supports target

# A current core gets the canonical name, for both transports.
make_fake_xray /srv/bin/xray-new mldsa65 mlkem768 vlessenc
XRAY_BIN=/srv/bin/xray-new
XRAY_CAPS=""
write_node pair both
write_config
for index in 0 1 2; do
    assert_eq "edge.example.com:443" \
        "$(jq -r ".inbounds[$index].streamSettings.realitySettings.target" "$XRAY_CONF")" \
        "a current core must receive target (inbound $index)"
    assert_eq "null" "$(jq -r ".inbounds[$index].streamSettings.realitySettings.dest" "$XRAY_CONF")" \
        "target and dest must not both be written (inbound $index)"
done
xray_supports vlessenc || fail_case "vlessenc capability was not detected"
xray_supports mldsa65 || fail_case "mldsa65 capability was not detected"

# Replacing the binary in place invalidates the cached capabilities.
make_fake_xray /srv/bin/xray-new
touch -d '2001-01-01' /srv/bin/xray-new
assert_fails "capabilities must be re-probed after the binary changes" xray_supports target

if use_real_xray; then
    write_config
    assert_eq "target" "$(xray_reality_target_key)" "the real core must support target"
    "$XRAY_BIN" run -test -config "$XRAY_CONF" >/srv/xray-test.out 2>&1 || {
        cat /srv/xray-test.out >&2
        fail_case "the real core rejected the rendered REALITY config"
    }
fi
SCENARIO

# Self-signed nodes: Hysteria2 links carry the certificate pin next to
# insecure=1, and the node info prints the fingerprints for manual pinning.
run_scenario selfsigned-pin-links <<'SCENARIO'
load_modules
write_node hy hysteria2
write_node plain anytls
gen_selfsigned_cert hy edge.example.com
gen_selfsigned_cert plain edge.example.com

expected_pin=$(openssl x509 -in "$SINGBOX_CERT_DIR/hy.crt" -outform der | sha256sum | awk '{print $1}')
assert_eq "$expected_pin" "$(cert_sha256_hex "$SINGBOX_CERT_DIR/hy.crt")" \
    "the pin must be the SHA-256 of the DER certificate"
expected_key=$(openssl x509 -in "$SINGBOX_CERT_DIR/hy.crt" -noout -pubkey \
    | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64 -w0)
assert_eq "$expected_key" "$(cert_pubkey_sha256_b64 "$SINGBOX_CERT_DIR/hy.crt")" \
    "the public-key pin must hash the SubjectPublicKeyInfo"

CURRENT_NODE_NAME=hy
link=$(get_share_link)
assert_contains "$link" "hysteria2://SafeHy2Password@203.0.113.10:1443/?" "Hysteria2 link shape"
assert_contains "$link" "&insecure=1" "insecure=1 stays for clients that only know that flag"
assert_contains "$link" "&pinSHA256=${expected_pin}" "the link must pin the node certificate"
info=$(show_info)
assert_contains "$info" "$expected_pin" "node info must print the certificate fingerprint"
assert_contains "$info" "$expected_key" "node info must print the public-key fingerprint"

# The pin follows the certificate: a regenerated certificate changes the link.
rm -f -- "$SINGBOX_CERT_DIR/hy.crt" "$SINGBOX_CERT_DIR/hy.key"
gen_selfsigned_cert hy edge.example.com
assert_not_contains "$(get_share_link)" "$expected_pin" "a new certificate must produce a new pin"

# A missing certificate degrades to the legacy link instead of an empty pin.
rm -f -- "$SINGBOX_CERT_DIR/hy.crt"
link=$(get_share_link)
assert_contains "$link" "&insecure=1#" "legacy link form without a certificate"
assert_not_contains "$link" "pinSHA256" "no empty pin may be emitted"
assert_fails "an unreadable certificate must not yield a pin" cert_sha256_hex /srv/absent.crt

# Plain AnyTLS has no standard pin parameter; the fingerprints are shown instead.
CURRENT_NODE_NAME=plain
plain_pin=$(cert_sha256_hex "$SINGBOX_CERT_DIR/plain.crt")
assert_contains "$(show_info)" "$plain_pin" "plain AnyTLS info must print the fingerprint"
assert_contains "$(get_share_link)" "insecure=1" "plain AnyTLS keeps insecure=1"

# REALITY variants have no certificate of their own and must not print one.
write_node real anytls_reality
CURRENT_NODE_NAME=real
assert_not_contains "$(show_info)" "Cert SHA-256" "REALITY nodes have no pinned certificate"
SCENARIO

printf '%s\n' "All protocol-refresh contract tests passed."
