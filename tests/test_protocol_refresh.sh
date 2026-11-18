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

# Optional REALITY ML-DSA-65: off by default, gated on the core's capability and
# on the size of the certificate the target returns.
run_scenario reality-mldsa65 <<'SCENARIO'
load_modules
VERIFY=$(head -c 1952 /dev/zero | base64 -w0 | tr '+/' '-_' | tr -d '=')
cat >/srv/bin/xray-pq <<XRAY
#!/bin/sh
case "\$1" in
  help) printf '\tmldsa65   ML-DSA-65\n\tvlessenc  VLESS Encryption\n' ;;
  mldsa65) printf 'Seed: M5gqgH8WoND6770YRg-JDO2qwuGr5vhLgbJBg4xOwMA\nVerify: %s\n' "$VERIFY" ;;
esac
XRAY
chmod 755 /srv/bin/xray-pq
make_fake_xray /srv/bin/xray-old
CHAIN_BYTES=4200
real_cert_bytes=$(declare -f reality_target_cert_bytes)
reality_target_cert_bytes() { printf '%s\n' "$CHAIN_BYTES"; }
SNI=edge.example.com

# Default: nothing is generated and nothing is probed.
XRAY_BIN=/srv/bin/xray-pq
XRAY_CAPS=""
configure_pq_options
assert_eq "/" "$MLDSA65_SEED/$MLDSA65_VERIFY" "ML-DSA-65 must stay off unless requested"

mldsa65=true configure_pq_options 2>/dev/null
assert_eq "M5gqgH8WoND6770YRg-JDO2qwuGr5vhLgbJBg4xOwMA" "$MLDSA65_SEED" "the seed must be captured"
assert_eq "$VERIFY" "$MLDSA65_VERIFY" "the verify key must be captured"

# A target whose certificate is too small cannot carry the signature.
CHAIN_BYTES=2900
mldsa65=1 configure_pq_options 2>/srv/pq.warn
assert_eq "" "$MLDSA65_SEED" "a short target certificate must disable ML-DSA-65"
assert_contains "$(cat /srv/pq.warn)" "2900 certificate bytes" "the skip must state the measured size"
CHAIN_BYTES=0
mldsa65=yes configure_pq_options 2>/dev/null
assert_eq "" "$MLDSA65_SEED" "an unmeasurable target must disable ML-DSA-65"
CHAIN_BYTES=4200

# A core without the command skips with a warning instead of failing the install.
XRAY_BIN=/srv/bin/xray-old
XRAY_CAPS=""
mldsa65=true configure_pq_options 2>/srv/pq.warn
assert_contains "$(cat /srv/pq.warn)" "does not support ML-DSA-65" "an old core must explain the skip"
assert_eq "" "$MLDSA65_SEED" "an old core must not enable ML-DSA-65"

# Rendering.
XRAY_BIN=/srv/bin/xray-pq
XRAY_CAPS=""
write_node pq both "MLDSA65_SEED=M5gqgH8WoND6770YRg-JDO2qwuGr5vhLgbJBg4xOwMA" "MLDSA65_VERIFY=$VERIFY"
write_node plain vision
write_config
for tag in pq_vision pq_xhttp; do
    assert_eq "M5gqgH8WoND6770YRg-JDO2qwuGr5vhLgbJBg4xOwMA" \
        "$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .streamSettings.realitySettings.mldsa65Seed" "$XRAY_CONF")" \
        "$tag must carry the seed"
done
assert_eq "null" \
    "$(jq -r '.inbounds[] | select(.tag == "plain_vision") | .streamSettings.realitySettings.mldsa65Seed' "$XRAY_CONF")" \
    "a node without ML-DSA-65 must not gain the field"

CURRENT_NODE_NAME=pq
safe_load_node_config "$NODES_DIR/pq.env"
vlink=$(get_vision_link 203.0.113.10 v)
assert_contains "$vlink" "&pqv=${VERIFY}&type=tcp#v" "the Vision link must carry pqv"
assert_contains "$(get_xhttp_link 203.0.113.10 x)" "&pqv=${VERIFY}#x" "the XHTTP link must carry pqv"
assert_not_contains "$vlink" "M5gqgH8WoND" "the seed is a server secret and must never enter a link"
assert_contains "$(show_info)" "ML-DSA-65" "node info must mention ML-DSA-65"
CURRENT_NODE_NAME=plain
safe_load_node_config "$NODES_DIR/plain.env"
assert_not_contains "$(get_vision_link 203.0.113.10 v)" "pqv=" "ordinary nodes have no pqv"

# Long links are not turned into an unscannable QR code.
qrencode() { fail_case "qrencode ran for a link that is too long to scan"; }
assert_contains "$(show_qrcode "$vlink")" "too long for a scannable QR code" "long links must skip the QR code"
qrencode() { printf 'QR-RENDERED\n'; }
assert_contains "$(show_qrcode "vless://short")" "QR-RENDERED" "ordinary links still render a QR code"

# An enabled node on a core that lost the capability must fail, not degrade.
XRAY_BIN=/srv/bin/xray-old
XRAY_CAPS=""
rc=0
write_config 2>/srv/mldsa.err || rc=$?
assert_eq "1" "$rc" "rendering an ML-DSA-65 node on an unsupporting core must fail"
assert_contains "$(cat /srv/mldsa.err)" "run xray-update first" "the failure must say how to fix it"

# Certificate-chain measurement.
eval "$real_cert_bytes"
cat >/srv/bin/openssl <<'FAKE'
#!/bin/sh
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=' '-----END CERTIFICATE-----' \
    'noise' '-----BEGIN CERTIFICATE-----' 'QUJDRA==' '-----END CERTIFICATE-----'
FAKE
chmod 755 /srv/bin/openssl
PATH="/srv/bin:$PATH"
assert_eq "33" "$(reality_target_cert_bytes edge.example.com)" "chain size sums every certificate in the handshake"

