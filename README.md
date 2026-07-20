# Proxy Hub

一键部署多协议代理节点的自动化脚本，支持 VLESS Reality、Shadowsocks 2022、
AnyTLS、Hysteria2、多节点管理、WARP 分流、系统优化工具和多语言界面。

## 特性

### 支持协议
- **VLESS + Vision + REALITY** - TCP 传输，推荐
- **VLESS + XHTTP + REALITY** - XHTTP 传输，更好的伪装
- **Shadowsocks 2022** - 高性能 SS 协议，支持多种加密方式
- **AnyTLS** - 基于 sing-box 的抗 "TLS in TLS" 检测协议，自签名证书
- **AnyTLS + REALITY** - AnyTLS 叠加 REALITY 伪装，抗封锁能力更强（推荐）
- **Hysteria2** - 基于 sing-box 的 QUIC/UDP 协议，适合高延迟或不稳定链路

> AnyTLS 与 Hysteria2 由 sing-box 提供；VLESS 与 Shadowsocks 由 Xray 提供。
> 脚本按节点类型安装、生成并同步对应内核的配置。每个 AnyTLS 节点都会生成
> **独立、随机化的 padding scheme**；Hysteria2 使用独立密码和自签名 TLS 证书，
> 客户端分享链接会带 `insecure=1`。

### 核心功能
- **多节点支持** - 同时运行多个节点，独立配置
- **双栈链接** - 自动检测并生成 IPv4/IPv6 分享链接
- **动态 SNI** - 自动测试 117 个域名，选择最低延迟 SNI
- **并行测试** - 30 并发测试，5-10 秒完成（原需 4+ 分钟）
- **二维码** - 自动生成分享二维码；`both` 节点分别显示 Vision 与 XHTTP 两个二维码
- **安装验收** - 服务健康后才按 TCP/UDP 类型放行本机端口并报告安装成功；失败自动回滚新节点

### 系统优化工具
- **WARP 分流** - Netflix/AI 服务智能分流
- **BBR 优化** - TCP 拥塞控制优化
- **Swap 管理** - 虚拟内存管理
- **Fail2ban** - SSH 暴力破解防护
- **端口管理** - SSH/Vision/XHTTP/SS 端口修改
- **日志查看** - 统一日志查看器

### 多系统支持
- **Linux 发行版** - Debian/Ubuntu/CentOS/RHEL/Fedora/Alpine
- **Init 系统** - systemd 和 OpenRC
- **包管理器** - apt/dnf/yum/apk

### 安全特性
- **单实例锁** - 防止脚本重复运行
- **安全配置加载** - 防止配置文件注入攻击
- **IPv6 SSH 保护** - 防止禁用 IPv6 时断开连接
- **包管理器检查** - 等待系统更新完成后再安装
- **Xray 安全更新** - 强制校验官方 SHA-256，配置预检后原子替换；启动失败自动回滚

## 快速开始

