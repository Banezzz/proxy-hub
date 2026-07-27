#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_bwrap
require_command jq

test_base="$TEST_DIR/.tmp"
mkdir -p -- "$test_base"
test_tmp=$(mktemp -d "$test_base/proxy-hub-test.remote-features.XXXXXXXX")
register_cleanup_dir "$test_tmp"
mkdir -p -- "$test_tmp/tmp"

sandbox=(
    bwrap
    --ro-bind / /
    --dev-bind /dev /dev
    --proc /proc
    --tmpfs /tmp
    --tmpfs /root
    --tmpfs /run
    --unshare-net
    --die-with-parent
    --ro-bind "$REPO_ROOT" /mnt
    --bind "$test_tmp" /srv
    --setenv TMPDIR /srv/tmp
)

run_scenario() {
    local label="$1"
    if [[ -n "${REMOTE_FEATURE_CASE:-}" && "$REMOTE_FEATURE_CASE" != "$label" ]]; then
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

# The QR contract deliberately exercises real node files and real link builders.
# Only terminal rendering is stubbed. This catches regressions that reintroduce
# `source "$node_file"` instead of the safe key-by-key loader.
run_scenario qr-contract <<'SCENARIO'
source /mnt/lib/00_security_state.sh
source /mnt/lib/10_runtime_platform_ui.sh
source /mnt/lib/20_installers_restart.sh
source /mnt/lib/30_provision_network.sh
source /mnt/lib/40_config_share.sh
source /mnt/lib/50_node_commands.sh

NODES_DIR=/srv/nodes
mkdir -m 700 -- "$NODES_DIR"
ENABLE_CONFIG_ENCRYPTION=false

show_qrcode() {
    [[ -n "${1:-}" ]] || fail_case "show_node_qrcodes passed an empty link"
    printf '%s\n' "$1" >>/srv/qr.calls
}

write_node() {
    local protocol="$1" node_name="$2"
    cat >"$NODES_DIR/${node_name}.env" <<ENV
NODE_NAME=$node_name
SERVER_IP=2001:db8::10
SERVER_IPV4=
SERVER_IPV6=2001:db8::10
PORT=1443
UUID=11111111-1111-4111-8111-111111111111
SNI=edge.example.com
PUBLIC_KEY=PublicKey_123
PRIVATE_KEY=PrivateKey_123
SHORT_ID=0123456789abcdef
PROTOCOL_TYPE=$protocol
XHTTP_PORT=2443
XHTTP_PATH=/branch-test
SS_METHOD=aes-256-gcm
SS_PASSWORD=SafeSsPassword
ANYTLS_PASSWORD=SafeAnyTlsPassword
ANYTLS_PADDING_B64=
HY2_PASSWORD=SafeHy2Password
ENV
    chmod 600 "$NODES_DIR/${node_name}.env"
}

write_node both dual
CURRENT_NODE_NAME=dual
: >/srv/qr.calls
show_node_qrcodes >/srv/qr.output
assert_eq 2 "$(wc -l </srv/qr.calls | tr -d '[:space:]')" "both must render exactly two QR codes"
dual_links=$(cat /srv/qr.calls)
assert_contains "$dual_links" "[2001:db8::10]:1443" "Vision QR must bracket IPv6"
assert_contains "$dual_links" "type=tcp" "both must include the Vision link"
assert_contains "$dual_links" "[2001:db8::10]:2443" "XHTTP QR must bracket IPv6"
assert_contains "$dual_links" "type=xhttp" "both must include the XHTTP link"
assert_contains "$dual_links" "#dual_Vision" "Vision QR must have a distinct label"
assert_contains "$dual_links" "#dual_XHTTP" "XHTTP QR must have a distinct label"

for protocol in vision xhttp shadowsocks anytls anytls_reality hysteria2; do
    node_name="single_${protocol}"
    write_node "$protocol" "$node_name"
    CURRENT_NODE_NAME="$node_name"
    : >/srv/qr.calls
    show_node_qrcodes >/srv/qr.output
    assert_eq 1 "$(wc -l </srv/qr.calls | tr -d '[:space:]')" \
        "$protocol must render exactly one QR code"
    link=$(cat /srv/qr.calls)
    assert_contains "$link" "[2001:db8::10]" "$protocol QR must bracket IPv6"
    case "$protocol" in
        vision|xhttp) assert_contains "$link" "vless://" "$protocol QR scheme" ;;
        shadowsocks) assert_contains "$link" "ss://" "$protocol QR scheme" ;;
        anytls|anytls_reality) assert_contains "$link" "anytls://" "$protocol QR scheme" ;;
        hysteria2) assert_contains "$link" "hysteria2://" "$protocol QR scheme" ;;
    esac
