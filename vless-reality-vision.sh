#!/usr/bin/env bash
set -euo pipefail
export LANG=en_US.UTF-8

# =========================
# VLESS TCP REALITY Vision 自动化脚本
# 增强版：XHTTP支持 + 双栈链接 + WARP分流 + 系统优化工具
# =========================

# Bash 版本检查 (需要 4.3+ 支持 nameref 和 wait -n)
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    echo "Error: This script requires bash 4.3 or newer (current: ${BASH_VERSION})"
    echo "Please upgrade bash or use a newer system"
    exit 1
fi

# ============== 单实例锁机制 ==============
LOCK_DIR="/tmp/reality_vision_lock"
PID_FILE="$LOCK_DIR/pid"

lock_acquire() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$PID_FILE"
        return 0
    fi
    # 检查持有锁的进程是否还活着
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && ! kill -0 "$old_pid" 2>/dev/null; then
            # 进程已死，强制接管
            rm -rf "$LOCK_DIR"
            mkdir "$LOCK_DIR" 2>/dev/null || return 1
            echo "$$" > "$PID_FILE"
            return 0
        fi
    fi
    return 1
}

lock_release() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

# ============== Security Helper Functions ==============

# Atomic lock using flock (preferred) with mkdir fallback
LOCK_FILE="/var/lock/reality_vision.lock"
LOCK_FD=200

# Try flock-based locking first (atomic, no TOCTOU race)
lock_acquire_flock() {
    # Create lock file directory if needed
    local lock_dir
    lock_dir=$(dirname "$LOCK_FILE")
    if [[ ! -d "$lock_dir" ]]; then
        LOCK_FILE="/tmp/reality_vision.lock"
    fi

    # Open lock file descriptor
    exec 200>"$LOCK_FILE" || return 1

    # Try non-blocking lock
    if flock -n 200; then
        echo "$$" >&200
        return 0
    fi
    return 1
}

lock_release_flock() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
}

# Smart lock acquire: use flock if available, fallback to mkdir
lock_acquire_smart() {
    if command -v flock &>/dev/null; then
        lock_acquire_flock
    else
        lock_acquire
    fi
}

lock_release_smart() {
    if command -v flock &>/dev/null; then
        lock_release_flock
    fi
    lock_release  # Always clean up mkdir lock too
}

# Secure curl wrapper with TLS enforcement and redirect limits
# Usage: secure_curl [curl_options] URL
secure_curl() {
    curl --proto '=https' --tlsv1.2 --max-redirs 3 -fsSL "$@"
}

# Safe download with optional SHA256 verification
# Usage: safe_download_and_verify URL DEST_FILE [EXPECTED_SHA256]
# Returns: 0 on success, 1 on download failure, 2 on checksum mismatch
safe_download_and_verify() {
    local url="$1"
    local dest="$2"
    local expected_sha="${3:-}"

    # Download file
    if ! secure_curl "$url" -o "$dest" 2>/dev/null; then
        return 1
    fi

    # Verify checksum if provided
    if [[ -n "$expected_sha" ]]; then
        local actual_sha
        actual_sha=$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1)
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            log_warn "Checksum mismatch for $url"
            log_warn "Expected: $expected_sha"
            log_warn "Got: $actual_sha"
            return 2
        fi
    fi

    return 0
}

# Fetch GitHub release tag using jq instead of grep/cut
# Usage: fetch_github_release_tag REPO
fetch_github_release_tag() {
    local repo="$1"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local response

    response=$(secure_curl "$api_url" 2>/dev/null) || return 1

    # Use jq for safe JSON parsing
    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.tag_name // empty' 2>/dev/null
    else
        # Fallback: careful grep (less safe but functional)
        echo "$response" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1
    fi
}

# Safe config value extraction (prevents command injection)
# Usage: safe_read_config_value FILE KEY
# Returns the value or empty string if not found/invalid
safe_read_config_value() {
    local file="$1"
    local key="$2"
    local value=""

    [[ ! -f "$file" ]] && return 1

    # Read line matching KEY= pattern
    # Strict pattern: KEY=VALUE where VALUE contains no shell metacharacters
    while IFS='=' read -r k v; do
        # Skip comments and empty lines
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$k" ]] && continue

        # Match exact key
        if [[ "$k" == "$key" ]]; then
            # Security: reject values containing dangerous characters
            # Allow: alphanumeric, dash, underscore, dot, slash, colon, equals, plus, at, brackets
            # Reject: backticks, $, ;, |, &, newlines, etc.
            # Note: In POSIX regex, ] must be first if included, - must be last or first
            if [[ "$v" =~ ^[]a-zA-Z0-9_./:=+@[-]*$ ]]; then
                value="$v"
            else
                # Log warning but don't fail (backward compat)
                log_warn "Potentially unsafe value for $key in $file, using empty"
                value=""
            fi
            break
        fi
    done < "$file"

    echo "$value"
}

# Safe load all config values from node file
# Usage: safe_load_node_config FILE
# Sets variables: NODE_NAME, PORT, UUID, SNI, PUBLIC_KEY, PRIVATE_KEY, SHORT_ID,
#                 PROTOCOL_TYPE, XHTTP_PORT, XHTTP_PATH, SERVER_IP, SERVER_IPV4, SERVER_IPV6,
#                 SS_METHOD, SS_PASSWORD
safe_load_node_config() {
    local file="$1"

    [[ ! -f "$file" ]] && return 1

    # Reset all variables first
    NODE_NAME="" PORT="" UUID="" SNI="" PUBLIC_KEY="" PRIVATE_KEY="" SHORT_ID=""
    PROTOCOL_TYPE="" XHTTP_PORT="" XHTTP_PATH="" SERVER_IP="" SERVER_IPV4="" SERVER_IPV6=""
    SS_METHOD="" SS_PASSWORD=""

    # Load each value safely
    NODE_NAME=$(safe_read_config_value "$file" "NODE_NAME")
    PORT=$(safe_read_config_value "$file" "PORT")
    UUID=$(safe_read_config_value "$file" "UUID")
    SNI=$(safe_read_config_value "$file" "SNI")
    PUBLIC_KEY=$(safe_read_config_value "$file" "PUBLIC_KEY")
    PRIVATE_KEY=$(safe_read_config_value "$file" "PRIVATE_KEY")
    SHORT_ID=$(safe_read_config_value "$file" "SHORT_ID")
    PROTOCOL_TYPE=$(safe_read_config_value "$file" "PROTOCOL_TYPE")
    XHTTP_PORT=$(safe_read_config_value "$file" "XHTTP_PORT")
    XHTTP_PATH=$(safe_read_config_value "$file" "XHTTP_PATH")
    SERVER_IP=$(safe_read_config_value "$file" "SERVER_IP")
    SERVER_IPV4=$(safe_read_config_value "$file" "SERVER_IPV4")
    SERVER_IPV6=$(safe_read_config_value "$file" "SERVER_IPV6")
    SS_METHOD=$(safe_read_config_value "$file" "SS_METHOD")
    SS_PASSWORD=$(safe_read_config_value "$file" "SS_PASSWORD")

    return 0
}

# Validate and extract port number (strips non-numeric, validates range)
# Usage: get_validated_port RAW_PORT [SILENT]
# Returns: validated port number or empty string
get_validated_port() {
    local raw_port="$1"
    local silent="${2:-false}"

    # Strip any non-numeric characters (security hardening)
    local port="${raw_port//[^0-9]/}"

    # Validate range
    if [[ -z "$port" ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        [[ "$silent" != "true" ]] && log_error "Invalid port: $raw_port"
        return 1
    fi

    echo "$port"
}

# Build Vision inbound JSON using jq (prevents injection)
# Usage: build_vision_inbound NAME PORT UUID SNI PRIVATE_KEY SHORT_ID
build_vision_inbound() {
    local name="$1"
    local port="$2"
    local uuid="$3"
    local sni="$4"
    local private_key="$5"
    local short_id="$6"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_vision" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "\($sni):443",
                    "serverNames": [$sni],
                    "privateKey": $private_key,
                    "shortIds": [$short_id],
                    "fingerprint": "chrome"
                }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }'
}

# Build XHTTP inbound JSON using jq (prevents injection)
# Usage: build_xhttp_inbound NAME PORT UUID SNI PRIVATE_KEY SHORT_ID PATH
build_xhttp_inbound() {
    local name="$1"
    local port="$2"
    local uuid="$3"
    local sni="$4"
    local private_key="$5"
    local short_id="$6"
    local xhttp_path="$7"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_xhttp" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --arg path "$xhttp_path" \
        '{
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": ""}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "xhttpSettings": {"path": $path},
                "realitySettings": {
                    "show": false,
                    "dest": "\($sni):443",
                    "serverNames": [$sni],
                    "privateKey": $private_key,
                    "shortIds": [$short_id],
                    "fingerprint": "chrome"
                }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }'
}

# Build Shadowsocks inbound JSON using jq (prevents injection)
# Usage: build_shadowsocks_inbound NAME PORT METHOD PASSWORD
build_shadowsocks_inbound() {
    local name="$1"
    local port="$2"
    local method="$3"
    local password="$4"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_ss" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        '{
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "shadowsocks",
            "settings": {
                "method": $method,
                "password": $password,
                "network": "tcp,udp"
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }'
}

# Optional encryption for sensitive config values
# Usage: encrypt_value PLAINTEXT
# Returns: base64-encoded encrypted value with "U2FsdGVk" prefix (OpenSSL magic)
ENCRYPTION_KEY_FILE="/root/.reality_vision_key"

setup_encryption_key() {
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        # Generate random key on first use
        head -c 32 /dev/urandom | base64 > "$ENCRYPTION_KEY_FILE"
        chmod 600 "$ENCRYPTION_KEY_FILE"
    fi
}

encrypt_value() {
    local plaintext="$1"
    [[ -z "$plaintext" ]] && return 0

    setup_encryption_key
    local key
    key=$(cat "$ENCRYPTION_KEY_FILE")

    echo -n "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -a -pass "pass:$key" 2>/dev/null
}

decrypt_value() {
    local ciphertext="$1"
    [[ -z "$ciphertext" ]] && return 0

    # Check if value is encrypted (starts with U2FsdGVk after base64 decode)
    if [[ ! "$ciphertext" =~ ^U2FsdGVk ]]; then
        # Not encrypted, return as-is (backward compatibility)
        echo "$ciphertext"
        return 0
    fi

    [[ ! -f "$ENCRYPTION_KEY_FILE" ]] && { echo "$ciphertext"; return 0; }

    local key
    key=$(cat "$ENCRYPTION_KEY_FILE")

    echo "$ciphertext" | openssl enc -aes-256-cbc -pbkdf2 -d -a -pass "pass:$key" 2>/dev/null || echo "$ciphertext"
}

# Check if config encryption is enabled
is_encryption_enabled() {
    [[ -f "$ENCRYPTION_KEY_FILE" ]] && [[ "${ENABLE_CONFIG_ENCRYPTION:-false}" == "true" ]]
}

# 配置目录（支持多节点）
NODES_DIR="/root/reality_nodes"
LANG_FILE="/root/reality_vision.lang"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_GEODATA_DIR="/usr/local/share/xray"
SERVICE="xray"

# 缓存配置（放在 /root 下更安全）
CACHE_FILE="/root/.sni_latency_cache"
CACHE_TTL=3600  # 1小时

# 当前操作的节点名称
CURRENT_NODE_NAME=""

# 包管理器变量
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CHECK=""

# 服务管理变量 (systemd 或 openrc)
INIT_SYSTEM=""

# WARP 配置
WARP_SOCKS_PORT=40000

PORT_MIN=10000
PORT_MAX=65535

# 语言设置 (zh/en)
CURRENT_LANG="${CURRENT_LANG:-}"

# Spinner 动画帧
SPINNER_FRAMES=('|' '/' '-' '\')

# SNI 域名列表（完整列表，用于延迟测试）
SNI_LIST=(
    "amd.com"
    "aws.com"
    "c.6sc.co"
    "j.6sc.co"
    "b.6sc.co"
    "intel.com"
    "r.bing.com"
    "th.bing.com"
    "www.amd.com"
    "www.aws.com"
    "ipv6.6sc.co"
    "www.xbox.com"
    "www.sony.com"
    "rum.hlx.page"
    "www.bing.com"
    "xp.apple.com"
    "www.wowt.com"
    "www.apple.com"
    "www.intel.com"
    "www.tesla.com"
    "www.xilinx.com"
    "www.oracle.com"
    "www.icloud.com"
    "apps.apple.com"
    "c.marsflag.com"
    "www.nvidia.com"
    "snap.licdn.com"
    "aws.amazon.com"
    "drivers.amd.com"
    "cdn.bizibly.com"
    "s.go-mpulse.net"
    "tags.tiqcdn.com"
    "cdn.bizible.com"
    "ocsp2.apple.com"
    "cdn.userway.org"
    "download.amd.com"
    "d1.awsstatic.com"
    "s0.awsstatic.com"
    "mscom.demdex.net"
    "a0.awsstatic.com"
    "go.microsoft.com"
    "apps.mzstatic.com"
    "sisu.xboxlive.com"
    "www.microsoft.com"
    "s.mp.marsflag.com"
    "images.nvidia.com"
    "vs.aws.amazon.com"
    "c.s-microsoft.com"
    "statici.icloud.com"
    "beacon.gtv-pub.com"
    "ts4.tc.mm.bing.net"
    "ts3.tc.mm.bing.net"
    "d2c.aws.amazon.com"
    "ts1.tc.mm.bing.net"
    "ce.mf.marsflag.com"
    "d0.m.awsstatic.com"
    "t0.m.awsstatic.com"
    "ts2.tc.mm.bing.net"
    "tag.demandbase.com"
    "assets-www.xbox.com"
    "logx.optimizely.com"
    "azure.microsoft.com"
    "aadcdn.msftauth.net"
    "d.oracleinfinity.io"
    "assets.adobedtm.com"
    "lpcdn.lpsnmedia.net"
    "res-1.cdn.office.net"
    "is1-ssl.mzstatic.com"
    "electronics.sony.com"
    "intelcorp.scene7.com"
    "acctcdn.msftauth.net"
    "cdnssl.clicktale.net"
    "catalog.gamepass.com"
    "consent.trustarc.com"
    "gsp-ssl.ls.apple.com"
    "munchkin.marketo.net"
    "s.company-target.com"
    "cdn77.api.userway.org"
    "cua-chat-ui.tesla.com"
    "assets-xbxweb.xbox.com"
    "ds-aksb-a.akamaihd.net"
    "static.cloud.coveo.com"
    "api.company-target.com"
    "devblogs.microsoft.com"
    "s7mbrstream.scene7.com"
    "fpinit.itunes.apple.com"
    "digitalassets.tesla.com"
    "d.impactradius-event.com"
    "downloadmirror.intel.com"
    "iosapps.itunes.apple.com"
    "se-edge.itunes.apple.com"
    "publisher.liveperson.net"
    "tag-logger.demandbase.com"
    "services.digitaleast.mobi"
    "configuration.ls.apple.com"
    "gray-wowt-prod.gtv-cdn.com"
    "visualstudio.microsoft.com"
    "prod.log.shortbread.aws.dev"
    "amp-api-edge.apps.apple.com"
    "store-images.s-microsoft.com"
    "cdn-dynmedia-1.microsoft.com"
    "github.gallerycdn.vsassets.io"
    "prod.pa.cdn.uis.awsstatic.com"
    "a.b.cdn.console.awsstatic.com"
    "d3agakyjgjv5i8.cloudfront.net"
    "vscjava.gallerycdn.vsassets.io"
    "location-services-prd.tesla.com"
    "ms-vscode.gallerycdn.vsassets.io"
    "ms-python.gallerycdn.vsassets.io"
    "gray-config-prod.api.arc-cdn.net"
    "i7158c100-ds-aksb-a.akamaihd.net"
    "downloaddispatch.itunes.apple.com"
    "res.public.onecdn.static.microsoft"
    "gray.video-player.arcpublishing.com"
    "gray-config-prod.api.cdn.arcpublishing.com"
    "img-prod-cms-rt-microsoft-com.akamaized.net"
    "prod.us-east-1.ui.gcr-chat.marketing.aws.dev"
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# ============== 进程清理 ==============

# 清理函数，确保脚本退出时清理后台进程和临时文件
cleanup() {
    # 恢复光标
    tput cnorm 2>/dev/null || true
    # 终止所有后台作业
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    # 清理可能残留的临时目录
    rm -rf /tmp/tmp.*/ 2>/dev/null || true
    # 释放锁
    lock_release
}
trap cleanup EXIT INT TERM

# ============== Spinner 动画执行器 ==============

# 带 spinner 动画的任务执行器
# 用法: execute_task "命令" "描述" [max_retries]
execute_task() {
    local cmd="$1"
    local desc="$2"
    local max_retries="${3:-3}"
    local log_file="/tmp/xray_task_$$.log"
    local attempt=1
    local i=0

    while [[ $attempt -le $max_retries ]]; do
        echo "" > "$log_file"

        # 后台执行命令
        bash -c "$cmd" > "$log_file" 2>&1 &
        local pid=$!

        # 隐藏光标
        tput civis 2>/dev/null || true

        # 显示 spinner
        while kill -0 $pid 2>/dev/null; do
            local frame="${SPINNER_FRAMES[$((i % 4))]}"
            printf "\r  ${BLUE}[%s]${NC} %s..." "$frame" "$desc"
            ((i++))
            sleep 0.1
        done

        # 恢复光标
        tput cnorm 2>/dev/null || true

        wait $pid
        local status=$?

        # 清除当前行
        printf "\r\033[K"

        if [[ $status -eq 0 ]]; then
            echo -e "  ${GREEN}[OK]${NC}   $desc"
            rm -f "$log_file"
            return 0
        fi

        echo -e "  ${RED}[ERR]${NC}  $desc (attempt $attempt/$max_retries)"

        if [[ $attempt -ge $max_retries ]]; then
            echo -e "  ${RED}Error log:${NC}"
            tail -n 5 "$log_file" 2>/dev/null | sed 's/^/    /'
            rm -f "$log_file"
            return 1
        fi

        ((attempt++))
        sleep 2
    done

    rm -f "$log_file"
    return 1
}

# 简单的 spinner 显示（用于等待操作）
show_spinner() {
    local pid=$1
    local msg="$2"
    local i=0

    tput civis 2>/dev/null || true
    while kill -0 $pid 2>/dev/null; do
        local frame="${SPINNER_FRAMES[$((i % 4))]}"
        printf "\r  ${BLUE}[%s]${NC} %s..." "$frame" "$msg"
        ((i++))
        sleep 0.1
    done
    tput cnorm 2>/dev/null || true
    printf "\r\033[K"
}

# ============== 超时输入函数 ==============

# 交互超时设置
UI_TIMEOUT_SHORT=30   # 简单询问
UI_TIMEOUT_LONG=60    # 复杂操作

# 核心：统一倒计时交互函数
# 用法: read_with_timeout "提示语" "默认值" "超时时间"
# 返回值存储在 USER_INPUT 变量中
USER_INPUT=""

read_with_timeout() {
    local prompt="$1"
    local default="$2"
    local timeout="${3:-$UI_TIMEOUT_SHORT}"
    local input_char=""

    # 清空之前的输入残留 (防止幽灵回车导致秒过)
    while read -r -t 0 2>/dev/null; do read -r -n 1 2>/dev/null; done

    USER_INPUT=""

    # 设定截止时间戳
    local start_time end_time current_time remaining
    start_time=$(date +%s)
    end_time=$((start_time + timeout))

    while true; do
        current_time=$(date +%s)
        remaining=$((end_time - current_time))

        # 如果时间到了，退出循环
        if [[ "$remaining" -le 0 ]]; then
            break
        fi

        # 交互 UI： 提示语 [默认: X] [ 10s ] :
        printf "\r${YELLOW}%s [默认: %s] [ ${RED}%ds${YELLOW} ] : ${NC}" "$prompt" "$default" "$remaining"

        # -t 1 等待一秒，但我们只关心是否按键
        if read -t 1 -n 1 input_char 2>/dev/null; then
            # 用户按下了键
            echo "" # 换行
            if [[ -z "$input_char" ]]; then
                USER_INPUT="$default"
            else
                USER_INPUT="$input_char"
            fi
            return 0
        fi
    done

    # 超时处理
    echo ""
    echo -e "${BLUE}[INFO]${NC} 倒计时结束，使用默认值: ${default}"
    USER_INPUT="$default"
}

# ============== 包管理器状态检查 ==============

# 检查包管理器是否繁忙
is_pkg_manager_busy() {
    case "$PKG_MANAGER" in
        apt)
            pgrep -x apt >/dev/null 2>&1 || \
            pgrep -x apt-get >/dev/null 2>&1 || \
            pgrep -x dpkg >/dev/null 2>&1 || \
            pgrep -f "unattended-upgr" >/dev/null 2>&1
            ;;
        dnf|yum)
            pgrep -x dnf >/dev/null 2>&1 || \
            pgrep -x yum >/dev/null 2>&1 || \
            pgrep -x rpm >/dev/null 2>&1
            ;;
        apk)
            pgrep -x apk >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查 dpkg/rpm 数据库状态
