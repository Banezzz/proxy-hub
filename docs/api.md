# CLI 与 Loader 契约

Proxy Hub 没有 HTTP API。本文件记录对用户和发布工具稳定的 CLI、环境变量、节点
配置与 loader 契约。

## 入口

```text
bash proxy-hub.sh [command]
./proxy-hub.sh [command]
bash <(curl -Ls https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh) [command]
```

无命令或 `menu` 进入交互菜单。参数必须原样从 loader 传给业务入口；loader 不得
消费业务 stdin，也不得把进程替换改为会占用 stdin 的 `curl | bash`。

## 命令

| 类型 | 命令 |
| --- | --- |
| 节点 | `install`, `list`, `info`, `qr`, `status`, `health`, `remove`, `edit` |
| 运维 | `restart`, `regenerate`/`regen`, `update-ip`, `netstack`/`ipstack`, `uninstall`, `test-sni`, `xray-update`, `singbox-update` |
| 升级 | `upgrade`/`migrate`（向导）, `upgrade apply recommended\|all\|ID,ID...` |
| 只读状态 | `xray-version`, `singbox-version`, `upgrade check` |
| 工具 | `tools`, `warp`, `bbr`, `swap`, `fail2ban`, `timesync`, `ports`, `logs` |
| 调度 | `xray-restart`/`restart-schedule` |
| 其他 | `menu`, `help`, `--help`, `-h` |

未知命令显示帮助。写操作沿用单实例锁；只读命令保持现有 dispatch 分类。

## 安装环境变量

| 变量 | 契约 |
| --- | --- |
| `name` | 节点名称 |
| `proto` | `vision`, `xhttp`, `both`, `shadowsocks`/`ss`, `anytls`, `anytls-reality`, `hysteria2`/`hy2` |
| `xhttp` | 兼容参数；`true`/`1`/`y` 等同 `proto=both` |
| `reym` | SNI 域名 |
| `vlpt` | Vision 端口 |
| `xhpt` | XHTTP 端口 |
| `sspt` | Shadowsocks 端口 |
| `atpt` | AnyTLS 端口 |
| `hy2pt` | Hysteria2 UDP 端口 |
| `uuid` | VLESS UUID |
| `ssmethod` | Shadowsocks method |
| `sspwd` | Shadowsocks 密码 |
| `atpwd` | AnyTLS 密码 |
| `hy2pwd` | Hysteria2 密码；8-128 位 URI 安全字符，不传时随机生成 |
| `hy2sni` | Hysteria2 TLS SNI；不传时使用 `www.bing.com` |
| `hy2obfs` | Hysteria2 Salamander 混淆；布尔真值生成随机密码，其他值作为密码（8-128 位字母、数字或 `._-`） |
| `hy2hop` | Hysteria2 端口跳跃；`auto` 随机选 200 个端口，或 `起始-结束`（跨度不超过 20000，不得覆盖其他节点的 UDP 端口或跳跃范围）；需要 iptables |
| `hy2domain` | 用 ACME 为该域名签发证书；需 80/tcp 或 443/tcp 至少一个空闲 |
| `hy2email` | ACME 账户邮箱，可选 |
| `hy2core` | Hysteria2 的承载内核：`singbox`/`sing-box`（默认）或 `xray`；其他值返回非零 |
| `vlessenc` | VLESS Encryption；布尔真值或 `x25519` 使用 X25519 认证，`mlkem` 使用 ML-KEM-768 认证 |
| `mldsa65` | 布尔真值启用 REALITY ML-DSA-65；目标证书不超过 3500 字节或内核不支持时告警并跳过 |
| `sids` | 附加 REALITY shortId，逗号或冒号分隔；每个为 2-16 位、偶数长度的十六进制 |
| `ipstack` | `dual`（默认）、`v4`、`v6`；同时接受 `both`/`ipv4`/`ipv6`/`4`/`6`/`v4-only` 等写法 |
| `restart` | `daily`, `12h`, `6h`, `weekly`, `no` 及既有布尔别名 |

变量名为既有的小写 shell 环境变量，拆分不能改名或转换为只接受命令行 flag。

布尔真值为 `true`/`1`/`y`/`yes`/`on`（不区分大小写）。上表中 `hy2obfs` 及其后的变量
都是可选增强，**未设置时一律关闭**。只要调用方设置了 `proto` 或任一增强变量，安装
流程就不会追加任何新的交互提问，因此既有的无人值守脚本得到与之前相同的节点。完全
交互的安装（未设置 `proto`）才显示引导菜单，其中 Hysteria2 的默认选择是"Salamander
混淆（随机密码）"。

