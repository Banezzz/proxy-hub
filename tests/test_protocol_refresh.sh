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

# Self-signed certificates must stay ECDSA P-256.  sing-box 1.14 Hysteria2
# clients mimic Chrome's QUIC handshake, which does not offer Ed25519, so an
# Ed25519 server certificate fails the handshake outright.
run_scenario selfsigned-cert-algorithm <<'SCENARIO'
load_modules
gen_selfsigned_cert algo edge.example.com
cert_text=$(openssl x509 -in "$SINGBOX_CERT_DIR/algo.crt" -noout -text)
assert_contains "$cert_text" "Public Key Algorithm: id-ecPublicKey" "the certificate key must be ECDSA"
assert_contains "$cert_text" "prime256v1" "the certificate curve must be P-256"
assert_not_contains "$cert_text" "ED25519" "Ed25519 certificates break Chrome-parroting Hysteria2 clients"
assert_contains "$cert_text" "CN = edge.example.com" "the certificate CN follows the SNI"
assert_eq "600" "$(stat -c '%a' "$SINGBOX_CERT_DIR/algo.key")" "the private key must stay private"
SCENARIO

# REALITY short IDs: new keys use the full 8 bytes, and extra IDs widen only
# the server allow-list while share links keep the primary ID.
run_scenario reality-short-ids <<'SCENARIO'
load_modules

validate_reality_short_ids "" || fail_case "an empty list is valid"
validate_reality_short_ids "0123456789abcdef" || fail_case "a 16-hex ID is valid"
validate_reality_short_ids "aa11:BB22cc33" || fail_case "a colon list of even-length IDs is valid"
for bad in "abc" "0123456789abcdef00" "zz11" "aa11::bb22" ":aa11" "aa11:" "aa11,bb22" 'aa11;id'; do
    assert_fails "short ID list '$bad' must be rejected" validate_reality_short_ids "$bad"
done
assert_eq "aa:bb" "$(reality_short_id_list aa bb)" "primary and extra IDs join with a colon"
assert_eq "aa" "$(reality_short_id_list aa "")" "no extra IDs leaves the primary alone"
assert_eq "" "$(reality_short_id_list "" "")" "an empty primary stays empty"

# Key generation: fake core output in the current `x25519` format.
cat >/srv/bin/xray-keys <<'XRAY'
#!/bin/sh
printf '%s\n' 'PrivateKey: 0L7o52zLQdOiD9cNmJwq0t9hmBupbWOBAhSmJVSXDVY' \
    'Password (PublicKey): ui4-cJGwxFuwDxEorVUjWRt8GxpfXfLzDzsFimVabnY' 'Hash32: unused'