done

cat >"$NODES_DIR/unsafe.env" <<'ENV'
NODE_NAME=$(touch /srv/unsafe-node-name-executed)
SERVER_IP=2001:db8::11
SERVER_IPV4=
SERVER_IPV6=2001:db8::11
PORT=3443
UUID=22222222-2222-4222-8222-222222222222
SNI=edge.example.com
PUBLIC_KEY=PublicKey_456
PRIVATE_KEY=PrivateKey_456
SHORT_ID=fedcba9876543210
PROTOCOL_TYPE=vision
XHTTP_PORT=
XHTTP_PATH=
SS_METHOD=
SS_PASSWORD=
ANYTLS_PASSWORD=
ANYTLS_PADDING_B64=
HY2_PASSWORD=
ENV
CURRENT_NODE_NAME=unsafe
: >/srv/qr.calls
show_node_qrcodes >/srv/qr.output
[[ ! -e /srv/unsafe-node-name-executed ]] || fail_case "node config was executed instead of safely loaded"
assert_eq 1 "$(wc -l </srv/qr.calls | tr -d '[:space:]')" \
    "unsafe optional label must not prevent rendering a safe link"
SCENARIO

# SS2022 post-install prompting is a numeric menu. A container without
# CAP_SYS_TIME must never be offered or routed to the installation action.
run_scenario timesync-menu-contract <<'SCENARIO'
source /mnt/lib/00_security_state.sh
source /mnt/lib/10_runtime_platform_ui.sh
source /mnt/lib/80_timesync.sh

MODE=host
CAPABLE=yes
INSTALLED=no
ACTIVE=no
CALLS=/srv/timesync.calls

is_timesync_installed() { [[ "$INSTALLED" == yes ]]; }
get_chrony_service_name() { printf '%s\n' chrony; }
service_is_active() { [[ "$ACTIVE" == yes ]]; }
is_container_env() { [[ "$MODE" == container ]]; }
check_time_capability() { [[ "$CAPABLE" == yes ]]; }
timesync_install() { printf '%s\n' install >>"$CALLS"; }
timesync_check() { printf '%s\n' check >>"$CALLS"; }
msg() { printf '%s\n' "$1"; }

run_choice() {
    local mode="$1" capable="$2" choice="$3" expected="$4"
    MODE="$mode"
    CAPABLE="$capable"
    INSTALLED=no
    ACTIVE=no
    : >"$CALLS"
    prompt_timesync_for_ss2022 <<<"$choice" >/srv/timesync.output
    assert_eq "$expected" "$(tr -d '\n' <"$CALLS")" \
        "timesync menu route mode=$mode capable=$capable choice=$choice"
}

run_choice host yes 1 install
run_choice host yes 2 check
run_choice host yes 0 ""
run_choice host yes 9 ""
run_choice container yes 1 install
run_choice container yes 2 check
run_choice container no 1 check
run_choice container no 0 ""
run_choice container no 2 ""

MODE=host
CAPABLE=yes
prompt_timesync_for_ss2022 <<<0 >/srv/timesync.output
menu_output=$(cat /srv/timesync.output)
assert_contains "$menu_output" timesync_install "host menu must offer installation"
assert_contains "$menu_output" timesync_check "host menu must offer an accuracy check"
assert_contains "$menu_output" timesync_skip "host menu must offer skip"

MODE=container
CAPABLE=no
prompt_timesync_for_ss2022 <<<0 >/srv/timesync.output
menu_output=$(cat /srv/timesync.output)
assert_not_contains "$menu_output" timesync_install \
    "unprivileged container menu must not offer installation"
assert_contains "$menu_output" timesync_check \
    "unprivileged container menu must offer an accuracy check"
assert_contains "$menu_output" timesync_skip "unprivileged container menu must offer skip"

INSTALLED=yes
ACTIVE=yes
: >"$CALLS"
prompt_timesync_for_ss2022 </dev/null >/srv/timesync.output
assert_eq "" "$(cat "$CALLS")" "running time sync must skip the menu"
SCENARIO