## 节点文件字段

节点文件 `/root/reality_nodes/<name>.env` 每行一个 `KEY=VALUE`，只能经
`safe_read_config_value` / `safe_load_node_config` 读取。下列字段是在原有字段之外
新增的，**全部可选**：缺失时行为与新增之前完全一致，旧节点文件无需迁移。

| 字段 | 含义 |
| --- | --- |
| `EXTRA_SHORT_IDS` | 附加 REALITY shortId，冒号分隔；只进服务端白名单，不进分享链接 |
| `XHTTP_UUID`, `XHTTP_PUBLIC_KEY`, `XHTTP_PRIVATE_KEY`, `XHTTP_SHORT_ID` | `both` 节点 XHTTP inbound 的独立凭据；缺失时与 Vision 共用 |
| `MLDSA65_SEED`, `MLDSA65_VERIFY` | REALITY ML-DSA-65 的服务端种子与客户端公钥（分享链接 `pqv`） |
| `VLESS_DECRYPTION`, `VLESS_ENCRYPTION` | VLESS Encryption 的服务端与客户端串（分享链接 `encryption`） |
| `HY2_OBFS_PASSWORD` | 非空即启用 Salamander 混淆 |
| `HY2_HOP_PORTS` | 端口跳跃范围 `起始-结束` |
| `HY2_DOMAIN`, `HY2_EMAIL` | 非空即使用 ACME 证书 |
| `HY2_CORE` | Hysteria2 的承载内核；`xray` 表示 Xray，空或其他值表示 sing-box |

`reset_node_state` 仍是这些变量的唯一权威清单；`load_node_for_edit` 是"读入、解密、
修改后 `save_env` 重存"流程的唯一入口，节点编辑与升级向导共用。

### 节点归属

一个节点由哪个内核承载只由 `node_core_of PROTOCOL_TYPE [HY2_CORE]` 决定，节点计数、
两个内核的配置渲染、安装、编辑与回滚都经过它：

| `PROTOCOL_TYPE` | `HY2_CORE` | 内核 |
| --- | --- | --- |
| `anytls`, `anytls_reality` | 任意 | sing-box |
| `hysteria2` | `xray` | Xray |
| `hysteria2` | 空或其他 | sing-box |
| 其余（含缺失） | 任意 | Xray |

### 可选的配置加密

`ENABLE_CONFIG_ENCRYPTION=true` 且密钥文件 `/root/.reality_vision_key` 存在时，
`save_env` 把敏感字段写成密文。契约：

- 密文是**单行** base64（以 `U2FsdGVk` 开头），符合节点文件的字符集与逐行格式。
- `decrypt_value` 对未加密的值原样返回；对解不开的密文输出**空串**并告警，始终返回
  0。它从不把密文当作明文返回。
- `decrypt_into VAR` 就地解密一个全局变量，解不开时返回非零且不改动该变量。
  `load_node_for_edit` 用它：任何一个敏感字段解不开就拒绝加载，从而不会在随后的
  `save_env` 里用空值覆盖节点文件中仅存的密文。

## sing-box Release 契约

| 变量 | 兼容别名 | 契约 |
| --- | --- | --- |
| `SINGBOX_VERSION` | `singbox_version` | 固定 release；可带 `v` 前缀；语法同 Xray 的版本校验 |
| `SINGBOX_SHA256` | 无 | release 元数据缺少摘要时由操作者给出的期望 SHA-256；给出后同样强制比对 |
| `SINGBOX_BACKUP_KEEP` | 无 | 脚本备份保留数；默认 `3` |

`singbox-version` 只读显示本地版本、latest stable 与安全基线；远端查询失败只把该项
标为不可用。`singbox-update` 属于写操作，沿用单实例写锁。

安装与更新共用 `singbox_install_release`，顺序不可交换：

1. 读取 release 元数据（`releases/latest` 或 `releases/tags/v<version>`）；
2. 按 libc 从元数据里选归档名（musl 优先 `-musl`，不存在则回落默认归档）；
3. 要求资产的 `digest` 为 `sha256:<64 位十六进制>`，且下载地址位于官方 release 路径；
   不满足即失败关闭，不下载、不执行；
4. 下载并比对 SHA-256，解包，候选 binary 必须可执行且报告 tag 对应的版本；
5. 存在配置时候选 binary 必须通过 `check -c`；
6. 备份旧 binary，在同目录暂存后 `rename` 替换；
7. 原先 active 的服务重启后必须恢复 active，否则换回备份并再次重启。

未指定版本时不降级：已安装版本高于 stable 时保持不变。普通节点 `install` 发现可运行
的 sing-box 时只报告、不替换，与 Xray 的语义一致。