XRAY
chmod 755 /srv/bin/xray-keys
XRAY_BIN=/srv/bin/xray-keys
gen_reality_keys 2>/dev/null
[[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || fail_case "new short IDs must be 16 hex characters: $SHORT_ID"
assert_eq "ui4-cJGwxFuwDxEorVUjWRt8GxpfXfLzDzsFimVabnY" "$PUBLIC_KEY" "public key label with a parenthetical"

sids="AA11, bb22cc33" apply_extra_short_ids 2>/dev/null
assert_eq "aa11:bb22cc33" "$EXTRA_SHORT_IDS" "sids accepts commas and normalizes case"
rc=0
( sids="xyz" apply_extra_short_ids 2>/dev/null ) || rc=$?
assert_eq "1" "$rc" "an invalid sids value must fail the install"
unset sids
apply_extra_short_ids
assert_eq "" "$EXTRA_SHORT_IDS" "no sids leaves the extra list empty"

XRAY_BIN=/srv/absent-xray
XRAY_CAPS=""
write_node multi both "EXTRA_SHORT_IDS=aa11:bb22cc33"
write_node solo vision
write_node ar anytls_reality "EXTRA_SHORT_IDS=cc44"
write_config
assert_eq '["0123456789abcdef","aa11","bb22cc33"]' \
    "$(jq -c '.inbounds[] | select(.tag == "multi_vision") | .streamSettings.realitySettings.shortIds' "$XRAY_CONF")" \
    "extra IDs must extend the Vision allow-list"
assert_eq '["0123456789abcdef","aa11","bb22cc33"]' \
    "$(jq -c '.inbounds[] | select(.tag == "multi_xhttp") | .streamSettings.realitySettings.shortIds' "$XRAY_CONF")" \
    "extra IDs must extend the XHTTP allow-list"
assert_eq '["0123456789abcdef"]' \
    "$(jq -c '.inbounds[] | select(.tag == "solo_vision") | .streamSettings.realitySettings.shortIds' "$XRAY_CONF")" \
    "a node without extra IDs keeps a single short ID"
write_singbox_config
assert_eq '["0123456789abcdef","cc44"]' \
    "$(jq -c '.inbounds[] | select(.tag == "ar_anytls") | .tls.reality.short_id' "$SINGBOX_CONF")" \
    "extra IDs must extend the sing-box REALITY allow-list"

CURRENT_NODE_NAME=multi
link=$(get_share_link)
assert_contains "$link" "sid=0123456789abcdef" "links use the primary short ID"
assert_not_contains "$link" "aa11" "extra IDs never enter a share link"
assert_contains "$(show_info)" "aa11, bb22cc33" "node info lists the extra IDs"

# Round trip through save_env keeps the extra IDs.
safe_load_node_config "$NODES_DIR/multi.env"
save_env
assert_eq "aa11:bb22cc33" "$(safe_read_config_value "$NODES_DIR/multi.env" EXTRA_SHORT_IDS)" \
    "save_env must persist the extra short IDs"

if use_real_xray; then
    write_config
    "$XRAY_BIN" run -test -config "$XRAY_CONF" >/srv/xray-test.out 2>&1 || {
        cat /srv/xray-test.out >&2
        fail_case "the real core rejected multiple short IDs"
    }
fi
if use_real_singbox; then
    write_singbox_config || fail_case "the real sing-box rejected multiple short IDs"
fi
SCENARIO

# REALITY nodes default to 443 when it is free; everything else keeps a random
# high port, and explicit ports are never overridden.
run_scenario reality-default-port <<'SCENARIO'
load_modules
LISTENING=""
ss() {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
    local port
    for port in $LISTENING; do
        printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$port"
    done
}
gen_random_free_port() { printf '%s\n' 30001; }

assert_eq "443" "$(default_reality_port 2>/dev/null)" "a free 443 is the REALITY default"

LISTENING="443"
assert_eq "30001" "$(default_reality_port 2>/dev/null)" "a listening 443 must not be offered"
assert_contains "$(default_reality_port 2>&1 >/dev/null)" "443/tcp is taken" \
    "falling back from 443 must be explained"
LISTENING=""

# A stopped node that owns 443 on disk still blocks it.
write_node holder vision
sed -i 's/^PORT=1443$/PORT=443/' "$NODES_DIR/holder.env"
node_tcp_port_claimed 443 || fail_case "a node file holding 443 must claim it"
assert_eq "30001" "$(default_reality_port 2>/dev/null)" "443 claimed by a stopped node must not be offered"
sed -i 's/^PORT=443$/PORT=1443/; s/^XHTTP_PORT=2443$/XHTTP_PORT=443/' "$NODES_DIR/holder.env"
node_tcp_port_claimed 443 || fail_case "an XHTTP port of 443 must claim it"
rm -f -- "$NODES_DIR/holder.env"

# A Hysteria2 node on UDP 443 does not claim TCP 443.
write_node quic hysteria2
sed -i 's/^PORT=1443$/PORT=443/; /^XHTTP_PORT=/d' "$NODES_DIR/quic.env"
assert_fails "UDP 443 must not claim TCP 443" node_tcp_port_claimed 443
assert_eq "443" "$(default_reality_port 2>/dev/null)" "a UDP listener leaves TCP 443 available"
rm -f -- "$NODES_DIR/quic.env"

# The second inbound of a `both` node silently takes a random port.
assert_eq "" "$(default_reality_port 443 2>&1 >/dev/null)" "the sibling inbound must not warn about 443"
assert_eq "30001" "$(default_reality_port 443 2>/dev/null)" "the sibling inbound must avoid 443"

# choose_ports wiring.  The function draws its banner on /dev/tty, so this part
# only runs where the harness has a controlling terminal.
if ( : >/dev/tty ) 2>/dev/null; then
    prompt_port() { printf '%s\n' "$2"; }
    pick() {
        ( PROTOCOL_TYPE="$1"
          choose_ports >/dev/null 2>&1
          printf '%s/%s\n' "${PORT:-}" "${XHTTP_PORT:-}" )
    }
    assert_eq "443/" "$(pick vision)" "Vision defaults to 443"
    assert_eq "443/" "$(pick anytls_reality)" "AnyTLS+REALITY defaults to 443"
    assert_eq "30001/" "$(pick anytls)" "plain AnyTLS keeps a random port"
    assert_eq "443/30001" "$(pick both)" "both: Vision takes 443 and XHTTP a random port"
    assert_eq "8443/" "$(vlpt=8443 pick vision)" "an explicit Vision port wins"
fi
SCENARIO

# The built-in candidate list no longer offers Apple / iCloud targets, and a
# manually chosen one is flagged instead of silently accepted.
run_scenario reality-target-candidates <<'SCENARIO'
load_modules
for domain in "${SNI_LIST[@]}"; do
    assert_fails "built-in candidate $domain is a discouraged REALITY target" \
        reality_target_discouraged "$domain"
done
(( ${#SNI_LIST[@]} >= 100 )) || fail_case "the candidate list shrank unexpectedly: ${#SNI_LIST[@]}"
unique=$(printf '%s\n' "${SNI_LIST[@]}" | sort -u | wc -l)
assert_eq "${#SNI_LIST[@]}" "$unique" "the candidate list must not contain duplicates"

for domain in apple.com www.apple.com WWW.ICLOUD.COM gsp-ssl.ls.apple.com is1-ssl.mzstatic.com; do
    reality_target_discouraged "$domain" || fail_case "$domain must be flagged"
done
for domain in www.tesla.com pineapple.com.example notapple.com icloud.com.example.org ""; do
    assert_fails "$domain must not be flagged" reality_target_discouraged "$domain"
done

assert_contains "$(warn_discouraged_reality_target www.icloud.com 2>&1)" "discouraged as a REALITY target" \
    "a discouraged target must produce a warning"
assert_eq "" "$(warn_discouraged_reality_target www.tesla.com 2>&1)" "an ordinary target stays quiet"
SCENARIO

# SNI probing requires TLS 1.3 where the local openssl can ask for it, and the
# fastest candidates are re-ranked by ASN: same ASN first, generic CDNs last.
run_scenario sni-ranking <<'SCENARIO'
load_modules
real_sni_bulk_asn=$(declare -f sni_bulk_asn)

# TLS 1.3 flag detection follows the local openssl, and is cached.
cat >/srv/bin/openssl <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>/srv/openssl.args
case "$*" in
  *"-help"*) [ -n "${FAKE_TLS13:-}" ] && echo " -tls1_3  Just use TLSv1.3" ;;
esac
exit 0
FAKE
chmod 755 /srv/bin/openssl
PATH="/srv/bin:$PATH"
: >/srv/openssl.args
SNI_TLS13_STATE=""
assert_eq "" "$(sni_tls13_flag)" "an openssl without -tls1_3 must not receive the flag"
SNI_TLS13_STATE=""
export FAKE_TLS13=1
assert_eq "-tls1_3" "$(sni_tls13_flag)" "a current openssl must be asked for TLS 1.3"
sni_tls13_flag >/dev/null
: >/srv/openssl.args
test_domain_latency example.com >/dev/null
assert_eq "s_client -tls1_3 -connect example.com:443 -servername example.com" "$(cat /srv/openssl.args)" \
    "the probe must require TLS 1.3 and reuse the cached capability"
printf '%s\n' v6 >"$NETSTACK_FILE"
: >/srv/openssl.args
test_domain_latency example.com >/dev/null
assert_eq "s_client -6 -tls1_3 -connect example.com:443 -servername example.com" "$(cat /srv/openssl.args)" \
    "the address family and TLS 1.3 flags must combine"
rm -f -- "$NETSTACK_FILE"

# Ranking with a stubbed resolver and ASN source.
sni_resolve_ip() {
    case "$1" in
        fast-cdn.example) echo 198.51.100.1 ;;
        plain.example) echo 198.51.100.2 ;;
        neighbour.example) echo 198.51.100.3 ;;
        slow.example) echo 198.51.100.4 ;;
        unresolved.example) : ;;
    esac
}
get_ipv4() { echo 203.0.113.10; }
sni_bulk_asn() {
    printf '%s\n' "$*" >/srv/asn.query
    printf '%s\n' "198.51.100.1 13335" "198.51.100.2 64500" "198.51.100.3 64511" \
        "198.51.100.4 64500" "203.0.113.10 64511"
}
declare -A lat=( [fast-cdn.example]=10 [plain.example]=20 [neighbour.example]=90
                 [slow.example]=120 [unresolved.example]=15 )