### 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh)
```

仓库根目录的 `proxy-hub.sh` 是轻量 loader：在完整仓库中运行时加载本地
`lib/` 模块；通过上面的一行命令远程运行时，从 GitHub 获取 `PROXY_HUB_REF`
选择的完整、自校验 `dist` bundle，校验后执行。因此，这条一行命令和“只下载
`proxy-hub.sh` 再运行”都需要在运行期间能够访问 GitHub。loader 的本地和远程
模式都要求至少提供 `sha256sum`、`shasum` 或 `openssl` 之一；远程模式还要求
系统已有 `curl`。

`main` 是移动引用。需要可复现执行时，应让外层 loader URL 和内层 bundle 使用
同一个完整 commit SHA：

```bash
export PROXY_HUB_REF='<40-character-commit-sha>'
bash <(curl -Ls "https://raw.githubusercontent.com/Banezzz/proxy-hub/${PROXY_HUB_REF}/proxy-hub.sh")
```

### 手动安装

只下载 loader（运行时仍需 GitHub 网络）：

```bash
curl -O https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh
chmod +x proxy-hub.sh
./proxy-hub.sh
```

需要离线运行时，请预先克隆或下载完整仓库，确保 `proxy-hub.sh` 与 `lib/`
来自同一个版本：

```bash
git clone https://github.com/Banezzz/proxy-hub.git
cd proxy-hub
chmod +x proxy-hub.sh
./proxy-hub.sh
```

不要只复制 `lib/` 中的部分文件，也不要混用不同 commit 的 loader、模块和
bundle。开发与发布架构见 [`docs/dev.md`](docs/dev.md)，稳定的命令行及环境变量
契约见 [`docs/api.md`](docs/api.md)。

## 使用方法

### 交互式菜单

```bash
./proxy-hub.sh
```

```
╔═══════════════════════════════════════════════════════════════╗
║              Proxy Hub 管理面板                               ║
╠═══════════════════════════════════════════════════════════════╣
║   1. 安装节点 (Add Node)                                       ║
║   2. 查看节点信息                                              ║
║   3. 显示二维码                                                ║
║   4. 服务状态 [●] (3 nodes)                                    ║
║   5. List Nodes / 列出节点                                     ║
║   6. Remove Node / 删除节点                                    ║
║   7. 重启服务                                                  ║
║   8. 测试 SNI 延迟                                             ║
║   9. 健康检查                                                  ║
╠═══════════════════════════════════════════════════════════════╣
║   T. 系统工具 (Xray/WARP/BBR/Swap/Fail2ban/Ports/Logs)         ║
╠═══════════════════════════════════════════════════════════════╣
║   L. 切换语言                                                  ║
║   U. 卸载 (All)                                                ║
║   0. 退出                                                      ║
╚═══════════════════════════════════════════════════════════════╝
```

### 协议选择

安装节点时可以选择：

```
═══════════════════════════════════════════════════════════════
                     选择节点协议类型
═══════════════════════════════════════════════════════════════

  1. VLESS + Vision + REALITY  (TCP 传输, 推荐)
  2. VLESS + XHTTP + REALITY   (XHTTP 传输)
  3. 两个都安装               (生成两个端口)
  4. Shadowsocks 2022         (SS 协议, 高性能)
  5. AnyTLS                   (sing-box, 自签名证书)
  6. AnyTLS + REALITY         (sing-box, 抗封锁, 推荐)
  7. Hysteria2                (sing-box, QUIC/UDP)
```

### Shadowsocks 加密方式

选择 Shadowsocks 时支持以下加密方式：

| 方式 | 说明 |
|------|------|
| `2022-blake3-aes-256-gcm` | 推荐，硬件加速 |
| `2022-blake3-chacha20-poly1305` | 移动设备优化 |
| `chacha20-ietf-poly1305` | 传统方式，广泛支持 |
| `aes-256-gcm` | 传统方式，经典加密 |

### 命令行模式

```bash
# 节点管理
./proxy-hub.sh install     # 添加新节点
./proxy-hub.sh list        # 列出所有节点
./proxy-hub.sh info        # 查看节点信息
./proxy-hub.sh qr          # 显示二维码
./proxy-hub.sh status      # 服务状态
./proxy-hub.sh health      # 健康检查
./proxy-hub.sh remove      # 删除节点
./proxy-hub.sh restart     # 重启服务
./proxy-hub.sh test-sni    # 测试 SNI 延迟
./proxy-hub.sh uninstall   # 卸载所有节点和 Xray

# Xray 版本管理
./proxy-hub.sh xray-version  # 显示当前、stable 与含 prerelease 的最新版本
./proxy-hub.sh xray-update   # 安全更新 Xray，失败自动回滚

# 系统工具
./proxy-hub.sh tools       # 系统工具菜单
./proxy-hub.sh ports       # 端口管理
./proxy-hub.sh logs        # 日志查看
./proxy-hub.sh warp        # WARP 分流管理
./proxy-hub.sh bbr         # BBR 优化
./proxy-hub.sh swap        # Swap 管理
./proxy-hub.sh fail2ban    # Fail2ban 管理
```

### Xray 版本管理

版本选择按 `XRAY_VERSION > XRAY_CHANNEL > stable` 解析；大写变量优先，同时兼容
已有的小写参数风格 `xray_version`、`xray_channel`。固定版本可以省略前导 `v`，
脚本校验后统一为 Xray release tag：

```bash
# 查看本地版本、latest stable 与包括 prerelease 在内的 latest release
bash proxy-hub.sh xray-version

