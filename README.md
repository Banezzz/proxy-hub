# Proxy Hub

一键部署多协议代理节点的自动化脚本，支持 VLESS Reality、Shadowsocks 2022、
AnyTLS、Hysteria2、多节点管理、WARP 分流、系统优化工具和多语言界面。

## 特性

### 支持协议
- **VLESS + Vision + REALITY** - TCP 传输，推荐
- **VLESS + XHTTP + REALITY** - XHTTP 传输，更好的伪装
- **Shadowsocks 2022** - 无伪装的全加密协议，建议只用于中转或落地链路
- **AnyTLS** - 基于 sing-box 的抗 "TLS in TLS" 检测协议，自签名证书
- **AnyTLS + REALITY** - AnyTLS 叠加 REALITY 伪装，抗封锁能力更强（推荐）
- **Hysteria2** - 基于 sing-box 的 QUIC/UDP 协议，适合高延迟或不稳定链路；
  可选 Salamander 混淆、端口跳跃与 ACME 真证书

> AnyTLS 由 sing-box 提供；VLESS 与 Shadowsocks 由 Xray 提供；Hysteria2 默认由
> sing-box 承载，也可以用 `hy2core=xray` 交给 Xray（分享链接不变）。
> 脚本按节点类型安装、生成并同步对应内核的配置。每个 AnyTLS 节点都会生成
> **独立、随机化的 padding scheme**；Hysteria2 使用独立密码和自签名 TLS 证书，
> 分享链接同时带 `insecure=1` 与证书指纹 `pinSHA256`（用域名申请 ACME 证书后两者都不需要）。

### 核心功能
- **多节点支持** - 同时运行多个节点，独立配置
- **双栈链接** - 自动检测并生成 IPv4/IPv6 分享链接
- **动态 SNI** - 自动测试 102 个域名，选择最低延迟 SNI
- **并行测试** - 30 并发测试，5-10 秒完成（原需 4+ 分钟）
- **二维码** - 自动生成分享二维码；`both` 节点分别显示 Vision 与 XHTTP 两个二维码
- **安装验收** - 服务健康后才按 TCP/UDP 类型放行本机端口并报告安装成功；失败自动回滚新节点
- **引导式菜单** - 每个选项都写明"做什么 / 代价是什么"，复杂功能提供回车即用的推荐方案，
  所需的密码、端口范围、密钥全部随机生成
- **升级向导** - 检测旧版脚本留下的节点与内核，逐项说明后一键升级，失败自动恢复

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
- **sing-box 安全更新** - 同样强制校验 SHA-256、预检现有配置、失败回滚
- **服务沙箱加固** - 以 systemd drop-in 收窄代理内核的权限；加固后起不来会自动撤销
- **第三方下载校验** - GeoIP/GeoSite 校验 SHA-256 后原子替换；WARP 脚本执行前显示摘要并可固定
- **内核安全基线** - 健康检查会指出低于安全基线的 Xray / sing-box

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
║   I. 更新节点 IP                                               ║
║   N. 网络栈 (IPv4 / IPv6)                                      ║
║   T. 系统工具 (Xray/WARP/BBR/Swap/Fail2ban/Ports/Logs)         ║
║   P. 协议 / 内核升级向导                                       ║
╠═══════════════════════════════════════════════════════════════╣
║   L. 切换语言                                                  ║
║   U. 卸载 (All)                                                ║
║   0. 退出                                                      ║
╚═══════════════════════════════════════════════════════════════╝
```

### 协议选择

安装节点时每个协议下面都有一行说明，回车采用推荐项：

```
═══════════════════════════════════════════════════════════════
        选择节点协议类型（回车采用推荐）