check_pkg_db_status() {
    case "$PKG_MANAGER" in
        apt)
            if ! dpkg --audit >/dev/null 2>&1; then
                echo -e "${RED}[ERROR]${NC} 检测到 dpkg 数据库状态异常！"
                echo -e "${YELLOW}建议执行: 'dpkg --configure -a' 修复系统。${NC}"
                return 1
            fi
            ;;
        dnf|yum)
            if ! rpm --query --all >/dev/null 2>&1; then
                echo -e "${RED}[ERROR]${NC} 检测到 RPM 数据库状态异常！"
                echo -e "${YELLOW}建议执行: 'rpm --rebuilddb' 修复系统。${NC}"
                return 1
            fi
            ;;
    esac
    return 0
}

# 等待包管理器释放
wait_for_pkg_manager() {
    local max_wait=300  # 最长等待 5 分钟
    local waited=0
    local i=0

    if ! is_pkg_manager_busy; then
        return 0
    fi

    echo -e "${BLUE}[INFO]${NC} 检测到系统更新进程正在运行，正在等待释放..."
    tput civis 2>/dev/null || true

    while is_pkg_manager_busy; do
        if [[ $waited -ge $max_wait ]]; then
            tput cnorm 2>/dev/null || true
            echo ""
            echo -e "${YELLOW}[WARN]${NC} 等待超时！"
            echo -n "是否强制终止占用进程? (y/n) [n]: "
            read -r kill_choice
            if [[ "$kill_choice" == "y" || "$kill_choice" == "Y" ]]; then
                case "$PKG_MANAGER" in
                    apt)
                        killall apt apt-get dpkg 2>/dev/null || true
                        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null
                        ;;
                    dnf|yum)
                        killall dnf yum 2>/dev/null || true
                        rm -f /var/run/yum.pid /var/run/dnf.pid 2>/dev/null
                        ;;
                esac
                return 0
            else
                echo -e "${RED}[ERROR]${NC} 用户取消，安装终止。"
                return 1
            fi
        fi

        local frame="${SPINNER_FRAMES[$((i % 4))]}"
        printf "\r  ${BLUE}[%s]${NC} 等待包管理器释放... (%ds)" "$frame" "$waited"
        sleep 1
        ((waited++))
        ((i++))
    done

    tput cnorm 2>/dev/null || true
    printf "\r\033[K"
    echo -e "${GREEN}[OK]${NC} 包管理器已释放"
    return 0
}

# ============== IPv6 SSH 保护 ==============

# 检查当前 SSH 连接方式 (防自杀核心)
check_ssh_connection() {
    # 获取当前 SSH 连接的客户端 IP
    local client_ip="${SSH_CLIENT%% *}"
    if [[ -z "$client_ip" ]]; then
        echo "unknown"
    elif [[ "$client_ip" =~ : ]]; then
        echo "v6" # 当前是 IPv6 连接
    else
        echo "v4" # 当前是 IPv4 连接
    fi
}

# IPv6 操作前安全检查
check_ipv6_ssh_safety() {
    local action="$1"  # disable 或 其他操作

    if [[ "$action" == "disable" ]]; then
        if [[ "$(check_ssh_connection)" == "v6" ]]; then
            echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
            echo -e "${RED}                 [危险操作拦截]                        ${NC}"
            echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}检测到您当前正在通过 IPv6 连接 SSH！${NC}"
            echo -e "${YELLOW}若此时禁用 IPv6，您将立即断开连接且无法重连！${NC}"
            echo -e "${RED}操作已取消。请切换到 IPv4 网络连接 SSH 后再试。${NC}"
            echo ""
            read -n 1 -s -r -p "按任意键返回..."
            return 1
        fi
    fi
    return 0
}

# ============== 包管理器检测 ==============

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt-get update -y"
        PKG_INSTALL="apt-get install -y"
        PKG_CHECK="dpkg -s"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf check-update || true"
        PKG_INSTALL="dnf install -y"
        PKG_CHECK="rpm -q"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum check-update || true"
        PKG_INSTALL="yum install -y"
        PKG_CHECK="rpm -q"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add --no-cache"
        PKG_CHECK="apk info -e"
    else
        echo -e "${RED}[ERROR]${NC} Unsupported package manager"
        echo "Please use Debian/Ubuntu, CentOS/RHEL/Fedora, or Alpine Linux"
        exit 1
    fi
}

# ============== init 系统检测 ==============

detect_init_system() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        # 默认尝试 systemd
        INIT_SYSTEM="systemd"
    fi
}

# ============== 服务管理抽象 ==============

# 启动服务
service_start() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" start
    else
        systemctl start "$svc"
    fi
}

# 停止服务
service_stop() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" stop 2>/dev/null || true
    else
        systemctl stop "$svc" 2>/dev/null || true
    fi
}

# 重启服务
service_restart() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" restart
    else
        systemctl restart "$svc"
    fi
}

# 设置开机启动
service_enable() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add "$svc" default 2>/dev/null || true
    else
        systemctl enable "$svc" 2>/dev/null || true
    fi
}

# 取消开机启动
service_disable() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update del "$svc" default 2>/dev/null || true
    else
        systemctl disable "$svc" 2>/dev/null || true
    fi
}

# 检查服务是否运行
service_is_active() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" status &>/dev/null
    else
        systemctl is-active --quiet "$svc" 2>/dev/null
    fi
}

# 显示服务状态
service_status() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" status 2>/dev/null || echo "Service $svc is not running"
    else
        systemctl status "$svc" --no-pager 2>/dev/null | head -10 || true
    fi
}

# 初始化包管理器和 init 系统
detect_pkg_manager
detect_init_system

# ============== 多语言支持 ==============

# 获取翻译文本
msg() {
    local key="$1"
    if [[ "$CURRENT_LANG" == "en" ]]; then
        case "$key" in
            "menu_title") echo "VLESS TCP REALITY Vision Management" ;;
            "menu_install") echo "Install Node" ;;
            "menu_info") echo "View Node Info" ;;
            "menu_qr") echo "Show QR Code" ;;
            "menu_status") echo "Service Status" ;;
            "menu_health") echo "Health Check" ;;
            "menu_restart") echo "Restart Service" ;;
            "menu_test_sni") echo "Test SNI Latency" ;;
            "menu_uninstall") echo "Uninstall" ;;
            "menu_lang") echo "Switch Language" ;;
            "menu_exit") echo "Exit" ;;
            "menu_choice") echo "Please enter your choice" ;;
            "menu_invalid") echo "Invalid option, please try again" ;;
            "menu_press_enter") echo "Press Enter to continue..." ;;
            "lang_select") echo "Select Language / 选择语言" ;;
            "lang_zh") echo "Chinese (中文)" ;;
            "lang_en") echo "English" ;;
            "installing") echo "Installing VLESS TCP REALITY Vision..." ;;
            "install_deps") echo "Installing dependencies..." ;;
            "install_xray") echo "Installing Xray..." ;;
            "gen_keys") echo "Generating Reality keys..." ;;
            "testing_sni") echo "Testing all SNI domains for latency..." ;;
            "testing") echo "Testing..." ;;
            "test_progress") echo "Progress" ;;
            "current") echo "Current" ;;
            "sni_timeout") echo "All test domains timed out, using default SNI: www.tesla.com" ;;
            "sni_selected") echo "Selected optimal SNI" ;;
            "sni_multiple") echo "Multiple domains have the same lowest latency" ;;
            "sni_choose") echo "Please choose one" ;;
            "latency") echo "latency" ;;
            "install_complete") echo "Installation complete!" ;;
            "uninstalling") echo "Uninstalling..." ;;
            "uninstall_complete") echo "Uninstall complete" ;;
            "config_not_found") echo "Configuration not found, please install first" ;;
            "run_as_root") echo "Please run this script as root" ;;
            "node_info") echo "VLESS Reality Vision Node Info" ;;
            "server_addr") echo "Server Address" ;;
            "port") echo "Port" ;;
            "share_link") echo "Share Link" ;;
            "qr_title") echo "Node QR Code (Scan to Import)" ;;
            "qr_tip") echo "Tip: Run 'bash $0 qr' to regenerate QR code" ;;
            "common_cmds") echo "Common commands" ;;
            "view_info") echo "View node info" ;;
            "show_qr") echo "Show QR code" ;;
            "service_status") echo "Service Status" ;;
            "service_restarted") echo "Service restarted" ;;
            "test_complete") echo "Test complete" ;;
            "timeout") echo "timeout" ;;
            "using_sni") echo "Using specified SNI" ;;
            "installed") echo "Installed" ;;
            "not_installed") echo "Not Installed" ;;
            "total_domains") echo "Total domains" ;;
            "best_latency") echo "Best latency" ;;
            "health_check") echo "Health Check" ;;
            "connections") echo "Active Connections" ;;
            "sni_selection_title") echo "SNI Domain Selection" ;;
            "sni_top_results") echo "Top 5 Fastest Domains" ;;
            "sni_auto_select") echo "Auto select best" ;;
            "sni_manual_input") echo "Enter custom domain" ;;
            "sni_choice_prompt") echo "Your choice" ;;
            "sni_no_results") echo "No test results available" ;;
            "sni_use_default") echo "Use default" ;;
            "sni_input_hint") echo "Enter domain (e.g. www.microsoft.com)" ;;
            "sni_empty_input") echo "Empty input" ;;
            "sni_custom_set") echo "Custom SNI set" ;;
            "sni_testing_custom") echo "Testing connectivity" ;;
            "sni_custom_ok") echo "Domain is reachable" ;;
            "sni_custom_unreachable") echo "Domain may be unreachable, but will use it anyway" ;;
            "sni_invalid_format") echo "Invalid domain format" ;;
            # 新功能翻译
            "menu_tools") echo "System Tools" ;;
            "menu_warp") echo "WARP Routing" ;;
            "menu_bbr") echo "BBR Management" ;;
            "menu_swap") echo "Swap Management" ;;
            "menu_fail2ban") echo "Fail2ban Management" ;;
            "install_geodata") echo "Installing GeoIP/GeoSite databases..." ;;
            "geodata_updated") echo "GeoData databases updated" ;;
            "xhttp_port") echo "XHTTP Port" ;;
            "vision_port") echo "Vision Port" ;;
            "ipv4_links") echo "IPv4 Links" ;;
            "ipv6_links") echo "IPv6 Links" ;;
            "warp_status") echo "WARP Status" ;;
            "warp_running") echo "Running" ;;
            "warp_stopped") echo "Stopped" ;;
            "warp_install") echo "Install WARP" ;;
            "warp_uninstall") echo "Uninstall WARP" ;;
            "warp_netflix") echo "Netflix Routing" ;;
            "warp_ai") echo "AI Services Routing" ;;
            "bbr_enabled") echo "BBR Enabled" ;;
            "bbr_disabled") echo "BBR Disabled" ;;
            "swap_size") echo "Swap Size" ;;
            "fail2ban_status") echo "Fail2ban Status" ;;
            "script_running") echo "Script is already running!" ;;
            "enable_xhttp") echo "Enable XHTTP protocol? (y/n)" ;;
            "xhttp_enabled") echo "XHTTP protocol enabled" ;;
            "detecting_ip") echo "Detecting server IP..." ;;
            "tools_menu") echo "System Optimization Tools" ;;
            *) echo "$key" ;;
        esac
    else
        case "$key" in
            "menu_title") echo "VLESS TCP REALITY Vision 管理面板" ;;
            "menu_install") echo "安装节点" ;;
            "menu_info") echo "查看节点信息" ;;
            "menu_qr") echo "显示二维码" ;;
            "menu_status") echo "服务状态" ;;
            "menu_health") echo "健康检查" ;;
            "menu_restart") echo "重启服务" ;;
            "menu_test_sni") echo "测试 SNI 延迟" ;;
            "menu_uninstall") echo "卸载节点" ;;
            "menu_lang") echo "切换语言" ;;
            "menu_exit") echo "退出" ;;
            "menu_choice") echo "请输入选项" ;;
            "menu_invalid") echo "无效选项，请重新输入" ;;
            "menu_press_enter") echo "按 Enter 键继续..." ;;
            "lang_select") echo "Select Language / 选择语言" ;;
            "lang_zh") echo "中文" ;;
            "lang_en") echo "English (英文)" ;;
            "installing") echo "开始安装 VLESS TCP REALITY Vision..." ;;
            "install_deps") echo "安装依赖..." ;;
            "install_xray") echo "安装 Xray..." ;;
            "gen_keys") echo "生成 Reality 密钥..." ;;
            "testing_sni") echo "测试所有 SNI 域名延迟..." ;;
            "testing") echo "测试中..." ;;
            "test_progress") echo "进度" ;;
            "current") echo "当前" ;;
            "sni_timeout") echo "所有测试域名均超时，使用默认 SNI: www.tesla.com" ;;
            "sni_selected") echo "选择最优 SNI" ;;
            "sni_multiple") echo "多个域名具有相同的最低延迟" ;;
            "sni_choose") echo "请选择一个" ;;
            "latency") echo "延迟" ;;
            "install_complete") echo "安装完成！" ;;
            "uninstalling") echo "开始卸载..." ;;
            "uninstall_complete") echo "卸载完成" ;;
            "config_not_found") echo "未找到配置文件，请先运行安装" ;;
            "run_as_root") echo "请使用 root 用户运行此脚本" ;;
            "node_info") echo "VLESS Reality Vision 节点信息" ;;
            "server_addr") echo "服务器地址" ;;
            "port") echo "端口" ;;
            "share_link") echo "分享链接" ;;
            "qr_title") echo "节点二维码（扫码导入）" ;;
            "qr_tip") echo "提示: 可运行 'bash $0 qr' 重新生成二维码" ;;
            "common_cmds") echo "常用命令" ;;
            "view_info") echo "查看节点信息" ;;
            "show_qr") echo "显示二维码" ;;
            "service_status") echo "服务状态" ;;
            "service_restarted") echo "服务已重启" ;;
            "test_complete") echo "测试完成" ;;
            "timeout") echo "超时" ;;
            "using_sni") echo "使用指定 SNI" ;;
            "installed") echo "已安装" ;;
            "not_installed") echo "未安装" ;;
            "total_domains") echo "域名总数" ;;
            "best_latency") echo "最低延迟" ;;
            "health_check") echo "健康检查" ;;
            "connections") echo "当前连接数" ;;
            "sni_selection_title") echo "SNI 域名选择" ;;
            "sni_top_results") echo "延迟最低的 5 个域名" ;;
            "sni_auto_select") echo "自动选择最佳" ;;
            "sni_manual_input") echo "输入自定义域名" ;;
            "sni_choice_prompt") echo "请选择" ;;
            "sni_no_results") echo "没有可用的测试结果" ;;
            "sni_use_default") echo "使用默认" ;;
            "sni_input_hint") echo "输入域名 (例如 www.microsoft.com)" ;;
            "sni_empty_input") echo "输入为空" ;;
            "sni_custom_set") echo "已设置自定义 SNI" ;;
            "sni_testing_custom") echo "测试连通性" ;;
            "sni_custom_ok") echo "域名可访问" ;;
            "sni_custom_unreachable") echo "域名可能无法访问，但仍会使用" ;;
            "sni_invalid_format") echo "域名格式无效" ;;
            # 新功能翻译
            "menu_tools") echo "系统工具" ;;
            "menu_warp") echo "WARP 分流" ;;
            "menu_bbr") echo "BBR 管理" ;;
            "menu_swap") echo "Swap 管理" ;;
            "menu_fail2ban") echo "Fail2ban 管理" ;;
            "install_geodata") echo "安装 GeoIP/GeoSite 数据库..." ;;
            "geodata_updated") echo "GeoData 数据库已更新" ;;
            "xhttp_port") echo "XHTTP 端口" ;;
            "vision_port") echo "Vision 端口" ;;
            "ipv4_links") echo "IPv4 链接" ;;
            "ipv6_links") echo "IPv6 链接" ;;
            "warp_status") echo "WARP 状态" ;;
            "warp_running") echo "运行中" ;;
            "warp_stopped") echo "已停止" ;;
            "warp_install") echo "安装 WARP" ;;
            "warp_uninstall") echo "卸载 WARP" ;;
            "warp_netflix") echo "Netflix 分流" ;;
            "warp_ai") echo "AI 服务分流" ;;
            "bbr_enabled") echo "BBR 已启用" ;;
            "bbr_disabled") echo "BBR 未启用" ;;
            "swap_size") echo "Swap 大小" ;;
            "fail2ban_status") echo "Fail2ban 状态" ;;
            "script_running") echo "脚本已在运行中！" ;;
            "enable_xhttp") echo "是否启用 XHTTP 协议？(y/n)" ;;
            "xhttp_enabled") echo "XHTTP 协议已启用" ;;
            "detecting_ip") echo "检测服务器 IP..." ;;
            "tools_menu") echo "系统优化工具" ;;
            *) echo "$key" ;;
        esac
    fi
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