# 更新到 latest stable（默认）
XRAY_CHANNEL=stable bash proxy-hub.sh xray-update

# 更新到最新非 draft release，包括 prerelease
XRAY_CHANNEL=prerelease bash proxy-hub.sh xray-update

# 固定版本；26.7.11 与 v26.7.11 等价
XRAY_VERSION=v26.7.11 bash proxy-hub.sh xray-update
xray_version=26.7.11 bash proxy-hub.sh xray-update
```

普通 `install` 创建节点时，如果现有 Xray 可执行且版本可读取，脚本只报告当前版本，
不会自动升级、降级或覆盖用户手动安装的 prerelease。只有全新安装或显式运行
`xray-update` 才按上述目标选择执行 release 安装。
取得 lifecycle lock 后脚本会重新读取实际版本：普通安装保留并发出现的健康版本，
channel 更新只允许升级，只有固定版本请求可以重装或降级。

### 高级参数

```bash
# VLESS Vision 节点
name=hk1 proto=vision vlpt=443 reym=www.microsoft.com ./proxy-hub.sh install

# VLESS XHTTP 节点
name=jp1 proto=xhttp xhpt=8443 reym=www.apple.com ./proxy-hub.sh install

# VLESS Vision + XHTTP 双协议
name=sg1 proto=both vlpt=443 xhpt=8443 ./proxy-hub.sh install

# Shadowsocks 2022 节点
name=us1 proto=shadowsocks sspt=8388 ./proxy-hub.sh install

# AnyTLS 节点 (自签名证书)
name=at1 proto=anytls atpt=8443 ./proxy-hub.sh install

# AnyTLS + REALITY 节点 (推荐)
name=ar1 proto=anytls-reality atpt=443 reym=www.microsoft.com ./proxy-hub.sh install

# Hysteria2 节点 (QUIC/UDP)
name=hy1 proto=hysteria2 hy2pt=8443 ./proxy-hub.sh install

# 指定 UUID (VLESS)
uuid=your-custom-uuid ./proxy-hub.sh install

# 组合使用
name=de1 proto=vision vlpt=12345 reym=www.tesla.com ./proxy-hub.sh install
```

### 参数说明

| 参数 | 说明 | 示例 |
|------|------|------|
| `name` | 节点名称 | `name=hk1` |
| `proto` | 协议类型 | `proto=vision/xhttp/both/shadowsocks/anytls/anytls-reality/hysteria2` |
| `vlpt` | Vision 端口 | `vlpt=443` |
| `xhpt` | XHTTP 端口 | `xhpt=8443` |
| `sspt` | Shadowsocks 端口 | `sspt=8388` |
| `atpt` | AnyTLS 端口 | `atpt=8443` |
| `atpwd` | AnyTLS 密码 (默认随机) | `atpwd=xxxxxxxx` |
| `hy2pt` | Hysteria2 UDP 端口 | `hy2pt=8443` |
| `hy2pwd` | Hysteria2 密码（默认随机，8-128 位 URI 安全字符） | `hy2pwd=xxxxxxxx` |
| `hy2sni` | Hysteria2 TLS SNI（默认 `www.bing.com`） | `hy2sni=edge.example.com` |
| `reym` | SNI 域名 (VLESS / AnyTLS+REALITY) | `reym=www.microsoft.com` |
| `uuid` | 自定义 UUID | `uuid=xxx-xxx-xxx` |

## 系统工具

### Xray Version / Update

```bash
./proxy-hub.sh xray-version
./proxy-hub.sh xray-update
```

系统工具菜单中的 Xray 版本管理会先显示当前、stable、含 prerelease 的最新版本，
并提供更新到 stable、更新到含 prerelease 的最新 release、安装指定版本等入口。
更新包和官方 digest 均从同一个 Xray release 获取；官方 SHA-256 缺失、格式异常或
不匹配时失败关闭。新二进制通过版本核对和现有配置测试后才会替换旧版本；cutover
先保留并核验实际 target，再用同目录 no-clobber 操作发布 candidate；恢复时同时核对
binary 的 SHA-256、owner 与 mode，并要求 service MainPID 是唯一 Xray 进程。脚本保留最近 3 份自建备份，并通过统一 service adapter 支持
systemd 与 Alpine/OpenRC。

可捕获的中断（包括 `Ctrl+C`）会在当前进程内触发回滚。`SIGKILL` 或断电无法执行
shell trap，因此事务状态和旧 binary 备份会保留，由下一次 Xray 写操作先恢复并验证，
再允许开始新的安装或更新；只读的 `xray-version` 不会修改该状态。

### WARP 分流

通过 WARP Socks5 代理实现智能分流：

```bash
./proxy-hub.sh warp
```

功能：
- 安装/卸载 WARP
- Netflix 分流 (解锁地区限制)
- AI 服务分流 (OpenAI/Claude/Gemini)
- 自定义分流规则

### BBR 优化

TCP 拥塞控制优化：

```bash
./proxy-hub.sh bbr
```

功能：
- 启用/禁用 BBR
- TCP 参数优化
- 网络缓冲区调优

### 端口管理

```bash
./proxy-hub.sh ports
```

```
═══════════════════════════════════════════════════════════════
              端口管理面板 (Port Manager)
