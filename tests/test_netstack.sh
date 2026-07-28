#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_bwrap
require_command jq

test_base="$TEST_DIR/.tmp"
mkdir -p -- "$test_base"
test_tmp=$(mktemp -d "$test_base/proxy-hub-test.netstack.XXXXXXXX")
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
    --tmpfs /usr/local/etc
    --unshare-net
    --die-with-parent
    --ro-bind "$REPO_ROOT" /mnt
    --bind "$test_tmp" /srv
    --setenv TMPDIR /srv/tmp
)

run_scenario() {
    local label="$1"
    if [[ -n "${NETSTACK_CASE:-}" && "$NETSTACK_CASE" != "$label" ]]; then
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

# `cmd && fail_case ...` 会在 `set -e` 下把失败的期望变成脚本自身的退出码，
# 因此负向断言统一走 if 条件位置。
assert_fails() {
    local context="$1"
    shift
    if "$@"; then
        fail_case "$context"
    fi
}

load_modules() {
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/20_installers_restart.sh
    source /mnt/lib/30_provision_network.sh
    source /mnt/lib/40_config_share.sh
    source /mnt/lib/50_node_commands.sh

    # 所有场景共享同一个 /srv 挂载，先清掉上一个场景留下的状态，否则"没有设置
    # 文件时回退 dual"这类断言会读到别人写的值。
    rm -rf -- /srv/netstack /srv/nodes /srv/xray.json /srv/sing-box \
        /srv/openssl.args /srv/regenerate.calls /srv/bin

    # 只重定向路径与外部副作用，网络栈判定、JSON builder 和配置渲染都跑真实实现。
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
    mkdir -p -- "$NODES_DIR" "$SINGBOX_CERT_DIR"
    chmod 700 -- "$NODES_DIR"

    check_warp_running() { return 1; }
    gen_selfsigned_cert() {
        : >"$SINGBOX_CERT_DIR/${1}.crt"
        : >"$SINGBOX_CERT_DIR/${1}.key"
    }
}

write_vless_node() {
    local node_name="$1" protocol="$2"
    cat >"$NODES_DIR/${node_name}.env" <<ENV
NODE_NAME=$node_name
SERVER_IP=203.0.113.10
SERVER_IPV4=203.0.113.10
SERVER_IPV6=2001:db8::10
PORT=1443
UUID=11111111-1111-4111-8111-111111111111
SNI=edge.example.com
PUBLIC_KEY=PublicKey_123
PRIVATE_KEY=PrivateKey_123
SHORT_ID=0123456789abcdef
PROTOCOL_TYPE=$protocol
XHTTP_PORT=2443
XHTTP_PATH=/netstack-test
SS_METHOD=
SS_PASSWORD=
ANYTLS_PASSWORD=
ANYTLS_PADDING_B64=
HY2_PASSWORD=
ENV
}

write_ss_node() {
    local node_name="$1"
    cat >"$NODES_DIR/${node_name}.env" <<ENV
NODE_NAME=$node_name
SERVER_IP=203.0.113.10
SERVER_IPV4=203.0.113.10
SERVER_IPV6=2001:db8::10
PORT=3443
UUID=
SNI=
PUBLIC_KEY=
PRIVATE_KEY=
SHORT_ID=
PROTOCOL_TYPE=shadowsocks
XHTTP_PORT=
XHTTP_PATH=
SS_METHOD=aes-256-gcm
SS_PASSWORD=SafeSsPassword
ANYTLS_PASSWORD=
ANYTLS_PADDING_B64=
HY2_PASSWORD=
ENV
}

write_singbox_nodes() {
    cat >"$NODES_DIR/at1.env" <<ENV
NODE_NAME=at1
SERVER_IP=203.0.113.10
SERVER_IPV4=203.0.113.10
SERVER_IPV6=2001:db8::10
PORT=4443
UUID=
SNI=edge.example.com
PUBLIC_KEY=
PRIVATE_KEY=
SHORT_ID=
PROTOCOL_TYPE=anytls
XHTTP_PORT=
XHTTP_PATH=
SS_METHOD=
SS_PASSWORD=
ANYTLS_PASSWORD=SafeAnyTlsPassword
ANYTLS_PADDING_B64=
HY2_PASSWORD=
ENV
    cat >"$NODES_DIR/hy1.env" <<ENV
NODE_NAME=hy1
SERVER_IP=203.0.113.10
SERVER_IPV4=203.0.113.10
SERVER_IPV6=2001:db8::10
PORT=5443
UUID=
SNI=www.bing.com
PUBLIC_KEY=
PRIVATE_KEY=
SHORT_ID=
PROTOCOL_TYPE=hysteria2
XHTTP_PORT=
XHTTP_PATH=
SS_METHOD=
SS_PASSWORD=
ANYTLS_PASSWORD=
ANYTLS_PADDING_B64=
HY2_PASSWORD=SafeHy2Password
ENV
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

# 默认档必须与引入本设置之前的产物逐字段一致：通配监听地址、没有 sockopt、
# freedom 出站不带 settings。任何"顺手把 0.0.0.0 改成 ::"的改动都会在这里失败，
# 因为以 ipv6.disable=1 启动的内核上 bind "::" 会让服务起不来。
run_scenario netstack-default-is-unchanged <<'SCENARIO'
load_modules

write_vless_node both1 both
write_ss_node ss1
write_singbox_nodes

assert_eq "dual" "$(netstack_mode)" "missing setting file falls back to dual"

write_config || fail_case "write_config failed in dual mode"
write_singbox_config || fail_case "write_singbox_config failed in dual mode"

assert_eq "0.0.0.0" "$(jq -r '[.inbounds[].listen] | unique | join(",")' "$XRAY_CONF")" \
    "dual mode listens on the wildcard address"
assert_eq "0" "$(jq '[.inbounds[] | select(.streamSettings.sockopt != null)] | length' "$XRAY_CONF")" \
    "dual mode writes no sockopt"
assert_eq "null" "$(jq -c '.outbounds[] | select(.tag == "direct") | .settings' "$XRAY_CONF")" \
    "dual mode keeps the freedom outbound at the Xray default (AsIs)"
# 两个内核在 dual 档各自保留历史写法（Xray "0.0.0.0"、sing-box "::"）。它们在
# 通配地址上等价，这条断言钉住"默认档不给现有 AnyTLS / Hysteria2 安装换绑定"。
assert_eq "::" "$(jq -r '[.inbounds[].listen] | unique | join(",")' "$SINGBOX_CONF")" \
    "dual mode leaves the sing-box listen address untouched"
SCENARIO

# v4 档只改出站解析策略与协议族范围，监听地址仍是通配地址：真正的 v4-only 监听
# 需要 bind 具体网卡地址，而 NAT 型云主机上公网地址并不在网卡上。
run_scenario netstack-v4 <<'SCENARIO'
load_modules
printf 'v4\n' >"$NETSTACK_FILE"

write_vless_node both1 both
write_ss_node ss1
write_singbox_nodes

assert_eq "v4" "$(netstack_mode)" "v4 setting is read back"
write_config || fail_case "write_config failed in v4 mode"
write_singbox_config || fail_case "write_singbox_config failed in v4 mode"

assert_eq "0.0.0.0" "$(jq -r '[.inbounds[].listen] | unique | join(",")' "$XRAY_CONF")" \
    "v4 mode keeps the wildcard listen address"
assert_eq "0" "$(jq '[.inbounds[] | select(.streamSettings.sockopt != null)] | length' "$XRAY_CONF")" \
    "v4 mode writes no sockopt"
assert_eq "UseIPv4" "$(jq -r '.outbounds[] | select(.tag == "direct") | .settings.domainStrategy' "$XRAY_CONF")" \
    "v4 mode pins the freedom outbound to IPv4"
assert_eq "0.0.0.0" "$(jq -r '[.inbounds[].listen] | unique | join(",")' "$SINGBOX_CONF")" \
    "v4 mode sing-box listens on the wildcard address"
SCENARIO

# v6 档是唯一需要 socket 级强制的档：listen "::" 加 sockopt.v6only，Xray 会把它
# 翻译成 IPV6_V6ONLY，因此不再接受 v4-mapped 连接。
run_scenario netstack-v6 <<'SCENARIO'
load_modules
printf 'v6\n' >"$NETSTACK_FILE"

write_vless_node both1 both
write_ss_node ss1
write_singbox_nodes

assert_eq "v6" "$(netstack_mode)" "v6 setting is read back"
write_config || fail_case "write_config failed in v6 mode"
write_singbox_config || fail_case "write_singbox_config failed in v6 mode"

assert_eq "::" "$(jq -r '[.inbounds[].listen] | unique | join(",")' "$XRAY_CONF")" \
    "v6 mode listens on ::"
assert_eq "3" "$(jq '[.inbounds[] | select(.streamSettings.sockopt.v6only == true)] | length' "$XRAY_CONF")" \
    "every Xray inbound carries sockopt.v6only"
assert_eq "true" "$(jq -r '.inbounds[] | select(.protocol == "shadowsocks") | .streamSettings.sockopt.v6only' "$XRAY_CONF")" \
    "shadowsocks gains a streamSettings block for sockopt"
assert_eq "reality" "$(jq -r '.inbounds[] | select(.tag == "both1_vision") | .streamSettings.security' "$XRAY_CONF")" \
    "adding sockopt does not drop the existing streamSettings keys"
assert_eq "/netstack-test" "$(jq -r '.inbounds[] | select(.tag == "both1_xhttp") | .streamSettings.xhttpSettings.path' "$XRAY_CONF")" \
    "xhttp transport settings survive the sockopt merge"
assert_eq "UseIPv6" "$(jq -r '.outbounds[] | select(.tag == "direct") | .settings.domainStrategy' "$XRAY_CONF")" \
    "v6 mode pins the freedom outbound to IPv6"
assert_eq "::" "$(jq -r '[.inbounds[].listen] | unique | join(",")' "$SINGBOX_CONF")" \
    "v6 mode sing-box listens on ::"
SCENARIO

# 设置文件是普通文本，必须当作不可信输入：非法内容回退 dual，且绝不出现在配置里。
run_scenario netstack-untrusted-setting <<'SCENARIO'
load_modules
write_vless_node v1 vision

printf 'UseIPv4"; rm -rf /\n' >"$NETSTACK_FILE"
assert_eq "dual" "$(netstack_mode)" "invalid setting falls back to dual"
write_config || fail_case "write_config failed with an invalid setting file"
assert_not_contains "$(cat "$XRAY_CONF")" "rm -rf" "invalid setting must not reach the config"
assert_eq "null" "$(jq -c '.outbounds[] | select(.tag == "direct") | .settings' "$XRAY_CONF")" \
    "invalid setting behaves exactly like dual"

: >"$NETSTACK_FILE"
assert_eq "dual" "$(netstack_mode)" "empty setting falls back to dual"

rm -f "$NETSTACK_FILE"
ln -s /srv/nowhere "$NETSTACK_FILE"
assert_eq "dual" "$(netstack_mode)" "symlinked setting falls back to dual"

rm -f "$NETSTACK_FILE"
netstack_save "v6" || fail_case "netstack_save rejected a valid mode"
assert_eq "v6" "$(netstack_mode)" "netstack_save persists a valid mode"
assert_fails "netstack_save accepted an invalid mode" netstack_save "v7"
assert_eq "v6" "$(netstack_mode)" "a rejected save leaves the previous mode intact"

assert_eq "dual" "$(netstack_normalize 'BOTH')" "normalize accepts both"
assert_eq "v4" "$(netstack_normalize 'IPv4-only')" "normalize accepts ipv4-only"
assert_eq "v6" "$(netstack_normalize ' 6 ')" "normalize accepts 6"
assert_fails "normalize accepted garbage" netstack_normalize "garbage"
assert_fails "normalize accepted an empty value" netstack_normalize ""
SCENARIO

# SNI 测速必须按协议族限定：REALITY 的 dest 握手由服务器自己发起，v6 Only 主机上
# 只有 A 记录的域名握手必然失败，不能被测成"可用"。
run_scenario netstack-sni-family <<'SCENARIO'
load_modules

mkdir -p /srv/bin
cat >/srv/bin/openssl <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>/srv/openssl.args
exit 0
FAKE
chmod 755 /srv/bin/openssl
PATH="/srv/bin:$PATH"

assert_eq "" "$(netstack_openssl_family)" "dual mode does not pin an address family"
test_domain_latency example.com >/dev/null
assert_eq "s_client -connect example.com:443 -servername example.com" "$(tail -n 1 /srv/openssl.args)" \
    "dual mode leaves resolution to the system"

printf 'v4\n' >"$NETSTACK_FILE"
assert_eq "-4" "$(netstack_openssl_family)" "v4 mode pins IPv4"
test_domain_latency example.com >/dev/null
assert_eq "s_client -4 -connect example.com:443 -servername example.com" "$(tail -n 1 /srv/openssl.args)" \
    "v4 mode probes over IPv4 only"

printf 'v6\n' >"$NETSTACK_FILE"
assert_eq "-6" "$(netstack_openssl_family)" "v6 mode pins IPv6"
test_domain_latency example.com >/dev/null
assert_eq "s_client -6 -connect example.com:443 -servername example.com" "$(tail -n 1 /srv/openssl.args)" \
    "v6 mode probes over IPv6 only"
SCENARIO

# 地址探测与链接输出都必须跟随所选协议族，且不能让节点变成"一条链接都没有"。
run_scenario netstack-addresses-and-links <<'SCENARIO'
load_modules

get_ipv4() { printf '203.0.113.10'; }
get_ipv6() { printf '2001:db8::10'; }

printf 'v6\n' >"$NETSTACK_FILE"
detect_network_stack
assert_eq "" "$SERVER_IPV4" "v6 mode does not probe IPv4"
assert_eq "2001:db8::10" "$SERVER_IPV6" "v6 mode probes IPv6"

printf 'v4\n' >"$NETSTACK_FILE"
detect_network_stack
assert_eq "203.0.113.10" "$SERVER_IPV4" "v4 mode probes IPv4"
assert_eq "" "$SERVER_IPV6" "v4 mode does not probe IPv6"

write_vless_node dual1 vision
CURRENT_NODE_NAME=dual1

printf 'v4\n' >"$NETSTACK_FILE"
assert_contains "$(get_share_link)" "@203.0.113.10:1443" "v4 mode publishes the IPv4 address"
assert_contains "$(show_info)" "IPv4 Links" "v4 mode prints the IPv4 link section"
assert_not_contains "$(show_info)" "IPv6 Links" "v4 mode hides the IPv6 link section"

printf 'v6\n' >"$NETSTACK_FILE"
assert_contains "$(get_share_link)" "@[2001:db8::10]:1443" "v6 mode publishes the bracketed IPv6 address"
assert_contains "$(show_info)" "IPv6 Links" "v6 mode prints the IPv6 link section"
assert_not_contains "$(show_info)" "IPv4 Links" "v6 mode hides the IPv4 link section"

# 切到 v6 后查看一个只记录了 IPv4 的旧节点：必须回退到单链接，而不是什么都不输出。
sed -i 's|^SERVER_IPV6=.*|SERVER_IPV6=|' "$NODES_DIR/dual1.env"
info=$(show_info)
assert_not_contains "$info" "IPv4 Links" "the mismatching family stays hidden"
assert_contains "$info" "203.0.113.10" "a node without the selected family still yields a link"
SCENARIO

# 应用失败必须回到原设置，否则会留下"文件写着新档、运行中却是旧配置"的状态。
run_scenario netstack-apply-rollback <<'SCENARIO'
load_modules
write_vless_node v1 vision
printf 'dual\n' >"$NETSTACK_FILE"

cmd_regenerate() { return 1; }
assert_fails "netstack_apply reported success after a failed regenerate" netstack_apply v6
assert_eq "dual" "$(netstack_mode)" "a failed apply restores the previous setting"

cmd_regenerate() { printf 'regenerated\n' >>/srv/regenerate.calls; return 0; }
netstack_apply v6 || fail_case "netstack_apply failed on a healthy regenerate"
assert_eq "v6" "$(netstack_mode)" "a successful apply persists the new setting"
assert_eq "1" "$(wc -l </srv/regenerate.calls)" "apply regenerates exactly once"

# 同档重复应用不重建配置。
netstack_apply v6 || fail_case "re-applying the current mode failed"
assert_eq "1" "$(wc -l </srv/regenerate.calls)" "re-applying the current mode does not regenerate"

# 没有任何节点时无需重建。
rm -f "$NODES_DIR"/*.env
netstack_apply v4 || fail_case "apply failed with no nodes"
assert_eq "1" "$(wc -l </srv/regenerate.calls)" "apply with no nodes does not regenerate"
assert_eq "v4" "$(netstack_mode)" "apply with no nodes still persists the setting"
SCENARIO

pass "network stack selection covers listen, sockopt, outbound, SNI probing, links, and rollback"