## 升级契约

`upgrade_scan` 离线、只读，产出若干"可升级项"。每项有稳定 ID、分类和两行说明：

| 分类 | 含义 | 向导默认 |
| --- | --- | --- |
| `safe` | 只动服务端，客户端零改动 | 勾选 |
| `relink` | 分享链接改变，客户端必须重新导入 | 不勾选，执行前二次确认 |
| `info` | 仅告知，没有动作，不能被 `apply` 选中 | — |

| ID | 分类 | 触发条件 | 动作 |
| --- | --- | --- | --- |
| `core.xray` | safe | 已安装 Xray 低于安全基线 v26.10.31 | `XRAY_CHANNEL=stable` 的 `xray-update` |
| `core.singbox` | safe | 已安装 sing-box 低于安全基线 1.13.16 | `singbox_install_release update` |
| `cfg.reality-fields` | safe | Xray 配置含 `dest` 或 `fingerprint`，且内核支持 `target`（或本次会更新内核） | 重建配置 |
| `svc.hardening` | safe | systemd ≥ 235，服务在运行、未加固、无跳过标记 | 下发 drop-in 并验证 |
| `geodata.cron` | safe | crontab 仍是未校验的更新命令 | 安装 helper 并替换 cron |
| `sysctl.template` | safe | 调优文件含 `tcp_low_latency` | 按当前算法重写 |
| `node.<name>.sni` | relink | REALITY 目标是 Apple/iCloud 系域名 | 测速并按 ASN/CDN 评分自动换域名 |
| `node.<name>.port443` | relink | REALITY 节点不在 443，且 443/tcp 空闲、未被节点登记；每次扫描至多提供给一个节点 | 端口改为 443 并放行 |
| `node.<name>.shortid` | relink | REALITY 节点的 shortId 非空且不足 16 位 | 换成随机的 16 位 shortId（已拆分凭据的 `both` 节点连同 XHTTP 的一起换） |
| `node.<name>.split` | relink | `both` 节点没有 XHTTP 独立凭据 | 生成 XHTTP 凭据 |
| `node.<name>.vlessenc` | relink | VLESS 节点未启用 VLESS Encryption，且内核支持 | 生成 X25519 认证的密钥对 |
| `node.<name>.hy2obfs` | relink | 自签名 Hysteria2 节点未启用混淆 | 生成随机混淆密码 |
| `node.<name>.ss` | info | Shadowsocks 节点 | — |
| `links.pin` | info | 存在自签名 Hysteria2 节点 | — |

`upgrade_apply` 的顺序固定为"内核 → 节点与配置 → 系统项"。节点改动前把节点文件与
两个内核的配置快照到 `/var/lib/proxy-hub/upgrade-backups/<时间>-<pid>/`（mode 0700，
保留最近 5 份）；所有节点改动合并成一次 `cmd_regenerate`，失败时用快照恢复节点文件并
再次重建。一项失败不终止其余无关的项；有任何一项失败时命令返回非零。

- `upgrade check`：只读，不取写锁，退出码恒为 0。
- `upgrade apply [recommended|all|ID,ID...]`：缺省为 `recommended`（全部 `safe` 项）；
  `all` 为全部 `safe` 与 `relink` 项；显式列表中的每个 ID 必须出现在本次扫描结果里且
  不是 `info`，否则不执行任何项并返回非零。
- `upgrade`（无参数）：有终端时进入向导；没有终端时退化为 `upgrade check` 的输出并
  提示无人值守命令，不提问也不修改。

`/root/.proxy_hub_upgrade` 记录"已处理或已知悉"的那一批可升级项的指纹（ID 集合排序
后的 SHA-256）。打开交互菜单时，仅当存在可升级项且指纹与记录不同才提示一次。该
文件按不可信输入处理：非十六进制字符被剔除，符号链接不被信任，内容从不被求值。

## Xray Release 环境变量

| 变量 | 兼容别名 | 契约 |
| --- | --- | --- |
| `XRAY_VERSION` | `xray_version` | 固定 release；接受 `v26.7.11` 或 `26.7.11`，规范为带 `v` 的 tag |
| `XRAY_CHANNEL` | `xray_channel` | `stable` 或 `prerelease`；未设置时为 `stable` |
| `XRAY_BACKUP_KEEP` | 无 | 脚本备份保留数；默认 `3` |

选择优先级固定为 `XRAY_VERSION > XRAY_CHANNEL > stable`。同一变量的大写形式优先于
小写兼容别名，解析后内部只保留一份规范值。版本至少必须匹配
`^v?[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9._-]+)?$`；channel、版本或备份数非法时
返回非零，禁止把原值直接拼入 shell 命令、`eval` 或 source GitHub API JSON。