═══════════════════════════════════════════════════════════════

  服务              端口            状态
───────────────────────────────────────────────────────────────
  1. 修改 SSH          22            运行中
  2. 修改 Vision       12345         运行中
  3. 修改 XHTTP        8443          运行中
  4. 修改 Shadowsocks  8388          运行中
───────────────────────────────────────────────────────────────
  0. 返回 (Back)
```

**注意**: 修改 SSH 端口前，请确保已在云服务商控制台放行新端口！

节点安装成功后，脚本会按协议传输类型放行本机防火墙：VLESS/AnyTLS 使用 TCP，
Hysteria2 使用 UDP，Shadowsocks 使用 TCP 和 UDP。云服务商安全组不在来宾系统的
控制范围内，仍需在控制台放行相同端口和传输类型。

### SS2022 时间同步提示

Shadowsocks 2022 对系统时间较敏感。节点安装完成后可选择：

- 安装并启用时间同步；
- 只通过 HTTP 校验时间准确度；
- 跳过。

在没有宿主机时间权限的容器中，只提供“校验”和“跳过”，不会尝试修改宿主机时钟。

### 日志查看

```bash
./proxy-hub.sh logs
```

支持查看：
- Xray 运行日志
- Xray 错误日志
- SSH 登录日志
- Fail2ban 日志
- 系统日志

### 独立工具命令

安装独立工具后，可直接使用以下命令：

```bash
xray-info    # 查看节点信息
xray-ports   # 端口管理
xray-logs    # 日志查看
xray-bbr     # BBR 管理
xray-swap    # Swap 管理
xray-warp    # WARP 管理
xray-f2b     # Fail2ban 管理
```

在系统工具菜单中选择"安装独立工具命令"即可安装。

## 多节点管理

### 添加节点

```bash
# 交互式添加（会提示选择协议类型和端口）
./proxy-hub.sh install

# 命令行添加 VLESS 节点
name=hk1 proto=vision ./proxy-hub.sh install
name=jp1 proto=xhttp ./proxy-hub.sh install

# 命令行添加 Shadowsocks 节点
name=ss1 proto=shadowsocks sspt=8388 ./proxy-hub.sh install

# 命令行添加 Hysteria2 节点
name=hy1 proto=hysteria2 hy2pt=8443 ./proxy-hub.sh install
```

### 查看所有节点

```bash
./proxy-hub.sh list
```

输出示例：
```
═══════════════════════════════════════════════════════════════
                     All Nodes / 所有节点
═══════════════════════════════════════════════════════════════

  1. hk1 [VLESS Vision]
     Port: 12345 | SNI: www.microsoft.com
     UUID: 03761544...
     XHTTP: 8443

  2. ss1 [Shadowsocks]
     Port: 8388 | Method: 2022-blake3-aes-256-gcm
     Password: abc123...