═══════════════════════════════════════════════════════════════

  1. VLESS + Vision + REALITY  [推荐，默认]
     伪装成访问一个真实网站的 HTTPS，最稳妥的通用选择；无需域名和证书。
  2. VLESS + XHTTP + REALITY
     同样的伪装，流量形态更像网页请求；需要较新的客户端。
  3. Vision + XHTTP 两个都装
     一次生成两个端口、两套独立凭据，客户端可以互为备用。
  4. Shadowsocks 2022  [仅建议中转/落地]
     速度快但没有伪装，不建议直接跨境使用；适合放在中转链路后面。
  5. AnyTLS
     对抗 TLS-in-TLS 识别，自签名证书；客户端需支持 AnyTLS（sing-box / mihomo）。
  6. AnyTLS + REALITY  [AnyTLS 客户端推荐]
     AnyTLS 加上 REALITY 伪装，无需证书，抗封锁能力更强。
  7. Hysteria2
     基于 UDP/QUIC，丢包或高延迟线路上明显更快；需放行 UDP，部分网络会限速 UDP。
```

REALITY 系节点的默认端口是 443（空闲时），因为被借用的真实网站都在 443 上；
伪装域名候选不再包含 Apple / iCloud 系域名，测速要求 TLS 1.3，并按"与服务器同 ASN
优先、通用 CDN 靠后"重新排序。

### 推荐方案与可选增强

复杂功能都提供**回车即用的推荐方案**，所需参数全部随机生成，不需要你自己想密码或
端口范围。交互安装 Hysteria2 时会看到：

```
  1. Salamander 混淆  [推荐，默认]
     随机生成混淆密码，把流量打乱成看不出协议的数据。
  2. 混淆 + 端口跳跃
     在方案 1 之上，随机挑一段 200 个 UDP 端口轮换，对抗针对单个端口的限速或封锁。
     需要你到云厂商安全组放行这段 UDP 端口（安装后会显示），否则会间歇断流。
  3. 不加固
  4. 自定义（混淆密码 / 跳跃范围 / 用自己的域名申请 ACME 真证书）
```

交互安装 VLESS 节点时可以选择后量子增强（默认关闭，因为要求较新的客户端）：
VLESS Encryption（链接仍可扫码）与 REALITY ML-DSA-65（链接约 3KB，只能复制）。

用 `proto=` 等环境变量驱动的无人值守安装**不会**出现这些菜单，所有增强项默认关闭，
得到的节点与之前的版本一致；需要时用下文"参数说明"里的变量显式开启。

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
./proxy-hub.sh update-ip   # 检测 IP 变化并更新所有节点
./proxy-hub.sh netstack    # 选择网络栈：IPv4 & IPv6 / 仅 IPv4 / 仅 IPv6
./proxy-hub.sh uninstall   # 卸载所有节点和 Xray

# 旧节点 / 旧内核升级
./proxy-hub.sh upgrade                    # 升级向导（逐项说明，勾选后执行）
./proxy-hub.sh upgrade check              # 只读列出可升级项
./proxy-hub.sh upgrade apply recommended  # 无人值守：只执行不影响客户端的项

# 内核版本管理
./proxy-hub.sh xray-version     # 显示当前、stable 与含 prerelease 的最新版本
./proxy-hub.sh xray-update      # 安全更新 Xray，失败自动回滚
./proxy-hub.sh singbox-version  # 显示 sing-box 当前版本、latest stable 与安全基线
./proxy-hub.sh singbox-update   # 校验 SHA-256 后更新 sing-box，失败自动回滚

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

### sing-box 版本管理

```bash
bash proxy-hub.sh singbox-version                       # 只读状态
bash proxy-hub.sh singbox-update                        # 更新到 latest stable
SINGBOX_VERSION=v1.14.4 bash proxy-hub.sh singbox-update  # 固定版本（允许降级）
```

归档必须通过 GitHub release 元数据里的 SHA-256；元数据没有摘要时拒绝安装，除非用
`SINGBOX_SHA256=<hex>` 明确给出期望值。新 binary 先报告版本、再检查现有配置，然后
才以 rename 原子替换；原本在运行的服务重启后必须恢复 active，否则换回旧 binary。
脚本创建的备份默认保留最近 3 份（`SINGBOX_BACKUP_KEEP`）。

### 高级参数

```bash
# VLESS Vision 节点
name=hk1 proto=vision vlpt=443 reym=www.microsoft.com ./proxy-hub.sh install