is_port_free() {
    local port="$1"
    # 更精确的端口匹配：检查 :port 结尾，避免 80 匹配 8080
    ! ss -lnt | awk '{print $4}' | grep -qE ":${port}$"
}

# ============== 多节点管理 ==============

# 初始化节点目录
init_nodes_dir() {
    mkdir -p "$NODES_DIR"
    chmod 700 "$NODES_DIR"
}

# 获取节点配置文件路径
get_node_file() {
    local node_name="$1"
    echo "${NODES_DIR}/${node_name}.env"
}

# 列出所有节点
list_nodes() {
    local nodes=()
    if [[ -d "$NODES_DIR" ]]; then
        for f in "$NODES_DIR"/*.env; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f" .env)
            nodes+=("$name")
        done
    fi
    echo "${nodes[@]}"
}

# 获取节点数量
count_nodes() {
    local count=0
    if [[ -d "$NODES_DIR" ]]; then
        count=$(find "$NODES_DIR" -maxdepth 1 -name "*.env" 2>/dev/null | wc -l)
    fi
    echo "$count"
}

# 检查节点是否存在
node_exists() {
    local node_name="$1"
    [[ -f "$(get_node_file "$node_name")" ]]
}

# 生成随机节点名称
generate_random_name() {
    echo "node_$(openssl rand -hex 4)"
}

# 交互式输入节点名称
prompt_node_name() {
    local default_name
    default_name=$(generate_random_name)

    echo "" >/dev/tty
    echo -e "${CYAN}Enter node name (press Enter for random):${NC}" >/dev/tty
    echo -e "${CYAN}输入节点名称（直接回车使用随机名称）:${NC}" >/dev/tty
    echo -n "  [$default_name]: " >/dev/tty
    read -r input_name </dev/tty

    local node_name="${input_name:-$default_name}"

    # 清理非法字符，只保留字母、数字、下划线、短横线
    node_name=$(echo "$node_name" | tr -cd 'a-zA-Z0-9_-')

    # 如果名称已存在，添加后缀
    local base_name="$node_name"
    local counter=1
    while node_exists "$node_name"; do
        node_name="${base_name}_${counter}"
        ((counter++))
    done

    echo "$node_name"
}

# 选择节点（交互式）
select_node() {
    local nodes
    read -ra nodes <<< "$(list_nodes)"
    local count=${#nodes[@]}

    if [[ $count -eq 0 ]]; then
        log_error "$(msg config_not_found)"
        return 1
    fi

    if [[ $count -eq 1 ]]; then
        CURRENT_NODE_NAME="${nodes[0]}"
        return 0
    fi

    echo "" >/dev/tty
    echo -e "${CYAN}Available nodes / 可用节点:${NC}" >/dev/tty
    echo "" >/dev/tty

    local i=1
    for node in "${nodes[@]}"; do
        local node_file
        node_file=$(get_node_file "$node")
        # 使用安全的配置加载（防止命令注入）
        safe_load_node_config "$node_file"
        # 根据协议类型显示对应的端口
        local display_port=""
        local proto="${PROTOCOL_TYPE:-vision}"
        local display_info=""
        if [[ "$proto" == "shadowsocks" ]]; then
            display_port="${PORT:-N/A}"
            display_info="Method: ${SS_METHOD:-N/A}"
        elif [[ "$proto" == "xhttp" ]]; then
            display_port="${XHTTP_PORT:-N/A}"
            display_info="SNI: $SNI"
        elif [[ "$proto" == "both" ]]; then
            display_port="${PORT:-}/${XHTTP_PORT:-}"
            display_info="SNI: $SNI"
        else
            display_port="${PORT:-N/A}"
            display_info="SNI: $SNI"
        fi
        echo -e "  ${GREEN}$i.${NC} $node (Port: $display_port, $display_info)" >/dev/tty
        ((i++))
    done

    echo "" >/dev/tty
    echo -n "  Select node / 选择节点 [1-$count]: " >/dev/tty
    read -r choice </dev/tty

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $count ]]; then
        CURRENT_NODE_NAME="${nodes[$((choice - 1))]}"
    else
        CURRENT_NODE_NAME="${nodes[0]}"
    fi

    return 0
}

# 加载语言设置
load_lang() {
    if [[ -f "$LANG_FILE" ]]; then
        CURRENT_LANG=$(cat "$LANG_FILE")
    fi
}

# 保存语言设置
save_lang() {
    echo "$CURRENT_LANG" > "$LANG_FILE"
    chmod 600 "$LANG_FILE"
}

# 语言选择界面
select_language() {
    clear
    {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${YELLOW}Select Language / 选择语言${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}1.${NC} 中文 (Chinese)                                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}2.${NC} English                                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -n "   请选择 / Please choose [1-2]: "
    } >/dev/tty
    read -r lang_choice </dev/tty

    case "$lang_choice" in
        1)
            CURRENT_LANG="zh"
            ;;
        2)
            CURRENT_LANG="en"
            ;;
        *)
            CURRENT_LANG="zh"
            ;;
    esac
    save_lang
}

install_deps() {
    log_info "$(msg install_deps)"

    # 根据包管理器设置包名
    local required_packages
    case "$PKG_MANAGER" in
        apt)
            required_packages=(curl unzip openssl ca-certificates iproute2 qrencode jq cron)
            ;;
        dnf|yum)
            required_packages=(curl unzip openssl ca-certificates iproute qrencode jq cronie)
            ;;
        apk)
            # Alpine Linux 特殊包名
            # libqrencode-tools 提供 qrencode 命令
            required_packages=(curl unzip openssl ca-certificates iproute2 libqrencode-tools bash coreutils jq)
            ;;
        *)
            required_packages=(curl unzip openssl ca-certificates iproute qrencode jq)
            ;;
    esac

    local missing_packages=()

    # 检查哪些包未安装
    for pkg in "${required_packages[@]}"; do
        if ! $PKG_CHECK "$pkg" >/dev/null 2>&1; then
            missing_packages+=("$pkg")
        fi
    done

    # 如果所有包都已安装，跳过
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_info "All dependencies already installed, skipping..."
        return
    fi

    # 只安装缺失的包
    log_info "Installing: ${missing_packages[*]}"
    $PKG_UPDATE >/dev/null 2>&1 || true
    if ! $PKG_INSTALL "${missing_packages[@]}" >/dev/null 2>&1; then
        log_error "Failed to install dependencies"
        return 1
    fi
}

install_xray() {
    # 检查 Xray 是否已安装
    if [[ -f "$XRAY_BIN" ]] && "$XRAY_BIN" version &>/dev/null; then
        log_info "Xray already installed, skipping..."
        return 0
    fi

    log_info "$(msg install_xray)"

    # Alpine Linux 需要手动安装（官方脚本依赖 systemd）
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        install_xray_alpine
    else
        # Security: Download script to temp file first, then execute
        # This allows for potential verification and avoids direct pipe-to-bash
        local installer_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
        local tmp_installer="/tmp/xray-install-$$.sh"

        if ! secure_curl "$installer_url" -o "$tmp_installer"; then
            log_error "Failed to download Xray installer"
            rm -f "$tmp_installer"
            return 1
        fi

        # Execute downloaded script
        if ! bash "$tmp_installer" >/dev/null 2>&1; then
            log_error "Failed to install Xray. Please check your network connection."
            rm -f "$tmp_installer"
            return 1
        fi
        rm -f "$tmp_installer"
    fi
}

# Alpine Linux 专用 Xray 安装函数
install_xray_alpine() {
    local arch
    arch=$(uname -m)
    local xray_arch

    # 映射架构名称
    case "$arch" in
        x86_64)
            xray_arch="64"
            ;;
        aarch64|arm64)
            xray_arch="arm64-v8a"
            ;;
        armv7l)
            xray_arch="arm32-v7a"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    # 获取最新版本号（使用安全的 API 解析）
    local latest_version
    latest_version=$(fetch_github_release_tag "XTLS/Xray-core")
    if [[ -z "$latest_version" ]]; then
        log_error "Failed to get Xray latest version"
        return 1
    fi

    log_info "Installing Xray $latest_version for Alpine (${xray_arch})..."

    # 下载 Xray（使用安全的 curl 封装）
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_version}/Xray-linux-${xray_arch}.zip"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! secure_curl "$download_url" -o "${tmp_dir}/xray.zip"; then
        log_error "Failed to download Xray"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 解压安装
    unzip -q "${tmp_dir}/xray.zip" -d "${tmp_dir}"
    mkdir -p /usr/local/bin /usr/local/etc/xray /usr/local/share/xray /var/log/xray

    install -m 755 "${tmp_dir}/xray" /usr/local/bin/xray
    [[ -f "${tmp_dir}/geoip.dat" ]] && install -m 644 "${tmp_dir}/geoip.dat" /usr/local/share/xray/
    [[ -f "${tmp_dir}/geosite.dat" ]] && install -m 644 "${tmp_dir}/geosite.dat" /usr/local/share/xray/

    rm -rf "$tmp_dir"

    # 创建 OpenRC 服务脚本
    create_xray_openrc_service

    log_info "Xray installed successfully on Alpine"
}

# 创建 Xray OpenRC 服务脚本
create_xray_openrc_service() {
    cat > /etc/init.d/xray <<'OPENRC_SERVICE'
#!/sbin/openrc-run

name="xray"
description="Xray - A platform for building proxies"

command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner root:root --mode 0755 /var/log/xray
}
OPENRC_SERVICE

    chmod 755 /etc/init.d/xray
}

# ============== GeoData 安装 ==============

install_geodata() {
    log_info "$(msg install_geodata)"

    mkdir -p "$XRAY_GEODATA_DIR"

    local geoip_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    local geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

    # 下载 geoip.dat（使用安全的 curl 选项，内联因为 execute_task 在子 shell 运行）
    if execute_task "curl --proto '=https' --tlsv1.2 -fsSL '$geoip_url' -o '$XRAY_GEODATA_DIR/geoip.dat'" "Downloading geoip.dat"; then
        # 创建软链接到 /usr/local/bin (Xray 查找位置)
        ln -sf "$XRAY_GEODATA_DIR/geoip.dat" /usr/local/bin/geoip.dat 2>/dev/null || true
    fi

    # 下载 geosite.dat
    if execute_task "curl --proto '=https' --tlsv1.2 -fsSL '$geosite_url' -o '$XRAY_GEODATA_DIR/geosite.dat'" "Downloading geosite.dat"; then
        ln -sf "$XRAY_GEODATA_DIR/geosite.dat" /usr/local/bin/geosite.dat 2>/dev/null || true
    fi

    # 设置自动更新定时任务（每周日 4:00）
    setup_geodata_cron

    log_info "$(msg geodata_updated)"
}

setup_geodata_cron() {
    # Use secure curl options in cron job (--proto, --tlsv1.2)
    local cron_cmd="curl --proto '=https' --tlsv1.2 -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o $XRAY_GEODATA_DIR/geoip.dat && curl --proto '=https' --tlsv1.2 -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o $XRAY_GEODATA_DIR/geosite.dat"
    local cron_job="0 4 * * 0 $cron_cmd >/dev/null 2>&1"

    # 检查 crontab 命令是否存在
    if ! command -v crontab &>/dev/null; then
        return 0
    fi

    # 添加定时任务（先删除旧的）
    (crontab -l 2>/dev/null | grep -v 'geoip.dat' | grep -v 'geosite.dat'; echo "$cron_job") | crontab - 2>/dev/null || true
}

# ============== 协议类型选择 ==============

# 协议类型: vision, xhttp, both, shadowsocks
PROTOCOL_TYPE="vision"
XHTTP_PORT=""
XHTTP_PATH=""

# Shadowsocks 相关变量
SS_METHOD=""
SS_PASSWORD=""

# Shadowsocks 支持的加密方式
SS_METHODS_2022=(
    "2022-blake3-aes-256-gcm"
    "2022-blake3-chacha20-poly1305"
)
SS_METHODS_LEGACY=(
    "chacha20-ietf-poly1305"
    "aes-256-gcm"
)

# 选择协议类型
prompt_protocol_type() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     选择节点协议类型${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} VLESS + Vision + REALITY  ${GRAY}(TCP 传输, 推荐)${NC}"
    echo -e "  ${GREEN}2.${NC} VLESS + XHTTP + REALITY   ${GRAY}(XHTTP 传输)${NC}"
    echo -e "  ${GREEN}3.${NC} 两个都安装               ${GRAY}(生成两个端口)${NC}"
    echo -e "  ${GREEN}4.${NC} Shadowsocks 2022         ${GRAY}(SS 协议, 高性能)${NC}"
    echo ""
    echo -n "  请选择 [1-4] (默认 1): "
    } >/dev/tty

    local choice
    read -r choice </dev/tty

    case "$choice" in
        2)
            PROTOCOL_TYPE="xhttp"
            log_info "已选择: VLESS + XHTTP + REALITY"
            ;;
        3)
            PROTOCOL_TYPE="both"
            log_info "已选择: Vision + XHTTP 双协议"
            ;;
        4)
            PROTOCOL_TYPE="shadowsocks"
            log_info "已选择: Shadowsocks 2022"
            ;;
        *)
            PROTOCOL_TYPE="vision"
            log_info "已选择: VLESS + Vision + REALITY"
            ;;
    esac
}

# 选择 Shadowsocks 加密方式
prompt_ss_method() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                  Shadowsocks 加密方式${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}推荐 (2022 协议, 更安全):${NC}"
    echo -e "  ${GREEN}1.${NC} 2022-blake3-aes-256-gcm      ${GRAY}(推荐, 硬件加速)${NC}"
    echo -e "  ${GREEN}2.${NC} 2022-blake3-chacha20-poly1305 ${GRAY}(移动设备优化)${NC}"
    echo ""
    echo -e "  ${YELLOW}传统方式 (兼容性更好):${NC}"
    echo -e "  ${GREEN}3.${NC} chacha20-ietf-poly1305       ${GRAY}(广泛支持)${NC}"
    echo -e "  ${GREEN}4.${NC} aes-256-gcm                  ${GRAY}(经典加密)${NC}"
    echo ""
    echo -n "  请选择 [1-4] (默认 1): "
    } >/dev/tty

    local choice
    read -r choice </dev/tty

    case "$choice" in
        2)
            SS_METHOD="2022-blake3-chacha20-poly1305"
            ;;
        3)
            SS_METHOD="chacha20-ietf-poly1305"
            ;;
        4)
            SS_METHOD="aes-256-gcm"
            ;;
        *)
            SS_METHOD="2022-blake3-aes-256-gcm"
            ;;
    esac
    log_info "加密方式: $SS_METHOD"
}

# 生成 Shadowsocks 密码/密钥
gen_ss_password() {
    # 2022 协议需要 base64 编码的预共享密钥
    # 2022-blake3-aes-256-gcm 和 2022-blake3-chacha20-poly1305 需要 32 字节
    # 传统方式使用随机字符串密码
    case "$SS_METHOD" in
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            SS_PASSWORD=$(openssl rand -base64 32)
            ;;
        2022-blake3-aes-128-gcm)
            SS_PASSWORD=$(openssl rand -base64 16)
            ;;
        *)
            # 传统方式：生成 16 字符随机密码
            SS_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
            ;;
    esac
    log_info "密码已生成"
}

gen_uuid() {
    UUID="${uuid:-$(cat /proc/sys/kernel/random/uuid)}"
}

# 生成一个可用的随机端口
gen_random_free_port() {
    local exclude_port="${1:-0}"
    local port
    while true; do
        port="$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)"
        if is_port_free "$port" && [[ "$port" != "$exclude_port" ]]; then
            echo "$port"
            return 0
        fi
    done
}

# 交互式选择端口
# Usage: prompt_port "提示信息" "默认端口" "排除端口(可选)"
prompt_port() {
    local prompt_msg="$1"
    local default_port="$2"
    local exclude_port="${3:-0}"
    local user_port

    while true; do
        echo -n "  $prompt_msg [默认: $default_port]: " >/dev/tty
        read -r user_port </dev/tty

        # 用户直接回车，使用默认端口
        if [[ -z "$user_port" ]]; then
            echo "$default_port"
            return 0
        fi

        # 验证端口格式
        if ! [[ "$user_port" =~ ^[0-9]+$ ]]; then
            echo -e "  ${RED}端口必须是数字${NC}" >/dev/tty
            continue
        fi

        # 验证端口范围
        if [[ "$user_port" -lt 1 || "$user_port" -gt 65535 ]]; then
            echo -e "  ${RED}端口必须在 1-65535 之间${NC}" >/dev/tty
            continue
        fi

        # 检查是否与排除端口冲突
        if [[ "$user_port" == "$exclude_port" ]]; then
            echo -e "  ${RED}端口不能与其他服务端口相同${NC}" >/dev/tty
            continue
        fi

        # 检查端口是否被占用
        if ! is_port_free "$user_port"; then
            echo -e "  ${YELLOW}端口 $user_port 已被占用，是否仍然使用? [y/N]: ${NC}" >/dev/tty
            read -r confirm </dev/tty
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                echo "$user_port"
                return 0
            fi
            continue
        fi

        echo "$user_port"
        return 0
    done
}

# 选择端口（根据协议类型）
choose_ports() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     端口配置${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    } >/dev/tty

    # Shadowsocks 端口
    if [[ "$PROTOCOL_TYPE" == "shadowsocks" ]]; then
        if [[ -n "${sspt:-}" ]]; then
            # 环境变量指定
            PORT="$sspt"
        elif [[ -n "${vlpt:-}" ]]; then
            # 兼容 vlpt 变量
            PORT="$vlpt"
        else
            # 交互式选择
            local default_ss_port
            default_ss_port=$(gen_random_free_port)
            PORT=$(prompt_port "Shadowsocks 端口" "$default_ss_port")
        fi
        log_info "Shadowsocks 端口: $PORT"
        XHTTP_PORT=""
        XHTTP_PATH=""
        echo "" >/dev/tty
        return 0
    fi

    # Vision 端口（如果需要）
    if [[ "$PROTOCOL_TYPE" == "vision" || "$PROTOCOL_TYPE" == "both" ]]; then
        if [[ -n "${vlpt:-}" ]]; then
            # 环境变量指定，直接使用
            PORT="$vlpt"
        else
            # 交互式选择
            local default_vision_port
            default_vision_port=$(gen_random_free_port)
            PORT=$(prompt_port "Vision 端口" "$default_vision_port")
        fi
        log_info "Vision 端口: $PORT"
    else
        PORT=""
    fi

    # XHTTP 端口（如果需要）
    if [[ "$PROTOCOL_TYPE" == "xhttp" || "$PROTOCOL_TYPE" == "both" ]]; then
        if [[ -n "${xhpt:-}" ]]; then
            # 环境变量指定，直接使用
            XHTTP_PORT="$xhpt"
        else
            # 交互式选择（排除 Vision 端口）
            local default_xhttp_port
            default_xhttp_port=$(gen_random_free_port "${PORT:-0}")
            XHTTP_PORT=$(prompt_port "XHTTP 端口" "$default_xhttp_port" "${PORT:-0}")
        fi
        XHTTP_PATH="/$(openssl rand -hex 4)"
        log_info "XHTTP 端口: $XHTTP_PORT, 路径: $XHTTP_PATH"
    else
        XHTTP_PORT=""
        XHTTP_PATH=""
    fi

    echo "" >/dev/tty
}

gen_reality_keys() {
    log_info "$(msg gen_keys)"
    local KEYS
    KEYS="$("$XRAY_BIN" x25519)"

    # 提取私钥 (支持 "PrivateKey: xxx" 格式)
    PRIVATE_KEY="$(echo "$KEYS" | awk -F'[: ]+' '/PrivateKey|Private key/ {print $2}')"

    # 提取公钥 (支持 "Password: xxx" 或 "PublicKey: xxx" 格式)
    # 某些 xray 版本输出 "Password" 而不是 "Public key"
    PUBLIC_KEY="$(echo "$KEYS" | awk -F'[: ]+' '/Password|Public key|PublicKey/ {print $2}')"

    SHORT_ID="$(openssl rand -hex 4)"

    # 验证密钥
    if [[ -z "$PRIVATE_KEY" ]]; then
        log_error "Failed to extract private key"
        log_error "Xray output: $KEYS"
        return 1
    fi

    if [[ -z "$PUBLIC_KEY" ]]; then
        log_error "Failed to extract public key"
        log_error "Xray output: $KEYS"
        return 1
    fi

    log_info "Keys generated successfully"
}

# 验证 IPv4 地址格式
is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" -le 255 ]] || return 1
    done
    return 0
}

# 验证 IPv6 地址格式
is_valid_ipv6() {
    local ip="$1"
    # 简单验证：包含冒号且不包含非法字符
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *:* ]]
}

# 全局 IP 变量
SERVER_IPV4=""
SERVER_IPV6=""

# 获取 IPv4 地址
get_ipv4() {
    local ip
    ip=$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi
    ip=$(curl -s4 --max-time 3 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi
    echo ""
}

# 获取 IPv6 地址
get_ipv6() {
    local ip
    ip=$(curl -s6 --max-time 3 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv6 "$ip"; then
        echo "$ip"
        return 0
    fi
    ip=$(curl -s6 --max-time 3 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv6 "$ip"; then
        echo "$ip"
        return 0
    fi
    echo ""
}

# 检测网络栈类型
detect_network_stack() {
    log_info "$(msg detecting_ip)"

    SERVER_IPV4=$(get_ipv4)
    SERVER_IPV6=$(get_ipv6)

    if [[ -n "$SERVER_IPV4" ]] && [[ -n "$SERVER_IPV6" ]]; then
        log_info "Dual-Stack detected: IPv4=$SERVER_IPV4, IPv6=$SERVER_IPV6"
    elif [[ -n "$SERVER_IPV4" ]]; then
        log_info "IPv4 Only: $SERVER_IPV4"
    elif [[ -n "$SERVER_IPV6" ]]; then
        log_info "IPv6 Only: $SERVER_IPV6"
    else
        log_warn "Could not detect server IP automatically"
        SERVER_IPV4="YOUR_SERVER_IP"
    fi
}

# 并行获取服务器 IP 地址 (向后兼容)
get_server_ip_parallel() {
    local result_file pids=()
    result_file=$(mktemp)

    # IP 检测 API 列表
    local apis=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
    )

    # 并行请求所有 API
    for api in "${apis[@]}"; do
        (
            ip=$(curl -s --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]')
            if is_valid_ipv4 "$ip"; then
                echo "$ip" >> "$result_file"
            fi
        ) &
        pids+=($!)
    done

    # 等待第一个有效结果（最多 5 秒）
    local i=0
    while [[ $i -lt 50 ]]; do
        if [[ -s "$result_file" ]]; then
            local ip
            ip=$(head -n1 "$result_file")
            # 终止所有后台进程
            for pid in "${pids[@]}"; do
                kill "$pid" 2>/dev/null || true
            done
            wait 2>/dev/null || true
            rm -f "$result_file"
            echo "$ip"
            return 0
        fi
        sleep 0.1
        ((i++))
    done

    # 超时后清理
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true

    # 检查是否有结果
    if [[ -s "$result_file" ]]; then
        local ip
        ip=$(head -n1 "$result_file")
        rm -f "$result_file"
        echo "$ip"
        return 0
    fi

    rm -f "$result_file"
    echo "YOUR_SERVER_IP"
}

# 保存延迟缓存
save_latency_cache() {
    local -n cache_map=$1
    {
        echo "# timestamp: $(date +%s)"
        for domain in "${!cache_map[@]}"; do
            echo "$domain ${cache_map[$domain]}"
        done
    } > "$CACHE_FILE"
}

# 加载延迟缓存
# 返回 0 表示加载成功且缓存有效，返回 1 表示缓存无效或不存在
load_latency_cache() {
    local -n cache_map=$1

    # 检查缓存文件是否存在
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi

    # 读取时间戳并检查是否过期
    local timestamp
    timestamp=$(grep "^# timestamp:" "$CACHE_FILE" 2>/dev/null | awk '{print $3}')
    if [[ -z "$timestamp" ]]; then
        return 1
    fi

    local current_time
    current_time=$(date +%s)
    if (( current_time - timestamp > CACHE_TTL )); then
        return 1
    fi

    # 加载缓存数据
    while IFS=' ' read -r domain latency; do
        # 跳过注释行和空行
        [[ "$domain" =~ ^#.*$ || -z "$domain" ]] && continue
        cache_map["$domain"]=$latency
    done < "$CACHE_FILE"

    # 检查是否成功加载了数据
    if [[ ${#cache_map[@]} -eq 0 ]]; then
        return 1
    fi

    return 0
}

# 测试单个域名延迟
test_domain_latency() {
    local domain="$1"
    local t1 t2
    t1=$(date +%s%3N)
    if timeout 2 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null &>/dev/null; then
        t2=$(date +%s%3N)
        echo "$((t2 - t1))"
    else
        echo "9999"
    fi
}

# 测试单个域名并将结果写入文件（用于并行执行）
test_domain_to_file() {
    local domain="$1"
    local result_dir="$2"
    local latency
    latency=$(test_domain_latency "$domain")
    echo "$latency" > "${result_dir}/${domain}"
}

# 并行测试所有域名
# 参数1: 关联数组名称（用于存储结果）
# 设置全局变量 BEST_LATENCY 为最低延迟值
test_domains_parallel() {
    local -n _latency_map=$1
    local total=${#SNI_LIST[@]}
    local max_jobs=30
    local result_dir
    result_dir=$(mktemp -d)

    # 创建标记文件表示测试进行中
    local progress_flag="${result_dir}/.in_progress"
    touch "$progress_flag"

    # 清空结果数组
    _latency_map=()

    echo ""
    echo -e "${CYAN}$(msg testing)${NC}"

    # 启动进度显示后台进程
    (
        while [[ -f "$progress_flag" ]]; do
            local completed
            completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
            local percent=$((completed * 100 / total))
            printf "\r[%-50s] %d%% (%d/%d)          " \
                "$(printf '#%.0s' $(seq 1 $((percent / 2))))" \
                "$percent" "$completed" "$total"
            sleep 0.5
        done
    ) &
    local progress_pid=$!

    # 并行执行测试
    local running=0
    for domain in "${SNI_LIST[@]}"; do
        # 控制并发数
        while [[ $running -ge $max_jobs ]]; do
            wait -n 2>/dev/null || true
            running=$((running - 1))
        done

        # 启动后台任务
        test_domain_to_file "$domain" "$result_dir" &
        running=$((running + 1))
    done

    # 等待所有测试任务完成（不等待进度显示进程）
    # 通过检查结果文件数量来判断是否完成
    while true; do
        local completed
        completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
        if [[ "$completed" -ge "$total" ]]; then
            break
        fi
        sleep 0.2
    done

    # 停止进度显示（先删除 flag 让进程退出）
    rm -f "$progress_flag"
    sleep 0.3
    kill $progress_pid 2>/dev/null || true
    wait $progress_pid 2>/dev/null || true

    # 显示最终进度
    printf "\r[%-50s] %d%% (%d/%d)          \n" \
        "$(printf '#%.0s' $(seq 1 50))" \
        "100" "$total" "$total"

    # 读取结果到关联数组
    local best_latency=9999
    for domain in "${SNI_LIST[@]}"; do
        local result_file="${result_dir}/${domain}"
        if [[ -f "$result_file" ]]; then
            local latency
            latency=$(cat "$result_file")
            # 验证 latency 是有效整数
            if [[ "$latency" =~ ^[0-9]+$ ]] && [[ "$latency" -ne 9999 ]]; then
                _latency_map["$domain"]=$latency
                if [[ "$latency" -lt "$best_latency" ]]; then
                    best_latency=$latency
                fi
            fi
        fi
    done

    # 清理临时目录
    rm -rf "$result_dir"

    echo ""

    # 返回最佳延迟值（通过全局变量）
    BEST_LATENCY=$best_latency
}

# 并行测试所有域名（带详细输出，用于 cmd_test_sni）
# 参数1: 关联数组名称（用于存储结果）
test_domains_parallel_verbose() {
    local -n _latency_map_v=$1
    local total=${#SNI_LIST[@]}
    local max_jobs=30
    local result_dir
    result_dir=$(mktemp -d)

    # 创建标记文件表示测试进行中
    local progress_flag="${result_dir}/.in_progress"
    touch "$progress_flag"

    # 清空结果数组
    _latency_map_v=()

    # 启动进度显示后台进程
    (
        while [[ -f "$progress_flag" ]]; do
            local completed
            completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
            local percent=$((completed * 100 / total))
            printf "\r${CYAN}$(msg testing)${NC} [%-50s] %d%% (%d/%d)          " \
                "$(printf '#%.0s' $(seq 1 $((percent / 2))))" \
                "$percent" "$completed" "$total"
            sleep 0.5
        done
    ) &
    local progress_pid=$!

    # 并行执行测试
    local running=0
    for domain in "${SNI_LIST[@]}"; do
        # 控制并发数
        while [[ $running -ge $max_jobs ]]; do
            wait -n 2>/dev/null || true
            running=$((running - 1))
        done

        # 启动后台任务
        test_domain_to_file "$domain" "$result_dir" &
        running=$((running + 1))
    done

    # 等待所有测试任务完成（不等待进度显示进程）
    while true; do
        local completed
        completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
        if [[ "$completed" -ge "$total" ]]; then
            break
        fi
        sleep 0.2
    done

    # 停止进度显示（先删除 flag 让进程退出）
    rm -f "$progress_flag"
    sleep 0.3
    kill $progress_pid 2>/dev/null || true
    wait $progress_pid 2>/dev/null || true

    # 清除进度行
    printf "\r%-80s\r" " "

    # 读取结果并显示详细信息
    local idx=0
    for domain in "${SNI_LIST[@]}"; do
        idx=$((idx + 1))
        local result_file="${result_dir}/${domain}"
        if [[ -f "$result_file" ]]; then
            local latency
            latency=$(cat "$result_file")
            # 验证 latency 是有效整数
            if [[ ! "$latency" =~ ^[0-9]+$ ]] || [[ "$latency" -eq 9999 ]]; then
                printf "[%3d/%3d] ${RED}%-50s $(msg timeout)${NC}\n" "$idx" "$total" "$domain"
            else
                printf "[%3d/%3d] ${GREEN}%-50s %dms${NC}\n" "$idx" "$total" "$domain" "$latency"
                _latency_map_v["$domain"]=$latency
            fi
        fi
    done

    # 清理临时目录
    rm -rf "$result_dir"
}

# 动态选择最低延迟的 SNI（测试所有域名）
select_best_sni() {
    local total=${#SNI_LIST[@]}
    declare -A latency_map
    local best_latency=9999
    local cache_loaded=0

    # 尝试加载缓存
    if load_latency_cache latency_map; then
        cache_loaded=1
        log_info "Using cached SNI latency results (valid for $((CACHE_TTL / 60)) minutes)"
        # 从缓存计算最低延迟
        for domain in "${!latency_map[@]}"; do
            if [[ "${latency_map[$domain]}" -lt "$best_latency" ]]; then
                best_latency="${latency_map[$domain]}"
            fi
        done
    else
        # 缓存无效，执行并行测试
        log_info "$(msg testing_sni) ($(msg total_domains): $total)"

        # 使用并行测试
        test_domains_parallel latency_map
        best_latency=$BEST_LATENCY

        # 保存测试结果到缓存
        if [[ ${#latency_map[@]} -gt 0 ]]; then
            save_latency_cache latency_map
        fi
    fi

    # 检查是否有可用域名
    if [[ ${#latency_map[@]} -eq 0 ]]; then
        log_warn "$(msg sni_timeout)"
        # 即使测试失败也让用户选择
        prompt_sni_choice "" ""
        return
    fi

    # 获取排序后的 Top 5 域名
    local top_domains=()
    local top_latencies=()
    while IFS=' ' read -r lat dom; do
        top_domains+=("$dom")
        top_latencies+=("$lat")
    done < <(for domain in "${!latency_map[@]}"; do
        echo "${latency_map[$domain]} $domain"
    done | sort -n | head -5)

    # 让用户选择 SNI
    prompt_sni_choice top_domains top_latencies
}

# 让用户选择 SNI 的交互函数
# 参数1: top_domains 数组名称
# 参数2: top_latencies 数组名称
prompt_sni_choice() {
    local -n _top_domains=$1 2>/dev/null || true
    local -n _top_latencies=$2 2>/dev/null || true
    local has_results=false

    if [[ ${#_top_domains[@]} -gt 0 ]] 2>/dev/null; then
        has_results=true
    fi

    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg sni_selection_title)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    if $has_results; then
        echo -e "  ${BLUE}$(msg sni_top_results):${NC}"
        echo ""
        local i=1
        for idx in "${!_top_domains[@]}"; do
            printf "    ${GREEN}%d.${NC} %-40s ${YELLOW}%dms${NC}\n" "$i" "${_top_domains[$idx]}" "${_top_latencies[$idx]}"
            ((i++))
        done
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${GREEN}A.${NC} $(msg sni_auto_select) (${_top_domains[0]})"
        echo -e "  ${GREEN}M.${NC} $(msg sni_manual_input)"
        echo ""
        echo -n "  $(msg sni_choice_prompt) [A/1-5/M]: "
    else
        echo -e "  ${YELLOW}$(msg sni_no_results)${NC}"
        echo ""
        echo -e "  ${GREEN}D.${NC} $(msg sni_use_default) (www.tesla.com)"
        echo -e "  ${GREEN}M.${NC} $(msg sni_manual_input)"
        echo ""
        echo -n "  $(msg sni_choice_prompt) [D/M]: "
    fi
    } >/dev/tty

    read -r choice </dev/tty

    # 处理用户选择
    choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

    if $has_results; then
        case "$choice" in
            A|"")
                # 自动选择最佳
                SNI="${_top_domains[0]}"
                log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${_top_latencies[0]}ms)"
                ;;
            1|2|3|4|5)
                # 从 Top 5 中选择
                local idx=$((choice - 1))
                if [[ $idx -lt ${#_top_domains[@]} ]]; then
                    SNI="${_top_domains[$idx]}"
                    log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${_top_latencies[$idx]}ms)"
                else
                    SNI="${_top_domains[0]}"
                    log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${_top_latencies[0]}ms)"
                fi
                ;;
            M)
                # 手动输入
                prompt_custom_sni
                ;;
            *)
                # 默认自动选择
                SNI="${_top_domains[0]}"
                log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${_top_latencies[0]}ms)"
                ;;
        esac
    else
        case "$choice" in
            D|"")
                SNI="www.tesla.com"
                log_info "$(msg sni_use_default): ${SNI}"
                ;;
            M)
                prompt_custom_sni
                ;;
            *)
                SNI="www.tesla.com"
                log_info "$(msg sni_use_default): ${SNI}"
                ;;
        esac
    fi
}

# 提示用户输入自定义 SNI
prompt_custom_sni() {
    {
    echo ""
    echo -e "  ${CYAN}$(msg sni_input_hint)${NC}"
    echo -n "  SNI: "
    } >/dev/tty

    read -r custom_sni </dev/tty

    # 清理输入（移除空格和协议前缀）
    custom_sni=$(echo "$custom_sni" | sed 's/^https\?:\/\///' | sed 's/\/.*$//' | tr -d '[:space:]')

    if [[ -z "$custom_sni" ]]; then
        SNI="www.tesla.com"
        log_warn "$(msg sni_empty_input), $(msg sni_use_default): ${SNI}"
    else
        # 验证域名格式
        if [[ "$custom_sni" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
            SNI="$custom_sni"
            log_info "$(msg sni_custom_set): ${SNI}"

            # 可选：测试自定义域名连通性
            echo -e "  ${CYAN}$(msg sni_testing_custom)...${NC}" >/dev/tty
            if timeout 3 openssl s_client -connect "${SNI}:443" -servername "$SNI" </dev/null &>/dev/null; then
                log_info "$(msg sni_custom_ok)"
            else
                log_warn "$(msg sni_custom_unreachable)"
            fi
        else
            log_warn "$(msg sni_invalid_format), $(msg sni_use_default)"
            SNI="www.tesla.com"
        fi
    fi
}

# 验证 Xray 配置文件有效性
validate_xray_config() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        log_error "Config file not found: $XRAY_CONF"
        return 1
    fi

    # 检查文件不为空
    if [[ ! -s "$XRAY_CONF" ]]; then
        log_error "Config file is empty"
        return 1
    fi

    # 检查 JSON 有效性
    if ! jq . "$XRAY_CONF" > /dev/null 2>&1; then
        log_error "Config file contains invalid JSON"
        return 1
    fi

    # 如果 xray 可用，使用 xray -test 验证
    if command -v "$XRAY_BIN" &>/dev/null; then
        local test_output
        if ! test_output=$("$XRAY_BIN" -test -config "$XRAY_CONF" 2>&1); then
            log_error "Xray config test failed: $test_output"
            return 1
        fi
    fi

    return 0
}

write_config() {
    mkdir -p /usr/local/etc/xray

    # 构建 inbounds 数组
    local inbounds_json="[]"

    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue

        # 使用安全的配置读取方式（防止命令注入）
        local n_name n_port n_uuid n_sni n_private_key n_short_id n_xhttp_port n_xhttp_path n_protocol_type
        local n_ss_method n_ss_password
        n_name=$(safe_read_config_value "$node_file" "NODE_NAME")
        n_port=$(safe_read_config_value "$node_file" "PORT")
        n_uuid=$(safe_read_config_value "$node_file" "UUID")
        n_sni=$(safe_read_config_value "$node_file" "SNI")
        n_private_key=$(safe_read_config_value "$node_file" "PRIVATE_KEY")
        n_short_id=$(safe_read_config_value "$node_file" "SHORT_ID")
        n_xhttp_port=$(safe_read_config_value "$node_file" "XHTTP_PORT")
        n_xhttp_path=$(safe_read_config_value "$node_file" "XHTTP_PATH")
        n_protocol_type=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")
        n_ss_method=$(safe_read_config_value "$node_file" "SS_METHOD")
        n_ss_password=$(safe_read_config_value "$node_file" "SS_PASSWORD")

        # 处理可能加密的敏感值
        n_private_key=$(decrypt_value "$n_private_key")
        n_uuid=$(decrypt_value "$n_uuid")
        n_ss_password=$(decrypt_value "$n_ss_password")

        # 向后兼容：旧配置没有 PROTOCOL_TYPE，根据端口判断
        if [[ -z "$n_protocol_type" ]]; then
            if [[ -n "$n_port" ]] && [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="both"
            elif [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="xhttp"
            else
                n_protocol_type="vision"
            fi
        fi

        # 跳过无效节点（VLESS 需要 UUID，Shadowsocks 需要密码）
        if [[ "$n_protocol_type" == "shadowsocks" ]]; then
            [[ -z "$n_ss_password" ]] && continue
        else
            [[ -z "$n_uuid" ]] && continue
        fi

        # 添加 Shadowsocks inbound
        if [[ "$n_protocol_type" == "shadowsocks" ]] && [[ -n "$n_port" ]] && [[ -n "$n_ss_method" ]] && [[ -n "$n_ss_password" ]]; then
            local validated_port
            validated_port=$(get_validated_port "$n_port" true)
            if [[ -z "$validated_port" ]]; then
                log_warn "Invalid Shadowsocks port for node '$n_name', skipping"
                continue
            fi

            local ss_inbound
            ss_inbound=$(build_shadowsocks_inbound "$n_name" "$validated_port" "$n_ss_method" "$n_ss_password")
            if [[ -z "$ss_inbound" ]]; then
                log_error "Failed to build Shadowsocks inbound for node '$n_name'"
                return 1
            fi

            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$ss_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add Shadowsocks inbound for node '$n_name': $new_inbounds"
                return 1
            fi
            continue  # Shadowsocks 节点处理完毕，跳过 VLESS 处理
        fi

        # 添加 Vision inbound（如果协议类型包含 vision）
        if [[ "$n_protocol_type" == "vision" || "$n_protocol_type" == "both" ]] && [[ -n "$n_port" ]]; then
            # 验证端口（安全检查）
            local validated_port
            validated_port=$(get_validated_port "$n_port" true)
            if [[ -z "$validated_port" ]]; then
                log_warn "Invalid Vision port for node '$n_name', skipping"
                continue
            fi

            # 使用安全的 JSON 构建器（防止注入）
            local vision_inbound
            vision_inbound=$(build_vision_inbound "$n_name" "$validated_port" "$n_uuid" "$n_sni" "$n_private_key" "$n_short_id")
            if [[ -z "$vision_inbound" ]]; then
                log_error "Failed to build Vision inbound for node '$n_name'"
                return 1
            fi

            # 使用临时变量和错误检查来防止 jq 失败导致脚本退出
            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$vision_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add Vision inbound for node '$n_name': $new_inbounds"
                return 1
            fi
        fi

        # 添加 XHTTP inbound（如果协议类型包含 xhttp）
        if [[ "$n_protocol_type" == "xhttp" || "$n_protocol_type" == "both" ]] && [[ -n "$n_xhttp_port" ]] && [[ -n "$n_xhttp_path" ]]; then
            # 验证端口（安全检查）
            local validated_xhttp_port
            validated_xhttp_port=$(get_validated_port "$n_xhttp_port" true)
            if [[ -z "$validated_xhttp_port" ]]; then
                log_warn "Invalid XHTTP port for node '$n_name', skipping"
                continue
            fi

            # 使用安全的 JSON 构建器（防止注入）
            local xhttp_inbound
            xhttp_inbound=$(build_xhttp_inbound "$n_name" "$validated_xhttp_port" "$n_uuid" "$n_sni" "$n_private_key" "$n_short_id" "$n_xhttp_path")
            if [[ -z "$xhttp_inbound" ]]; then
                log_error "Failed to build XHTTP inbound for node '$n_name'"
                return 1
            fi

            # 使用临时变量和错误检查来防止 jq 失败导致脚本退出
            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$xhttp_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add XHTTP inbound for node '$n_name': $new_inbounds"
                return 1
            fi
        fi
    done

    # 构建 outbounds
    local outbounds_json='[{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}]'

    # 检查是否有 WARP 代理
    if check_warp_running; then
        local warp_outbound='{"tag": "warp_proxy", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": '$WARP_SOCKS_PORT'}]}}'
        local new_outbounds
        if new_outbounds=$(echo "$outbounds_json" | jq --argjson outbound "$warp_outbound" '. += [$outbound]' 2>&1); then
            outbounds_json="$new_outbounds"
        else
            log_error "Failed to add WARP outbound: $new_outbounds"
            return 1
        fi
    fi

    # 构建路由规则
    local routing_json
    routing_json=$(cat <<EOF
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
  ]
}
EOF
)

    # 检查并添加 WARP 分流规则
    if [[ -f "/root/.warp_netflix" ]] && check_warp_running; then
        local new_routing
        if new_routing=$(echo "$routing_json" | jq '.rules = [{"type": "field", "domain": ["geosite:netflix"], "outboundTag": "warp_proxy"}] + .rules' 2>&1); then
            routing_json="$new_routing"
        else
            log_warn "Failed to add Netflix routing rule: $new_routing"
        fi
    fi
    if [[ -f "/root/.warp_ai" ]] && check_warp_running; then
        local new_routing
        if new_routing=$(echo "$routing_json" | jq '.rules = [{"type": "field", "domain": ["geosite:openai", "geosite:anthropic"], "outboundTag": "warp_proxy"}] + .rules' 2>&1); then
            routing_json="$new_routing"
        else
            log_warn "Failed to add AI routing rule: $new_routing"
        fi
    fi

    # 组装最终配置
    local config_json
    if ! config_json=$(jq -n \
        --argjson inbounds "$inbounds_json" \
        --argjson outbounds "$outbounds_json" \
        --argjson routing "$routing_json" \
        '{
            "log": {"loglevel": "warning"},
            "inbounds": $inbounds,
            "outbounds": $outbounds,
            "routing": $routing
        }' 2>&1); then
        log_error "Failed to assemble final config: $config_json"
        return 1
    fi

    echo "$config_json" > "$XRAY_CONF"

    # 验证配置文件有效性
    if ! validate_xray_config; then
        log_error "Generated config is invalid"
        return 1
    fi

    return 0
}

# 检查 WARP 是否运行
check_warp_running() {
    (echo > /dev/tcp/127.0.0.1/$WARP_SOCKS_PORT) 2>/dev/null
}

save_env() {
    init_nodes_dir

    # 使用节点名称或端口作为文件名
    local node_name="${CURRENT_NODE_NAME:-$PORT}"
    local node_file
    node_file=$(get_node_file "$node_name")

    # 使用检测到的 IP（优先使用 SERVER_IPV4，向后兼容 SERVER_IP）
    local save_ipv4="${SERVER_IPV4:-$SERVER_IP}"
    local save_ipv6="${SERVER_IPV6:-}"

    # Optional: encrypt sensitive values if encryption is enabled
    local save_uuid="$UUID"
    local save_private_key="$PRIVATE_KEY"
    local save_ss_password="${SS_PASSWORD:-}"

    if is_encryption_enabled; then
        save_uuid=$(encrypt_value "$UUID")
        save_private_key=$(encrypt_value "$PRIVATE_KEY")
        [[ -n "$save_ss_password" ]] && save_ss_password=$(encrypt_value "$SS_PASSWORD")
    fi

    cat > "$node_file" <<ENV
NODE_NAME=$node_name
SERVER_IP=${save_ipv4:-YOUR_SERVER_IP}
SERVER_IPV4=${save_ipv4:-}
SERVER_IPV6=${save_ipv6:-}
PORT=${PORT:-}
UUID=$save_uuid
SNI=$SNI
PUBLIC_KEY=$PUBLIC_KEY
PRIVATE_KEY=$save_private_key
SHORT_ID=$SHORT_ID
PROTOCOL_TYPE=${PROTOCOL_TYPE:-vision}
XHTTP_PORT=${XHTTP_PORT:-}
XHTTP_PATH=${XHTTP_PATH:-}
SS_METHOD=${SS_METHOD:-}
SS_PASSWORD=$save_ss_password
ENV
    chmod 600 "$node_file"

    CURRENT_NODE_NAME="$node_name"
}

# 生成 Vision 分享链接
get_vision_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    echo "vless://${UUID}@${ip_formatted}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${node_label}"
}

# 生成 XHTTP 分享链接
get_xhttp_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    # 注意：XHTTP 不需要 flow 参数，path 需要 URL 编码
    local encoded_path
    encoded_path=$(echo -n "$XHTTP_PATH" | sed 's|/|%2F|g')
    echo "vless://${UUID}@${ip_formatted}:${XHTTP_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=xhttp&path=${encoded_path}&sni=${SNI}&sid=${SHORT_ID}#${node_label}"
}

# 生成 Shadowsocks 分享链接
# 格式: ss://BASE64(method:password)@host:port#name
get_ss_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    # SS 链接格式: ss://BASE64(method:password)@server:port#tag
    local userinfo
    userinfo=$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0)
    echo "ss://${userinfo}@${ip_formatted}:${PORT}#${node_label}"
}

# 向后兼容的获取分享链接函数
get_share_link() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    # 使用安全的配置加载（防止命令注入）
    safe_load_node_config "$node_file"
    local node_label="${NODE_NAME:-RV-Reality}"
    local ip="${SERVER_IPV4:-$SERVER_IP}"
    local proto_type="${PROTOCOL_TYPE:-vision}"

    # 根据协议类型返回对应的链接
    if [[ "$proto_type" == "shadowsocks" ]] && [[ -n "${SS_PASSWORD:-}" ]]; then
        # Shadowsocks 节点
        get_ss_link "$ip" "${node_label}_SS"
    elif [[ "$proto_type" == "xhttp" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
        # XHTTP-only 节点
        get_xhttp_link "$ip" "${node_label}_XHTTP"
    elif [[ -n "${PORT:-}" ]]; then
        # Vision 节点或 both 节点（优先显示 Vision）
        get_vision_link "$ip" "$node_label"
    elif [[ -n "${XHTTP_PORT:-}" ]]; then
        # 后备：如果没有 Vision 端口，使用 XHTTP
        get_xhttp_link "$ip" "${node_label}_XHTTP"
    else
        echo ""
    fi
}

show_qrcode() {
    local link="$1"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    $(msg qr_title)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$link"
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}$(msg share_link):${NC}"
    echo -e "${YELLOW}$link${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${MAGENTA}$(msg qr_tip)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

show_info() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    # 使用安全的配置加载（防止命令注入）
    safe_load_node_config "$node_file"

    local hostname
    hostname=$(hostname 2>/dev/null || echo "server")

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg node_info)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BLUE}Node Name:${NC}   ${NODE_NAME:-$CURRENT_NODE_NAME}"
    if [[ -n "${SERVER_IPV4:-}" ]]; then
        echo -e "  ${BLUE}IPv4:${NC}        $SERVER_IPV4"
    fi
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        echo -e "  ${BLUE}IPv6:${NC}        $SERVER_IPV6"
    fi
    if [[ -z "${SERVER_IPV4:-}" ]] && [[ -z "${SERVER_IPV6:-}" ]]; then
        echo -e "  ${BLUE}$(msg server_addr):${NC} ${SERVER_IP:-N/A}"
    fi

    local proto_type="${PROTOCOL_TYPE:-both}"

    # Shadowsocks 节点显示不同信息
    if [[ "$proto_type" == "shadowsocks" ]]; then
        echo -e "  ${BLUE}Port:${NC}        ${PORT:-N/A}"
        echo -e "  ${BLUE}Method:${NC}      ${SS_METHOD:-N/A}"
        echo -e "  ${BLUE}Password:${NC}    ${SS_PASSWORD:-N/A}"
        echo -e "  ${BLUE}协议类型:${NC}    Shadowsocks"
        echo ""

        # Shadowsocks IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Shadowsocks:${NC}"
            echo -e "  $(get_ss_link "$SERVER_IPV4" "${hostname}_SS_v4")"
        fi

        # Shadowsocks IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Shadowsocks:${NC}"
            echo -e "  $(get_ss_link "$SERVER_IPV6" "${hostname}_SS_v6")"
        fi
    else
        # VLESS 节点显示
        # 根据协议类型显示端口
        if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
            echo -e "  ${BLUE}$(msg vision_port):${NC}  $PORT"
        fi
        if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
            echo -e "  ${BLUE}$(msg xhttp_port):${NC}   $XHTTP_PORT"
        fi
        echo -e "  ${BLUE}UUID:${NC}        $UUID"
        echo -e "  ${BLUE}SNI:${NC}         $SNI"
        echo -e "  ${BLUE}PublicKey:${NC}   $PUBLIC_KEY"
        echo -e "  ${BLUE}ShortID:${NC}     $SHORT_ID"
        echo -e "  ${BLUE}协议类型:${NC}    $proto_type"
        echo ""

        # IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            # Vision 链接
            if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
                echo -e "  ${YELLOW}Vision:${NC}"
                echo -e "  $(get_vision_link "$SERVER_IPV4" "${hostname}_Vision_v4")"
            fi
            # XHTTP 链接
            if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
                echo ""
                echo -e "  ${YELLOW}XHTTP:${NC}"
                echo -e "  $(get_xhttp_link "$SERVER_IPV4" "${hostname}_XHTTP_v4")"
            fi
        fi

        # IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            # Vision 链接
            if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
                echo -e "  ${YELLOW}Vision:${NC}"
                echo -e "  $(get_vision_link "$SERVER_IPV6" "${hostname}_Vision_v6")"
            fi
            # XHTTP 链接
            if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
                echo ""
                echo -e "  ${YELLOW}XHTTP:${NC}"
                echo -e "  $(get_xhttp_link "$SERVER_IPV6" "${hostname}_XHTTP_v6")"
            fi
        fi
    fi

    # 向后兼容：如果没有 IPv4/IPv6，使用旧的 SERVER_IP
    if [[ -z "${SERVER_IPV4:-}" ]] && [[ -z "${SERVER_IPV6:-}" ]] && [[ -n "${SERVER_IP:-}" ]]; then
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "${GREEN}$(msg share_link):${NC}"
        if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
            echo -e "${YELLOW}$(get_vision_link "$SERVER_IP" "${NODE_NAME:-RV-Reality}")${NC}"
        elif [[ "$proto_type" == "xhttp" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
            echo -e "${YELLOW}$(get_xhttp_link "$SERVER_IP" "${NODE_NAME:-RV-Reality}_XHTTP")${NC}"
        fi
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

cmd_install() {
    if ! is_root; then
        log_error "$(msg run_as_root)"
        return 1
    fi

    log_info "$(msg installing)"

    install_deps
    install_xray
    install_geodata

    # 交互式输入节点名称（或使用环境变量 name=xxx）
    if [[ -n "${name:-}" ]]; then
        CURRENT_NODE_NAME="$name"
        # 如果名称已存在，添加后缀
        local base_name="$CURRENT_NODE_NAME"
        local counter=1
        while node_exists "$CURRENT_NODE_NAME"; do
            CURRENT_NODE_NAME="${base_name}_${counter}"
            ((counter++))
        done
    else
        CURRENT_NODE_NAME=$(prompt_node_name)
    fi
    log_info "Node name: $CURRENT_NODE_NAME"

    # 选择协议类型（除非通过环境变量指定）
    if [[ -n "${proto:-}" ]]; then
        # 支持环境变量 proto=vision/xhttp/both/shadowsocks/ss
        case "$proto" in
            xhttp) PROTOCOL_TYPE="xhttp" ;;
            both) PROTOCOL_TYPE="both" ;;
            shadowsocks|ss) PROTOCOL_TYPE="shadowsocks" ;;
            *) PROTOCOL_TYPE="vision" ;;
        esac
        log_info "协议类型: $PROTOCOL_TYPE"
    elif [[ -n "${xhttp:-}" ]]; then
        # 向后兼容: xhttp=true 等同于 proto=both
        if [[ "$xhttp" == "true" ]] || [[ "$xhttp" == "1" ]] || [[ "$xhttp" == "y" ]]; then
            PROTOCOL_TYPE="both"
            log_info "协议类型: both (Vision + XHTTP)"
        fi
    else
        prompt_protocol_type
    fi

    # Shadowsocks 和 VLESS 的安装流程不同
    if [[ "$PROTOCOL_TYPE" == "shadowsocks" ]]; then
        # Shadowsocks 安装流程
        # 选择加密方式（或使用环境变量 ssmethod=xxx）
        if [[ -n "${ssmethod:-}" ]]; then
            SS_METHOD="$ssmethod"
            log_info "加密方式: $SS_METHOD"
        else
            prompt_ss_method
        fi

        # 生成密码（或使用环境变量 sspwd=xxx）
        if [[ -n "${sspwd:-}" ]]; then
            SS_PASSWORD="$sspwd"
            log_info "使用指定密码"
        else
            gen_ss_password
        fi

        # 选择端口
        choose_ports

        # SS 不需要 SNI, UUID, Reality Keys
        SNI=""
        UUID=""
        PUBLIC_KEY=""
        PRIVATE_KEY=""
        SHORT_ID=""
    else
        # VLESS 安装流程
        # 安装时清除 SNI 缓存，强制重新测试
        rm -f "$CACHE_FILE" 2>/dev/null

        if [[ -n "${reym:-}" ]]; then
            SNI="$reym"
            log_info "$(msg using_sni): $SNI"
        else
            select_best_sni
        fi

        gen_uuid
        choose_ports
        gen_reality_keys
    fi

    # 检测双栈 IP
    detect_network_stack

    save_env

    # 生成配置文件，如果失败则回滚
    if ! write_config; then
        log_error "Failed to generate Xray config, rolling back..."
        # 删除刚保存的节点配置
        local node_file
        node_file=$(get_node_file "$CURRENT_NODE_NAME")
        rm -f "$node_file" 2>/dev/null
        return 1
    fi

    service_enable xray
    service_restart xray

    # 验证服务启动成功
    sleep 1
    if ! service_is_active xray; then
        log_warn "Xray service may not have started correctly. Run 'xray health' to check."
    fi

    log_info "$(msg install_complete)"

    show_info

    # 显示主要链接的二维码
    local link
    link=$(get_share_link)
    show_qrcode "$link"
}

cmd_info() {
    select_node || return 1
    show_info
}

cmd_qr() {
    select_node || return 1

    if ! command -v qrencode &>/dev/null; then
        log_info "$(msg install_deps)"
        $PKG_UPDATE >/dev/null 2>&1 || true
        $PKG_INSTALL qrencode >/dev/null 2>&1
    fi

    local link
    link=$(get_share_link)
    show_qrcode "$link"
}

# 列出所有节点
cmd_list() {
    local nodes
    read -ra nodes <<< "$(list_nodes)"

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_error "$(msg config_not_found)"
        return 1
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     All Nodes / 所有节点${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local i=1
    for node in "${nodes[@]}"; do
        local node_file
        node_file=$(get_node_file "$node")
        # 使用安全的配置加载（防止命令注入）
        safe_load_node_config "$node_file"
        # 根据协议类型显示对应的端口
        local display_port=""
        local proto="${PROTOCOL_TYPE:-vision}"
        if [[ "$proto" == "shadowsocks" ]]; then
            display_port="${PORT:-N/A}"
        elif [[ "$proto" == "xhttp" ]]; then
            display_port="${XHTTP_PORT:-N/A}"
        elif [[ "$proto" == "both" ]]; then
            display_port="${PORT:-}/${XHTTP_PORT:-}"
        else
            display_port="${PORT:-N/A}"
        fi
        echo -e "  ${GREEN}$i.${NC} ${BLUE}$node${NC}"
        if [[ "$proto" == "shadowsocks" ]]; then
            echo -e "     Port: $display_port | Method: ${SS_METHOD:-N/A}"
            echo -e "     Password: ${SS_PASSWORD:0:12}..."
        else
            echo -e "     Port: $display_port | SNI: $SNI"
            echo -e "     UUID: ${UUID:0:8}..."
            if [[ -n "$XHTTP_PORT" ]] && [[ "$proto" != "vision" ]]; then
                echo -e "     XHTTP: $XHTTP_PORT"
            fi
        fi
        echo ""
        ((i++))
    done

    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

cmd_status() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg service_status)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    if service_is_active xray; then
        echo -e "  Xray: ${GREEN}● Running${NC}"
    else
        echo -e "  Xray: ${RED}○ Stopped${NC}"
    fi

    local node_count
    node_count=$(count_nodes)
    echo -e "  Nodes: ${GREEN}${node_count}${NC}"

    # 显示每个节点的连接数
    if [[ $node_count -gt 0 ]]; then
        echo ""
        echo -e "  ${BLUE}Active connections:${NC}"
        for node_file in "$NODES_DIR"/*.env; do
            [[ -f "$node_file" ]] || continue
            local n_name n_port
            n_name=$(basename "$node_file" .env)
            n_port=$(grep "^PORT=" "$node_file" | cut -d= -f2)
            local conn_count
            conn_count=$(ss -tn state established "( sport = :${n_port} )" 2>/dev/null | tail -n +2 | wc -l)
            echo -e "    $n_name (Port $n_port): ${GREEN}${conn_count}${NC}"
        done
    fi

    echo ""
    service_status xray
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

cmd_restart() {
    service_restart xray
    log_info "$(msg service_restarted)"
}

# 重新生成配置文件（用于修复配置问题）
cmd_regenerate() {
    log_info "Regenerating Xray config from node files..."

    # 备份当前配置
    if [[ -f "$XRAY_CONF" ]]; then
        cp "$XRAY_CONF" "${XRAY_CONF}.bak"
        log_info "Backed up current config to ${XRAY_CONF}.bak"
    fi

    # 重新生成配置
    if write_config; then
        log_info "Config regenerated successfully"
        service_restart xray
        sleep 1
        if service_is_active xray; then
            log_info "Xray service restarted successfully"
        else
            log_error "Xray service failed to start. Restoring backup..."
            if [[ -f "${XRAY_CONF}.bak" ]]; then
                mv "${XRAY_CONF}.bak" "$XRAY_CONF"
                service_restart xray
            fi
            return 1
        fi
    else
        log_error "Failed to regenerate config"
        if [[ -f "${XRAY_CONF}.bak" ]]; then
            log_info "Restoring backup config..."
            mv "${XRAY_CONF}.bak" "$XRAY_CONF"
        fi
        return 1
    fi

    # 清理备份
    rm -f "${XRAY_CONF}.bak" 2>/dev/null
    return 0
}

# 删除单个节点
cmd_remove() {
    select_node || return 1

    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")

    {
    echo ""
    echo -e "${YELLOW}About to remove node: $CURRENT_NODE_NAME${NC}"
    echo -n "Confirm? [y/N]: "
    } >/dev/tty
    read -r confirm </dev/tty

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        return 0
    fi

    rm -f "$node_file"
    log_info "Node '$CURRENT_NODE_NAME' removed"

    # 重新生成 xray 配置
    write_config
    service_restart xray

    log_info "Xray config updated"
}

cmd_uninstall() {
    log_info "$(msg uninstalling)"
    service_stop xray
    service_disable xray
    rm -f "$XRAY_CONF" "$LANG_FILE"
    rm -rf "$NODES_DIR"

    # Alpine 使用手动安装，需要手动清理
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        rm -f /usr/local/bin/xray
        rm -rf /usr/local/etc/xray
        rm -rf /usr/local/share/xray
        rm -rf /var/log/xray
        rm -f /etc/init.d/xray
    else
        # Security: Download script to temp file first, then execute
        local tmp_installer="/tmp/xray-uninstall-$$.sh"
        if secure_curl "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "$tmp_installer"; then
            bash "$tmp_installer" remove >/dev/null 2>&1
            rm -f "$tmp_installer"
        fi
    fi
    log_info "$(msg uninstall_complete)"
}

cmd_test_sni() {
    local total=${#SNI_LIST[@]}
    log_info "$(msg testing_sni) ($(msg total_domains): $total)"
    echo ""

    declare -A latency_map

    # 使用并行测试（带详细输出）
    test_domains_parallel_verbose latency_map

    echo ""

    # 显示排序结果（前10名）
    if [[ ${#latency_map[@]} -gt 0 ]]; then
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     Top 10 $(msg best_latency)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""

        # 排序并显示前10
        for domain in "${!latency_map[@]}"; do
            echo "${latency_map[$domain]} $domain"
        done | sort -n | head -10 | while read -r lat dom; do
            printf "  ${GREEN}%4dms${NC}  %s\n" "$lat" "$dom"
        done

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    fi

    log_info "$(msg test_complete)"
}

cmd_health() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg health_check)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local all_ok=true

    # 1. 检查 Xray 服务状态
    if service_is_active xray; then
        echo -e "  ${GREEN}✓${NC} Xray service is running"
    else
        echo -e "  ${RED}✗${NC} Xray service is not running"
        all_ok=false
    fi

    # 2. 检查节点数量
    local node_count
    node_count=$(count_nodes)
    if [[ $node_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $node_count node(s) configured"
    else
        echo -e "  ${RED}✗${NC} No nodes configured"
        all_ok=false
    fi

    # 3. 检查每个节点的端口和 SNI
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        local n_name n_port n_sni n_xhttp_port n_protocol_type
        n_name=$(basename "$node_file" .env)
        n_port=$(grep "^PORT=" "$node_file" | cut -d= -f2)
        n_sni=$(grep "^SNI=" "$node_file" | cut -d= -f2)
        n_xhttp_port=$(grep "^XHTTP_PORT=" "$node_file" | cut -d= -f2)
        n_protocol_type=$(grep "^PROTOCOL_TYPE=" "$node_file" | cut -d= -f2)

        # 向后兼容：旧配置没有 PROTOCOL_TYPE，根据端口判断
        if [[ -z "$n_protocol_type" ]]; then
            if [[ -n "$n_port" ]] && [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="both"
            elif [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="xhttp"
            else
                n_protocol_type="vision"
            fi
        fi

        echo ""
        echo -e "  ${BLUE}Node: $n_name${NC} (${n_protocol_type})"

        # 根据协议类型检查端口
        if [[ "$n_protocol_type" == "vision" || "$n_protocol_type" == "both" ]] && [[ -n "$n_port" ]]; then
            if ss -lnt | grep -qE ":${n_port}\s"; then
                echo -e "    ${GREEN}✓${NC} Vision port $n_port is listening"
            else
                echo -e "    ${RED}✗${NC} Vision port $n_port is not listening"
                all_ok=false
            fi
        fi

        if [[ "$n_protocol_type" == "xhttp" || "$n_protocol_type" == "both" ]] && [[ -n "$n_xhttp_port" ]]; then
            if ss -lnt | grep -qE ":${n_xhttp_port}\s"; then
                echo -e "    ${GREEN}✓${NC} XHTTP port $n_xhttp_port is listening"
            else
                echo -e "    ${RED}✗${NC} XHTTP port $n_xhttp_port is not listening"
                all_ok=false
            fi
        fi

        # 测试 SNI 连接
        if timeout 3 openssl s_client -connect "${n_sni}:443" -servername "$n_sni" </dev/null &>/dev/null; then
            echo -e "    ${GREEN}✓${NC} SNI ($n_sni) is reachable"
        else
            echo -e "    ${YELLOW}!${NC} SNI ($n_sni) connection timeout"
        fi
    done

    echo ""
    if $all_ok; then
        echo -e "  ${GREEN}All checks passed! Nodes are healthy.${NC}"
    else
        echo -e "  ${RED}Some checks failed. Please review above.${NC}"
    fi
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# ============== WARP 管理 ==============

cmd_warp() {
    while true; do
        clear
        local warp_status
        if check_warp_running; then
            warp_status="${GREEN}$(msg warp_running)${NC}"
        else
            warp_status="${RED}$(msg warp_stopped)${NC}"
        fi

        local netflix_status ai_status
        if [[ -f "/root/.warp_netflix" ]]; then
            netflix_status="${GREEN}ON${NC}"
        else
            netflix_status="${YELLOW}OFF${NC}"
        fi
        if [[ -f "/root/.warp_ai" ]]; then
            ai_status="${GREEN}ON${NC}"
        else
            ai_status="${YELLOW}OFF${NC}"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_warp)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg warp_status): $warp_status"
        echo ""
        echo -e "  ${GREEN}1.${NC} $(msg warp_install)"
        echo -e "  ${GREEN}2.${NC} $(msg warp_uninstall)"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}3.${NC} $(msg warp_netflix) [$netflix_status]"
        echo -e "  ${GREEN}4.${NC} $(msg warp_ai) [$ai_status]"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-4]: "
        read -r choice

        case "$choice" in
            1) warp_install ;;
            2) warp_uninstall ;;
            3) warp_toggle_netflix ;;
            4) warp_toggle_ai ;;
            0) return ;;
            *) ;;
        esac
    done
}

warp_install() {
    echo ""
    log_info "Installing WARP (Socks5 mode)..."
    # Security: Download to temp file with secure options
    local tmp_warp="/tmp/warp-menu-$$.sh"
    if secure_curl "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" -o "$tmp_warp" 2>/dev/null; then
        bash "$tmp_warp" c
        rm -f "$tmp_warp"
        if check_warp_running; then
            log_info "WARP installed successfully"
            write_config
            service_restart xray
        fi
    else
        log_error "Failed to download WARP installer"
        rm -f "$tmp_warp"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

warp_uninstall() {
    echo ""
    log_info "Uninstalling WARP..."
    if command -v warp &>/dev/null; then
        warp u
    elif [[ -f menu.sh ]]; then
        bash menu.sh u
    else
        # Security: Download to temp file with secure options
        local tmp_warp="/tmp/warp-menu-$$.sh"
        if secure_curl "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" -o "$tmp_warp" 2>/dev/null; then
            bash "$tmp_warp" u
            rm -f "$tmp_warp"
        fi
    fi
    rm -f /root/.warp_netflix /root/.warp_ai
    write_config
    service_restart xray
    log_info "WARP uninstalled"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

warp_toggle_netflix() {
    if ! check_warp_running; then
        log_warn "WARP is not running. Please install first."
        sleep 2
        return
    fi
    if [[ -f "/root/.warp_netflix" ]]; then
        rm -f /root/.warp_netflix
        log_info "Netflix routing disabled"
    else
        touch /root/.warp_netflix
        log_info "Netflix routing enabled"
    fi
    write_config
    service_restart xray
    sleep 1
}

warp_toggle_ai() {
    if ! check_warp_running; then
        log_warn "WARP is not running. Please install first."
        sleep 2
        return
    fi
    if [[ -f "/root/.warp_ai" ]]; then
        rm -f /root/.warp_ai
        log_info "AI services routing disabled"
    else
        touch /root/.warp_ai
        log_info "AI services routing enabled"
    fi
    write_config
    service_restart xray
    sleep 1
}

# ============== BBR 管理 ==============

cmd_bbr() {
    while true; do
        clear
        local bbr_status qdisc_status
        local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)

        if [[ "$cc" == "bbr" ]]; then
            bbr_status="${GREEN}$(msg bbr_enabled)${NC} (BBR)"
        else
            bbr_status="${YELLOW}$(msg bbr_disabled)${NC} ($cc)"
        fi
        qdisc_status="$qd"

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_bbr)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  Congestion Control: $bbr_status"
        echo -e "  Queue Discipline: ${YELLOW}$qdisc_status${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Enable BBR + FQ"
        echo -e "  ${GREEN}2.${NC} Disable BBR (use CUBIC)"
        echo -e "  ${GREEN}3.${NC} Apply TCP optimization"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-3]: "
        read -r choice

        case "$choice" in
            1) bbr_enable ;;
            2) bbr_disable ;;
            3) bbr_optimize ;;
            0) return ;;
            *) ;;
        esac
    done
}

bbr_enable() {
    echo ""
    log_info "Enabling BBR..."
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1
    log_info "BBR enabled"
    sleep 1
}

bbr_disable() {
    echo ""
    log_info "Disabling BBR..."
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic
EOF
    sysctl --system >/dev/null 2>&1
    log_info "BBR disabled, using CUBIC"
    sleep 1
}

bbr_optimize() {
    echo ""
    log_info "Applying TCP optimization..."
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = $qd
net.ipv4.tcp_congestion_control = $cc
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl --system >/dev/null 2>&1
    log_info "TCP optimization applied"
    sleep 1
}

# ============== Swap 管理 ==============

cmd_swap() {
    while true; do
        clear
        local swap_total swap_status swappiness
        swap_total=$(free -m | grep Swap | awk '{print $2}')
        swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")

        if [[ "$swap_total" -eq 0 ]]; then
            swap_status="${RED}Not enabled${NC}"
        else
            swap_status="${GREEN}${swap_total}MB${NC}"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_swap)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg swap_size): $swap_status"
        echo -e "  Swappiness: ${YELLOW}$swappiness${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Create/Resize Swap"
        echo -e "  ${GREEN}2.${NC} Remove Swap"
        echo -e "  ${GREEN}3.${NC} Change Swappiness"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-3]: "
        read -r choice

        case "$choice" in
            1) swap_create ;;
            2) swap_remove ;;
            3) swap_swappiness ;;
            0) return ;;
            *) ;;
        esac
    done
}

swap_create() {
    echo ""
    echo -n "  Enter swap size in MB [1024]: "
    read -r size
    size=${size:-1024}

    log_info "Creating ${size}MB swap..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile

    if ! fallocate -l ${size}M /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=$size status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    log_info "Swap created: ${size}MB"
    sleep 1
}

swap_remove() {
    echo ""
    log_info "Removing swap..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true
    log_info "Swap removed"
    sleep 1
}

swap_swappiness() {
    echo ""
    local current=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
    echo -e "  Current swappiness: ${YELLOW}$current${NC}"
    echo -n "  Enter new value [0-100]: "
    read -r val
    if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 0 ]] && [[ "$val" -le 100 ]]; then
        sysctl -w vm.swappiness=$val >/dev/null
        sed -i '/vm.swappiness/d' /etc/sysctl.conf 2>/dev/null || true
        echo "vm.swappiness = $val" >> /etc/sysctl.conf
        log_info "Swappiness set to $val"
    else
        log_error "Invalid value"
    fi
    sleep 1
}

# ============== Fail2ban 管理 ==============

cmd_fail2ban() {
    # 检查是否是 Alpine (不支持 fail2ban)
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        log_warn "Fail2ban is not available on Alpine Linux"
        sleep 2
        return
    fi

    while true; do
        clear
        local f2b_status banned_count

        if systemctl is-active fail2ban &>/dev/null; then
            f2b_status="${GREEN}Running${NC}"
            banned_count=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -o "[0-9]*" || echo "0")
        else
            f2b_status="${RED}Stopped${NC}"
            banned_count="N/A"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_fail2ban)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg fail2ban_status): $f2b_status"
        echo -e "  Banned IPs: ${RED}$banned_count${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Install & Enable Fail2ban"
        echo -e "  ${GREEN}2.${NC} Stop Fail2ban"
        echo -e "  ${GREEN}3.${NC} View Banned IPs"
        echo -e "  ${GREEN}4.${NC} Unban IP"
        echo -e "  ${GREEN}5.${NC} View Logs"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-5]: "
        read -r choice

        case "$choice" in
            1) fail2ban_install ;;
            2) fail2ban_stop ;;
            3) fail2ban_list ;;
            4) fail2ban_unban ;;
            5) fail2ban_logs ;;
            0) return ;;
            *) ;;
        esac
    done
}

fail2ban_install() {
    echo ""
    log_info "Installing Fail2ban..."

    if ! $PKG_CHECK fail2ban >/dev/null 2>&1; then
        $PKG_UPDATE >/dev/null 2>&1 || true
        $PKG_INSTALL fail2ban >/dev/null 2>&1
    fi

    # 获取当前 SSH 端口
    local ssh_port
    ssh_port=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | head -1 | awk '{print $2}')
    ssh_port=${ssh_port:-22}

    # 配置 jail
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1d
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 30d
findtime = 7d
maxretry = 3
backend = auto

[sshd]
enabled = true
port = $ssh_port,22
mode = aggressive
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    log_info "Fail2ban installed and configured"
    sleep 1
}

fail2ban_stop() {
    echo ""
    systemctl stop fail2ban 2>/dev/null
    systemctl disable fail2ban 2>/dev/null
    log_info "Fail2ban stopped"
    sleep 1
}

fail2ban_list() {
    echo ""
    echo -e "${CYAN}Banned IPs:${NC}"
    fail2ban-client status sshd 2>/dev/null | grep "Banned IP" || echo "  None"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_unban() {
    echo ""
    echo -n "  Enter IP to unban: "
    read -r ip
    if [[ -n "$ip" ]]; then
        fail2ban-client set sshd unbanip "$ip" 2>/dev/null && log_info "Unbanned: $ip" || log_error "Failed to unban"
    fi
    sleep 1
}

fail2ban_logs() {
    echo ""
    echo -e "${CYAN}Recent Fail2ban logs:${NC}"
    if [[ -f /var/log/fail2ban.log ]]; then
        grep -E "(Ban|Unban)" /var/log/fail2ban.log 2>/dev/null | tail -20
    else
        echo "  No logs available"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== 端口管理 ==============

# 验证端口号
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        echo -e "${RED}[ERROR]${NC} 端口必须是 1-65535 之间的数字！"
        return 1
    fi
    return 0
}

# 检查端口运行状态
check_port_status() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

# 开放端口 (跨系统支持)
open_firewall_port() {
    local port="$1"

    # iptables (if available)
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true

        # IPv6
        if [[ -f /proc/net/if_inet6 ]] && command -v ip6tables &>/dev/null; then
            ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi

        # 持久化 (如果有 netfilter-persistent)
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null || true
        fi
    fi

    # firewalld (if available)
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="${port}/udp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi

    # ufw (if available)
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port" 2>/dev/null || true
    fi
}

# 获取当前端口配置
get_current_ports() {
    local ssh_config="/etc/ssh/sshd_config"

    # SSH 端口
    CURRENT_SSH=$(grep "^Port" "$ssh_config" 2>/dev/null | head -n 1 | awk '{print $2}')
    [[ -z "$CURRENT_SSH" ]] && CURRENT_SSH=22

    # Xray 端口
    if [[ -f "$XRAY_CONF" ]] && command -v jq &>/dev/null; then
        CURRENT_VISION=$(jq -r '.inbounds[] | select(.tag=="vision_node" or .tag=="vless-reality-vision" or .settings.clients) | .port' "$XRAY_CONF" 2>/dev/null | head -1)
        CURRENT_XHTTP=$(jq -r '.inbounds[] | select(.tag=="xhttp_node") | .port' "$XRAY_CONF" 2>/dev/null | head -1)
    else
        CURRENT_VISION="N/A"
        CURRENT_XHTTP="N/A"
    fi

    [[ -z "$CURRENT_VISION" || "$CURRENT_VISION" == "null" ]] && CURRENT_VISION="N/A"
    [[ -z "$CURRENT_XHTTP" || "$CURRENT_XHTTP" == "null" ]] && CURRENT_XHTTP="N/A"
}

# SSH rollback helper: restore original port
_ssh_rollback() {
    local ssh_config="$1"
    local backup_file="$2"
    local original_port="$3"

    if [[ -f "$backup_file" ]]; then
        cp "$backup_file" "$ssh_config"
        rm -f "$backup_file"

        # Restart SSH with original config
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null || true
        else
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        fi

        echo -e "\n${YELLOW}[AUTO-ROLLBACK]${NC} SSH 端口已自动恢复为 ${original_port}"
    fi
}

# 修改 SSH 端口（带自动回滚保护）
change_ssh_port() {
    local ssh_config="/etc/ssh/sshd_config"
    local backup_file="/tmp/sshd_config.backup.$$"
    local rollback_timeout=120  # 2 minutes to confirm

    # 安全警告框
    clear
    echo -e "${RED}################################################################${NC}"
    echo -e "${RED}#                    高风险操作警告 (WARNING)                  #${NC}"
    echo -e "${RED}################################################################${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  1. 云服务器用户 (阿里云/腾讯云/AWS等)：                     ${RED}#${NC}"
    echo -e "${RED}#${NC}     必须先在网页控制台的【安全组/防火墙】放行新端口！        ${RED}#${NC}"
    echo -e "${RED}#${NC}     (脚本只能修改系统内部防火墙，无法修改云平台安全组)       ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  2. 修改后你有 ${rollback_timeout} 秒时间确认连接是否正常         ${RED}#${NC}"
    echo -e "${RED}#${NC}     如果未确认，端口将自动恢复为原端口 ($CURRENT_SSH)       ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  3. 请新开一个 SSH 窗口测试新端口，然后回来输入 'confirm'   ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}################################################################${NC}"
    echo ""

    read -p "我已知晓风险，确认继续修改? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}>>> 操作已取消。${NC}"
        sleep 1
        return
    fi

    echo ""
    read -p "请输入新的 SSH 端口 [当前: $CURRENT_SSH]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    # Security: validate port more strictly
    new_port=$(get_validated_port "$new_port" false) || return

    echo -e "${BLUE}正在修改 SSH 端口...${NC}"

    # Step 1: Create backup BEFORE any changes
    cp "$ssh_config" "$backup_file"
    echo -e "${GREEN}[BACKUP]${NC} 配置已备份到 $backup_file"

    # Step 2: Modify config
    if grep -q "^Port" "$ssh_config"; then
        sed -i "s/^Port.*/Port $new_port/" "$ssh_config"
    else
        echo "Port $new_port" >> "$ssh_config"
    fi

    # Step 3: Open firewall for new port
    open_firewall_port "$new_port"

    # Step 4: Start background rollback timer
    (
        sleep "$rollback_timeout"
        # Check if marker file exists (means user confirmed)
        if [[ ! -f "/tmp/ssh_port_confirmed.$$" ]]; then
            _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH"
        fi
    ) &
    local rollback_pid=$!
    disown $rollback_pid 2>/dev/null || true

    # Step 5: Restart SSH service
    echo -e "${BLUE}[INFO]${NC} 重启 SSH 服务..."
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null || true
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi

    # Step 6: Wait for user confirmation
    echo ""
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  SSH 端口已修改为 $new_port                                     ${NC}"
    echo -e "${YELLOW}║                                                               ${NC}"
    echo -e "${YELLOW}║  请立即在【新窗口】测试: ssh -p $new_port user@server          ${NC}"
    echo -e "${YELLOW}║                                                               ${NC}"
    echo -e "${YELLOW}║  如果连接成功，请在这里输入 'confirm' 保留更改                ${NC}"
    echo -e "${YELLOW}║  如果 ${rollback_timeout} 秒内未确认，端口将自动恢复为 $CURRENT_SSH     ${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local user_confirm=""
    local start_time=$SECONDS
    while [[ $((SECONDS - start_time)) -lt $rollback_timeout ]]; do
        local remaining=$((rollback_timeout - (SECONDS - start_time)))
        echo -ne "\r  剩余时间: ${remaining}s | 输入 'confirm' 确认: "
        if read -t 1 -r user_confirm; then
            break
        fi
    done
    echo ""

    if [[ "$user_confirm" == "confirm" ]]; then
        # User confirmed, create marker and clean up
        touch "/tmp/ssh_port_confirmed.$$"
        rm -f "$backup_file"
        # Try to kill rollback process
        kill $rollback_pid 2>/dev/null || true
        echo -e "${GREEN}[SUCCESS]${NC} SSH 端口修改已确认！新端口: $new_port"
        rm -f "/tmp/ssh_port_confirmed.$$"
    else
        # Timeout or cancelled, rollback will happen automatically
        echo -e "${YELLOW}[TIMEOUT]${NC} 未收到确认，将自动回滚..."
        # Force immediate rollback instead of waiting
        kill $rollback_pid 2>/dev/null || true
        _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH"
    fi

    read -n 1 -s -r -p "按任意键继续..."
}