if use_real_xray; then
    reset_node_state
    gen_mldsa65_keys || fail_case "the real core did not produce ML-DSA-65 keys"
    [[ ${#MLDSA65_VERIFY} -gt 2000 ]] || fail_case "unexpected verify key length: ${#MLDSA65_VERIFY}"
    write_node realpq both "MLDSA65_SEED=$MLDSA65_SEED" "MLDSA65_VERIFY=$MLDSA65_VERIFY"
    write_config
    "$XRAY_BIN" run -test -config "$XRAY_CONF" >/srv/xray-test.out 2>&1 || {
        cat /srv/xray-test.out >&2
        fail_case "the real core rejected the ML-DSA-65 config"
    }
    assert_eq "$MLDSA65_VERIFY" "$(safe_read_config_value "$NODES_DIR/realpq.env" MLDSA65_VERIFY)" \
        "a real verify key must survive the node-file reader"
fi
SCENARIO

# Optional VLESS Encryption: off by default; when on, both inbounds decrypt and
# the XHTTP inbound gains the Vision flow that the encryption layer unlocks.
run_scenario vless-encryption <<'SCENARIO'
load_modules
cat >/srv/bin/xray-enc <<'XRAY'
#!/bin/sh
case "$1" in
  help) printf '\tmldsa65   ML-DSA-65\n\tvlessenc  VLESS Encryption\n' ;;
  vlessenc) cat <<'OUT'
Choose one Authentication to use, do not mix them. Ephemeral key exchange is Post-Quantum safe anyway.

Authentication: X25519, not Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.EN5iuqWArcTGaz2Sgm5H7-n7TXD1am4vYKCQ9PraP3U"
"encryption": "mlkem768x25519plus.native.0rtt.ls4tO2BFOQS9z6pMkz4ty6LRj4GpYfUfQ0o8UKxxQRo"

Authentication: ML-KEM-768, Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.92MSizeJKdX-kGZU3lc1LSGA3tl7WGZmhUgy-zczYeMKLO3sUKrWYx66jmwt6B41LUbrSDvFgiJQvOmSenNtjw"
"encryption": "mlkem768x25519plus.native.0rtt.YEaD36oML8mWHgw86qao95BwbYgzHxa6_xnLkoKR8aAFqVo6sIEnNULGCdahPnZr51XB"
OUT
  ;;
esac
XRAY
chmod 755 /srv/bin/xray-enc
make_fake_xray /srv/bin/xray-old
XRAY_BIN=/srv/bin/xray-enc
XRAY_CAPS=""
SNI=edge.example.com
DEC_X="mlkem768x25519plus.native.600s.EN5iuqWArcTGaz2Sgm5H7-n7TXD1am4vYKCQ9PraP3U"
ENC_X="mlkem768x25519plus.native.0rtt.ls4tO2BFOQS9z6pMkz4ty6LRj4GpYfUfQ0o8UKxxQRo"

# proto= marks a scripted install: no prompt, and nothing is enabled by default.
export proto=vision
configure_pq_options
assert_eq "/" "$VLESS_DECRYPTION/$VLESS_ENCRYPTION" "VLESS Encryption must stay off unless requested"

vlessenc=true configure_pq_options 2>/dev/null
assert_eq "$DEC_X" "$VLESS_DECRYPTION" "vlessenc=true selects the X25519-authenticated pair (decryption)"
assert_eq "$ENC_X" "$VLESS_ENCRYPTION" "vlessenc=true selects the X25519-authenticated pair (encryption)"
vlessenc=MLKEM configure_pq_options 2>/dev/null
assert_contains "$VLESS_DECRYPTION" "92MSizeJKdX" "vlessenc=mlkem selects the ML-KEM-authenticated pair"
assert_contains "$VLESS_ENCRYPTION" "YEaD36oML8mW" "the client string must come from the same section"
vlessenc=no configure_pq_options
assert_eq "" "$VLESS_DECRYPTION" "a false value leaves VLESS Encryption off"

XRAY_BIN=/srv/bin/xray-old
XRAY_CAPS=""
vlessenc=true configure_pq_options 2>/srv/enc.warn
assert_eq "" "$VLESS_DECRYPTION" "an old core must not enable VLESS Encryption"
assert_contains "$(cat /srv/enc.warn)" "does not support VLESS Encryption" "an old core must explain the skip"

# Rendering.
XRAY_BIN=/srv/bin/xray-enc
XRAY_CAPS=""
write_node enc both "VLESS_DECRYPTION=$DEC_X" "VLESS_ENCRYPTION=$ENC_X"
write_node plain both
write_config
assert_eq "$DEC_X" "$(jq -r '.inbounds[] | select(.tag == "enc_vision") | .settings.decryption' "$XRAY_CONF")" \
    "the Vision inbound must decrypt"
assert_eq "$DEC_X" "$(jq -r '.inbounds[] | select(.tag == "enc_xhttp") | .settings.decryption' "$XRAY_CONF")" \
    "the XHTTP inbound must decrypt"
assert_eq "xtls-rprx-vision" \
    "$(jq -r '.inbounds[] | select(.tag == "enc_xhttp") | .settings.clients[0].flow' "$XRAY_CONF")" \
    "VLESS Encryption unlocks the Vision flow on XHTTP"
assert_eq "none/" \
    "$(jq -r '.inbounds[] | select(.tag == "plain_xhttp") | "\(.settings.decryption)/\(.settings.clients[0].flow)"' "$XRAY_CONF")" \
    "a node without VLESS Encryption keeps decryption none and an empty XHTTP flow"

CURRENT_NODE_NAME=enc
safe_load_node_config "$NODES_DIR/enc.env"
vlink=$(get_vision_link 203.0.113.10 v)
xlink=$(get_xhttp_link 203.0.113.10 x)
assert_contains "$vlink" "?encryption=${ENC_X}&flow=xtls-rprx-vision&" "the Vision link carries the client string"
assert_contains "$xlink" "&encryption=${ENC_X}&flow=xtls-rprx-vision&pbk=" "the XHTTP link carries the string and the flow"
assert_not_contains "$vlink$xlink" "EN5iuqWArcTGaz2" "the server decryption key must never enter a link"
assert_contains "$(show_info)" "VLESS Encryption" "node info must mention VLESS Encryption"
CURRENT_NODE_NAME=plain
safe_load_node_config "$NODES_DIR/plain.env"
assert_contains "$(get_vision_link 203.0.113.10 v)" "?encryption=none&" "ordinary links keep encryption=none"
assert_not_contains "$(get_xhttp_link 203.0.113.10 x)" "flow=" "ordinary XHTTP links have no flow"

XRAY_BIN=/srv/bin/xray-old
XRAY_CAPS=""
rc=0
write_config 2>/srv/enc.err || rc=$?
assert_eq "1" "$rc" "rendering a VLESS Encryption node on an unsupporting core must fail"
assert_contains "$(cat /srv/enc.err)" "run xray-update first" "the failure must say how to fix it"

if use_real_xray; then
    for mode in x25519 mlkem; do
        reset_node_state
        gen_vlessenc_keys "$mode" || fail_case "the real core did not produce a $mode key pair"
        rm -f -- "$NODES_DIR"/*.env
        write_node "real$mode" both "VLESS_DECRYPTION=$VLESS_DECRYPTION" "VLESS_ENCRYPTION=$VLESS_ENCRYPTION"
        write_config
        "$XRAY_BIN" run -test -config "$XRAY_CONF" >/srv/xray-test.out 2>&1 || {
            cat /srv/xray-test.out >&2
            fail_case "the real core rejected the VLESS Encryption config ($mode)"
        }
        assert_eq "$VLESS_ENCRYPTION" "$(safe_read_config_value "$NODES_DIR/real$mode.env" VLESS_ENCRYPTION)" \
            "a real $mode client string must survive the node-file reader"
    done
fi
SCENARIO

# Hysteria2 Salamander obfuscation: optional, validated, and reflected in the
# inbound, the share link and the node info.
run_scenario hysteria2-obfs <<'SCENARIO'
load_modules

configure_hy2_options
assert_eq "" "$HY2_OBFS_PASSWORD" "obfuscation must stay off unless requested"
hy2obfs=true configure_hy2_options 2>/dev/null
[[ "$HY2_OBFS_PASSWORD" =~ ^[0-9a-f]{32}$ ]] || fail_case "hy2obfs=true must generate a random password"
hy2obfs=Chosen.Obfs-Pass_1 configure_hy2_options 2>/dev/null
assert_eq "Chosen.Obfs-Pass_1" "$HY2_OBFS_PASSWORD" "an explicit obfs password must be kept"
hy2obfs=off configure_hy2_options
assert_eq "" "$HY2_OBFS_PASSWORD" "a false value leaves obfuscation off"
for bad in short 'has space' 'semi;colon' 'quote"x12345'; do
    rc=0
    ( hy2obfs="$bad" configure_hy2_options 2>/dev/null ) || rc=$?
    assert_eq "1" "$rc" "obfs password '$bad' must be rejected"
done

assert_fails "the builder must reject an unsafe obfs password" \
    build_hysteria2_inbound n 4443 SafeHy2Password edge.example.com /c /k 'bad"pw12345'

write_node obfs hysteria2 "HY2_OBFS_PASSWORD=Chosen.Obfs-Pass_1"
write_node clear hysteria2
gen_selfsigned_cert obfs edge.example.com
gen_selfsigned_cert clear edge.example.com
write_singbox_config
assert_eq '{"type":"salamander","password":"Chosen.Obfs-Pass_1"}' \
    "$(jq -c '.inbounds[] | select(.tag == "obfs_hysteria2") | .obfs' "$SINGBOX_CONF")" "obfs block"
assert_eq "null" "$(jq -r '.inbounds[] | select(.tag == "obfs_hysteria2") | .masquerade' "$SINGBOX_CONF")" \
    "an obfuscated inbound cannot serve an HTTP/3 masquerade"
assert_eq "null/proxy" \
    "$(jq -r '.inbounds[] | select(.tag == "clear_hysteria2") | "\(.obfs)/\(.masquerade.type)"' "$SINGBOX_CONF")" \
    "a node without obfuscation keeps the masquerade and gains no obfs block"

CURRENT_NODE_NAME=obfs
link=$(get_share_link)
assert_contains "$link" "&obfs=salamander&obfs-password=Chosen.Obfs-Pass_1#" "the link must carry the obfs settings"
assert_contains "$link" "pinSHA256=" "obfuscation and certificate pinning combine"
assert_contains "$(show_info)" "salamander" "node info must show the obfuscation"
CURRENT_NODE_NAME=clear
assert_not_contains "$(get_share_link)" "obfs" "an ordinary link has no obfs parameters"

safe_load_node_config "$NODES_DIR/obfs.env"
save_env
assert_eq "Chosen.Obfs-Pass_1" "$(safe_read_config_value "$NODES_DIR/obfs.env" HY2_OBFS_PASSWORD)" \
    "save_env must persist the obfs password"

if use_real_singbox; then
    write_singbox_config || fail_case "the real sing-box rejected the Salamander config"
fi
SCENARIO

# Hysteria2 port hopping: range validation, conflict detection, an idempotent
# dedicated NAT chain, and re-application on every service start.
run_scenario hysteria2-port-hopping <<'SCENARIO'
load_modules
HY2_HOP_HELPER=/srv/state/libexec/proxy-hub-hy2-hop
HY2_HOP_DROPIN=/srv/state/systemd/sing-box.service.d/20-proxy-hub-hy2-hop.conf
systemctl() { printf '%s\n' "$*" >>/srv/systemctl.calls; }
: >/srv/systemctl.calls

assert_eq "20000-20100" "$(validate_hop_range 20000-20100)" "a plain range is accepted"
assert_eq "8000-9000" "$(validate_hop_range 08000-09000)" "leading zeros are normalized, not read as octal"
for bad in "" 20000 20100-20000 20000-20000 0-100 60000-70000 1-30000 "20000-20100;id" 'a-b' "20000 - 20100"; do
    assert_fails "hop range '$bad' must be rejected" validate_hop_range "$bad"
done

# Conflicts with other nodes.
write_node hy1 hysteria2 "HY2_HOP_PORTS=30000-30100"
sed -i 's/^PORT=1443$/PORT=4443/' "$NODES_DIR/hy1.env"
write_node ss1 shadowsocks
sed -i 's/^PORT=1443$/PORT=25000/' "$NODES_DIR/ss1.env"
write_node tcp1 vision
sed -i 's/^PORT=1443$/PORT=26000/' "$NODES_DIR/tcp1.env"
hy2_hop_range_conflicts 30050-30200 other || fail_case "overlapping hop ranges must conflict"
hy2_hop_range_conflicts 4000-5000 other || fail_case "a range covering another Hysteria2 port must conflict"
hy2_hop_range_conflicts 24990-25010 other || fail_case "a range covering a Shadowsocks UDP port must conflict"
assert_fails "a TCP-only node inside the range is not a conflict" hy2_hop_range_conflicts 25990-26010 other
assert_fails "a node does not conflict with itself" hy2_hop_range_conflicts 30000-30100 hy1
assert_fails "a disjoint range is free" hy2_hop_range_conflicts 40000-40100 other

# Random recommendation: valid, 200 wide, and conflict-free.
for _ in 1 2 3 4 5; do
    auto=$(gen_hy2_hop_range other)
    validate_hop_range "$auto" >/dev/null || fail_case "generated range is invalid: $auto"
    assert_eq "199" "$(( ${auto#*-} - ${auto%-*} ))" "the generated range spans 200 ports"
    assert_fails "the generated range must not conflict: $auto" hy2_hop_range_conflicts "$auto" other
done

# Option handling at install time.
cat >/srv/bin/iptables <<'FAKE'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >>/srv/iptables.calls
[ -z "${FAKE_IPTABLES_FAIL:-}" ] || case "$*" in *"$FAKE_IPTABLES_FAIL"*) exit 1 ;; esac
exit 0
FAKE
chmod 755 /srv/bin/iptables
cp /srv/bin/iptables /srv/bin/ip6tables
PATH="/srv/bin:$PATH"
CURRENT_NODE_NAME=fresh
hy2hop=41000-41050 configure_hy2_options 2>/dev/null
assert_eq "41000-41050" "$HY2_HOP_PORTS" "an explicit range is adopted"
hy2hop=AUTO configure_hy2_options 2>/dev/null
validate_hop_range "$HY2_HOP_PORTS" >/dev/null || fail_case "hy2hop=auto must produce a range"
configure_hy2_options
assert_eq "" "$HY2_HOP_PORTS" "port hopping must stay off unless requested"
rc=0
( hy2hop=30050-30200 configure_hy2_options 2>/dev/null ) || rc=$?
assert_eq "1" "$rc" "a conflicting range must fail the install"
rc=0
( hy2hop=nonsense configure_hy2_options 2>/dev/null ) || rc=$?
assert_eq "1" "$rc" "an invalid range must fail the install"

# Sync: helper, rules, drop-in.
: >/srv/iptables.calls
hy2_hop_sync || fail_case "hop sync failed"
[[ -x "$HY2_HOP_HELPER" ]] || fail_case "the helper was not installed"
sh -n "$HY2_HOP_HELPER" || fail_case "the helper is not valid POSIX sh"
calls=$(cat /srv/iptables.calls)
assert_contains "$calls" "iptables -t nat -N PROXY_HUB_HY2_HOP" "the dedicated chain is created"
assert_contains "$calls" "iptables -t nat -A PROXY_HUB_HY2_HOP -p udp --dport 30000:30100 -j REDIRECT --to-ports 4443" \
    "the range is redirected to the listen port"
assert_contains "$calls" "iptables -t nat -A PREROUTING -j PROXY_HUB_HY2_HOP" "the chain is hooked into PREROUTING"
if [[ -f /proc/net/if_inet6 ]]; then
    assert_contains "$calls" "ip6tables -t nat -A PROXY_HUB_HY2_HOP -p udp --dport 30000:30100" "IPv6 gets the same rule"
fi
assert_not_contains "$calls" "-A INPUT" "the helper must not touch filter rules"
assert_contains "$(cat "$HY2_HOP_DROPIN")" "ExecStartPre=-$HY2_HOP_HELPER apply" \
    "sing-box re-applies the rules on every start"
assert_contains "$(cat /srv/systemctl.calls)" "daemon-reload" "systemd must reload after the drop-in changes"

# Idempotent: every apply tears the chain down before rebuilding it.
: >/srv/iptables.calls
"$HY2_HOP_HELPER" apply
assert_eq "1" "$(grep -c '^iptables -t nat -A PREROUTING' /srv/iptables.calls)" "one PREROUTING hook per apply"
assert_contains "$(head -n 3 /srv/iptables.calls)" "-D PREROUTING -j PROXY_HUB_HY2_HOP" "apply starts by unhooking"

# An IPv4 failure is fatal; an IPv6-only failure is tolerated.
rc=0
FAKE_IPTABLES_FAIL="--dport" hy2_hop_sync 2>/dev/null || rc=$?
assert_eq "1" "$rc" "a failed IPv4 rule must fail the sync"
cat >/srv/bin/ip6tables <<'FAKE'
#!/bin/sh
case "$*" in *"-N "*) exit 1 ;; esac
exit 0
FAKE
hy2_hop_sync || fail_case "a missing IPv6 NAT table must not fail the sync"

# Link and info.
gen_selfsigned_cert hy1 edge.example.com
CURRENT_NODE_NAME=hy1
assert_contains "$(get_share_link)" "&mport=30000-30100#" "the link advertises the hop range"
assert_contains "$(show_info)" "UDP 30000-30100 -> 4443" "node info shows the redirect"

# Removing the last hop range clears rules, helper and drop-in.
sed -i 's/^HY2_HOP_PORTS=.*/HY2_HOP_PORTS=/' "$NODES_DIR/hy1.env"
cp /srv/bin/iptables /srv/bin/ip6tables
: >/srv/iptables.calls
hy2_hop_sync
assert_contains "$(cat /srv/iptables.calls)" "iptables -t nat -X PROXY_HUB_HY2_HOP" "the chain is deleted"
assert_not_contains "$(cat /srv/iptables.calls)" " -N " "no chain is recreated without rules"
[[ ! -e "$HY2_HOP_HELPER" && ! -e "$HY2_HOP_DROPIN" ]] || fail_case "helper or drop-in was left behind"
hy2_hop_sync || fail_case "syncing with nothing to do must succeed"

# OpenRC wires the helper into start_pre instead of a drop-in.
openrc_script=$(declare -f create_singbox_openrc_service)
assert_contains "$openrc_script" "proxy-hub-hy2-hop apply" "the OpenRC service must re-apply hop rules on start"
SCENARIO

# Hysteria2 with an ACME certificate: the config shape follows the installed
# sing-box, challenges that would fight a local node for a port are disabled,
# and the share link drops insecure/pin in favour of normal verification.
run_scenario hysteria2-acme <<'SCENARIO'
load_modules
make_singbox() {
    printf '#!/bin/sh\n[ "$1" = version ] && echo "sing-box version %s"\nexit 0\n' "$1" >/srv/bin/sing-box-fake
    chmod 755 /srv/bin/sing-box-fake
    SINGBOX_BIN=/srv/bin/sing-box-fake
}

version_ge 1.14.4 1.14.0 || fail_case "1.14.4 >= 1.14.0"
version_ge v1.14.0 1.14.0 || fail_case "v-prefixed versions compare equal"
assert_fails "1.13.16 < 1.14.0" version_ge 1.13.16 1.14.0
assert_fails "1.9.9 < 1.14.0 (numeric, not lexical)" version_ge 1.9.9 1.14.0
make_singbox 1.14.4
assert_eq "1.14.4" "$(singbox_installed_version)" "installed version is parsed"
SINGBOX_BIN=/srv/absent-sing-box
assert_fails "an absent binary has no version" singbox_installed_version

# Option validation.
get_ipv4() { echo 203.0.113.10; }
get_ipv6() { echo ""; }
getent() { [[ "$2" == hy.example.com ]] && printf '203.0.113.10 STREAM hy.example.com\n'; return 0; }
ss() { printf 'State Recv-Q Send-Q Local Address:Port\n'; for p in ${LISTENING:-}; do printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$p"; done; }
CURRENT_NODE_NAME=fresh
hy2domain=HY.Example.com hy2email=ops@example.com configure_hy2_options 2>/dev/null
assert_eq "hy.example.com/ops@example.com" "$HY2_DOMAIN/$HY2_EMAIL" "domain is lower-cased and the email kept"
configure_hy2_options
assert_eq "" "$HY2_DOMAIN" "ACME must stay off unless a domain is given"
for bad in localhost 203.0.113.10 'bad domain.com' 'a..b.com' '-x.example.com'; do
    rc=0
    ( hy2domain="$bad" configure_hy2_options 2>/dev/null ) || rc=$?
    assert_eq "1" "$rc" "ACME domain '$bad' must be rejected"
done
rc=0
( hy2domain=hy.example.com hy2email='not an email' configure_hy2_options 2>/dev/null ) || rc=$?
assert_eq "1" "$rc" "an invalid ACME email must be rejected"
rc=0
( LISTENING="80 443"; hy2domain=hy.example.com configure_hy2_options 2>/dev/null ) || rc=$?
assert_eq "1" "$rc" "ACME without a free challenge port must be rejected"
hy2domain=other.example.com configure_hy2_options 2>/srv/acme.warn
assert_contains "$(cat /srv/acme.warn)" "does not resolve yet" "an unresolvable domain must be flagged"
getent() { printf '198.51.100.7 STREAM x\n'; }
hy2domain=hy.example.com configure_hy2_options 2>/srv/acme.warn
assert_contains "$(cat /srv/acme.warn)" "not this server" "a domain pointing elsewhere must be flagged"

# Rendering on sing-box >= 1.14: shared certificate provider.
write_node acme hysteria2 "HY2_DOMAIN=hy.example.com" "HY2_EMAIL=ops@example.com"
write_node self hysteria2
sed -i 's/^PORT=1443$/PORT=5443/' "$NODES_DIR/self.env"
make_singbox 1.14.4
write_singbox_config
assert_eq '{"enabled":true,"server_name":"hy.example.com","certificate_provider":"acme-acme"}' \
    "$(jq -c '.inbounds[] | select(.tag == "acme_hysteria2") | .tls' "$SINGBOX_CONF")" "provider reference"
assert_eq '[{"type":"acme","tag":"acme-acme","domain":["hy.example.com"],"data_directory":"/srv/sing-box/acme","email":"ops@example.com"}]' \
    "$(jq -c '.certificate_providers' "$SINGBOX_CONF")" "shared ACME provider"
assert_eq "/srv/sing-box/certs/self.crt" \
    "$(jq -r '.inbounds[] | select(.tag == "self_hysteria2") | .tls.certificate_path' "$SINGBOX_CONF")" \
    "self-signed nodes keep their certificate files"
[[ ! -e "$SINGBOX_CERT_DIR/acme.crt" ]] || fail_case "an ACME node must not get a self-signed certificate"

# A REALITY node on 443 turns off the TLS-ALPN challenge.
write_node web vision
sed -i 's/^PORT=1443$/PORT=443/' "$NODES_DIR/web.env"
write_singbox_config
assert_eq "true/null" \
    "$(jq -r '.certificate_providers[0] | "\(.disable_tls_alpn_challenge)/\(.disable_http_challenge)"' "$SINGBOX_CONF")" \
    "443 claimed by a node disables TLS-ALPN-01 only"
rm -f -- "$NODES_DIR/web.env"

# Older sing-box: inline ACME, no top-level providers.
make_singbox 1.13.16
write_singbox_config
assert_eq "hy.example.com" \
    "$(jq -r '.inbounds[] | select(.tag == "acme_hysteria2") | .tls.acme.domain[0]' "$SINGBOX_CONF")" "inline ACME"
assert_eq "null" "$(jq -r '.certificate_providers' "$SINGBOX_CONF")" "no provider list before 1.14"

# Without ACME nodes the config has no provider key at all.
rm -f -- "$NODES_DIR/acme.env"
make_singbox 1.14.4
write_singbox_config
assert_eq "false" "$(jq 'has("certificate_providers")' "$SINGBOX_CONF")" "no ACME node, no provider key"

# Link and info.
write_node acme hysteria2 "HY2_DOMAIN=hy.example.com"
CURRENT_NODE_NAME=acme
link=$(get_share_link)
assert_contains "$link" "/?sni=hy.example.com#" "the link verifies against the domain"
assert_not_contains "$link" "insecure" "a CA-issued certificate needs no insecure flag"
assert_not_contains "$link" "pinSHA256" "a renewing certificate must not be pinned"
assert_contains "$(show_info)" "ACME" "node info states the certificate source"

assert_fails "the ACME builder must reject an unsafe domain" \
    build_hy2_acme_json n 'bad"domain' "" /d 1 0 0
assert_fails "the ACME builder must reject an unsafe email" \
    build_hy2_acme_json n hy.example.com 'a"b@c' /d 1 0 0

if use_real_singbox; then
    write_node acme hysteria2 "HY2_DOMAIN=hy.example.com" "HY2_EMAIL=ops@example.com" \
        "HY2_OBFS_PASSWORD=Chosen.Obfs-Pass_1"
    write_singbox_config || fail_case "the real sing-box rejected the ACME provider config"
    assert_eq "acme-acme" "$(jq -r '.inbounds[] | select(.tag == "acme_hysteria2") | .tls.certificate_provider' "$SINGBOX_CONF")" \
        "the real core is new enough for certificate providers"
fi
SCENARIO

# Guided presets: an interactive install explains every choice, generates all
# parameters itself, and Enter picks the recommended preset.  A scripted install
# (proto= or any option variable) is never asked and keeps everything off.
run_scenario guided-presets <<'SCENARIO'
load_modules
cat >/srv/bin/iptables <<'FAKE'
#!/bin/sh
exit 0
FAKE
chmod 755 /srv/bin/iptables
SAFE_PATH="$PATH"
PATH="/srv/bin:$PATH"
CURRENT_NODE_NAME=fresh
PROXY_HUB_TTY_OUT=/srv/tty.out

# Feed answers through the test seam: one line per question.
answer_with() {
    printf '%s\n' "$@" >/srv/tty.answers
    exec 7</srv/tty.answers
    PROXY_HUB_TTY_FD=7
    : >/srv/tty.out
}
done_answering() { exec 7<&-; unset PROXY_HUB_TTY_FD; }

# Enter: the recommended preset, obfuscation with a random password.
answer_with ""
configure_hy2_options 2>/dev/null
done_answering
[[ "$HY2_OBFS_PASSWORD" =~ ^[0-9a-f]{32}$ ]] || fail_case "Enter must enable obfuscation with a random password"
assert_eq "/" "$HY2_HOP_PORTS/$HY2_DOMAIN" "the default preset adds neither hopping nor ACME"
screen=$(cat /srv/tty.out)
assert_contains "$screen" "[recommended, default]" "the menu must mark the recommended preset"
assert_contains "$screen" "scrambles the traffic" "each preset must explain what it does"
assert_contains "$screen" "allow that UDP range in the cloud firewall" "the hopping preset must state its cost"
first_password="$HY2_OBFS_PASSWORD"
answer_with "1"
configure_hy2_options 2>/dev/null
done_answering
assert_ne_pw() { [[ "$1" != "$2" ]] || fail_case "$3"; }
assert_ne_pw "$first_password" "$HY2_OBFS_PASSWORD" "every install must get its own random password"

# Preset 2: obfuscation plus a random hop range.
answer_with "2"
configure_hy2_options 2>/dev/null
done_answering
[[ -n "$HY2_OBFS_PASSWORD" ]] || fail_case "preset 2 must enable obfuscation"
validate_hop_range "$HY2_HOP_PORTS" >/dev/null || fail_case "preset 2 must pick a hop range: $HY2_HOP_PORTS"

# Preset 2 without iptables degrades to preset 1 and says so.
mkdir -p /srv/nopath
for tool in bash sh cat awk sort head shuf openssl getent tr basename dirname mktemp rm mkdir chmod mv timeout stat; do
    tool_path=$(PATH="$SAFE_PATH" command -v "$tool") && ln -sf "$tool_path" "/srv/nopath/$tool"
done
answer_with "2"
PATH=/srv/nopath configure_hy2_options 2>/srv/preset.warn
done_answering
[[ -n "$HY2_OBFS_PASSWORD" && -z "$HY2_HOP_PORTS" ]] || fail_case "without iptables preset 2 must fall back to obfuscation only"
assert_contains "$(cat /srv/preset.warn)" "using preset 1" "the fallback must be announced"
assert_contains "$(cat /srv/tty.out)" "iptables is not installed" "the menu must show why hopping is unavailable"

# Preset 3: nothing.
answer_with "3"
configure_hy2_options
done_answering
assert_eq "//" "$HY2_OBFS_PASSWORD/$HY2_HOP_PORTS/$HY2_DOMAIN" "preset 3 leaves the node plain"

# Custom: every question has an Enter default.
answer_with "4" "" "a" ""
configure_hy2_options 2>/dev/null
done_answering
[[ "$HY2_OBFS_PASSWORD" =~ ^[0-9a-f]{32}$ ]] || fail_case "custom: Enter must generate the obfs password"
validate_hop_range "$HY2_HOP_PORTS" >/dev/null || fail_case "custom: 'a' must pick a random hop range"
assert_eq "" "$HY2_DOMAIN" "custom: Enter keeps the self-signed certificate"
assert_contains "$(cat /srv/tty.out)" "Enter = random (recommended)" "custom questions must state their defaults"

answer_with "4" "n" "41000-41100" ""
configure_hy2_options 2>/dev/null
done_answering
assert_eq "/41000-41100" "$HY2_OBFS_PASSWORD/$HY2_HOP_PORTS" "custom: explicit answers are honoured"

answer_with "4" "My.Own-Pass_99" "" ""
configure_hy2_options 2>/dev/null
done_answering
assert_eq "My.Own-Pass_99/" "$HY2_OBFS_PASSWORD/$HY2_HOP_PORTS" "custom: a typed password is kept"

# A scripted install is never asked and stays off by default.
answer_with "2"
proto=hysteria2 configure_hy2_options
assert_eq "//" "$HY2_OBFS_PASSWORD/$HY2_HOP_PORTS/$HY2_DOMAIN" "proto= must suppress the menu and keep defaults off"
assert_eq "" "$(cat /srv/tty.out)" "proto= must not draw the menu"
hy2obfs=false configure_hy2_options
assert_eq "" "$(cat /srv/tty.out)" "an option variable must not draw the menu"
done_answering

# Post-quantum menu.
make_fake_xray /srv/bin/xray-pq mldsa65 vlessenc
XRAY_BIN=/srv/bin/xray-pq
XRAY_CAPS=""
answer_with ""
prompt_pq_options
done_answering
assert_eq "/" "$PQ_WANT_VLESSENC/$PQ_WANT_MLDSA65" "Enter keeps post-quantum options off"
screen=$(cat /srv/tty.out)
assert_contains "$screen" "Works with every client" "the off choice must explain itself"
assert_contains "$screen" "[recommended for recent clients]" "the menu must say which option to prefer"
assert_contains "$screen" "no QR code" "the ML-DSA-65 cost must be stated"
answer_with "1"
prompt_pq_options
done_answering
assert_eq "x25519/" "$PQ_WANT_VLESSENC/$PQ_WANT_MLDSA65" "choice 1 selects VLESS Encryption"
answer_with "3"
prompt_pq_options
done_answering
assert_eq "x25519/true" "$PQ_WANT_VLESSENC/$PQ_WANT_MLDSA65" "choice 3 selects both"
answer_with "1"
proto=vision prompt_pq_options
assert_eq "" "$(cat /srv/tty.out)" "a scripted install must not draw the post-quantum menu"
make_fake_xray /srv/bin/xray-old
XRAY_BIN=/srv/bin/xray-old
XRAY_CAPS=""
prompt_pq_options
assert_eq "" "$(cat /srv/tty.out)" "a core without either capability must not draw the menu"
done_answering

# Without a terminal and without the seam nothing is asked.
unset PROXY_HUB_TTY_FD
if ! ( : >/dev/tty ) 2>/dev/null; then
    configure_hy2_options
    assert_eq "" "$HY2_OBFS_PASSWORD" "no terminal: defaults stay off instead of failing"
fi
SCENARIO

# The protocol menu explains every choice and positions Shadowsocks honestly.
run_scenario protocol-menu-guidance <<'SCENARIO'
load_modules
menu=$(declare -f prompt_protocol_type)
assert_contains "$menu" "[recommended, default]" "the menu must mark a recommended protocol"
assert_contains "$menu" "relay or landing use only" "Shadowsocks must be positioned as a relay protocol"
assert_contains "$menu" "No domain or certificate needed" "REALITY must explain why it is the default"
assert_contains "$menu" "needs UDP allowed" "Hysteria2 must state its network requirement"
for choice in 1 2 3 4 5 6 7; do
    assert_contains "$menu" "\${GREEN}${choice}.\${NC}" "protocol choice $choice must still be offered"
done
install_flow=$(declare -f cmd_install)
assert_contains "$install_flow" "Shadowsocks has no traffic disguise" "installing Shadowsocks must warn about its positioning"
SCENARIO

# sing-box releases: nothing unverified is executed, and a failed replacement
# leaves the previous binary and service state in place.
run_scenario singbox-verified-release <<'SCENARIO'
load_modules
SINGBOX_DIR=/srv/sb
SINGBOX_BIN=/srv/sb/bin/sing-box
SINGBOX_CONF=/srv/sb/config.json
mkdir -p /srv/sb/bin /srv/pkg
log_info() { printf 'info: %s\n' "$*" >>/srv/sb.log; }
log_warn() { printf 'warn: %s\n' "$*" >>/srv/sb.log; }
log_error() { printf 'error: %s\n' "$*" >>/srv/sb.log; }
uname() { printf 'x86_64\n'; }
system_is_musl() { return 1; }
sleep() { :; }

# A fake core: reports its version, and `check` obeys CHECK_RC baked in at build.
build_release() {
    local version="$1" check_rc="${2:-0}" dir="sing-box-$1-linux-amd64"
    rm -rf -- "/srv/pkg/$dir"
    mkdir -p -- "/srv/pkg/$dir"
    cat >"/srv/pkg/$dir/sing-box" <<CORE
#!/bin/sh
case "\$1" in
  version) echo "sing-box version $version" ;;
  check) exit $check_rc ;;
esac
CORE
    chmod 755 "/srv/pkg/$dir/sing-box"
    tar -czf "/srv/pkg/$version.tar.gz" -C /srv/pkg "$dir"
}
LATEST=1.14.4
DIGEST_MODE=real
ASSET_HOST=https://github.com
release_json() {
    local version="$1" name digest
    name="sing-box-${version}-linux-amd64.tar.gz"
    case "$DIGEST_MODE" in
        real) digest="\"sha256:$(sha256sum "/srv/pkg/$version.tar.gz" | awk '{print $1}')\"" ;;
        wrong) digest="\"sha256:$(printf 'x' | sha256sum | awk '{print $1}')\"" ;;
        malformed) digest='"md5:abc"' ;;
        absent) digest=null ;;
    esac
    printf '{"tag_name":"v%s","assets":[{"name":"%s","browser_download_url":"%s/SagerNet/sing-box/releases/download/v%s/%s","digest":%s}]}\n' \
        "$version" "$name" "$ASSET_HOST" "$version" "$name" "$digest"
}
secure_curl() {
    local arg url="" dest="" want_dest=0 version
    for arg in "$@"; do
        if ((want_dest)); then dest="$arg"; want_dest=0; continue; fi
        case "$arg" in -o) want_dest=1 ;; https://*) url="$arg" ;; esac
    done
    printf '%s\n' "$url" >>/srv/sb.urls
    case "$url" in
        */releases/latest) release_json "$LATEST" ;;
        */releases/tags/v*) release_json "${url##*/v}" ;;
        *) version="${url##*/sing-box-}"; version="${version%-linux-amd64.tar.gz}"
           cp -- "/srv/pkg/$version.tar.gz" "$dest" ;;
    esac
}
ACTIVE=yes
START_OK=yes
service_is_active() { [[ "$ACTIVE" == yes ]]; }
service_restart() {
    printf 'restart %s\n' "$("$SINGBOX_BIN" version)" >>/srv/sb.service
    if [[ "$START_OK" == yes || "$("$SINGBOX_BIN" version)" != *"$LATEST"* ]]; then ACTIVE=yes; else ACTIVE=no; return 1; fi
}
reset_case() { rm -f -- /srv/sb.log /srv/sb.urls /srv/sb.service; : >/srv/sb.urls; : >/srv/sb.log; : >/srv/sb.service; }
build_release 1.13.15
build_release 1.14.4
install_old() { tar -xzf /srv/pkg/1.13.15.tar.gz -C /srv/pkg; cp /srv/pkg/sing-box-1.13.15-linux-amd64/sing-box "$SINGBOX_BIN"; rm -f "$SINGBOX_BIN".bak-*; }