# Hysteria2 is emitted as a sing-box inbound. jq must carry every string into
# JSON without shell interpolation, and unsafe identity/password values fail.
run_scenario hysteria-inbound-contract <<'SCENARIO'
source /mnt/lib/00_security_state.sh

inbound=$(build_hysteria2_inbound \
    hy2_node 2443 'Safe.Pass_~123' edge.example.com \
    /etc/proxy-hub/certs/hy2_node.crt /etc/proxy-hub/certs/hy2_node.key)

jq -e '
    .type == "hysteria2" and
    .tag == "hy2_node_hysteria2" and
    .listen == "::" and
    .listen_port == 2443 and
    (.users | length) == 1 and
    .users[0].name == "hy2_node" and
    .users[0].password == "Safe.Pass_~123" and
    .tls.enabled == true and
    .tls.server_name == "edge.example.com" and
    .tls.certificate_path == "/etc/proxy-hub/certs/hy2_node.crt" and
    .tls.key_path == "/etc/proxy-hub/certs/hy2_node.key" and
    .masquerade.type == "proxy" and
    .masquerade.url == "https://www.bing.com" and
    .masquerade.rewrite_host == true
' <<<"$inbound" >/dev/null || fail_case "Hysteria2 inbound JSON contract mismatch"

if build_hysteria2_inbound bad/name 2443 SafePassword edge.example.com /cert /key >/dev/null; then
    fail_case "Hysteria2 accepted an unsafe node name"
fi
if build_hysteria2_inbound node 0 SafePassword edge.example.com /cert /key >/dev/null; then
    fail_case "Hysteria2 accepted port 0"
fi
if build_hysteria2_inbound node 65536 SafePassword edge.example.com /cert /key >/dev/null; then
    fail_case "Hysteria2 accepted an out-of-range port"
fi
if build_hysteria2_inbound node 2443 '$(touch /srv/password-executed)' edge.example.com /cert /key >/dev/null; then
    fail_case "Hysteria2 accepted an unsafe password"
fi
if build_hysteria2_inbound node 2443 SafePassword 'edge.example.com&insecure=0' /cert /key >/dev/null; then
    fail_case "Hysteria2 accepted a URI-injecting SNI"
fi
if build_hysteria2_inbound node 2443 SafePassword '.edge.example.com' /cert /key >/dev/null; then
    fail_case "Hysteria2 accepted an empty DNS label"
fi
[[ ! -e /srv/password-executed ]] || fail_case "Hysteria2 password was evaluated by the shell"
SCENARIO

# The optional transport argument is part of the public port probe contract.
# Exact endpoint matching must not confuse port 80 with port 8080.
run_scenario transport-aware-port-contract <<'SCENARIO'
source /mnt/lib/00_security_state.sh
source /mnt/lib/10_runtime_platform_ui.sh

ss() {
    local args="$*"
    if [[ "$args" == *t* ]]; then
        printf '%s\n' \
            'LISTEN 0 4096 0.0.0.0:10000 0.0.0.0:*' \
            'LISTEN 0 4096 [::]:8080 [::]:*'
    fi
    if [[ "$args" == *u* ]]; then
        printf '%s\n' \
            'UNCONN 0 0 0.0.0.0:20000 0.0.0.0:*' \
            'UNCONN 0 0 [::]:18080 [::]:*'
    fi
}

is_port_free 30000
is_port_free 30000 tcp
is_port_free 30000 udp
is_port_free 30000 both

if is_port_free 10000 tcp; then fail_case "occupied TCP port reported free"; fi
is_port_free 10000 udp
if is_port_free 10000 both; then fail_case "both ignored occupied TCP transport"; fi

is_port_free 20000 tcp
if is_port_free 20000 udp; then fail_case "occupied UDP port reported free"; fi
if is_port_free 20000 both; then fail_case "both ignored occupied UDP transport"; fi

is_port_free 80 tcp
is_port_free 80 udp
if is_port_free 8080 tcp; then fail_case "exact TCP endpoint matching failed"; fi
if is_port_free 18080 udp; then fail_case "exact UDP endpoint matching failed"; fi

if is_port_free 30000 sctp; then
    fail_case "unknown transport must fail closed"
fi
SCENARIO