# VLESS XHTTP 节点
name=jp1 proto=xhttp xhpt=8443 reym=www.microsoft.com ./proxy-hub.sh install

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

# Hysteria2 加固：随机混淆密码 + 随机端口跳跃范围
name=hy2 proto=hysteria2 hy2obfs=true hy2hop=auto ./proxy-hub.sh install

# Hysteria2 使用自己的域名申请 ACME 真证书（需 80 或 443/tcp 空闲）
name=hy3 proto=hysteria2 hy2domain=hy.example.com ./proxy-hub.sh install

# Hysteria2 由 Xray 承载（机器上不必再装 sing-box；分享链接与 sing-box 承载时相同）
name=hy4 proto=hysteria2 hy2core=xray ./proxy-hub.sh install

# VLESS 后量子增强（需要较新的客户端）
name=pq1 proto=vision vlessenc=true ./proxy-hub.sh install
name=pq2 proto=vision mldsa65=true ./proxy-hub.sh install

# REALITY 附加 shortId（只进服务端白名单，可单独发放/吊销）
name=multi proto=vision sids=aa11bb22,cc33dd44 ./proxy-hub.sh install

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
| `hy2obfs` | Hysteria2 Salamander 混淆：`true` 随机密码，或直接给密码 | `hy2obfs=true` |
| `hy2hop` | Hysteria2 端口跳跃范围：`auto` 随机 200 个端口，或 `起始-结束` | `hy2hop=auto` |
| `hy2domain` | 用 ACME 为该域名签发真证书（替代自签名） | `hy2domain=hy.example.com` |
| `hy2email` | ACME 账户邮箱（可选） | `hy2email=ops@example.com` |
| `hy2core` | Hysteria2 的承载内核：`singbox`（默认）或 `xray`（需 Xray ≥ v26.3.27） | `hy2core=xray` |
| `vlessenc` | VLESS Encryption：`true`/`x25519`（链接短）或 `mlkem`（认证也后量子） | `vlessenc=true` |
| `mldsa65` | REALITY ML-DSA-65 证书签名 | `mldsa65=true` |
| `sids` | 附加 REALITY shortId，逗号分隔 | `sids=aa11,bb22cc33` |
| `reym` | SNI 域名 (VLESS / AnyTLS+REALITY) | `reym=www.microsoft.com` |
| `uuid` | 自定义 UUID | `uuid=xxx-xxx-xxx` |
| `ipstack` | 网络栈：`dual`（默认）/ `v4` / `v6` | `ipstack=v6` |

## 网络栈 (IPv4 / IPv6)

主菜单 `N` 或 `./proxy-hub.sh netstack` 可以在三档之间切换，设置对所有节点、
两个内核同时生效：

```
1. IPv4 & IPv6 / 双栈   (默认)
2. IPv4 only / 仅 IPv4
3. IPv6 only / 仅 IPv6
```

| 档位 | 监听 | 出站 | SNI 测速 | 分享链接 |
|------|------|------|----------|----------|
| 双栈 | 通配地址，同时接受 IPv4 与 IPv6 | 跟随系统解析（Xray 默认 `AsIs`） | 不限定协议族 | IPv4 与 IPv6 都输出 |
| 仅 IPv4 | 通配地址 | `domainStrategy=UseIPv4` | 只测 IPv4 可达的域名 | 只输出 IPv4 |
| 仅 IPv6 | `::` 且置 `sockopt.v6only`，不再接受 IPv4 | `domainStrategy=UseIPv6` | 只测 IPv6 可达的域名 | 只输出 IPv6 |

几点说明：

- 默认档与升级前完全一致。Xray 的通配监听本来就同时收 IPv4 和 IPv6（官方文档
  说明 `"0.0.0.0"` 与 `"::"` 等价），因此双栈档不需要、也刻意不改写监听地址——
  以 `ipv6.disable=1` 启动的内核上绑定 `"::"` 会让服务起不来。
- 仅 IPv6 是唯一做 socket 级强制的档（`IPV6_V6ONLY`）。仅 IPv4 只收敛出站解析、
  SNI 测速与链接输出：真正的 v4-only 监听需要绑定具体网卡地址，而 NAT 型云主机的
  公网地址并不在网卡上。