# Fresh install of the latest stable release.
reset_case
singbox_install_release fresh || { cat /srv/sb.log >&2; fail_case "fresh install failed"; }
assert_eq "sing-box version 1.14.4" "$("$SINGBOX_BIN" version)" "the verified release is installed"
assert_eq "" "$(cat /srv/sb.service)" "a fresh install does not touch the service"

# Digest problems: nothing is installed and the cause is named.
for mode in wrong malformed absent; do
    reset_case
    rm -f -- "$SINGBOX_BIN"
    DIGEST_MODE="$mode"
    rc=0
    singbox_install_release fresh || rc=$?
    assert_eq "1" "$rc" "digest mode '$mode' must fail the install"
    [[ ! -e "$SINGBOX_BIN" ]] || fail_case "digest mode '$mode' left a binary installed"
    assert_contains "$(cat /srv/sb.log)" "SHA-256" "digest mode '$mode' must name the cause"
done
[[ -z "$(find /srv/sb/bin -name '.sing-box.new.*')" ]] || fail_case "a failed install leaked a staged binary"

# An operator-supplied digest is still enforced.
reset_case
DIGEST_MODE=absent
SINGBOX_SHA256=$(sha256sum /srv/pkg/1.14.4.tar.gz | awk '{print $1}') singbox_install_release fresh || \
    fail_case "a correct SINGBOX_SHA256 must allow the install"