# 修改 Vision 端口
change_vision_port() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        echo -e "${RED}[ERROR]${NC} Xray 配置文件不存在！"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    read -p "请输入新的 Vision 端口 [当前: $CURRENT_VISION]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    echo -e "${BLUE}正在修改 Vision 端口...${NC}"

    # 使用 jq 修改端口
    if command -v jq &>/dev/null; then
        # 尝试多种 tag 名称
        local tmp_file="${XRAY_CONF}.tmp"
        jq --argjson port "$new_port" '
            (.inbounds[] | select(.tag=="vision_node" or .tag=="vless-reality-vision" or (.settings.clients and .streamSettings.realitySettings)) | .port) |= $port
        ' "$XRAY_CONF" > "$tmp_file" && mv "$tmp_file" "$XRAY_CONF"
    fi

    # 更新节点配置文件
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        if grep -q "^PORT=" "$node_file"; then
            sed -i "s/^PORT=.*/PORT=$new_port/" "$node_file"
        fi
    done

    # 开放防火墙
    open_firewall_port "$new_port"

    # 重启 Xray
    echo -e "${BLUE}[INFO]${NC} 重启 Xray 服务..."
    service_restart xray

    echo -e "${GREEN}修改成功！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 修改 XHTTP 端口
change_xhttp_port() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        echo -e "${RED}[ERROR]${NC} Xray 配置文件不存在！"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    if [[ "$CURRENT_XHTTP" == "N/A" ]]; then
        echo -e "${YELLOW}[WARN]${NC} XHTTP 未启用"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    read -p "请输入新的 XHTTP 端口 [当前: $CURRENT_XHTTP]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    echo -e "${BLUE}正在修改 XHTTP 端口...${NC}"

    # 使用 jq 修改端口
    if command -v jq &>/dev/null; then
        local tmp_file="${XRAY_CONF}.tmp"
        jq --argjson port "$new_port" '
            (.inbounds[] | select(.tag=="xhttp_node") | .port) |= $port
        ' "$XRAY_CONF" > "$tmp_file" && mv "$tmp_file" "$XRAY_CONF"
    fi

    # 更新节点配置文件
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        if grep -q "^XHTTP_PORT=" "$node_file"; then
            sed -i "s/^XHTTP_PORT=.*/XHTTP_PORT=$new_port/" "$node_file"
        fi
    done

    # 开放防火墙
    open_firewall_port "$new_port"

    # 重启 Xray
    echo -e "${BLUE}[INFO]${NC} 重启 Xray 服务..."
    service_restart xray

    echo -e "${GREEN}修改成功！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 端口管理菜单