- 选择仅 IPv6 时 SNI 测速会自动只保留有 AAAA 记录的域名。REALITY 的 dest 握手由
  服务器自己发起，v6 Only 主机上选到只有 A 记录的域名会导致握手失败。
- 切换会重建两个内核的配置并重启；任何一步失败都自动回到原设置。
- 非交互：`ipstack=v6 ./proxy-hub.sh netstack`，或在安装时 `ipstack=v6 ... install`。

```bash
./proxy-hub.sh netstack              # 交互选择
ipstack=v6 ./proxy-hub.sh netstack   # 非交互切换
ipstack=v4 name=hk1 ./proxy-hub.sh install
```

## 升级向导（旧节点 / 旧内核）

更新脚本并不会更新旧脚本留下的东西：普通安装从不替换健康的既有内核，也不会回头
修改已有节点。用旧版脚本装过节点的机器，再次打开菜单时会看到一次提示：

```
        发现可以升级的协议 / 内核

   · 4 项推荐升级（客户端无需任何改动）
   · 5 项可选升级（客户端需要重新导入链接）
   · 1 条提示

  回车  查看详情并选择要升级的项（推荐）
  n     这次先不处理，下次打开再问
  s     不再提示这些项（之后仍可从主菜单 P 进入）
```

回车进入向导。向导里每一项都有两行说明——**为什么要升**和**代价是什么**——并按是否
影响客户端分组：

| 分组 | 含义 | 默认 |
|------|------|------|
| 推荐 · 客户端无需任何改动 | 更新低于安全基线的内核、改用新版配置字段、服务沙箱加固、带校验的 GeoData 更新、刷新调优参数 | 已勾选 |
| 可选 · 客户端需要重新导入链接 | 更换 Apple/iCloud 伪装域名、改到 443 端口、shortId 换成 16 位、给 XHTTP 独立凭据、启用 VLESS Encryption、给 Hysteria2 启用混淆 | 未勾选 |
| 提示 · 无需操作 | Shadowsocks 的定位说明、Hysteria2 链接新增证书指纹 | — |

直接回车就是"执行全部推荐项"，这些都不需要动客户端。会让旧链接失效的项必须主动
勾选，执行前还会再确认一次并列出受影响的节点；所需的新域名、密钥、密码都由脚本
自动选出或随机生成。操作键：数字切换勾选（可一次多个）、`r` 只选推荐、`a` 全选、
`n` 清空、`q` 不做任何改动退出。

安全保证：

- 节点改动前先把节点文件和两个内核的配置快照到
  `/var/lib/proxy-hub/upgrade-backups/`（保留最近 5 份）；
- 所有节点改动合并成一次配置重建，新配置起不来就用快照恢复节点并重建旧配置；
- 内核更新走各自带 SHA-256 校验与回滚的路径，一项失败不影响其余无关的项；
- 执行完成后直接显示改过链接的节点的新链接。

无人值守环境没有终端可提问，改用：

```bash
bash proxy-hub.sh upgrade check              # 只读列出，不占用写锁
bash proxy-hub.sh upgrade apply recommended  # 只执行不影响客户端的项
bash proxy-hub.sh upgrade apply all          # 全部（含会改链接的项）
bash proxy-hub.sh upgrade apply node.hk1.split,sysctl.template   # 指定项
```

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

WARP 由第三方脚本 `fscarmen/warp` 安装，它以 root 运行。脚本执行前会显示其
SHA-256 并询问是否继续（回车继续）。需要固定来源时：

```bash
WARP_SCRIPT_REF=<commit 或 tag> WARP_SCRIPT_SHA256=<hex> ./proxy-hub.sh warp
```

设置了 `WARP_SCRIPT_SHA256` 时摘要不一致即拒绝执行。分流规则依赖的
GeoIP/GeoSite 数据库会先对照发布方的 `.sha256sum` 校验，两份都通过才替换；每周的
定时更新走同一个带校验的 helper。

### BBR 优化

TCP 拥塞控制优化：

```bash
./proxy-hub.sh bbr
```