rm -f -- "$SINGBOX_BIN"
rc=0
SINGBOX_SHA256=$(printf y | sha256sum | awk '{print $1}') singbox_install_release fresh || rc=$?
assert_eq "1" "$rc" "a wrong SINGBOX_SHA256 must still fail"
DIGEST_MODE=real

# Download URLs outside the official release path are refused.
reset_case
ASSET_HOST=https://evil.example
rc=0
singbox_install_release fresh || rc=$?
assert_eq "1" "$rc" "an asset hosted elsewhere must be refused"
assert_not_contains "$(cat /srv/sb.urls)" "evil.example" "the foreign URL must never be fetched"
ASSET_HOST=https://github.com

# Update of a running service.
install_old
printf '{}\n' >"$SINGBOX_CONF"
reset_case
ACTIVE=yes
singbox_install_release update || { cat /srv/sb.log >&2; fail_case "update failed"; }
assert_eq "sing-box version 1.14.4" "$("$SINGBOX_BIN" version)" "the update replaces the binary"
assert_eq "restart sing-box version 1.14.4" "$(cat /srv/sb.service)" "a running service is restarted on the new binary"
backup=$(ls "$SINGBOX_BIN".bak-v1.13.15-* 2>/dev/null | head -n 1)
[[ -n "$backup" ]] || fail_case "the previous binary was not backed up with its version"
assert_eq "sing-box version 1.13.15" "$("$backup" version)" "the backup holds the previous binary"