cmd_ports() {
    while true; do
        get_current_ports
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}              端口管理面板 (Port Manager)              ${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  服务              端口            状态"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        printf "  ${GREEN}1.${NC} 修改 SSH          ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_SSH" "$(check_port_status "$CURRENT_SSH")"
        printf "  ${GREEN}2.${NC} 修改 Vision       ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_VISION" "$([[ "$CURRENT_VISION" != "N/A" ]] && check_port_status "$CURRENT_VISION" || echo -e "${RED}N/A${NC}")"
        printf "  ${GREEN}3.${NC} 修改 XHTTP        ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_XHTTP" "$([[ "$CURRENT_XHTTP" != "N/A" ]] && check_port_status "$CURRENT_XHTTP" || echo -e "${RED}N/A${NC}")"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} 返回 (Back)"
        echo ""
        read -p "请输入选项 [0-3]: " choice

        case "$choice" in
            1) change_ssh_port ;;
            2) change_vision_port ;;
            3) change_xhttp_port ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ============== 日志查看 ==============

cmd_logs() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}              日志查看器 (Log Viewer)                  ${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Xray 日志 (最新 50 行)"
        echo -e "  ${GREEN}2.${NC} Xray 错误日志"
        echo -e "  ${GREEN}3.${NC} SSH 登录日志"
        echo -e "  ${GREEN}4.${NC} Fail2ban 日志"
        echo -e "  ${GREEN}5.${NC} 系统日志"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} 返回 (Back)"
        echo ""
        read -p "请输入选项 [0-5]: " choice

        case "$choice" in
            1)
                echo ""
                echo -e "${CYAN}>>> Xray 日志 (最新 50 行):${NC}"
                echo ""
                if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                    if [[ -f /var/log/xray/access.log ]]; then
                        tail -50 /var/log/xray/access.log
                    else
                        echo "日志文件不存在"
                    fi
                else
                    journalctl -u xray --no-pager -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            2)
                echo ""
                echo -e "${CYAN}>>> Xray 错误日志:${NC}"
                echo ""
                if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                    if [[ -f /var/log/xray/error.log ]]; then
                        tail -50 /var/log/xray/error.log
                    else
                        echo "日志文件不存在"
                    fi
                else
                    journalctl -u xray --no-pager -p err -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            3)
                echo ""
                echo -e "${CYAN}>>> SSH 登录日志:${NC}"
                echo ""
                if [[ -f /var/log/auth.log ]]; then
                    grep -E "sshd.*(Accepted|Failed)" /var/log/auth.log 2>/dev/null | tail -30
                elif [[ -f /var/log/secure ]]; then
                    grep -E "sshd.*(Accepted|Failed)" /var/log/secure 2>/dev/null | tail -30
                else
                    journalctl -u ssh -u sshd --no-pager -n 30 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            4)
                echo ""
                echo -e "${CYAN}>>> Fail2ban 日志:${NC}"
                echo ""
                if [[ -f /var/log/fail2ban.log ]]; then
                    grep -E "(Ban|Unban)" /var/log/fail2ban.log 2>/dev/null | tail -30
                else
                    echo "Fail2ban 日志不存在"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            5)
                echo ""
                echo -e "${CYAN}>>> 系统日志 (最新 50 行):${NC}"
                echo ""
                if [[ -f /var/log/syslog ]]; then
                    tail -50 /var/log/syslog
                elif [[ -f /var/log/messages ]]; then
                    tail -50 /var/log/messages
                else
                    journalctl --no-pager -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ============== 独立工具安装 ==============