功能（菜单里每一项都有说明，BBR + FQ 为推荐项）：
- 启用/禁用 BBR
- TCP/UDP 缓冲区调优（保留当前拥塞控制算法；对高带宽线路和 Hysteria2 有帮助）

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

链接里可能出现的额外参数（导入链接即可，一般不需要手填）：

| 参数 | 含义 |
|------|------|
| `pinSHA256` | 自签名证书的 SHA-256 指纹。Xray 内核的客户端自 2026-06-01 起不再接受只带 `insecure` 的链接，靠它校验证书；节点信息里也会显示该指纹 |
| `obfs=salamander` / `obfs-password` | 启用了 Salamander 混淆 |
| `mport` | 端口跳跃范围；云安全组需放行这段 UDP 端口 |

用 `hy2domain` 申请了 ACME 证书的节点，链接只带 `sni=<域名>`，不需要 `insecure`
也不需要指纹。

**承载内核。** Hysteria2 默认跑在 sing-box 上；Xray 自 v26.3.27 起也有原生的
Hysteria2 入站。两者对客户端完全等价——同一个 UDP 端口、密码、证书、伪装与混淆
设置，分享链接一字不差——所以可以随时切换而不用动客户端：安装时加
`hy2core=xray`，或在"编辑节点"里选"切换承载内核"。机器上其余节点都在 Xray 上时，
切到 Xray 可以少装、少维护一个内核。Xray 承载有三条限制，不满足时脚本会拒绝并
说明原因：Xray 需 ≥ v26.3.27；不支持 ACME 证书；OpenRC（Alpine）上不支持端口跳跃。

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
| sing-box 备份 | `/usr/local/bin/sing-box.bak-v*-YYYYMMDD-HHMMSS`（默认保留最近 3 份） |
| sing-box ACME 数据 | `/usr/local/etc/sing-box/acme/` |
| 服务加固 drop-in | `/etc/systemd/system/{xray,sing-box}.service.d/10-proxy-hub-hardening.conf` |
| 端口跳跃 helper | `/usr/local/libexec/proxy-hub-hy2-hop` |
| GeoData 更新 helper | `/usr/local/libexec/proxy-hub-geodata-update` |
| 升级前快照 | `/var/lib/proxy-hub/upgrade-backups/`（保留最近 5 份） |
| 升级提示状态 | `/root/.proxy_hub_upgrade` |
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

### Q: 打开脚本提示"发现可以升级的协议 / 内核"，一定要升级吗？

不一定。提示只说明这台机器上有旧版脚本留下的节点或内核。回车进入向导后，默认只
勾选不影响客户端的项（更新内核、加固等）；会让旧链接失效的项默认不勾选。不想
处理就按 `n`（下次再问）或 `s`（不再提示这一批）。详见"升级向导"一节。

### Q: 升级后客户端连不上了？

只有你主动勾选了"需要重新导入链接"的项才会改变链接；向导结束时已显示新链接，
也可以在主菜单"查看节点信息"里重新复制。旧参数保存在
`/var/lib/proxy-hub/upgrade-backups/<时间>/nodes/` 里。

### Q: Hysteria2 节点在 v2rayN 等 Xray 内核客户端里连不上？

Xray 内核自 2026-06-01 起不再接受只带 `insecure=1` 的自签名节点。重新复制分享链接
即可——新链接带证书指纹 `pinSHA256`。也可以用 `hy2domain` 申请真证书，彻底不需要
`insecure`。

### Q: 启用端口跳跃后间歇断流？

多半是云厂商安全组没有放行那段 UDP 端口。节点信息里的 "Port hopping" 一行写着
范围，照着在安全组里放行 UDP 即可。

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

### Q: Alpine 上安装 AnyTLS / Hysteria2 报 `cannot execute: required file not found`？

这是 sing-box 归档选错的表现，已修复。sing-box 从 v1.13.0 起把默认 linux 归档改成
动态链接 glibc，Alpine（musl）没有 glibc 动态链接器，内核会直接拒绝执行，随后被报
成 `Generated sing-box config is invalid`。脚本现在会检测 musl 并下载静态链接的
`-musl` 归档，安装后立即验证二进制可执行。升级脚本后重新安装节点即可；已经装坏的
二进制会被自动替换。

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