# Already current: no download, no restart.
reset_case
singbox_install_release update
assert_not_contains "$(cat /srv/sb.urls)" "/download/" "an up-to-date core must not be downloaded again"
assert_eq "" "$(cat /srv/sb.service)" "an up-to-date core must not be restarted"

# A stopped service stays stopped.
install_old
reset_case
ACTIVE=no
singbox_install_release update || fail_case "update of a stopped service failed"
assert_eq "" "$(cat /srv/sb.service)" "a stopped service must not be started by an update"
assert_eq "sing-box version 1.14.4" "$("$SINGBOX_BIN" version)" "the stopped service still gets the new binary"

# The new core rejects the current config: the old binary is untouched.
install_old
build_release 1.14.4 1
reset_case
ACTIVE=yes
rc=0
singbox_install_release update || rc=$?
assert_eq "1" "$rc" "a config the new core rejects must cancel the update"
assert_eq "sing-box version 1.13.15" "$("$SINGBOX_BIN" version)" "the old binary must stay in place"
assert_eq "" "$(cat /srv/sb.service)" "a cancelled update must not restart the service"
build_release 1.14.4

# The new core fails to start: the old binary and the running state are restored.
install_old
reset_case
ACTIVE=yes
START_OK=no
rc=0
singbox_install_release update || rc=$?
assert_eq "1" "$rc" "a failed start must fail the update"
assert_eq "sing-box version 1.13.15" "$("$SINGBOX_BIN" version)" "the old binary must be restored"
assert_eq "yes" "$ACTIVE" "the service must be running again on the old binary"
assert_contains "$(cat /srv/sb.log)" "restoring the previous version" "the rollback must be reported"
START_OK=yes