# Core counts decide whether shared services should be regenerated, restarted,
# or considered healthy. Legacy node files without PROTOCOL_TYPE remain Xray.
run_scenario core-node-count-contract <<'SCENARIO'
source /mnt/lib/00_security_state.sh
source /mnt/lib/10_runtime_platform_ui.sh
source /mnt/lib/20_installers_restart.sh
source /mnt/lib/30_provision_network.sh
source /mnt/lib/40_config_share.sh

NODES_DIR=/srv/count-nodes
mkdir -m 700 -- "$NODES_DIR"

write_proto() {
    local name="$1" protocol="$2"
    {
        printf 'NODE_NAME=%s\n' "$name"
        printf 'PROTOCOL_TYPE=%s\n' "$protocol"
    } >"$NODES_DIR/$name.env"
}

write_proto vision vision
write_proto xhttp xhttp
write_proto both both
write_proto shadowsocks shadowsocks
write_proto anytls anytls
write_proto anytls_reality anytls_reality
write_proto hysteria2 hysteria2
printf '%s\n' 'NODE_NAME=legacy' >"$NODES_DIR/legacy.env"
printf '%s\n' \
    'NODE_NAME=safe_extra_line' \
    'PROTOCOL_TYPE=anytls' \
    'IGNORED=$(touch /srv/count-config-executed)' \
    >"$NODES_DIR/safe_extra_line.env"

assert_eq 4 "$(singbox_node_count)" \
    "sing-box count must include AnyTLS variants and Hysteria2"
assert_eq 5 "$(xray_node_count)" \
    "Xray count must include four explicit protocols and one legacy node"
[[ ! -e /srv/count-config-executed ]] || fail_case "node count sourced an env file"