示例：

```bash
XRAY_CHANNEL=prerelease bash proxy-hub.sh xray-update
XRAY_VERSION=v26.7.11 bash proxy-hub.sh xray-update
xray_version=26.7.11 bash proxy-hub.sh xray-update
```

## Xray Release 命令契约

### `xray-version`

只读显示本地安装版本、latest stable、最新非 draft release（包括 prerelease）、当前
配置 channel，以及本地相对两个远端版本的状态。本地版本从 `xray version` 的可识别
字段提取并规范为 `v...`，不能假设 stdout 只有一种固定句式。未安装时显示
`Not installed`；任一个 GitHub API 查询失败或限流时仍显示本地结果，并把对应远端项
标记为不可用，而不是让整个命令崩溃。版本比较优先使用 `sort -V`，平台不支持时使用
不执行用户输入的确定性 fallback。

### `xray-update`

非交互调用按上述环境变量解析目标；没有 release 变量时默认 stable。交互调用提供
latest stable、包括 prerelease 的 latest release、指定版本和取消。工具菜单中的
`Xray Version / Update` 先显示状态，再提供相同选择；新增菜单文案必须在英文、中文
`msg()` 映射中成对定义。`show_help` 同步列出两个命令、环境变量优先级和示例。

普通节点 `install` 发现 `$XRAY_BIN` 可执行且能读取版本时只报告并保留当前 binary，
不因默认 stable 或显式 channel 自动升级/降级。全新安装根据 release 变量选择目标；
显式 `xray-update` 才允许替换已安装 binary，包括用户明确选择同一版本时的重装。
最终授权在 lifecycle lock 内按操作意图重验：ordinary preserve，channel 仅 upgrade，
fixed 才允许 reinstall/downgrade/repair。锁外读取不作为替换依据。

release zip 与官方 SHA-256 digest 必须来自同一 Xray release。缺失 digest、无法唯一
定位目标 zip 的 digest 或 hash 不匹配均失败关闭。通过 checksum 后仍必须验证 zip、
新 binary 可执行且报告目标版本，并用新 binary 测试现有
`/usr/local/etc/xray/config.json`：先尝试 `run -test -config`，再兼容旧 `-test -config`
形式。只有全新安装且配置不存在时可跳过；更新已有 Xray 时配置缺失必须明确报错，
不得删除旧 binary。

激活前检查 `/usr/local/bin` 可用空间，在同目录准备 mode `0755` 的临时 binary；旧
binary 备份命名为 `xray.bak-v<version>-YYYYMMDD-HHMMSS`。cutover 将当时的 target
移动到 transaction staging 并核对记录 digest，随后仅在 canonical path 不存在时以
no-clobber hardlink 发布 candidate；fresh install 同样拒绝覆盖并发出现的 binary。
服务操作只经 `service_start`、`service_stop`、`service_restart`、`service_is_active`
等 adapter，兼容 systemd 与 OpenRC。事务记录开始时的 active 状态：原先运行则替换后
必须重启并同时通过服务状态与主进程 identity 检查，原先停止则不能把更新变成隐式启用。
下载后的旧 binary 在创建备份与实际 stop 边界都会重新核对 inode、digest、owner、mode
与服务 PID；`/proc/*/comm` 的 Xray 集合必须只含 service MainPID，
避免长时间预检期间的外部替换。archive 成员列表和 metadata probe 同样受时间、输出、
成员数、单成员大小与剩余解压空间上限约束。
临时父目录及其完整 canonical ancestor chain 必须是当前 UID/root-owned 且不可
group/world write，或 root-owned sticky directory；
创建后记录目录 device/inode，在下载、执行 candidate 与递归清理前重新验证，identity
改变时失败关闭并保留替代路径。原本 inactive 的服务若在预检期间变 active，也会在
rename 前失败关闭，不停止该外部启动的进程。无论服务是否 active，rename 前都再次
核对原 binary device/inode 与 digest；最终 cutover 和恢复仍按实际移动后的 digest
分类，外部替换会被保留而不是覆盖或删除。