### Q: 提示"脚本已在运行中"，但我确定没有在运行？

脚本用 `/tmp/proxy-hub-<uid>/write.lock.d` 保证同一时刻只有一个写操作。报错时
会给出锁记录的 PID 并区分两种情况：

- **另一个实例正在运行**：按提示先确认该进程（`ps -p <PID> -o pid,ppid,lstart,cmd`）。
  确认是 proxy-hub 后结束它即可释放锁（`kill <PID>`，脚本会在 TERM 时清理），不要
  对无关进程动手。注意 `pkill <PID>` 不做这件事，`pkill` 匹配的是进程名不是 PID。
- **残留锁**：owner 已退出、PID 已被无关进程复用或锁跨越了重启时，脚本会直接打印
  可复制的清理命令（`rm -rf -- /tmp/proxy-hub-<uid>/write.lock.d`）。

### Q: 多节点共用一个 Xray 进程吗？

VLESS 与 Shadowsocks 节点在同一个 Xray 配置中作为多个 inbounds；AnyTLS 与
Hysteria2 节点在同一个 sing-box 配置中作为多个 inbounds。两个内核独立运行，
脚本会按现有节点类型同步和重启需要的服务。

## 更新日志

### v5.7.1
- **修复**：可选的配置加密（`ENABLE_CONFIG_ENCRYPTION`）会把密文写成两行，节点文件
  读不回来。现在密文固定为单行；解不开的密文不再被当作明文使用，查看节点信息与
  分享链接时也会先解密
- **Hysteria2 可由 Xray 承载**：`hy2core=xray` 或在"编辑节点"里切换，分享链接不变；
  经真实 Xray 与 sing-box 客户端在本机回环上互通验证
- 升级向导新增可选项：把现有 REALITY 节点的 shortId 换成 16 位（收益有限，默认不勾选）
- `help` 补全了 Hysteria2、REALITY、VLESS 的安装参数

### v5.7.0
- **升级向导**：打开菜单时检测旧版脚本留下的节点与内核并提示一次；向导逐项说明
  "为什么升 / 代价是什么"，推荐项默认勾选、回车即执行，会改链接的项需主动勾选并二次
  确认；节点改动先快照，失败自动恢复。新增 `upgrade`、`upgrade check`、
  `upgrade apply recommended|all|ID`
- **引导式菜单**：协议选择、Hysteria2 加固、后量子选项、BBR 菜单都加了逐项说明；
  复杂功能提供回车即用的推荐方案，密码、端口范围、密钥全部随机生成
- **REALITY**：配置改用 `target`（按内核能力探测，旧内核仍写 `dest`）并去掉服务端无效
  的 `fingerprint`；默认端口优先 443；shortId 加长到 16 位并支持附加 shortId
  （`sids=`）；候选域名移除 Apple/iCloud，测速要求 TLS 1.3 并按 ASN/CDN 重排
- **VLESS**：`both` 节点的 XHTTP 使用独立凭据；可选 VLESS Encryption（`vlessenc=`）
  与 REALITY ML-DSA-65（`mldsa65=`）；XHTTP 链接带 `mode=auto`
- **Hysteria2**：分享链接加入证书指纹 `pinSHA256`；可选 Salamander 混淆
  （`hy2obfs=`）、端口跳跃（`hy2hop=`）与 ACME 真证书（`hy2domain=`）
- **sing-box**：安装与更新强制校验 SHA-256、预检配置、原子替换、失败回滚；新增
  `singbox-version`、`singbox-update`
- **加固**：服务沙箱 drop-in（起不来自动撤销）；GeoIP/GeoSite 校验后原子更新；
  WARP 第三方脚本执行前显示摘要并可固定；健康检查提示低于安全基线的内核；
  刷新 sysctl 调优模板
- **Shadowsocks 2022** 重新定位为中转/落地用途（仍完整支持）

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
- 内置 102 域名测速结果之外的补充手段，安装与编辑节点时均可用

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