# Stable older than the installed core: no automatic downgrade.
reset_case
LATEST=1.13.15
cp /srv/pkg/sing-box-1.14.4-linux-amd64/sing-box "$SINGBOX_BIN" 2>/dev/null || {
    tar -xzf /srv/pkg/1.14.4.tar.gz -C /srv/pkg; cp /srv/pkg/sing-box-1.14.4-linux-amd64/sing-box "$SINGBOX_BIN"; }
singbox_install_release update
assert_eq "sing-box version 1.14.4" "$("$SINGBOX_BIN" version)" "a newer installed core must not be downgraded"
assert_contains "$(cat /srv/sb.log)" "refusing an automatic downgrade" "the refusal must be explained"

# An explicit version is honoured, including a downgrade, and is validated.
SINGBOX_VERSION=v1.13.15 singbox_install_release update || fail_case "an explicit version must install"
assert_eq "sing-box version 1.13.15" "$("$SINGBOX_BIN" version)" "an explicit version allows a downgrade"
assert_contains "$(cat /srv/sb.urls)" "/releases/tags/v1.13.15" "an explicit version queries its own release"
rc=0
SINGBOX_VERSION='1.14;rm' singbox_install_release update || rc=$?
assert_eq "1" "$rc" "an unsafe version string must be rejected"
LATEST=1.14.4

# A release that reports another version than its tag is refused.
build_release 9.9.9
cp /srv/pkg/9.9.9.tar.gz /srv/pkg/1.14.4.tar.gz
install_old
reset_case
rc=0
singbox_install_release update || rc=$?
assert_eq "1" "$rc" "an archive reporting a different version must be refused"
assert_eq "sing-box version 1.13.15" "$("$SINGBOX_BIN" version)" "a refused archive must not replace the binary"
build_release 1.14.4

# Backups are pruned to the configured count.
for stamp in 20260101-000001 20260101-000002 20260101-000003 20260101-000004 20260101-000005; do
    : >"$SINGBOX_BIN.bak-v1.0.0-$stamp"
    touch -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} 00:00:0${stamp: -1}" "$SINGBOX_BIN.bak-v1.0.0-$stamp"
done
: >"$SINGBOX_BIN.bak-manual"
SINGBOX_BACKUP_KEEP=2 singbox_prune_backups
assert_eq "2" "$(ls "$SINGBOX_BIN".bak-v* | wc -l | tr -d ' ')" "only the newest backups are kept"
[[ -e "$SINGBOX_BIN.bak-manual" ]] || fail_case "a backup the script did not create must not be pruned"
SCENARIO