rm -f -- "$NODES_DIR"/*.env
assert_eq 0 "$(singbox_node_count)" "empty sing-box node count"
assert_eq 0 "$(xray_node_count)" "empty Xray node count"
SCENARIO

# Installation is transactional at the node/service boundary: firewall and
# success output occur only after the selected core reports healthy. A failed
# start removes the candidate and attempts to restore the previous core state.
run_scenario install-transaction-contract <<'SCENARIO'
source /mnt/lib/00_security_state.sh
source /mnt/lib/10_runtime_platform_ui.sh
source /mnt/lib/20_installers_restart.sh
source /mnt/lib/30_provision_network.sh
source /mnt/lib/40_config_share.sh
source /mnt/lib/50_node_commands.sh

NODES_DIR=/srv/install-nodes
SINGBOX_CERT_DIR=/srv/install-certs
SINGBOX_SERVICE=sing-box
ENABLE_CONFIG_ENCRYPTION=false
CALLS=/srv/install.calls
mkdir -m 700 -- "$NODES_DIR" "$SINGBOX_CERT_DIR"

record() { printf '%s\n' "$*" >>"$CALLS"; }
msg() { printf '%s\n' "$1"; }
log_info() { [[ "${1:-}" == install_complete ]] && record success || true; }
log_warn() { record "warn:$*"; }
log_error() { record "error:$*"; }
is_root() { return 0; }
install_deps() { record deps; }
node_exists() { return 1; }
install_xray() { record install-xray; }
install_singbox() { record install-singbox; }
select_best_sni() { SNI=edge.example.com; }
gen_uuid() { UUID=11111111-1111-4111-8111-111111111111; }
gen_reality_keys() {
    PUBLIC_KEY=PublicKey_123
    PRIVATE_KEY=PrivateKey_123
    SHORT_ID=0123456789abcdef
}
choose_ports() {
    if [[ "$PROTOCOL_TYPE" == hysteria2 ]]; then
        PORT=2443
    else
        PORT=1443
    fi
    XHTTP_PORT=""
    XHTTP_PATH=""
}
detect_network_stack() {
    SERVER_IP=192.0.2.10
    SERVER_IPV4=192.0.2.10
    SERVER_IPV6=""
}
save_env() {
    record save
    cat >"$NODES_DIR/${CURRENT_NODE_NAME}.env" <<ENV
NODE_NAME=$CURRENT_NODE_NAME
PROTOCOL_TYPE=$PROTOCOL_TYPE
PORT=$PORT
ENV
}
write_config() {
    record write-xray
    [[ "${WRITE_OK:-yes}" == yes ]]
}
service_enable() { record "enable:$1"; }
service_restart() {
    record "restart:$1"
    [[ "${RESTART_OK:-yes}" == yes ]]
}
service_is_active() {
    record "active:$1"
    [[ "${ACTIVE_OK:-yes}" == yes ]]
}
service_stop() { record "stop:$1"; }
sleep() { :; }
open_firewall_port() {
    record "firewall:$1:${2:-both}"
    return 0
}
show_info() { record info; }
show_node_qrcodes() { record qr; }
prompt_xray_restart_on_install() { record restart-prompt; }
prompt_timesync_for_ss2022() { record timesync-prompt; }
show_proxy_service_failure_logs() { record "diagnostics:$1"; }
gen_selfsigned_cert() {
    record "cert:$1:$2"
    : >"$SINGBOX_CERT_DIR/$1.crt"
    : >"$SINGBOX_CERT_DIR/$1.key"
}

run_vision() {
    local expected_rc="$1"
    shift
    : >"$CALLS"
    rm -f -- "$NODES_DIR"/*.env
    name=vision_txn proto=vision reym=edge.example.com
    WRITE_OK=yes RESTART_OK=yes ACTIVE_OK=yes
    while (($#)); do
        case "$1" in
            restart-fail) RESTART_OK=no ;;
            active-fail) ACTIVE_OK=no ;;
        esac
        shift
    done
    local rc=0
    cmd_install >/srv/install.output 2>/srv/install.error || rc=$?
    assert_eq "$expected_rc" "$rc" "Vision install exit status"
}

run_vision 0
vision_success=$(cat "$CALLS")
assert_contains "$vision_success" $'restart:xray\nactive:xray\nfirewall:1443:tcp\nsuccess\ninfo\nqr' \
    "Vision must prove health before firewall and success output"
[[ -f "$NODES_DIR/vision_txn.env" ]] || fail_case "successful Vision candidate disappeared"

run_vision 1 restart-fail
vision_restart_fail=$(cat "$CALLS")
assert_contains "$vision_restart_fail" diagnostics:xray "restart failure must show diagnostics"
assert_contains "$vision_restart_fail" $'write-xray\nstop:xray' \
    "restart failure must rebuild the previous empty Xray state"
assert_not_contains "$vision_restart_fail" firewall: "restart failure opened a firewall port"
assert_not_contains "$vision_restart_fail" $'\nsuccess\n' "restart failure reported success"
assert_not_contains "$vision_restart_fail" $'\nqr\n' "restart failure rendered a QR code"
[[ ! -e "$NODES_DIR/vision_txn.env" ]] || fail_case "restart failure retained the candidate node"

run_vision 1 active-fail
vision_active_fail=$(cat "$CALLS")
assert_contains "$vision_active_fail" diagnostics:xray "inactive service must show diagnostics"
assert_not_contains "$vision_active_fail" firewall: "inactive service opened a firewall port"
assert_not_contains "$vision_active_fail" $'\nsuccess\n' "inactive service reported success"
[[ ! -e "$NODES_DIR/vision_txn.env" ]] || fail_case "inactive service retained the candidate node"

SINGBOX_SYNC_FAIL_FIRST=no
SINGBOX_SYNC_CALLS=0
singbox_sync() {
    ((++SINGBOX_SYNC_CALLS))
    record "sync-singbox:$SINGBOX_SYNC_CALLS"
    if [[ "$SINGBOX_SYNC_FAIL_FIRST" == yes && "$SINGBOX_SYNC_CALLS" -eq 1 ]]; then
        return 1
    fi
    return 0
}

run_hysteria() {
    local expected_rc="$1" fail_first="$2"
    : >"$CALLS"
    rm -f -- "$NODES_DIR"/*.env "$SINGBOX_CERT_DIR"/*
    name=hysteria_txn proto=hy2 hy2pwd=SafeHy2Password hy2sni=edge.example.com
    SINGBOX_SYNC_FAIL_FIRST="$fail_first"
    SINGBOX_SYNC_CALLS=0
    local rc=0
    cmd_install >/srv/install.output 2>/srv/install.error || rc=$?
    assert_eq "$expected_rc" "$rc" "Hysteria2 install exit status"
}

run_hysteria 0 no
hy2_success=$(cat "$CALLS")
assert_contains "$hy2_success" $'sync-singbox:1\nfirewall:2443:udp\nsuccess\ninfo\nqr' \
    "Hysteria2 must use a healthy sing-box path and UDP firewall"
[[ -f "$NODES_DIR/hysteria_txn.env" ]] || fail_case "successful Hysteria2 candidate disappeared"

run_hysteria 1 yes
hy2_fail=$(cat "$CALLS")
assert_contains "$hy2_fail" $'sync-singbox:1\nerror:Failed to configure or start sing-box, rolling back...' \
    "sing-box failure must enter rollback"
assert_contains "$hy2_fail" sync-singbox:2 "rollback must resynchronize prior sing-box state"
assert_not_contains "$hy2_fail" firewall: "failed sing-box opened a firewall port"
assert_not_contains "$hy2_fail" $'\nsuccess\n' "failed sing-box reported success"
assert_not_contains "$hy2_fail" $'\nqr\n' "failed sing-box rendered a QR code"
[[ ! -e "$NODES_DIR/hysteria_txn.env" ]] || fail_case "failed sing-box retained the candidate node"
SCENARIO

# Node-scoped globals must survive `set -u` on every protocol path.
#
# The whole program runs under `set -euo pipefail`, so a variable that a protocol
# branch never assigns kills the install the moment anything expands it. This
# regression exists: anytls_reality called gen_reality_keys (which only produces
# PUBLIC_KEY/PRIVATE_KEY/SHORT_ID) and left UUID unassigned, so save_env aborted
# with "UUID: unbound variable" right after IP detection -- after sing-box had
# been installed but before any node file was written.
#
# Unlike install-transaction-contract above, this scenario deliberately runs the
# REAL save_env against a REAL nodes directory. Stubbing save_env is exactly what
# let the original defect through, since the stub never expanded the field set.
run_scenario node-state-contract <<'SCENARIO'
source /mnt/lib/00_security_state.sh
source /mnt/lib/10_runtime_platform_ui.sh
source /mnt/lib/20_installers_restart.sh
source /mnt/lib/30_provision_network.sh
source /mnt/lib/40_config_share.sh
source /mnt/lib/50_node_commands.sh

NODES_DIR=/srv/state-nodes
SINGBOX_CERT_DIR=/srv/state-certs
SINGBOX_SERVICE=sing-box
ENABLE_CONFIG_ENCRYPTION=false
mkdir -m 700 -- "$NODES_DIR" "$SINGBOX_CERT_DIR"

msg() { printf '%s\n' "$1"; }
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "$*" >&2; }
is_root() { return 0; }
install_deps() { :; }
node_exists() { return 1; }
install_xray() { :; }
install_singbox() { :; }
select_best_sni() { SNI=edge.example.com; }
prompt_ss_method() { SS_METHOD=2022-blake3-aes-256-gcm; }
gen_reality_keys() {
    PUBLIC_KEY=PublicKey_123
    PRIVATE_KEY=PrivateKey_123
    SHORT_ID=0123456789abcdef
}
choose_ports() { PORT=1443; XHTTP_PORT=""; XHTTP_PATH=""; }
detect_network_stack() {
    SERVER_IP=192.0.2.10
    SERVER_IPV4=192.0.2.10
    SERVER_IPV6=""
}
gen_selfsigned_cert() {
    : >"$SINGBOX_CERT_DIR/$1.crt"
    : >"$SINGBOX_CERT_DIR/$1.key"
}
singbox_sync() { :; }
write_config() { :; }
service_enable() { :; }
service_restart() { :; }
service_is_active() { :; }
sleep() { :; }
open_node_firewall_ports() { :; }
show_info() { :; }
show_node_qrcodes() { :; }
prompt_xray_restart_on_install() { :; }
prompt_timesync_for_ss2022() { :; }

node_field() {
    local file="$1" key="$2" line
    while IFS= read -r line; do
        [[ "$line" == "$key="* ]] && { printf '%s' "${line#*=}"; return 0; }
    done <"$file"
    return 0
}

# Every protocol must complete a real install, real save_env included. A branch
# that forgets a field aborts here instead of shipping.
for spec in vision:node_vision xhttp:node_xhttp both:node_both \
            shadowsocks:node_ss anytls:node_at anytls-reality:node_atr hy2:node_hy2; do
    protocol="${spec%%:*}"
    node="${spec#*:}"
    rc=0
    ( name="$node" proto="$protocol" cmd_install ) >/srv/state.out 2>/srv/state.err || rc=$?
    if ((rc != 0)); then
        sed -n '1,40p' /srv/state.err >&2
        fail_case "$protocol install aborted (exit $rc) -- likely an unset node variable under set -u"
    fi
    [[ -f "$NODES_DIR/$node.env" ]] || fail_case "$protocol install wrote no node file"
done

# AnyTLS authenticates by password and has no UUID, but the REALITY variant still
# needs its key material. Both facts must hold in the persisted file.
assert_eq "" "$(node_field "$NODES_DIR/node_atr.env" UUID)" \
    "anytls_reality must persist an empty UUID, not an unset one"
assert_eq "PublicKey_123" "$(node_field "$NODES_DIR/node_atr.env" PUBLIC_KEY)" \
    "anytls_reality must persist its REALITY public key"
assert_eq "0123456789abcdef" "$(node_field "$NODES_DIR/node_atr.env" SHORT_ID)" \
    "anytls_reality must persist its REALITY short id"
assert_eq "" "$(node_field "$NODES_DIR/node_at.env" PUBLIC_KEY)" \
    "plain anytls must not carry REALITY key material"

# Node variables are process globals. Installing a second node in the same menu
# session must not inherit the previous node's credentials.
rm -f -- "$NODES_DIR"/*.env
name=leak_vless proto=vision cmd_install >/srv/state.out 2>/srv/state.err
leaked_uuid=$(node_field "$NODES_DIR/leak_vless.env" UUID)
[[ -n "$leaked_uuid" ]] || fail_case "VLESS install produced no UUID to test leakage with"

name=leak_anytls proto=anytls-reality cmd_install >/srv/state.out 2>/srv/state.err
assert_eq "" "$(node_field "$NODES_DIR/leak_anytls.env" UUID)" \
    "AnyTLS node inherited the previously installed VLESS node's UUID"
assert_eq "" "$(node_field "$NODES_DIR/leak_anytls.env" SS_PASSWORD)" \
    "AnyTLS node inherited a stale Shadowsocks password"

# Installing VLESS after Shadowsocks must not carry the SS password forward.
rm -f -- "$NODES_DIR"/*.env
name=leak_ss proto=ss cmd_install >/srv/state.out 2>/srv/state.err
name=leak_vision proto=vision cmd_install >/srv/state.out 2>/srv/state.err
assert_eq "" "$(node_field "$NODES_DIR/leak_vision.env" SS_PASSWORD)" \
    "VLESS node inherited the previously installed Shadowsocks password"
assert_eq "" "$(node_field "$NODES_DIR/leak_vision.env" SS_METHOD)" \
    "VLESS node inherited the previously installed Shadowsocks method"

# IPv6-only hosts leave SERVER_IPV4 empty, so save_env falls back to the legacy
# SERVER_IP field. That fallback has no detection source of its own and must stay
# `set -u` safe for every protocol.
rm -f -- "$NODES_DIR"/*.env
detect_network_stack() {
    SERVER_IPV4=""
    SERVER_IPV6="2001:db8::10"
}
for spec in vision:v6_vision anytls-reality:v6_atr hy2:v6_hy2; do
    protocol="${spec%%:*}"
    node="${spec#*:}"
    rc=0
    ( name="$node" proto="$protocol" cmd_install ) >/srv/state.out 2>/srv/state.err || rc=$?
    if ((rc != 0)); then
        sed -n '1,40p' /srv/state.err >&2
        fail_case "$protocol install aborted on an IPv6-only host (exit $rc)"
    fi
    assert_eq "2001:db8::10" "$(node_field "$NODES_DIR/$node.env" SERVER_IPV6)" \
        "$protocol must persist the detected IPv6 address"
done

# reset_node_state is the single source of truth for these globals. If save_env
# grows a field that reset_node_state does not define, a fresh shell expanding it
# under `set -u` must fail here rather than mid-install on a user's server.
( set -u; reset_node_state; CURRENT_NODE_NAME=bare; NODES_DIR=/srv/state-nodes; save_env ) \
    || fail_case "save_env expanded a field that reset_node_state does not define"
assert_eq "bare" "$(node_field "$NODES_DIR/bare.env" NODE_NAME)" \
    "save_env must write a node file from freshly reset state"
SCENARIO

printf '%s\n' "All remote-branch feature contract tests passed."