install_standalone_tools() {
    local bin_dir="/usr/local/bin"

    echo -e "${BLUE}[INFO]${NC} 安装独立工具命令到 ${bin_dir}..."

    # 1. info 命令 - 显示节点信息
    cat > "${bin_dir}/xray-info" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Info Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" info
elif command -v reality-vision &>/dev/null; then
    reality-vision info
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-info"

    # 2. ports 命令 - 端口管理
    cat > "${bin_dir}/xray-ports" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Ports Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" ports
elif command -v reality-vision &>/dev/null; then
    reality-vision ports
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-ports"

    # 3. logs 命令 - 日志查看
    cat > "${bin_dir}/xray-logs" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Logs Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" logs
elif command -v reality-vision &>/dev/null; then
    reality-vision logs
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-logs"

    # 4. bbr 命令
    cat > "${bin_dir}/xray-bbr" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - BBR Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" bbr
elif command -v reality-vision &>/dev/null; then
    reality-vision bbr
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-bbr"

    # 5. swap 命令
    cat > "${bin_dir}/xray-swap" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Swap Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" swap
elif command -v reality-vision &>/dev/null; then
    reality-vision swap
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-swap"

    # 6. warp 命令
    cat > "${bin_dir}/xray-warp" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - WARP Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" warp
elif command -v reality-vision &>/dev/null; then
    reality-vision warp
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-warp"

    # 7. f2b 命令 - Fail2ban
    cat > "${bin_dir}/xray-f2b" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Fail2ban Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" fail2ban
elif command -v reality-vision &>/dev/null; then
    reality-vision fail2ban
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-f2b"

    # 8. 主脚本链接
    if [[ -f "/root/reality_vision.sh" ]]; then
        ln -sf "/root/reality_vision.sh" "${bin_dir}/reality-vision" 2>/dev/null || true
    fi

    echo -e "${GREEN}[OK]${NC} 独立工具已安装！可用命令:"
    echo "  xray-info   - 查看节点信息"
    echo "  xray-ports  - 端口管理"
    echo "  xray-logs   - 日志查看"
    echo "  xray-bbr    - BBR 管理"
    echo "  xray-swap   - Swap 管理"
    echo "  xray-warp   - WARP 管理"
    echo "  xray-f2b    - Fail2ban 管理"
}