替换、启动或健康检查失败时自动原子恢复旧 binary，并恢复事务开始时的服务状态。
成功后仅清理本脚本命名的备份并保留最新 `XRAY_BACKUP_KEEP` 份，不删除其他文件。
INT/TERM/HUP（包括 `Ctrl+C`）由函数局部 trap 触发当前进程回滚，且 trap 离开函数后
恢复；`SIGKILL` 与断电不可捕获，持久 transaction 状态与 backup 留给下一次 Xray
写操作先恢复/验证。恢复失败必须保留 backup，返回非零，并输出包含准确路径的人工
恢复命令。若 canonical path 的 binary 不等于 journal 中的旧/新 digest，恢复必须保留
该 binary 与 transaction evidence，并要求人工识别后再给出旧备份恢复步骤。
恢复源在发布前必须匹配 old digest、当前 UID owner 与 journal 记录的 old mode；损坏或被替换的 source 被跳过，不得先占用 canonical
path。`committed`/`rolled-back` 终态也必须先验证 canonical target 与 journal 一致，
symlink、目录、owner/mode/hash 失败或不一致均保留 journal/stages/backups 并失败关闭。
named backup 必须与 restore stage 使用不同 inode；所有终态清理复用同一 finalizer，
且在删除任何 stage 前先验证全部 stage 为脚本拥有的普通文件。
`xray-version` 是只读命令，不触发持久事务恢复。
持久状态只接受私有 root-owned 目录内、mode `0600`、单链接且有大小上限的固定 journal；
首次创建状态目录时同步其 containing directory。journal pathname 一经成功发布就立即
绑定新 inode，使随后 file/directory sync 的单点失败仍可由原事务写入 rollback 终态。
pre-rename payload 必须由 state 目录内的唯一 `mktemp` 创建，失败时仅按记录的 inode
删除该 payload，保证相同 transaction token 可以重试。durable committed journal 的发布窗口
会延迟并记录 INT/TERM/HUP，内存状态确认 committed 后才重放终止状态，禁止误回滚。

脚本创建的 Xray systemd/OpenRC 定义带 managed marker，并通过同目录临时文件、fsync
与 rename 原子发布；未标记且不匹配旧模板的用户自定义定义保持不变。周期重启不再对
lock pathname 直接调用 `flock`，而由固定 root-owned helper 校验 owner/symlink/mode，
append-open FD 并核对 inode 后获取同一 lifecycle lock，且只重启原本 active 的内核。
OpenRC 的 Xray MainPID 在没有可信 literal pidfile 时从同一 `/proc` 枚举器取得唯一 PID，
Xray release 路径不要求 `pgrep`。

## 网络栈契约

网络栈是**实例级**设置，持久化在 `/root/.proxy_hub_netstack`，取值只有 `dual`、
`v4`、`v6` 三种，默认 `dual`。文件缺失、为空、是符号链接或内容不在这三个值之内时
一律回退 `dual`；原始内容永远不会进入配置文件或被当作 shell 代码执行。

| 档位 | Xray inbound | sing-box inbound | Xray freedom 出站 | SNI 测速 | IP 探测与分享链接 |
| --- | --- | --- | --- | --- | --- |
| `dual` | `listen: "0.0.0.0"` | `listen: "::"` | 不写 `domainStrategy`（Xray 默认 `AsIs`） | 不限定协议族 | IPv4 与 IPv6 都探测、都输出 |
| `v4` | `listen: "0.0.0.0"` | `listen: "0.0.0.0"` | `settings.domainStrategy = "UseIPv4"` | `openssl s_client -4` | 只探测并输出 IPv4 |
| `v6` | `listen: "::"` + `streamSettings.sockopt.v6only = true` | `listen: "::"` | `settings.domainStrategy = "UseIPv6"` | `openssl s_client -6` | 只探测并输出 IPv6 |

约束与边界：

- `dual` 档产出的配置必须与引入本设置之前逐字段一致。Xray 与 sing-box 在该档
  各自保留历史写法：两者在通配地址上等价（Go 监听通配地址且 network 为 `tcp`
  时创建未设 `IPV6_V6ONLY` 的 `AF_INET6` socket，Xray 文档亦说明 `"0.0.0.0"`
  与 `"::"` 等价），改写只会给现有安装引入无收益的行为变更。
- 只有 `v6` 档写 `sockopt.v6only`，由 Xray 转成 `IPV6_V6ONLY`。sing-box 没有等价
  字段，因此 AnyTLS / Hysteria2 在 `v6` 档仍是双栈绑定，只是不再产出 IPv4 链接。
- `v4` 档不做 socket 级强制：真正的 v4-only 监听要求 bind 具体网卡地址，而 NAT 型
  云主机的公网地址并不在网卡上，bind 它会让服务无法启动。该边界记录在
  `docs/audits.md`。
- 出站只使用 `UseIPv4` / `UseIPv6`。`UseIPv4v6` 一类较新的枚举值会让旧 Xray binary
  在 `xray -test` 阶段拒绝配置，而普通 `install` 不会升级健康的既有 binary。