═══════════════════════════════════════════════════════════════
```

## 系统要求

- **操作系统**: Debian 10+, Ubuntu 18.04+, CentOS 7+, RHEL 7+, Fedora 30+, Alpine 3.14+
- **Init 系统**: systemd 或 OpenRC
- **Bash**: 4.3+（脚本会自动检测）
- **架构**: x86_64, aarch64
- **权限**: root 用户
- **网络**: 需要访问 GitHub 下载 Xray 或 sing-box

## 客户端配置

### VLESS Vision 协议

```
协议: VLESS
地址: your.server.ip
端口: 12345
UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Flow: xtls-rprx-vision
传输: TCP
安全: Reality
SNI: www.microsoft.com
Fingerprint: chrome
PublicKey: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ShortID: xxxxxxxx
```

### VLESS XHTTP 协议

```
协议: VLESS
地址: your.server.ip
端口: 8443
UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
传输: XHTTP
安全: Reality
SNI: www.microsoft.com
Fingerprint: chrome
PublicKey: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ShortID: xxxxxxxx
```

### Shadowsocks 2022

```
协议: Shadowsocks
地址: your.server.ip
端口: 8388
加密: 2022-blake3-aes-256-gcm
密码: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### AnyTLS

```
协议: AnyTLS
地址: your.server.ip
端口: 8443
密码: xxxxxxxxxxxxxxxx
SNI: www.bing.com
允许不安全 (insecure): 是   # 自签名证书
```

分享链接格式：`anytls://密码@地址:端口/?sni=域名&insecure=1#名称`

### AnyTLS + REALITY

```
协议: AnyTLS
地址: your.server.ip
端口: 443
密码: xxxxxxxxxxxxxxxx
SNI: www.microsoft.com
PublicKey: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ShortID: xxxxxxxx
Fingerprint: chrome
```

分享链接格式：`anytls://密码@地址:端口/?sni=域名&pbk=公钥&sid=ShortID&fp=chrome#名称`