# sing-box release commands: a read-only status view and a guarded update.
run_scenario singbox-release-commands <<'SCENARIO'
load_modules
SINGBOX_BIN=/srv/bin/sing-box
make_core() { printf '#!/bin/sh\n[ "$1" = version ] && echo "sing-box version %s"\nexit 0\n' "$1" >"$SINGBOX_BIN"; chmod 755 "$SINGBOX_BIN"; }
LATEST_TAG=v1.14.4
secure_curl() { [[ -n "$LATEST_TAG" ]] || return 22; printf '{"tag_name":"%s","assets":[]}\n' "$LATEST_TAG"; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

make_core 1.14.4
out=$(cmd_singbox_version | strip)
assert_contains "$out" "Installed:      v1.14.4" "the installed version is shown"
assert_contains "$out" "Latest stable:  v1.14.4" "the latest stable version is shown"
assert_contains "$out" "up to date" "a current core is reported as up to date"

make_core 1.14.0
assert_contains "$(cmd_singbox_version | strip)" "an update is available" "an older core is offered an update"

make_core 1.12.3
out=$(cmd_singbox_version | strip)
assert_contains "$out" "Security baseline: v1.13.16" "the baseline is shown"
assert_contains "$out" "below the security baseline" "a core below the baseline is flagged"

# A failed remote query keeps the local result.
LATEST_TAG=""
out=$(cmd_singbox_version | strip)
assert_contains "$out" "Installed:      v1.12.3" "the local version survives a failed query"
assert_contains "$out" "Latest stable:  unavailable" "the remote side is marked unavailable"
assert_contains "$out" "below the security baseline" "the baseline check needs no network"

rm -f -- "$SINGBOX_BIN"
assert_contains "$(cmd_singbox_version | strip)" "Not installed" "an absent core is reported"

# The update command refuses to run unprivileged or without an installed core.
is_root() { return 1; }
assert_fails "an unprivileged update must be refused" cmd_singbox_update
is_root() { return 0; }
rc=0
cmd_singbox_update 2>/srv/update.err || rc=$?
assert_eq "1" "$rc" "updating a core that is not installed must fail"
assert_contains "$(cat /srv/update.err)" "sing-box is not installed" "the failure must explain itself"
make_core 1.14.0
singbox_install_release() { printf '%s\n' "$1" >/srv/update.intent; }
cmd_singbox_update
assert_eq "update" "$(cat /srv/update.intent)" "the command drives the update intent"

# CLI wiring.
main=$(cat /mnt/lib/90_main.sh)
assert_contains "$main" "singbox-version)" "singbox-version must be dispatched"
assert_contains "$main" "singbox-update)" "singbox-update must be dispatched"
assert_contains "$main" "cmd_singbox_release_menu" "the tools menu must reach the sing-box release view"
SCENARIO

# Security baselines: an installed core older than its baseline is reported by
# the health check with the command that fixes it.
run_scenario core-security-baseline <<'SCENARIO'
load_modules
XRAY_BIN=/srv/bin/xray
SINGBOX_BIN=/srv/bin/sing-box
set_xray() { printf '#!/bin/sh\n[ "$1" = version ] && echo "Xray %s (Xray, Penetrates Everything.) abc (go1.27 linux/amd64)"\nexit 0\n' "$1" >"$XRAY_BIN"; chmod 755 "$XRAY_BIN"; }
set_singbox() { printf '#!/bin/sh\n[ "$1" = version ] && echo "sing-box version %s"\nexit 0\n' "$1" >"$SINGBOX_BIN"; chmod 755 "$SINGBOX_BIN"; }

assert_eq "" "$(core_baseline_gaps)" "no installed core, no gap"
set_xray 26.11.9
set_singbox 1.14.4
assert_eq "26.11.9" "$(xray_installed_version_plain)" "the Xray version is parsed"
assert_eq "" "$(core_baseline_gaps)" "current cores have no gap"

set_xray 26.10.21
assert_eq "xray 26.10.21 26.10.31" "$(core_baseline_gaps)" "an Xray below the baseline is reported"
set_xray 26.10.31
assert_eq "" "$(core_baseline_gaps)" "the baseline itself is acceptable"
set_xray 25.9.11
set_singbox 1.13.15
assert_eq "xray 25.9.11 26.10.31
sing-box 1.13.15 1.13.16" "$(core_baseline_gaps)" "both cores can be below their baselines"

# A core whose version cannot be read is not reported as outdated.
printf '#!/bin/sh\nexit 1\n' >"$XRAY_BIN"
assert_eq "sing-box 1.13.15 1.13.16" "$(core_baseline_gaps)" "an unreadable version is not a baseline gap"

# Health check output.
set_xray 25.9.11
write_node n1 vision
service_is_active() { return 0; }
ss() { printf 'LISTEN 0 128 0.0.0.0:1443 0.0.0.0:*\n'; }
timeout() { shift; [[ "$1" == openssl ]] && return 0; "$@"; }
health=$(cmd_health | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$health" "xray v25.9.11 is below the security baseline v26.10.31" "the health check names the Xray gap"
assert_contains "$health" "xray-update" "the health check names the fix for Xray"
assert_contains "$health" "sing-box v1.13.15 is below the security baseline v1.13.16" "the health check names the sing-box gap"
assert_contains "$health" "singbox-update" "the health check names the fix for sing-box"
assert_contains "$health" "All checks passed" "an outdated core is a warning, not a failed check"
SCENARIO

# The third-party WARP script: private download path, visible digest, optional
# pinning, and no execution of whatever menu.sh sits in the working directory.
run_scenario warp-script-guard <<'SCENARIO'
load_modules
cat >/srv/warp-menu.sh <<'REMOTE'
#!/bin/bash
printf 'ran:%s\n' "$1" >>/srv/warp.ran
REMOTE
SCRIPT_SHA=$(sha256sum /srv/warp-menu.sh | awk '{print $1}')
secure_curl() {
    local arg dest="" want_dest=0
    for arg in "$@"; do
        if ((want_dest)); then dest="$arg"; want_dest=0; continue; fi
        case "$arg" in -o) want_dest=1 ;; https://*) printf '%s\n' "$arg" >>/srv/warp.urls ;; esac
    done
    printf '%s\n' "$dest" >>/srv/warp.dest
    cp /srv/warp-menu.sh "$dest"
}
reset_case() { rm -f /srv/warp.ran /srv/warp.urls /srv/warp.dest; : >/srv/warp.ran; }

# A matching pinned digest runs without a question.
reset_case
WARP_SCRIPT_SHA256="$SCRIPT_SHA" warp_run_script c </dev/null >/srv/warp.out 2>&1 || fail_case "a matching digest must run"
assert_eq "ran:c" "$(cat /srv/warp.ran)" "the action is passed through"
assert_not_contains "$(cat /srv/warp.out)" "Continue?" "a pinned digest needs no confirmation"
dest=$(cat /srv/warp.dest)
[[ "$dest" != /tmp/warp-menu-* ]] || fail_case "the download path must not be predictable"
[[ ! -e "$dest" ]] || fail_case "the downloaded script must be removed afterwards"
assert_contains "$(cat /srv/warp.urls)" "/raw/main/menu.sh" "the default ref is main"

# A mismatching pinned digest refuses to run.
reset_case
rc=0
WARP_SCRIPT_SHA256=$(printf x | sha256sum | awk '{print $1}') warp_run_script c </dev/null >/srv/warp.out 2>&1 || rc=$?
assert_eq "1" "$rc" "a mismatching digest must refuse"
assert_eq "" "$(cat /srv/warp.ran)" "a mismatching script must not run"
[[ ! -e "$(cat /srv/warp.dest)" ]] || fail_case "a refused script must be removed"

# Unpinned: the digest is shown, Enter continues, n cancels.
reset_case
printf '\n' | warp_run_script c >/srv/warp.out 2>&1 || fail_case "Enter must continue"
assert_contains "$(cat /srv/warp.out)" "SHA-256: $SCRIPT_SHA" "the digest must be shown before running"
assert_contains "$(cat /srv/warp.out)" "third-party script" "the prompt must say what is about to run"
assert_eq "ran:c" "$(cat /srv/warp.ran)" "Enter runs the script"
reset_case
rc=0
printf 'n\n' | warp_run_script c >/srv/warp.out 2>&1 || rc=$?
assert_eq "1" "$rc" "n must cancel"
assert_eq "" "$(cat /srv/warp.ran)" "a cancelled script must not run"

# The source can be pinned to a ref, and the ref is validated.
reset_case
WARP_SCRIPT_REF=0123abcd WARP_SCRIPT_SHA256="$SCRIPT_SHA" warp_run_script u </dev/null >/dev/null 2>&1
assert_contains "$(cat /srv/warp.urls)" "/raw/0123abcd/menu.sh" "WARP_SCRIPT_REF selects the source ref"
assert_eq "ran:u" "$(cat /srv/warp.ran)" "the uninstall action is passed through"
reset_case
rc=0
WARP_SCRIPT_REF='main/../../x' warp_run_script c </dev/null >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "an unsafe ref must be rejected"
[[ ! -e /srv/warp.urls ]] || fail_case "an unsafe ref must not be fetched"

# Uninstall never runs a menu.sh found in the working directory.
uninstall=$(declare -f warp_uninstall)
assert_not_contains "$uninstall" "bash menu.sh" "a local menu.sh is not a trusted source"
SCENARIO

# GeoData: both databases must match their published checksums before either
# replaces the live copy, and the weekly cron job runs the same verified helper.
run_scenario geodata-verified-update <<'SCENARIO'
load_modules
XRAY_GEODATA_DIR=/srv/geo
GEODATA_HELPER=/srv/state/libexec/proxy-hub-geodata-update
mkdir -p /srv/geo /srv/remote
printf 'old-geoip\n' >/srv/geo/geoip.dat
printf 'old-geosite\n' >/srv/geo/geosite.dat

# A fake curl serving /srv/remote by file name.
cat >/srv/bin/curl <<'FAKE'
#!/bin/sh
url=""; dest=""
while [ $# -gt 0 ]; do
  case "$1" in -o) dest="$2"; shift ;; https://*) url="$1" ;; esac
  shift
done
name="${url##*/}"
[ -f "/srv/remote/$name" ] || exit 22
cp "/srv/remote/$name" "$dest"
FAKE
chmod 755 /srv/bin/curl
PATH="/srv/bin:$PATH"
publish() {
    printf '%s\n' "$1" >/srv/remote/geoip.dat
    printf '%s\n' "$2" >/srv/remote/geosite.dat
    printf '%s  geoip.dat\n' "$(sha256sum /srv/remote/geoip.dat | awk '{print $1}')" >/srv/remote/geoip.dat.sha256sum
    printf '%s  geosite.dat\n' "$(sha256sum /srv/remote/geosite.dat | awk '{print $1}')" >/srv/remote/geosite.dat.sha256sum
}

install_geodata_helper || fail_case "the helper could not be installed"
sh -n "$GEODATA_HELPER" || fail_case "the helper is not valid POSIX sh"

publish new-geoip new-geosite
"$GEODATA_HELPER" || fail_case "a verified update must succeed"
assert_eq "new-geoip/new-geosite" "$(cat /srv/geo/geoip.dat)/$(cat /srv/geo/geosite.dat)" "both databases are replaced"
[[ -z "$(find /srv/geo -name '.geodata.*')" ]] || fail_case "the staging directory was left behind"

# One bad checksum keeps both old files: no half-updated pair.
publish newer-geoip newer-geosite
printf '%s  geosite.dat\n' "$(printf x | sha256sum | awk '{print $1}')" >/srv/remote/geosite.dat.sha256sum
rc=0
"$GEODATA_HELPER" 2>/srv/geo.err || rc=$?
assert_eq "1" "$rc" "a checksum mismatch must fail"
assert_contains "$(cat /srv/geo.err)" "checksum mismatch: geosite.dat" "the failing file is named"
assert_eq "new-geoip/new-geosite" "$(cat /srv/geo/geoip.dat)/$(cat /srv/geo/geosite.dat)" \
    "a failed update must leave both live files untouched"

# A missing or malformed checksum file fails closed as well.
publish newer-geoip newer-geosite
rm -f /srv/remote/geoip.dat.sha256sum
assert_fails "a missing checksum file must fail" "$GEODATA_HELPER"
printf 'not-a-hash  geoip.dat\n' >/srv/remote/geoip.dat.sha256sum
assert_fails "a malformed checksum must fail" "$GEODATA_HELPER"
: >/srv/remote/geoip.dat.sha256sum
assert_fails "an empty checksum must fail" "$GEODATA_HELPER"
assert_eq "new-geoip" "$(cat /srv/geo/geoip.dat)" "failed runs never touch the live data"
[[ -z "$(find /srv/geo -name '.geodata.*')" ]] || fail_case "a failed run leaked its staging directory"

# Cron: the legacy unverified entry is replaced by one call to the helper.
CRONTAB_FILE=/srv/crontab
cat >"$CRONTAB_FILE" <<'CRON'
15 3 * * * /usr/bin/backup
0 4 * * 0 curl --proto '=https' --tlsv1.2 -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o /usr/local/share/xray/geoip.dat && curl --proto '=https' --tlsv1.2 -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o /usr/local/share/xray/geosite.dat >/dev/null 2>&1
CRON
# Like the real crontab, the stub replaces the table only after reading all input.
crontab() {
    if [[ "${1:-}" == "-l" ]]; then
        cat "$CRONTAB_FILE"
    else
        cat >"$CRONTAB_FILE.new"
        mv -f "$CRONTAB_FILE.new" "$CRONTAB_FILE"
    fi
}
geodata_cron_is_legacy || fail_case "the unverified cron entry must be recognised as legacy"
setup_geodata_cron
setup_geodata_cron
assert_eq "1" "$(grep -c 'proxy-hub-geodata' "$CRONTAB_FILE")" "repeated setup must not stack cron entries"
assert_contains "$(cat "$CRONTAB_FILE")" "0 4 * * 0 $GEODATA_HELPER" "cron runs the verified helper"
assert_not_contains "$(cat "$CRONTAB_FILE")" "geoip.dat -o" "the unverified download is gone"
assert_contains "$(cat "$CRONTAB_FILE")" "/usr/bin/backup" "unrelated cron entries survive"
assert_fails "a migrated crontab is no longer legacy" geodata_cron_is_legacy

# install_geodata reports failure instead of pretending the data is ready.
execute_task() { bash -c "$1"; }
msg() { printf '%s' "$1"; }
ln() { :; }
rm -f /srv/remote/geoip.dat
rc=0
install_geodata >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "install_geodata must fail when the download fails"
publish final-geoip final-geosite
install_geodata >/dev/null 2>&1 || fail_case "install_geodata failed with valid data"
assert_eq "final-geoip" "$(cat /srv/geo/geoip.dat)" "install_geodata installs verified data"
SCENARIO

# Service sandbox hardening: a drop-in that is only kept when the service still
# starts under it, with a reduced directive set inside containers.
run_scenario service-hardening <<'SCENARIO'
load_modules
SYSTEMD_DROPIN_ROOT=/srv/state/systemd
SERVICE_HARDENING_STATE_DIR=/srv/state/proxy-hub
SYSTEMD_VERSION=252
IN_CONTAINER=no
systemctl() {
    case "$1" in
        --version) printf 'systemd %s (%s-1)\n+PAM +AUDIT\n' "$SYSTEMD_VERSION" "$SYSTEMD_VERSION" ;;
        *) printf '%s\n' "$*" >>/srv/systemctl.calls ;;
    esac
}
systemd-detect-virt() { [[ "$IN_CONTAINER" == yes ]]; }
sleep() { :; }
log_info() { printf 'info: %s\n' "$*" >>/srv/hard.log; }
log_warn() { printf 'warn: %s\n' "$*" >>/srv/hard.log; }
: >/srv/hard.log; : >/srv/systemctl.calls
ACTIVE=yes
STARTS_HARDENED=yes
service_is_active() { [[ "$ACTIVE" == yes ]]; }
service_restart() {
    printf 'restart:%s:%s\n' "$1" "$([[ -f "$(service_hardening_dropin "$1")" ]] && echo hardened || echo plain)" >>/srv/restart.calls
    if [[ -f "$(service_hardening_dropin "$1")" && "$STARTS_HARDENED" != yes ]]; then ACTIVE=no; return 1; fi
    ACTIVE=yes
}
: >/srv/restart.calls