doms=() lats=()
rank_sni_candidates lat doms lats
assert_eq "neighbour.example unresolved.example plain.example slow.example fast-cdn.example" "${doms[*]}" \
    "same-ASN first, then by latency, generic CDN last"
assert_eq "90 15 20 120 10" "${lats[*]}" "latencies must stay attached to their domains"
assert_contains "${SNI_CANDIDATE_TAG[neighbour.example]}" "same ASN AS64511" "the same-ASN candidate is labelled"
assert_eq "CDN AS13335" "${SNI_CANDIDATE_TAG[fast-cdn.example]}" "the CDN candidate is labelled"
assert_eq "" "${SNI_CANDIDATE_TAG[plain.example]:-}" "ordinary candidates carry no label"
assert_contains "$(cat /srv/asn.query)" "203.0.113.10" "the server address must be part of the lookup"

# An unreachable ASN source degrades to plain latency order without failing.
sni_bulk_asn() { return 1; }
rank_sni_candidates lat doms lats
assert_eq "fast-cdn.example unresolved.example plain.example neighbour.example slow.example" "${doms[*]}" \
    "without ASN data the order is latency only"
assert_eq "0" "${#SNI_CANDIDATE_TAG[@]}" "no labels without ASN data"

# The check can be switched off, in which case nothing is resolved or queried.
sni_bulk_asn() { fail_case "ASN lookup ran although SNI_ASN_CHECK=0"; }
sni_resolve_ip() { fail_case "resolver ran although SNI_ASN_CHECK=0"; }
SNI_ASN_CHECK=0 rank_sni_candidates lat doms lats
assert_eq "fast-cdn.example" "${doms[0]}" "disabled ranking keeps latency order"

