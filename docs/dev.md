# 开发设计

## 目标

Proxy Hub 的可维护源码拆分到 `lib/`，同时保留稳定入口
`proxy-hub.sh`，并继续支持：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh)
```

拆分只改变代码的装载方式，不改变命令、环境变量、节点配置格式、交互流程或
系统副作用。根脚本是 loader；完整仓库优先加载本地模块，远程进程替换则加载
`PROXY_HUB_REF` 选择的完整、自校验 `dist` bundle。只有双重固定同一个 commit
SHA 时，才保证 loader 与 bundle 来自同一版本。

## 模块图

```text
proxy-hub.sh (loader)
  ├─ local:  lib/00_security_state.sh
  │          lib/10_runtime_platform_ui.sh
  │          lib/15_xray_release.sh
  │          lib/20_installers_restart.sh
  │          lib/30_provision_network.sh
  │          lib/40_config_share.sh
  │          lib/50_node_commands.sh
  │          lib/60_system_tools.sh
  │          lib/70_ports_logs.sh
  │          lib/80_timesync.sh
  │          lib/90_main.sh
  └─ remote: dist bundle -> 校验 -> 与上述模块相同的执行顺序
```

| 模块 | 主要职责 |
| --- | --- |
| `00_security_state.sh` | 锁、安全下载/配置读取、JSON builder、加密、全局状态与常量 |
| `10_runtime_platform_ui.sh` | 生命周期、日志与输入 UI、包管理器/init/service 适配、i18n、节点目录 |
| `15_xray_release.sh` | Xray release 查询、选择、校验、安装/更新事务、备份与恢复 |
| `20_installers_restart.sh` | sing-box、GeoData 安装、Xray service 衔接与代理内核定时重启 |
| `30_provision_network.sh` | 协议选择、凭据/transport-aware 端口生成、IP、证书与 SNI 探测 |
| `40_config_share.sh` | Xray/sing-box 配置渲染、校验、同步、节点持久化、分享链接与二维码 |
| `50_node_commands.sh` | 节点 install/info/list/edit/remove/health/update 等命令编排 |
| `60_system_tools.sh` | WARP、BBR、Swap、Fail2ban |
| `70_ports_logs.sh` | SSH/代理端口与日志管理、独立工具命令安装 |
| `80_timesync.sh` | 容器识别与时间同步管理 |
| `90_main.sh` | 工具菜单、主菜单、帮助、初始化和 CLI dispatch |

模块编号就是装载顺序，也是依赖方向。不得让低编号模块在 source 阶段调用尚未
定义的高编号模块；模块之间仍共享一个 Bash 进程和全局命名空间。

## 四分支语义移植设计

历史分支基于拆分前的单体脚本，不能把旧文件直接 cherry-pick 回来。本轮只移植
仍有价值的行为，并让实现服从当前模块、安全加载、双内核和发布产物契约。

### Hysteria2 复用 sing-box

Hysteria2 不安装独立 `hysteria` 二进制，也不为每个节点创建独立 service；它与
AnyTLS 一样由现有 `sing-box` service 承载。`write_singbox_config` 从节点目录聚合
`anytls`、`anytls_reality` 和 `hysteria2` inbounds，使用 jq builder 校验名称、端口、
密码和证书路径后一次生成配置。添加或删除其中任一节点都通过同一个 sync 路径
重建、校验并重启 sing-box；最后一个 sing-box 节点删除后才停用服务。

Hysteria2 使用 `PORT` 记录 UDP 监听端口、`HY2_PASSWORD` 记录认证密码，证书沿用
`SINGBOX_CERT_DIR/<name>.crt|key` 的逐节点自签名证书布局。密码进入节点文件前遵循
现有可选加密策略，读取一律经过 `safe_read_config_value`/`safe_load_node_config`，
不得 source 节点 env。分享链接支持 IPv4/IPv6，并明确 `insecure=1` 的自签名证书
语义。端口选择和健康检查查询 UDP socket，不得用 TCP 探测代替。

### `both` 节点的双二维码

`get_share_link` 保持返回单链接的兼容 ABI。新的二维码编排助手安全加载当前节点，
对普通协议显示一个二维码，对 `both` 分别构造 Vision 和 XHTTP 链接并显示两个。
`cmd_install` 与 `cmd_qr` 共用该助手，避免两套协议分支漂移；不得复制历史补丁中
`source "$node_file"` 的不安全做法。地址按可用的 IPv4、IPv6、旧 `SERVER_IP`
顺序回退，缺少对应端口时不生成空二维码。

### SS2022 时间同步菜单

SS2022 安装完成后的提示从 y/n 改为显式菜单。普通主机及具备时钟能力的容器提供
“安装并启用、只检查准确度、跳过”；没有 `CAP_SYS_TIME` 的容器保留权限说明，
只提供“检查、跳过”。检查路径只读取 HTTPS `Date` 头，不要求改时钟权限；空输入、
跳过和无效输入都不得产生安装副作用。菜单文案由 `10_runtime_platform_ui.sh` 的
中英文 `msg()` 表统一提供，行为位于 `80_timesync.sh`。

### 安装成功门与 transport-aware 防火墙

节点安装是“保存候选节点 → 重建并校验所属内核配置 → 重启并确认服务 active →
按 transport 放行本机端口 → 输出成功、分享信息和二维码”的有序流程。transport
映射为：Vision/XHTTP/AnyTLS 为 TCP，Hysteria2 为 UDP，Shadowsocks 为 TCP+UDP；
`both` 的两个 VLESS 端口分别按 TCP 处理。防火墙 helper 必须显式接收 transport，
避免为 Hysteria2 错开 TCP 或为所有协议无条件扩大 TCP+UDP 暴露面。

配置生成、服务重启或健康门失败时，安装返回非零，删除本次新节点及其尚未共享的
逐节点证书，重新生成受影响内核的旧节点配置并尝试恢复服务；失败路径不得继续输出
`install_complete`、分享链接或二维码。端口只在服务通过健康门后放行，因此启动失败
不产生新的防火墙规则。来宾系统无法修改云厂商安全组，仍需用户按相同 transport
在控制台放行；该边界记录在 `docs/audits.md`。

### 节点作用域变量与 `set -u`

入口脚本以 `set -euo pipefail` 运行，因此**任何一个未被赋值的变量在展开时都会立刻
终止整个进程**，而不是取到空值。节点变量（`UUID` / `SNI` / REALITY 密钥 /
各协议密码 / `SERVER_IP*` 等）又是进程级全局量，且每个协议分支只赋值自己用得到的
子集——AnyTLS 以密码认证因而没有 UUID，Shadowsocks 没有 REALITY 密钥，
Hysteria2 两者都没有。这两个事实叠加，会产生两类缺陷：

1. **未赋值即展开**。某个协议分支漏掉一个字段，安装就会在 `save_env` 处以
   `VAR: unbound variable` 中断。此前 `anytls_reality` 正是如此：它调用
   `gen_reality_keys`（只产出 `PUBLIC_KEY`/`PRIVATE_KEY`/`SHORT_ID`）而未置空
   `UUID`，安装在 sing-box 已安装、节点文件尚未落盘时崩溃。同源问题还出现在
   IPv6 Only 主机上的旧字段 `SERVER_IP`。
2. **跨节点串值**。同一次菜单会话里连续安装两个节点时，未重置的字段会把上一个
   节点的凭据写进新节点的 `.env`。

同类陷阱还有两个 bash 细节，新增代码时需一并注意：**空数组在 `set -u` 下等同未定义**
（`declare -A m` 后直接展开 `${#m[@]}` 会终止进程，必须先 `m=()` 赋值过），以及
**`local -n x=` 对空名会建立失败**，此后展开该 nameref 同样会终止进程。后者曾发生在
`prompt_sni_choice`：`select_best_sni` 在全部域名测速失败时以空名调用它，而同一行的
`2>/dev/null` 把 "unbound variable" 一并吞掉，表现为脚本无声退出、状态码 1、没有任何
提示。切勿用 `2>/dev/null || true` 掩盖 `local -n` 的失败——那只会把致命错误变成无法
诊断的静默退出。

因此约定：`lib/00_security_state.sh` 的 `reset_node_state()` 是这些变量的**唯一**
权威清单。它在模块加载时执行一次以建立基线，并由 `install_node` 在进入协议分支前
再次调用；`safe_load_node_config` 也复用它。不要在其他模块另建平行的默认值清单
——此前 `lib/20_installers_restart.sh` 与 `lib/30_provision_network.sh` 各维护了一份
只覆盖部分字段的清单，正是该缺陷的根因。新增协议或新增节点字段时只改
`reset_node_state()`，并在协议分支内显式把本协议不使用的字段置空以表明意图；
`save_env` 另以 `${VAR:-}` 兜底。回归覆盖见 `tests/test_remote_branch_features.sh`
的 `node-state-contract`，它刻意使用真实 `save_env`——把 `save_env` 打桩正是当初
让该缺陷逃过测试的原因。

## Xray Release Management

Xray target 由一个 resolver 统一决定，优先级固定为
`XRAY_VERSION > XRAY_CHANNEL > stable`。大写环境变量优先，同时兼容小写
`xray_version`/`xray_channel`；固定版本只接受受限版本语法，去除用户可选的前导
`v` 后再规范为单个 `v` 前缀。`stable` 使用 GitHub `releases/latest`，
`prerelease` 使用 releases 列表中最新的非 draft release，不把用户输入或 API JSON
当作 shell 代码执行。

普通节点安装与显式 release 变更是两条不同路径：已有 `$XRAY_BIN` 可执行且能报告
版本时，普通 `install` 只报告该版本并继续，不查询目标、不升级也不降级；全新安装
或 `xray-update` 才进入 release transaction。`xray-version` 是只读状态命令：本地
版本始终优先展示，stable 或 prerelease 查询单独失败时只标记该远端状态不可用。
安全决策在 lifecycle lock 内按 `ordinary-install`、`channel-update`、`fixed-update` 意图
重新读取实际 target：ordinary 永远保留健康 binary，channel 只升级，只有 fixed 允许
重装、降级或修复不可识别的普通 binary。

release transaction 的顺序不可交换：

1. 解析目标并映射架构；
2. 在私有临时目录下载 release zip 和同一官方 release 的 SHA-256 digest；
3. 强制校验 digest、zip 完整性、新 binary 可执行性和报告版本；
4. 以新 binary 的现代 CLI 测试现有 Xray 配置，必要时回退到旧 CLI 形式；
5. 检查目标目录空间，在 `/usr/local/bin` 同目录准备 `0755` staged binary；
6. 记录旧服务是否 active，创建带版本和时间戳的旧 binary 备份；实际 cutover 先保留并
   核验当前 target，再用 no-clobber hardlink 发布新 binary；
7. 仅经 service adapter 启停并验证 systemd 或 OpenRC；
8. 连续核对服务 active、主进程 PID 与其 executable identity，成功后清理 transaction，并只保留最近
   3 个符合 `xray.bak-v*-YYYYMMDD-HHMMSS` 的脚本备份。

release archive 的 listing/metadata 也在 timeout 与输出/成员数上限内解析，下载后的可用
空间必须同时容纳仍存在的 zip 与独立 candidate。服务真正停止前重新读取 PID，并核对
`/proc/PID/exe`、managed binary inode 与预检前 digest；同时扫描 `/proc/*/comm`，要求
service MainPID 是唯一 Xray 进程。旧 binary 在创建 hardlink backup 前也做相同的过期
状态检查；额外进程形成 sticky conflict，禁止删除 journal 或 transaction stages。
临时父目录的完整 canonical ancestor chain 必须是 trusted-owner/private 或 root-owned
sticky directory；创建的目录记录 owner 与
device/inode，artifact 验证、执行和清理都以该 identity 为门，路径被替换时保留现场并
失败关闭。激活前还会重新协调 service/process 状态，原本 inactive 却在预检期间启动的
Xray 不会被静默留在旧 inode 上并误报新版本已运行。cutover 把当时实际存在的 target
移动到本事务专属 staging 后再核验 digest；若它不是预检记录的旧 binary，则尝试恢复到
原路径并失败关闭。新 binary 只在 canonical path 不存在时以 hardlink 发布，因此 fresh
install 与 update 都不会覆盖在最后检查之后并发出现的 target。

SHA-256 是激活前的强制门：官方 digest 缺失、解析不唯一、目标 zip 条目缺失或 hash
不匹配都失败关闭，不能只依赖 HTTPS、解压成功或 binary 版本字符串。已有 Xray 的
更新必须用新 binary 测试现有配置；全新安装尚无配置时才允许显式跳过该测试，且不能
借此覆盖或删除旧配置。更新前服务未运行时，成功后保持原先的停止语义；原服务运行时，
更新后必须恢复为 active。

替换后的任何校验失败都使用已验证的旧 staging/backup 恢复，并按 transaction 开始时的运行状态恢复
服务。函数内部隔离 `set -e` 敏感步骤，确保失败处理不会在 rollback 中途提前退出；
临时 trap 捕获 INT/TERM/HUP，`Ctrl+C` 会先回滚再返回非零，且不会泄漏到脚本其他
命令。`SIGKILL` 与断电不可捕获，因此 transaction marker、staged 状态和旧 binary
备份必须持久保留；下一次 Xray 写操作在获取排他锁后先恢复/验证上一事务，再允许开始
新事务。只读的 `xray-version` 不触发恢复。恢复只会移动或删除 journal 中记录为新
binary 的 digest；canonical path 上不属于旧/新 digest 的外部 binary 必须原样保留，
并保留 journal、staging 与 backup。自动恢复失败时输出不会覆盖该外部 binary 的人工
处置指引，以及适用时引用具体备份路径的恢复命令。
journal 已标记 `committed` 或 `rolled-back` 也不是无条件清理许可：前者必须证明
canonical target 等于 new digest 且 mode 为 `0755`，后者必须证明它等于 old digest
并保留 journal 记录的 mode（fresh rollback 则必须真正不存在）；两者都要求当前 UID
拥有 binary。恢复源在 hardlink 前同时校验 owner、mode 与 digest，坏 stage 被跳过；
symlink、目录、metadata/hash 失败和无法识别的运行态一律保留现场。`XRAY_BACKUP_KEEP` 在 recovery cleanup 和
任何 Bash 算术前限制为安全的十进制范围。
named backup 经 noclobber copy、digest、独立 inode 与 fsync 验证，不与 restore stage
共享 inode。live commit、live rollback 和 persistent recovery 统一通过 terminal
finalizer；所有 managed stage 先全量预检，再复验 target/journal 后删除。dangling
journal symlink 从存在性检查开始即按冲突处理。
journal 目录首次创建时同步 containing directory；恢复只信任私有 root-owned 目录中的
`0600` 单链接、限长 journal。每次 journal 写入使用 state 目录内唯一 `mktemp` payload，
发布前失败按 device/inode identity 清理，因此不会阻塞同 token 的恢复重试。journal rename 成功后立即绑定新 inode，即使后续 file 或
directory fsync 失败，同一事务仍能发布 rolled-back 终态。commit journal fsync 到内存 committed 标记发布之间的信号
被延迟记录，标记发布后按原状态退出，从而留下可幂等清理的 committed journal 而不回滚。

Xray service 定义使用 managed marker 与同目录 fsync+rename；custom definition 不覆盖，
已管理定义每次 ensure 都可修复并重试 systemd daemon reload。周期重启安装固定 helper，
由 helper 校验并 append-open lifecycle lock FD、核对 inode 后才重启当前 active 的内核。
OpenRC 无可用 pidfile 时，Xray MainPID fallback 复用 `/proc` process-set，不依赖 `pgrep`。

## Loader 的两条路径

### 本地仓库路径

loader 通过 `BASH_SOURCE[0]` 定位自身目录。相邻 `lib/` 中出现 manifest 或任一
预期模块名时，视为本地 Proxy Hub footprint：此时必须恰好包含 manifest 和预期
的 11 个普通、非 symlink 模块，且 `lib/manifest.sha256` 匹配，才复制私有快照、
按固定顺序组装并加载；部分/损坏 footprint 或额外文件会失败关闭。空的或仅含无关
文件的 `lib/` 不算 footprint，单独下载的 loader 仍进入远程模式。完整 clone 可
离线运行，也可修改模块后通过构建脚本刷新 manifest/dist。组装的 runtime 必须
与快照模块的总字节数和独立串流 SHA-256 完全一致，否则不执行。

### 远程进程替换路径

`bash <(curl ...)` 下，`$0` 与 `BASH_SOURCE[0]` 通常是 `/dev/fd/<n>`；它们指向
进程替换 pipe，不是 GitHub URL，也没有可用的相对模块目录。loader 不能关闭或
复用仍承载脚本 body 的 file descriptor，也不能把它误判成仓库目录；bundle 的
manifest/trailer 校验必须在下载得到的独立文件描述符上下文中完成。

远程装载顺序为：

1. 检查 bootstrap 工具并判定 `/dev/fd` 远程上下文。
2. 语法校验 `PROXY_HUB_REF`（默认 `main`），再构造只允许 HTTPS 的
   `dist/proxy-hub.bundle.sh` URL。loader 不会自动把移动 ref 解析成 commit；需要
   可复现运行时由调用方显式传完整 commit SHA。
3. 完整下载 bundle；下载未完成前不 source 任何业务代码。
4. 解析 bundle 尾部六行 trailer，按其中的 byte count 切分 header/body。
5. 使用可用的 SHA-256 工具校验 header、body、build ID 和模块数；语法检查用
   header/body 精确重建，再按边界切回并复核两段 byte count/SHA，阻断短写和静默遗漏。
6. 在删除临时目录前打开已验证 runtime body 的只读 FD，对 FD 再验字节数/SHA；
   随后从 `/dev/fd/<n>`
   source 并原样转发用户参数，最后关闭该 FD。

本地和远程 loader 都要求至少存在以下一个 hash 工具：

- `sha256sum`
- `shasum`
- `openssl`

远程模式还要求系统预先存在 `curl`。这些是 loader 的前置条件，不能依赖业务层
的 `install_deps`，因为模块/bundle 必须先通过校验，业务代码才允许执行。
若设置 `TMPDIR`，其物理目录必须不可被其他 UID 改写，或是 root 拥有且启用 sticky
bit 的共享临时目录；不满足条件时 loader 会在下载前失败关闭。loader 记录自身
临时目录的 owner 与 device/inode identity，清理时发现同路径目录已被替换则拒绝
递归删除。

## Manifest 与 trailer 契约

`lib/manifest.sha256` 是 loader、模块与 dist 产物之间的发布契约，不是自由
格式注释。它固定为 15 行：

```text
# proxy-hub-manifest-v1
# api=1
# build-id=HEX
HEX  00_security_state.sh
...其余 10 个有序模块...
# proxy-hub-manifest-end-v1
```

每个 `HEX` 是 64 位小写 SHA-256；文件名不含目录、空白或 `/`。manifest
`build-id` 是规范字节流 `api=1\n` 后依次拼接
`module-name NUL module-digest LF` 的 SHA-256。构建器以自身固定的有序 `MODULES`
数组和 `lib/` 内容为输入并生成 manifest；本地 loader 以 manifest 加自身固定顺序
作为加载与完整性契约。manifest 原始字节禁止 NUL，并且必须以 LF 结尾；loader
会在 `mapfile` 解析前检查这两个 framing 条件，避免 Bash 丢弃 NUL 后误接受损坏内容。

bundle trailer 固定为末尾六行：

```text
# proxy-hub-bundle-manifest-v1
# header-bytes=N header-sha256=HEX
# body-bytes=N body-sha256=HEX
# build-id=HEX
# module-count=11
# proxy-hub-bundle-end-v1
```

字段契约：

- `header-bytes`/`header-sha256` 绑定 bundle 的生成头；
- `body-bytes`/`body-sha256` 绑定按 manifest 顺序拼接的模块正文；
- `build-id` 必须与 `body-sha256` 完全相同；
- `module-count` 当前必须是 `11`；
- 开始和结束 marker 必须占据六行 trailer 的首尾。

manifest、模块源码、组装 body 和最终 bundle 都禁止 NUL 字节；构建、本地加载和
远程加载三条路径使用同一失败关闭规则。

生成头当前取 `proxy-hub.sh` 的前 16 行；loader 内嵌该段的预期 byte count 与
digest。修改这 16 行时必须同步刷新 loader 契约并重建 dist，否则远程 preflight
会按设计拒绝新 bundle。

bundle trailer 是产物末尾六行的机器可读终止记录。构建器负责写入，loader 负责
验证。loader 还将 trailer 的 header 契约与自身嵌入的预期 header byte count 和
digest 对照。trailer 缺失、截断、尾部有额外内容，或 byte count/digest/build ID
不一致时一律失败关闭。

manifest 与 trailer 的字段、分隔符和顺序由 `scripts/build-bundle.sh` 生成。
不要手工修改 `dist/proxy-hub.bundle.sh`；任何模块变化都应更新 manifest、重新
构建并运行 loader/manifest 回归测试。

## 版本一致性与信任边界

`PROXY_HUB_REF` 决定远程 bundle 的 Git ref。默认值 `main` 是移动引用，便利但不
保证外层 loader 与 bundle 来自同一 commit。

日常一行命令为了方便仍使用 `main`。需要可复现或高信任执行时，应同时固定：

1. 外层 raw loader URL 中的完整 commit SHA；
2. 传给 loader 的 `PROXY_HUB_REF` 为同一完整 commit SHA。

示例：

```bash
export PROXY_HUB_REF='<40-character-commit-sha>'
bash <(curl -Ls "https://raw.githubusercontent.com/Banezzz/proxy-hub/${PROXY_HUB_REF}/proxy-hub.sh")
```

HTTPS 提供传输完整性，但不是独立的发布者认证。若 manifest 与 bundle 都从同一
个被攻陷的移动 ref 获取，内部 checksum 不能证明发布者身份。固定并通过可信
渠道核对外层 commit SHA，才为内部 digest 建立外部信任锚。当前发布模型不提供
独立签名或离线公钥验证。

## 生命周期与锁

所有新版写入口和兼容锁函数统一使用安全 `/tmp` 下每 UID 私有父目录中的原子
`mkdir` 锁：`/tmp/proxy-hub-<uid>/write.lock.d`。`/tmp` 必须是当前 UID 独占
可写或 root 拥有且带 sticky bit；目录内记录随机 owner token、PID 和
device/inode identity；cleanup 只释放本进程取得且 identity/token 仍匹配的锁、
只结束本 shell 拥有的后台进程树。锁发布临界区把 INT/TERM 记录为 pending，子进程
忽略可捕获信号并原子创建目录、owner 与 PID 元数据，发布完成后才恢复并重新投递
信号。交互主流程对 INT、TERM 与 HUP 使用同一条 cleanup 路径，因此 `Ctrl+C`、
被终止以及 SSH 断开或终端关闭（HUP 可捕获）都会释放写锁，而不是留下残留锁。
INT/TERM/HUP cleanup 先完成或验证 SSH rollback，再对其他后台进程树 TERM、有界
等待、必要时 KILL 并 reap，确认回滚与进程树都结束后才释放写锁，再重新发送
原信号。进程身份由 PID 加 `/proc` start time 绑定；
对可证明归属的进程组还绑定 leader start time，并在每轮从 `/proc` 重扫 PGID，捕获
TERM handler fork 后立即退出所留下的 reparent 子进程。PGID 复用、组归属不明或
进程仍可执行时都保留锁；扫描成员先进入 provisional 集合，scan 后与每次 signal
前再次核对 leader identity，确认无复用才吸收或发信号。KILL 前先 STOP 并重复收集
到稳定边界。

SSH 自动回滚状态位于 `/tmp/proxy-hub-<uid>/ssh-rollback.XXXXXXXX` 的 mode 0700
私有目录，目录、token、backup、confirm 与 result 都验证 owner/identity。回滚按
“恢复配置 → `sshd` validation → 服务 restart → 持久化完成结果”执行，全部成功后
才删除 backup；backup、恢复后的配置、完成结果和目录变更之间设置同步落盘屏障。
`phase.pending` 只能通过同文件系统原子 rename 被一个参与者 claim 为 `confirmed`
或 `rolling-back`。回滚先取得 claim 后，迟到的确认不会杀 timer 或删除 backup，
而是等待并验证回滚完成后报告确认失败。任一步失败都保留 backup/state 并使 cleanup
保留写锁。timer 在 timeout 结束前保持可取消；进入 claim 后只有本次原子 claim
成功的 worker 可执行恢复，并让 worker 及子命令忽略 INT/TERM/HUP 直到 durable result
与 backup 处理完成。父 cleanup 等待该身份绑定 worker，再解锁和按原信号语义退出。
远程 loader 只删除
owner、device/inode identity 均与创建时一致，且模板为
`${TMPDIR:-/tmp}/proxy-hub.bootstrap.XXXXXXXX` 的本进程临时目录，禁止使用宽泛的
`/tmp/tmp.*/` 删除模式。

发布前单文件版本使用 `/tmp/reality_vision_lock`，且其任何命令退出时都会无条件
删除该路径，因此无法与新版锁安全滚动共存。部署新版前必须停止并确认所有旧版
进程退出，切换期间禁止再次启动旧版；这是一项发布门限，不宣称跨版本在线互斥。

只有 `SIGKILL`、宿主机崩溃或断电无法执行 shell trap，才会留下新版锁目录（可捕获的
INT/TERM/HUP 已经过 cleanup 释放）。当前实现仍不会根据 PID 自动接管 stale 锁，以免
PID reuse 或伪造元数据导致误删；改为在获取写锁失败时做只读诊断：owner 进程仍存活则
提示另有实例正在运行，`/proc` 可证明其已退出则判定为残留锁并打印“确认无写操作后可
执行的精确删除命令”。诊断只读取 PID 与 `/proc`，从不移动、删除或接管锁；管理员据此
核实无写操作后人工清理。该限制记录在 `docs/audits.md`。

## 构建与验证

提交前至少运行仓库提供的完整验收入口，并执行以下静态检查：

```bash
bash scripts/build-bundle.sh
bash -n proxy-hub.sh
for file in lib/*.sh; do bash -n "$file"; done
bash -n dist/proxy-hub.bundle.sh
bash tests/test_structure.sh
bash tests/test_loader.sh
bash tests/test_loader_failures.sh
bash tests/test_cleanup_lock.sh
bash tests/test_ssh_rollback.sh
bash tests/test_remote_branch_features.sh
bash tests/test_firewall_protocols.sh
bash tests/test_xray_release.sh
bash tests/test_xray_transaction.sh
git diff --check
```

构建器与 loader 使用相同的安全临时父目录规则，并在发布 manifest/dist 以及递归
清理前重新核对 staging 目录的 owner 与 device/inode identity；同路径被替换时
拒绝发布和删除。`mktemp` 创建成功但尚未向父 shell 发布路径时，子 shell
会安装绑定 owner/device/inode/命名空间的 EXIT cleanup；验证失败只清理仍是
本进程创建的目录。manifest 与 bundle 分别在各自目标文件系统内准备 private staging
和旧版本 backup，cutover 期间延迟 HUP/INT/TERM；第一或第二件替换失败/收信号时按
身份逆序恢复两件旧 artifact，避免留下跨 build 混装。首次 `mktemp` 路径/identity
发布期间也延迟可捕获信号，发布到父 shell 后再恢复并重新投递。

构建器从源快照到双产物 cutover 和 transaction staging 处置全程持有一枚原子、
identity-bound 的 `.proxy-hub.release.lock`。活跃并发 publisher 会失败关闭；只有
可验证的死 PID active lock 才经 quarantine 重验后回收。cutover 前锁会原子转为
`uncertain` 形态，只有完整 rollback/commit 且事务目录验证清理成功才释放；
无法证明时保留锁和 backup，不自动 stale-reclaim，人工恢复见 `docs/audits.md`。

本轮自动化测试直接覆盖：

- 本地 loader 与远程 bundle 的命令/输出/退出码等价；
- `help` 别名和未知命令的本地、远程 dispatch；
- manifest/trailer 截断、hash mismatch、字段错误、尾部额外数据和错误 ref；
- hash 工具全部缺失时失败关闭；
- `/dev/fd` 远程上下文、任意 cwd、空格路径、symlink 与参数转发；
- PTY-backed 本地与精确远程零参数菜单，确认 stdin/stdout 保持 terminal-backed；
- 新旧兼容锁入口的竞争、owner/inode 保护、锁发布阶段信号注入，以及带抗 TERM
  后台 writer 与“fork 后立即退出”后台 root 的有界终止/reap/解锁顺序；
- PGID 在 root/scan/signal 三个窗口复用时零误杀并保留锁；
- SSH rollback 成功、restart/sync 失败后重试、原子 phase 唯一赢家、父先 claim、late confirm、
  active rollback 期间整个 PGID 的 TERM/HUP 等待、backup 创建失败、symlink 替换和 HUP 发布窗口；
- 本地 runtime 部分写入/整模块静默遗漏、远程语法重建写失败/静默遗漏，以及
  验证后到 FD 绑定前的 runtime 路径替换；
- manifest/bundle 第一件或第二件替换失败，以及 TERM/HUP/INT cutover 回滚；
- 两个不同源 generation 并发发布时不混装，以及 rollback/disposal 无法验证时
  保留不可自动回收的 uncertain release lock；
- Xray 版本规范化、API 响应完整性、架构映射、环境变量优先级、升级/重装/降级决策；
- Xray 更新的配置预检、运行/停止两种初始服务状态、成功原子替换，以及启动健康
  检查失败后的旧 binary 恢复；
- Xray 更新在停服后的 TERM 回滚，以及 activated 持久 journal 在下一次写操作中的
  旧 binary、active 状态与事务残留恢复；
- 七种协议各自跑通真实 `cmd_install` + 真实 `save_env`，确保没有协议分支在
  `set -u` 下留下未赋值的节点变量；AnyTLS/AnyTLS+REALITY 的 UUID 与 REALITY
  字段划分；同一会话内连续安装不串用上一个节点的凭据；IPv6 Only 主机上
  `SERVER_IP` 回退路径；以及 `reset_node_state` 覆盖 `save_env` 全部写出字段；
- 全部 SNI 域名测速失败时（出口被墙、DNS 被拦的主机）仍能进入域名选择菜单并
  回退到默认域名，而不是在 `prompt_sni_choice` 的 nameref 上无声崩溃；
- 生成 bundle 与历史基线 `8ca0766e66278ce22377ce81040a98c8159d9c6e` 加显式
  安全补丁的逐字等价性。该字节级门限覆盖
  未单独触发的只读/写命令 dispatch、协议实现和旧节点兼容代码，确保它们没有在
  拆分过程中被改写。

## 关键决策

- 保留一个稳定根入口，避免用户迁移命令。
- 本地使用拆分模块，远程使用单一 bundle，避免逐模块网络请求和跨版本混装。
- 所有远程内容在 source 前完成下载与验证，失败时不产生业务副作用。
- 普通节点安装不改变健康的现有 Xray；只有全新安装或显式 `xray-update` 解析 release。
- Xray release 激活必须通过官方 SHA-256、binary 版本与现有配置三重门限；默认
  stable，固定版本优先，prerelease 只在用户明确选择时启用。
- Xray binary 的替换、service 状态与持久 transaction 恢复组成一个事务，不能只把
  文件复制成功视为更新完成。
- 继续兼容现有 Bash 全局函数/变量 ABI；本轮不同时重写为对象模型。
- dist 是生成物，`lib/` 是事实源。

## 发布与回滚

发布时必须把 `lib/`、根 loader、`lib/manifest.sha256` 和
`dist/proxy-hub.bundle.sh` 放在同一个 commit/PR 中，禁止先发布 loader 再补
bundle，或只推送生成物的一部分。标准顺序：

1. 修改模块，运行 `bash scripts/build-bundle.sh`；
2. 运行上节全部验收，确认工作树中 manifest/dist 已是最新；
3. 部署切换前进入 quiescent window：停止并确认所有旧版脚本进程已退出，且禁止
   在验证完成前再次从旧 commit 启动；
4. 以同一个 Git commit 提交源码和生成物，经 PR 合入；
5. push 后先用分支/commit SHA 同时固定外层 loader URL 和 `PROXY_HUB_REF` 做远程
   smoke test；
6. 合入后等待 raw GitHub 可见，再运行 README 中原样的移动 `main` 一行命令，
   输入 `0` 验证无参数菜单路径，并用 `help` 验证非交互路径。

首次拆分的完整回滚与后续模块改动回滚必须区分：

- **完整回滚到旧单文件**：先进入 quiescent window，在新分支 revert 引入本架构的
  merge/commit 集合。该回滚会删除 `scripts/build-bundle.sh`、`lib/`、`dist/` 和本轮
  tests，因此不能再运行拆分后的构建/测试命令；应对恢复出的单文件运行 `bash -n`、
  固定回滚 commit 的 `help` 与零参数菜单 smoke test，PR 合入后再验证 README 原样
  的移动 `main` 命令。
- **模块化架构内的后续回滚**：revert 后架构和构建器仍存在，应重新运行
  `scripts/build-bundle.sh`、上文列出的全部测试、固定 SHA 远程 smoke，再经非 squash PR
  发布。

两类回滚都禁止手工删除或单独覆盖 raw URL 下的 dist 文件；merge commit 的 revert
按仓库主线父级执行。