# ============== 系统工具菜单 ==============

cmd_tools() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg tools_menu)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${BLUE}[网络优化]${NC}"
        echo -e "  ${GREEN}1.${NC} $(msg menu_warp)"
        echo -e "  ${GREEN}2.${NC} $(msg menu_bbr)"
        echo ""
        echo -e "  ${BLUE}[系统管理]${NC}"
        echo -e "  ${GREEN}3.${NC} $(msg menu_swap)"
        echo -e "  ${GREEN}4.${NC} $(msg menu_fail2ban)"
        echo ""
        echo -e "  ${BLUE}[服务管理]${NC}"
        echo -e "  ${GREEN}5.${NC} 端口管理 (Ports)"
        echo -e "  ${GREEN}6.${NC} 日志查看 (Logs)"
        echo ""
        echo -e "  ${BLUE}[其他]${NC}"
        echo -e "  ${GREEN}7.${NC} 安装独立工具命令"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-7]: "
        read -r choice

        case "$choice" in
            1) cmd_warp ;;
            2) cmd_bbr ;;
            3) cmd_swap ;;
            4) cmd_fail2ban ;;
            5) cmd_ports ;;
            6) cmd_logs ;;
            7)
                install_standalone_tools
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ============== 主菜单 ==============

show_menu() {
    clear
    local status_icon node_count
    if service_is_active xray; then
        status_icon="${GREEN}●${NC}"
    else
        status_icon="${RED}○${NC}"
    fi
    node_count=$(count_nodes)

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}         ${YELLOW}$(msg menu_title)${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}1.${NC} $(msg menu_install) (Add Node)                                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}2.${NC} $(msg menu_info)                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}3.${NC} $(msg menu_qr)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}4.${NC} $(msg menu_status)  [$status_icon] (${node_count} nodes)                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}5.${NC} List Nodes / 列出节点                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}6.${NC} Remove Node / 删除节点                                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}7.${NC} $(msg menu_restart)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}8.${NC} $(msg menu_test_sni)                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}9.${NC} $(msg menu_health)                                             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}   ${BLUE}T.${NC} $(msg menu_tools) (WARP/BBR/Swap/Fail2ban)                  ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}L.${NC} $(msg menu_lang)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${YELLOW}U.${NC} $(msg menu_uninstall) (All)                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${RED}0.${NC} $(msg menu_exit)                                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