assert_eq "252" "$(systemd_version)" "the systemd version is parsed"
service_hardening_applicable || fail_case "systemd 252 must be eligible"

# Bare metal / VM: the full set, with the ACME directory writable for sing-box.
rendered=$(service_hardening_render xray)
assert_contains "$rendered" "# proxy-hub-managed: hardening-v1" "the drop-in is marked as managed"
assert_contains "$rendered" "NoNewPrivileges=true" "core directive"
assert_contains "$rendered" "CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW" "capabilities are bounded"
assert_contains "$rendered" "ProtectSystem=full" "a non-container host gets the namespaced set"
assert_not_contains "$rendered" "ReadWritePaths" "Xray needs no writable path under /usr"
assert_contains "$(service_hardening_render "$SINGBOX_SERVICE")" "ReadWritePaths=-$SINGBOX_DIR" \
    "sing-box must keep its ACME directory writable"

# Container: only directives that need no mount namespace.
IN_CONTAINER=yes
rendered=$(service_hardening_render xray)
assert_contains "$rendered" "NoNewPrivileges=true" "containers keep the core set"
for directive in ProtectSystem ProtectHome PrivateTmp ProtectKernelModules ProtectKernelTunables ProtectControlGroups; do
    assert_not_contains "$rendered" "$directive" "containers must not get $directive"
done
unset -f systemd-detect-virt
if ! command -v systemd-detect-virt >/dev/null 2>&1; then
    assert_not_contains "$(service_hardening_render xray)" "ProtectSystem" "an unknown environment is treated as a container"
fi
systemd-detect-virt() { [[ "$IN_CONTAINER" == yes ]]; }
IN_CONTAINER=no

# Applying to a running service that survives the restart.
service_hardening_ensure xray || fail_case "hardening a healthy service must succeed"
dropin=$(service_hardening_dropin xray)
assert_eq "/srv/state/systemd/xray.service.d/10-proxy-hub-hardening.conf" "$dropin" "drop-in location"
[[ -f "$dropin" ]] || fail_case "the drop-in was not written"
assert_eq "restart:xray:hardened" "$(cat /srv/restart.calls)" "the service is restarted under the drop-in"
assert_contains "$(cat /srv/systemctl.calls)" "daemon-reload" "systemd is reloaded"
service_hardening_is_applied xray || fail_case "the applied state must be detectable"

# Idempotent: nothing is restarted the second time.
: >/srv/restart.calls
service_hardening_ensure xray || fail_case "an already hardened service must report success"
assert_eq "" "$(cat /srv/restart.calls)" "an already hardened service is not restarted again"

# A service that cannot start hardened is reverted, restored and remembered.
STARTS_HARDENED=no
: >/srv/restart.calls
rc=0
service_hardening_ensure sing-box || rc=$?
assert_eq "2" "$rc" "a failed hardened start must report the revert"
[[ ! -e "$(service_hardening_dropin sing-box)" ]] || fail_case "the failing drop-in must be removed"
assert_eq "restart:sing-box:hardened
restart:sing-box:plain" "$(cat /srv/restart.calls)" "the service is restarted again without the drop-in"
assert_eq "yes" "$ACTIVE" "the service must be running again after the revert"
assert_contains "$(cat /srv/hard.log)" "reverted and the service restored" "the revert must be reported"
[[ -e "$(service_hardening_skip_marker sing-box)" ]] || fail_case "the failure must be remembered"

# The remembered failure is not retried implicitly, but can be forced.
: >/srv/restart.calls
rc=0
service_hardening_ensure sing-box || rc=$?
assert_eq "1" "$rc" "a remembered failure must be skipped"
assert_eq "" "$(cat /srv/restart.calls)" "a skipped service is not restarted"
STARTS_HARDENED=yes
service_hardening_ensure sing-box force || fail_case "a forced retry must be attempted"
[[ ! -e "$(service_hardening_skip_marker sing-box)" ]] || fail_case "a successful retry must clear the marker"

# Not applicable: stopped services, old systemd, OpenRC.
service_hardening_remove xray
[[ ! -e "$dropin" && ! -d "$(dirname "$dropin")" ]] || fail_case "removal must delete the drop-in and its directory"
ACTIVE=no
rc=0; service_hardening_ensure xray || rc=$?
assert_eq "1" "$rc" "a stopped service is not hardened (nothing could be verified)"
ACTIVE=yes
SYSTEMD_VERSION=219
rc=0; service_hardening_ensure xray || rc=$?
assert_eq "1" "$rc" "an old systemd is not hardened"
SYSTEMD_VERSION=252
INIT_SYSTEM=openrc
assert_fails "OpenRC has no drop-ins" service_hardening_applicable
INIT_SYSTEM=systemd
[[ ! -e "$dropin" ]] || fail_case "inapplicable cases must not write a drop-in"

# The port-hopping helper escapes the sandbox so it can still load NAT modules.
HY2_HOP_HELPER=/srv/state/libexec/proxy-hub-hy2-hop
HY2_HOP_DROPIN=/srv/state/systemd/sing-box.service.d/20-proxy-hub-hy2-hop.conf
printf '#!/bin/sh\nexit 0\n' >/srv/bin/iptables; chmod 755 /srv/bin/iptables
PATH="/srv/bin:$PATH"
write_node hy hysteria2 "HY2_HOP_PORTS=30000-30100"
hy2_hop_sync || fail_case "hop sync failed"
assert_contains "$(cat "$HY2_HOP_DROPIN")" "ExecStartPre=-+$HY2_HOP_HELPER apply" \
    "on a current systemd the helper runs with full privileges"
SYSTEMD_VERSION=219
hy2_hop_sync
assert_contains "$(cat "$HY2_HOP_DROPIN")" "ExecStartPre=-$HY2_HOP_HELPER apply" \
    "an old systemd keeps the prefix it understands"
SCENARIO

# The sysctl tuning template: no dead keys, UDP floors for QUIC, and a way to
# recognise a file written by the previous template.
run_scenario sysctl-tuning-template <<'SCENARIO'
load_modules
SYSCTL_TUNING_FILE=/srv/state/99-bbr.conf
content=$(sysctl_tuning_content bbr fq)
assert_contains "$content" "net.ipv4.tcp_congestion_control = bbr" "the congestion control is preserved"
assert_contains "$content" "net.core.default_qdisc = fq" "the qdisc is preserved"
assert_contains "$content" "net.core.rmem_max = 33554432" "receive buffers are raised"
assert_contains "$content" "net.ipv4.udp_rmem_min = 16384" "UDP sockets get a receive floor"
assert_contains "$content" "net.ipv4.udp_wmem_min = 16384" "UDP sockets get a send floor"
assert_not_contains "$content" "tcp_low_latency" "tcp_low_latency is a no-op since Linux 4.14"
# Every line is either a comment or a well-formed key = value pair.
while IFS= read -r line; do
    [[ "$line" =~ ^# || "$line" =~ ^[a-z0-9_.]+\ =\ [a-z0-9_\ ]+$ ]] || fail_case "malformed sysctl line: $line"
done <<<"$content"
assert_contains "$(sysctl_tuning_content "" "")" "tcp_congestion_control = bbr" "an unreadable current value falls back to bbr"

assert_fails "a missing file is not legacy" sysctl_tuning_is_legacy
printf '%s\n' 'net.ipv4.tcp_congestion_control = cubic' 'net.ipv4.tcp_low_latency = 1' >"$SYSCTL_TUNING_FILE"
sysctl_tuning_is_legacy || fail_case "a file with tcp_low_latency is the legacy template"

sysctl() {
    case "$*" in
        "-n net.ipv4.tcp_congestion_control") echo cubic ;;
        "-n net.core.default_qdisc") echo fq_codel ;;
        *) printf '%s\n' "$*" >>/srv/sysctl.calls ;;
    esac
}
sysctl_tuning_apply || fail_case "applying the template failed"
assert_contains "$(cat "$SYSCTL_TUNING_FILE")" "tcp_congestion_control = cubic" "the running algorithm is kept, not forced to BBR"
assert_contains "$(cat "$SYSCTL_TUNING_FILE")" "default_qdisc = fq_codel" "the running qdisc is kept"
assert_fails "a rewritten file is no longer legacy" sysctl_tuning_is_legacy
assert_contains "$(cat /srv/sysctl.calls)" "--system" "the new values are loaded immediately"
SCENARIO

printf '%s\n' "All protocol-refresh contract tests passed."