- 切换必须走"保存 → 重建两个内核配置 → 重启"的顺序，任一步失败都恢复原设置并
  再次重建，不允许留下"文件写着新档、运行中却是旧配置"的状态。尚无节点时只保存。
- `netstack` 是写操作，沿用单实例写锁。`ipstack=` 环境变量在 `netstack` 与
  `install` 两条路径上都被接受；`install` 路径必须在 SNI 测速与 IP 探测之前落盘。

## 协议运行时契约

| `PROTOCOL_TYPE` | 内核 | 监听 transport | 安装后本机防火墙 |
| --- | --- | --- | --- |
| `vision` | Xray | TCP | `PORT/tcp` |
| `xhttp` | Xray | TCP | `XHTTP_PORT/tcp` |
| `both` | Xray | TCP | `PORT/tcp` 与 `XHTTP_PORT/tcp` |
| `shadowsocks` | Xray | TCP+UDP | `PORT/tcp` 与 `PORT/udp` |
| `anytls`, `anytls_reality` | sing-box | TCP | `PORT/tcp` |
| `hysteria2` | sing-box | UDP/QUIC | `PORT/udp` |

由 sing-box 承载的 AnyTLS 与 Hysteria2 聚合到同一个
`/usr/local/etc/sing-box/config.json` 和 sing-box service；Hysteria2 不引入独立
二进制或每节点 service。云平台安全组不属于本机防火墙契约，调用方仍须按上表开放
外部入口。

`HY2_CORE=xray` 的 Hysteria2 节点改由 Xray 承载，渲染进 Xray 配置：
`protocol: hysteria`、`settings.version: 2`、`streamSettings.network: hysteria`、
`security: tls`（`alpn: ["h3"]`，证书仍是 `SINGBOX_CERT_DIR` 下的逐节点证书）；未启用
混淆时带 `hysteriaSettings.masquerade`，启用时改为
`streamSettings.finalmask.udp[{type: salamander}]`。监听地址与 `sockopt.v6only` 跟随
网络栈设置。对客户端而言它与 sing-box 承载的节点等价，**分享链接不随内核改变**。
限制：需要 Xray ≥ v26.3.27，否则配置生成失败；不支持 `HY2_DOMAIN`（ACME）；OpenRC
上不支持 `HY2_HOP_PORTS`。这些组合在安装与编辑时被拒绝。上表"内核"一列对这类节点
读作 Xray，transport 与防火墙规则不变。

Hysteria2 的证书与链接：

- 默认使用逐节点自签名证书（ECDSA P-256，不得改为 Ed25519），分享链接为
  `hysteria2://...?sni=...&insecure=1&pinSHA256=<证书 DER 的 SHA-256 十六进制>`；
  证书文件缺失时省略 `pinSHA256`。
- 设置了 `HY2_DOMAIN` 时由 sing-box 通过 ACME 签发：sing-box ≥ 1.14 渲染为顶层
  `certificate_providers` 加 inbound 的 `certificate_provider` 引用，更早版本渲染为
  内联 `tls.acme`；443/tcp 被本机节点登记时禁用 TLS-ALPN-01，80/tcp 被登记时禁用
  HTTP-01。链接只带 `sni=<域名>`。安装后额外放行未被节点占用的 `80/tcp` 与 `443/tcp`。
- `HY2_OBFS_PASSWORD` 非空时 inbound 增加 `obfs.type=salamander` 并去掉 `masquerade`，
  链接追加 `obfs=salamander&obfs-password=...`。
- `HY2_HOP_PORTS` 非空时链接追加 `mport=<范围>`；NAT 规则位于专用链
  `PROXY_HUB_HY2_HOP`，由 `/usr/local/libexec/proxy-hub-hy2-hop apply` 幂等重建，并随
  sing-box 与 xray 两个服务的启动重新下发（systemd drop-in；OpenRC 只有 sing-box
  有该钩子）。

REALITY 入站（Xray）：内核支持时写 `target`，否则写 `dest`，两者不同时出现；不写
`fingerprint`；`shortIds` 为主 shortId 加 `EXTRA_SHORT_IDS`。节点带有 `MLDSA65_SEED`
或 `VLESS_DECRYPTION` 而内核不支持对应能力时，配置生成失败而不是丢弃该字段。

## 交互输出契约

- `qr` 与安装完成后的二维码使用同一安全节点加载和协议分派路径。
- `vision`、`xhttp`、Shadowsocks、AnyTLS、Hysteria2 各显示一个二维码；`both`
  分别显示 Vision 和 XHTTP 两个二维码。`get_share_link` 继续保持单链接兼容行为。