# The whois response parser accepts the Team Cymru bulk format.
eval "$real_sni_bulk_asn"
timeout() { printf '%s\n' "13335   | 198.51.100.1     | CLOUDFLARENET, US" "NA      | 198.51.100.9     | NA" \
    "64500   | 2001:db8::1      | EXAMPLE-AS"; }
assert_eq "198.51.100.1 13335
2001:db8::1 64500" "$(sni_bulk_asn 198.51.100.1 198.51.100.9 2001:db8::1)" "bulk whois rows must parse to 'IP ASN'"
assert_fails "an empty lookup must fail" sni_bulk_asn
SCENARIO

# `both` nodes: Vision and XHTTP get separate UUIDs, REALITY keys and short IDs.
# A node created before the split keeps rendering the shared credentials.
run_scenario both-split-credentials <<'SCENARIO'
load_modules

# Legacy node: no XHTTP_* fields, both inbounds share everything.
write_node legacy both
write_config
vision=$(jq -c '.inbounds[] | select(.tag == "legacy_vision")' "$XRAY_CONF")
xhttp=$(jq -c '.inbounds[] | select(.tag == "legacy_xhttp")' "$XRAY_CONF")
assert_eq "$(jq -r '.settings.clients[0].id' <<<"$vision")" "$(jq -r '.settings.clients[0].id' <<<"$xhttp")" \
    "a legacy both node keeps one UUID"
assert_eq "$(jq -r '.streamSettings.realitySettings.privateKey' <<<"$vision")" \
    "$(jq -r '.streamSettings.realitySettings.privateKey' <<<"$xhttp")" "a legacy both node keeps one key"
CURRENT_NODE_NAME=legacy
safe_load_node_config "$NODES_DIR/legacy.env"
assert_contains "$(get_xhttp_link 203.0.113.10 l)" "vless://11111111-1111-4111-8111-111111111111@" \
    "a legacy XHTTP link uses the shared UUID"

# Split node.
write_node split both \
    "XHTTP_UUID=22222222-2222-4222-8222-222222222222" \
    "XHTTP_PUBLIC_KEY=SplitPublicKey_abc" \
    "XHTTP_PRIVATE_KEY=YEaD36oML8mWHgw86qao95BwbYgzHxa6_xnLkoKR8aA" \
    "XHTTP_SHORT_ID=fedcba9876543210" \
    "EXTRA_SHORT_IDS=aa11"