main_menu() {
    while true; do
        show_menu
        echo -n "   $(msg menu_choice) [0-9,T,L,U]: "
        read -r choice
        echo ""

        case "$choice" in
            1)
                cmd_install
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            2)
                cmd_info
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            3)
                cmd_qr
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            4)
                cmd_status
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            5)
                cmd_list
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            6)
                cmd_remove
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            7)
                cmd_restart
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            8)
                cmd_test_sni
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            9)
                cmd_health
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            [Tt])
                cmd_tools
                ;;
            [Ll])
                select_language
                ;;
            [Uu])
                cmd_uninstall
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0)
                echo -e "${GREEN}Bye!${NC}"
                exit 0
                ;;
            *)
                log_error "$(msg menu_invalid)"
                sleep 1
                ;;
        esac
    done
}

show_help() {
    echo ""
    echo -e "${CYAN}VLESS TCP REALITY Vision (Enhanced Edition)${NC}"
    echo ""
    echo "Usage: bash $0 [command]"
    echo ""
    echo "Commands:"
    echo "  (none)      Show interactive menu"
    echo "  install     Add a new node"
    echo "  list        List all nodes"
    echo "  info        Show node information"
    echo "  qr          Show QR code"
    echo "  status      Show service status"
    echo "  health      Run health check"
    echo "  remove      Remove a node"
    echo "  restart     Restart service"
    echo "  regenerate  Regenerate config from node files (fix config issues)"
    echo "  uninstall   Uninstall all nodes and Xray"
    echo "  test-sni    Test all SNI latency"
    echo ""
    echo "System Tools:"
    echo "  tools       System tools menu (WARP/BBR/Swap/Fail2ban/Ports/Logs)"
    echo "  ports       Port management (SSH/Vision/XHTTP)"
    echo "  logs        Log viewer"
    echo "  warp        WARP routing management"
    echo "  bbr         BBR/TCP optimization"
    echo "  swap        Swap management"
    echo "  fail2ban    Fail2ban management"
    echo ""
    echo "Other:"
    echo "  menu        Show interactive menu"
    echo "  help        Show this help"
    echo ""
    echo "Optional parameters (for install):"
    echo "  name=xxx      Specify node name"
    echo "  reym=xxx      Specify SNI domain (VLESS only)"
    echo "  proto=xxx     Protocol type: vision, xhttp, both, or shadowsocks"
    echo "  vlpt=xxx      Specify Vision port (for vision/both)"
    echo "  xhpt=xxx      Specify XHTTP port (for xhttp/both)"
    echo "  uuid=xxx      Specify UUID (VLESS only)"
    echo ""
    echo "Shadowsocks parameters:"
    echo "  ssmethod=xxx  Encryption: 2022-blake3-aes-256-gcm (default),"
    echo "                2022-blake3-chacha20-poly1305, chacha20-ietf-poly1305, aes-256-gcm"
    echo "  sspwd=xxx     Specify password (auto-generated if not set)"
    echo "  sspt=xxx      Specify Shadowsocks port"
    echo "  xhttp=true    (deprecated) Same as proto=both"
    echo ""
    echo "Examples:"
    echo "  bash $0                                    # Interactive menu"
    echo "  bash $0 install                            # Add node (interactive)"
    echo "  name=hk1 bash $0 install                   # Add Vision node with name"
    echo "  name=jp1 proto=xhttp bash $0 install       # Add XHTTP only node"
    echo "  name=sg1 proto=both bash $0 install        # Add Vision + XHTTP node"
    echo "  bash $0 tools                              # System tools menu"
    echo "  bash $0 ports                              # Port management"
    echo "  bash $0 logs                               # Log viewer"
    echo ""
}

# ============== 主入口 ==============

# 加载语言设置
load_lang

# 如果没有语言设置且是交互模式，先选择语言
init_language_if_needed() {
    if [[ -z "$CURRENT_LANG" ]]; then
        select_language
    fi
}

# 单实例锁检查（对于可能冲突的操作）
check_lock_for_write_ops() {
    if ! lock_acquire; then
        log_error "$(msg script_running)"
        log_error "If you are sure no other instance is running, remove: $LOCK_DIR"
        exit 1
    fi
}

case "${1:-}" in
    install)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_install
        ;;
    list)
        init_language_if_needed
        cmd_list
        ;;
    info)
        init_language_if_needed
        cmd_info
        ;;
    qr)
        init_language_if_needed
        cmd_qr
        ;;
    status)
        init_language_if_needed
        cmd_status
        ;;
    health)
        init_language_if_needed
        cmd_health
        ;;
    remove)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_remove
        ;;
    restart)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_restart
        ;;
    regenerate|regen)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_regenerate
        ;;
    uninstall)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_uninstall
        ;;
    test-sni)
        init_language_if_needed
        cmd_test_sni
        ;;
    tools)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_tools
        ;;
    warp)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_warp
        ;;
    bbr)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_bbr
        ;;
    swap)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_swap
        ;;
    fail2ban)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_fail2ban
        ;;
    ports)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_ports
        ;;
    logs)
        init_language_if_needed
        cmd_logs
        ;;
    menu|"")
        check_lock_for_write_ops
        init_language_if_needed
        main_menu
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        ;;
esac