> AnyTLS 需要支持该协议的客户端：[sing-box](https://github.com/SagerNet/sing-box)、
> [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo)、NekoBox 等。
> 旧版 v2rayN/v2rayNG（仅 Xray 内核）不支持 AnyTLS。

### Hysteria2

```
协议: Hysteria2
地址: your.server.ip
端口: 8443 (UDP)
密码: xxxxxxxxxxxxxxxx
SNI: www.bing.com
允许不安全 (insecure): 是   # 自签名证书
```

分享链接使用 `hysteria2://` scheme。客户端和云安全组都必须允许对应 UDP 端口；
仅开放同号 TCP 端口不能建立 Hysteria2 连接。

### 推荐客户端

| 平台 | 客户端 |
|------|--------|
| Windows | [v2rayN](https://github.com/2dust/v2rayN) |
| macOS | [V2rayU](https://github.com/yanue/V2rayU) |
| iOS | Shadowrocket, Quantumult X |
| Android | [v2rayNG](https://github.com/2dust/v2rayNG) |
| Linux | [v2rayA](https://github.com/v2rayA/v2rayA) |

## 文件位置

| 文件 | 路径 |
|------|------|
| Xray 程序 | `/usr/local/bin/xray` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| Xray 备份 | `/usr/local/bin/xray.bak-v*-YYYYMMDD-HHMMSS`（默认保留最近 3 份） |
| sing-box 程序 | `/usr/local/bin/sing-box` |
| sing-box 配置 | `/usr/local/etc/sing-box/config.json` |
| sing-box 证书 | `/usr/local/etc/sing-box/certs/` |
| GeoIP 数据 | `/usr/local/share/xray/geoip.dat` |
| GeoSite 数据 | `/usr/local/share/xray/geosite.dat` |
| 节点配置目录 | `/root/reality_nodes/` |
| 单节点配置 | `/root/reality_nodes/<name>.env` |
| 语言设置 | `/root/reality_vision.lang` |
| SNI 缓存 | `/root/.sni_latency_cache` |
| 独立工具 | `/usr/local/bin/xray-*` |

## 常见问题

### Q: 安装后无法连接？

1. 运行 `./proxy-hub.sh status` 检查服务状态
2. 确保服务器防火墙/安全组开放了对应端口
3. 检查客户端配置是否正确
4. 查看日志：`./proxy-hub.sh logs`

### Q: SNI 测试全部超时？

- 可能是服务器网络限制，使用 `reym=www.tesla.com` 指定 SNI 跳过测试

### Q: 如何更换某个节点的 SNI？

```bash
# 删除旧节点，重新添加
./proxy-hub.sh remove
name=hk1 reym=new.sni.com ./proxy-hub.sh install
```

### Q: 如何修改端口？

```bash
./proxy-hub.sh ports
# 选择要修改的端口类型
```

### Q: WARP 分流不生效？

1. 确认 WARP 服务运行中：`./proxy-hub.sh warp`
2. 检查 Xray 配置中是否有 WARP outbound
3. 重启 Xray 服务：`./proxy-hub.sh restart`

### Q: Shadowsocks 密码错误？

确保客户端使用完整的 base64 密码，包括末尾的 `==` 填充字符。

### Q: Alpine Linux 支持如何？

完全支持 Alpine Linux，使用 OpenRC 作为 init 系统，apk 作为包管理器。

### Q: 添加节点会自动把 Xray 升级或降级到 stable 吗？

不会。已有 Xray 可正常运行时，普通节点安装会保留当前版本。需要变更版本时，请显式
运行 `xray-update` 并选择 stable、包括 prerelease 的 latest release 或固定版本。

### Q: Xray 更新失败会影响现有节点吗？

不会修改节点配置、UUID、Reality 密钥、SNI、端口或密码；原本运行的 Xray 在原子
替换窗口内会短暂停服。更新前会用新 binary 测试现有 Xray 配置；替换或重启后的健康
检查失败时自动恢复旧 binary 和原服务运行状态。若更新或崩溃恢复期间发现不属于该
事务的外部 binary，脚本不会覆盖或删除它，并保留 journal、staging 与 backup 供人工确认。
若自动回滚也失败，命令会高亮输出使用已保留备份进行人工恢复的准确命令。

### Q: 多节点共用一个 Xray 进程吗？

VLESS 与 Shadowsocks 节点在同一个 Xray 配置中作为多个 inbounds；AnyTLS 与
Hysteria2 节点在同一个 sing-box 配置中作为多个 inbounds。两个内核独立运行，
脚本会按现有节点类型同步和重启需要的服务。

## 更新日志

### v5.6.0
- 新增 Xray Release Management：支持 `xray-version`、`xray-update`、stable、包含
  prerelease 的 latest release 与固定版本；普通节点安装保留健康的现有 Xray
- Xray release zip 必须通过官方 SHA-256，且新 binary 必须通过版本核对、现有配置
  预检、原子替换和 systemd/OpenRC 服务健康检查；失败自动恢复旧 binary
- Xray binary 备份默认保留最近 3 份；`Ctrl+C` 当前进程回滚，`SIGKILL`/断电遗留
  事务由下一次 Xray 写操作先恢复
- 新增 Hysteria2 节点，复用现有 sing-box 服务和安全配置生成路径，支持
  `proto=hysteria2`/`hy2`、`hy2pt`、`hy2pwd`、IPv4/IPv6 分享链接与二维码
- 修复 `both` 节点二维码只显示 Vision：安装完成和 `qr` 命令现在分别显示 Vision、
  XHTTP 两个二维码，同时继续使用安全节点配置加载
- SS2022 安装后改为时间同步菜单；无时钟权限的容器只提供准确度检查与跳过
- 安装流程在代理服务健康后按 transport 放行本机防火墙；启动失败会输出诊断、
  删除本次节点并重建原有内核配置，不再显示误导性的安装成功和二维码

### v5.5.0
- 修复：创建 AnyTLS / AnyTLS+REALITY 节点后，定时重启功能实际重启的服务。
  定时重启改为重启「所有在用的代理内核」(Xray 和/或 sing-box)，AnyTLS 节点
  不再错误地只重启 Xray；相关提示文案也从「Xray」改为「代理服务」
- 单独 AnyTLS 选择 SNI 时新增提示：SNI 仅作 TLS 伪装（自签证书），测速仅供参考

### v5.4.0
- SNI 选择时新增「测试自定义域名」(`C`)：可输入逗号分隔的多个域名
  （如 `a.com,b.com,c.com`），仅对这些域名测速，并从结果中选择 SNI
- 内置 117 域名测速结果之外的补充手段，安装与编辑节点时均可用

### v5.3.0
- 新增「编辑节点」功能（菜单 `E` / 命令 `edit`）：节点创建后可修改参数
  - VLESS：端口、SNI/dest（测速或自定义）、重新生成 UUID / Reality 密钥对、XHTTP path
  - Shadowsocks：端口、加密方式、重新生成密码
  - AnyTLS / AnyTLS+REALITY：端口、SNI、重新生成密码 / padding / Reality 密钥对
- 单独 AnyTLS（自签证书）现已支持自定义 SNI：创建与编辑均可「测速选择 + 手动输入」

### v5.2.0
- 按需安装代理内核：在选择协议类型之后才安装对应内核
  （VLESS/Shadowsocks → Xray，AnyTLS → sing-box），不再默认安装 Xray
- AnyTLS + REALITY 的密钥改用 sing-box 生成，AnyTLS 节点完全无需 Xray
- 不再默认下载 GeoIP/GeoSite 数据库；默认路由用显式私网 CIDR 替代
  `geoip:private`（保留拦截内网/环回的安全策略），仅在启用 WARP 分流时
  才按需下载 GeoSite 数据库

### v5.1.1
- 修复「更新节点 IP」只按首个节点判断是否变更，导致换 IP 前已存在的旧节点
  不被同步（分享链接仍显示旧 IP）的问题，改为逐节点独立比较与更新

### v5.1.0
- 新增 **AnyTLS** 与 **AnyTLS + REALITY** 协议支持（基于 sing-box）
- 每个 AnyTLS 节点生成独立、随机化的 padding scheme，握手时自动下发给客户端
- sing-box 按需自动安装/卸载，与 Xray 独立运行（systemd / OpenRC 双支持）
- 节点列表、状态、健康检查、二维码、分享链接均已适配 AnyTLS

### v5.0.0
- 项目重命名为 Proxy Hub
- 新增 Shadowsocks 2022 协议支持
- 支持多种 SS 加密方式 (2022-blake3-aes-256-gcm, chacha20-ietf-poly1305 等)
- 交互式端口选择
- 安全增强：配置文件安全加载，防止注入攻击
- 修复 base64 密码解析问题

### v4.0.0
- XHTTP 协议支持
- IPv4/IPv6 双栈链接生成
- GeoIP/GeoSite 规则数据库
- WARP 分流功能
- BBR/Swap 系统优化工具
- Fail2ban SSH 防护
- 端口管理功能
- 日志查看器
- 独立工具命令安装
- Alpine Linux / OpenRC 支持
- 单实例锁机制
- IPv6 SSH 自杀保护
- 包管理器状态检查

### v3.0.0
- 多节点支持（同时运行多个独立节点）
- 交互式节点命名（直接回车使用随机名称）
- 节点管理命令（list/remove）
- 智能 xray 配置合并
- 每个节点独立连接数统计

### v2.0.0
- 并行 SNI 测试（30 并发，性能提升 28-56 倍）
- 并行 IP 获取（4 API 竞速）
- 多发行版支持（apt/yum/dnf）
- 健康检查功能
- 连接数显示
- SNI 测试结果缓存

### v1.0.0
- 初始版本
- VLESS + TCP + REALITY 自动配置
- 动态 SNI 选择
- 多语言支持
- 二维码生成

## 致谢

- [Xray-core](https://github.com/XTLS/Xray-core) - 核心代理引擎
- [REALITY](https://github.com/XTLS/REALITY) - 协议实现
- [Loyalsoldier](https://github.com/Loyalsoldier/v2ray-rules-dat) - GeoIP/GeoSite 规则
- [WARP](https://github.com/fscarmen/warp) - WARP 实现参考

## License

MIT License