write_config
vision=$(jq -c '.inbounds[] | select(.tag == "split_vision")' "$XRAY_CONF")
xhttp=$(jq -c '.inbounds[] | select(.tag == "split_xhttp")' "$XRAY_CONF")
assert_eq "11111111-1111-4111-8111-111111111111" "$(jq -r '.settings.clients[0].id' <<<"$vision")" "Vision UUID"
assert_eq "22222222-2222-4222-8222-222222222222" "$(jq -r '.settings.clients[0].id' <<<"$xhttp")" "XHTTP UUID"
assert_eq "YEaD36oML8mWHgw86qao95BwbYgzHxa6_xnLkoKR8aA" \
    "$(jq -r '.streamSettings.realitySettings.privateKey' <<<"$xhttp")" "XHTTP private key"
assert_eq '["0123456789abcdef","aa11"]' "$(jq -c '.streamSettings.realitySettings.shortIds' <<<"$vision")" \
    "Vision short IDs"
assert_eq '["fedcba9876543210","aa11"]' "$(jq -c '.streamSettings.realitySettings.shortIds' <<<"$xhttp")" \
    "XHTTP short IDs: its own primary plus the shared extras"

CURRENT_NODE_NAME=split
safe_load_node_config "$NODES_DIR/split.env"
xlink=$(get_xhttp_link 203.0.113.10 x)
vlink=$(get_vision_link 203.0.113.10 v)
assert_contains "$xlink" "vless://22222222-2222-4222-8222-222222222222@203.0.113.10:2443" "XHTTP link UUID and port"
assert_contains "$xlink" "pbk=SplitPublicKey_abc&" "XHTTP link public key"
assert_contains "$xlink" "sid=fedcba9876543210" "XHTTP link short ID"
assert_contains "$xlink" "&type=xhttp&mode=auto&path=%2Frefresh-test&" "XHTTP link states the transport mode"
assert_not_contains "$vlink" "mode=" "a raw TCP link has no XHTTP mode"
assert_contains "$vlink" "vless://11111111-1111-4111-8111-111111111111@203.0.113.10:1443" "Vision link is unchanged"
assert_not_contains "$vlink" "SplitPublicKey" "Vision link must not carry the XHTTP key"
info=$(show_info)
assert_contains "$info" "SplitPublicKey_abc" "node info shows the XHTTP key"
assert_contains "$info" "XHTTP has its own credentials" "node info explains the split"

# save_env round trip.
save_env
for field in XHTTP_UUID XHTTP_PUBLIC_KEY XHTTP_PRIVATE_KEY XHTTP_SHORT_ID; do
    [[ -n "$(safe_read_config_value "$NODES_DIR/split.env" "$field")" ]] || fail_case "$field was not persisted"
done

# Generator: fresh XHTTP credentials, Vision ones restored.
cat >/srv/bin/xray-keys <<'XRAY'
#!/bin/sh
n=$(cat /srv/keycount 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >/srv/keycount
printf 'PrivateKey: priv%s\nPassword (PublicKey): pub%s\n' "$n" "$n"
XRAY
chmod 755 /srv/bin/xray-keys
XRAY_BIN=/srv/bin/xray-keys
reset_node_state
gen_reality_keys 2>/dev/null
vision_sid="$SHORT_ID"
gen_xhttp_credentials 2>/dev/null
assert_eq "priv1/pub1/$vision_sid" "$PRIVATE_KEY/$PUBLIC_KEY/$SHORT_ID" "Vision credentials must be restored"
assert_eq "priv2/pub2" "$XHTTP_PRIVATE_KEY/$XHTTP_PUBLIC_KEY" "XHTTP must receive a second key pair"
[[ "$XHTTP_SHORT_ID" =~ ^[0-9a-f]{16}$ && "$XHTTP_SHORT_ID" != "$vision_sid" ]] || \
    fail_case "XHTTP must receive its own short ID"
[[ "$XHTTP_UUID" =~ ^[0-9a-f-]{36}$ ]] || fail_case "XHTTP must receive its own UUID"

if use_real_xray; then
    write_config
    "$XRAY_BIN" run -test -config "$XRAY_CONF" >/srv/xray-test.out 2>&1 || {
        cat /srv/xray-test.out >&2
        fail_case "the real core rejected the split-credential config"
    }
fi
SCENARIO

printf '%s\n' "All protocol-refresh contract tests passed."