- SS2022 安装后的时间同步提示在普通环境提供 `1=安装`、`2=检查`、`0=跳过`；
  无时钟权限的容器只提供 `1=检查`、`0=跳过`。跳过、空输入和无效输入无副作用。

## Loader 环境变量

### `PROXY_HUB_REF`

指定远程 dist bundle 的 Git ref。默认发布通道可使用 `main`；可复现执行应传完整
commit SHA，并让外层 loader URL 使用同一个 SHA：

```bash
export PROXY_HUB_REF='<40-character-commit-sha>'
bash <(curl -Ls "https://raw.githubusercontent.com/Banezzz/proxy-hub/${PROXY_HUB_REF}/proxy-hub.sh")
```

loader 必须拒绝可导致 URL/path 注入的 ref，禁止协议、空白、控制字符、`..` 和
shell 元字符。

## 本地装载契约

- loader 从可用的 `BASH_SOURCE[0]` 推导仓库根。
- 相邻 `lib/` 出现 manifest 或任一预期模块名即视为本地 footprint，必须恰好含
  manifest 和预期 11 个普通、非 symlink 模块并通过校验；部分、损坏或额外文件
  都失败关闭。空目录或只有无关文件时仍按 standalone loader 进入远程模式。
- 将模块复制到私有快照后按 manifest 固定顺序组装/source，不能使用未排序 glob。
- 最终组装 body 必须匹配快照模块的总字节数和独立串流 SHA-256，打开只读
  FD 后再验 bytes/digest，防止短写、整模块遗漏或验证后路径替换进入执行。
- 本地模式同样要求 `sha256sum`、`shasum` 或 `openssl` 之一。
- 只下载一个 loader 文件不构成离线安装；缺少本地模块时进入远程路径。

## 远程装载契约

- `bash <(curl ...)` 的脚本主体来自 `/dev/fd/<n>`；loader 不能关闭或复用仍承载
  脚本 body 的 FD，也不能假设该路径旁存在模块目录。bundle 校验在下载得到的
  独立文件/FD 上完成。
- bundle 只能通过 HTTPS 获取。
- 完整下载后，先验证 SHA-256 与 trailer，再 source；禁止边下边执行。
- trailer 的 header byte count/digest 必须与 loader 内嵌的 header 契约相同。
- 支持 `sha256sum`、`shasum` 或 `openssl`，三者均无时失败关闭。
- byte count、digest、build ID、模块数或 trailer marker 任一缺失/冲突时，以
  非零状态退出。
- 用于 `bash -n` 的 header/body 重建必须重验总长度，并按 trailer 边界切回后分别
  重验 SHA-256；写入失败或静默遗漏不得仅凭“剩余前缀语法合法”通过。
- 临时文件位于 `${TMPDIR:-/tmp}/proxy-hub.bootstrap.XXXXXXXX` 进程专属目录，
  `TMPDIR` 必须是当前 UID 独占可写或 root 拥有且带 sticky bit 的安全目录；临时
  目录 owner/device/inode 未变化时才会在成功、失败和可捕获信号下清理。
- loader 在删除临时目录前打开已验证 runtime body 的只读 FD，然后从
  `/dev/fd/<n>` source、原样传递用户参数并关闭 FD。

## Manifest/Trailer 发布契约

`lib/manifest.sha256` 固定为 start marker、`# api=1`、64 位小写
`# build-id=HEX`、11 行 `HEX<两个空格>module-name`、end marker，共 15 行。
模块名不得包含目录、空白或 `/`。manifest build ID 是规范字节流 `api=1\n` 加
每个 `module-name NUL module-digest LF` 的 SHA-256。dist 构建器按该顺序合并
模块。manifest 自身禁止 NUL 且必须以 LF 结尾；loader 在行解析前验证原始字节。
构建器在 bundle 文件尾追加以下唯一 trailer：

```text
# proxy-hub-bundle-manifest-v1
# header-bytes=N header-sha256=HEX
# body-bytes=N body-sha256=HEX
# build-id=HEX
# module-count=11
# proxy-hub-bundle-end-v1
```

`build-id` 等于 `body-sha256`。loader 必须验证 byte count、digest、build ID、模块
数和首尾 marker；模块、body、bundle 均禁止 NUL 字节。trailer 不是展示文本，
不得手工编辑。唯一构建入口是：

```bash
bash scripts/build-bundle.sh
```

HTTPS 和同源 checksum 只证明所下载字节的一致性，不能独立认证发布者。高信任
使用方必须从可信渠道取得外层 commit SHA，并同时 pin loader URL 和
`PROXY_HUB_REF`。

## 节点配置契约

节点文件保持位于 `/root/reality_nodes/<name>.env`，键集合保持：

```text
NODE_NAME SERVER_IP SERVER_IPV4 SERVER_IPV6 PORT UUID SNI
PUBLIC_KEY PRIVATE_KEY SHORT_ID PROTOCOL_TYPE XHTTP_PORT XHTTP_PATH
SS_METHOD SS_PASSWORD ANYTLS_PASSWORD ANYTLS_PADDING_B64
HY2_PASSWORD
```

旧配置没有 `PROTOCOL_TYPE` 时继续按现有端口字段推断协议；`UUID`、私钥、SS/AnyTLS/
Hysteria2 密码等敏感字段继续兼容明文和现有 OpenSSL 格式。节点文件只能通过安全
配置读取器加载，禁止直接 source。

## 错误语义

- loader 错误发生在业务 source 前，不得产生代理配置、服务或节点文件副作用。
- 下载失败、hash mismatch、远程 trailer 错误、本地 manifest 错误和缺少 hash
  工具均返回非零。
- 业务命令的既有退出码和 stdout/stderr 分流保持不变。
- 节点安装只有在目标内核配置生成/校验成功、服务重启且健康检查通过后才输出成功、
  分享链接和二维码，并在这之后按协议 transport 放行本机防火墙。
- 配置或服务健康门失败时返回非零，移除本次节点并重建此前节点的内核配置；失败
  诊断写 stderr，且不得继续输出安装成功信息。
- Xray release API 限流、空/非法 tag、官方 digest 缺失或不匹配、下载中断、zip
  损坏、新 binary 不可执行或版本不符、配置测试失败、空间不足、服务健康检查失败
  都返回非零；下载或验证失败不得停止现有 Xray，替换后的失败必须先尝试回滚。
- Xray rollback 失败时不得清理 transaction marker 或旧 binary backup，stderr 必须
  给出管理员可直接核对并执行的恢复命令。

## 写操作锁契约

所有新版写命令和兼容锁函数共享 `/tmp/proxy-hub-<uid>/write.lock.d`；`/tmp`
必须是当前 UID 独占可写或 root 拥有且带 sticky bit。锁目录由原子 `mkdir`
创建；新版只在 owner token 和目录 device/inode identity 均匹配时释放，
不会按 PID 自动删除无法证明归属的 stale 锁。发布前单文件版本的锁/cleanup 协议
不安全且不兼容；升级或回滚必须先停止全部脚本进程，禁止在线混跑新旧版本。
锁获取期间的 INT/TERM 会延迟到 owner/PID 元数据完整发布后处理；终止 cleanup
必须以 PID + start time 验证进程身份；可证明归属的进程组还绑定 leader start time
并按 PGID 重扫 reparent 子进程；成员只在 scan 后复核 leader 成功时从 provisional
集合提交，且每次发信号前再复核。TERM 后将进程树 STOP 到稳定边界，再确认退出或
KILL/reap，之后才释放锁；PGID 复用或归属不明时保留锁。SSH 自动回滚 timer 也必须
完成取消/必要回滚。`phase.pending` 通过原子 rename 只允许确认或回滚一个赢家；回滚
已 claim 时，迟到确认必须等待验证而不能 kill timer。私有状态与 backup 只有在恢复、
配置落盘、验证、服务重启、完成结果落盘全部成功后才能删除；删除成功后同步清空
进程内 rollback 状态。timeout 后只有本次 phase claim 返回成功的 worker 可恢复；该
worker 及其外部命令在 critical transaction 内忽略 INT/TERM/HUP，父 cleanup 等待完成。
若进程树或 rollback 无法确认完成，保留锁并失败关闭。

`xray-update` 与会安装 Xray 的全新节点安装属于写操作，必须在同一排他域内先检查
并恢复持久 Xray transaction；`xray-version` 只读，不获取写锁也不执行恢复。

## 构建发布锁契约

`scripts/build-bundle.sh` 使用仓库根目录 `.proxy-hub.release.lock` 串行化源快照、
manifest/bundle 双产物 cutover 和 transaction staging 清理。活跃 publisher 持有的
lock 绑定 UID/PID/start-time/token/device/inode；同一 checkout 的第二个 builder 立即
失败关闭。cutover 期间 lock payload 为 `proxy-hub-release-uncertain-v1:*`，该形态即使
PID 已死也不会自动回收；必须把两件 artifact 恢复到同一 generation 并验证后
才可人工移除。完整 rollback 或 commit 且 transaction staging 验证清理后，构建器会自动
释放自己持有且 identity 未变的 lock。
