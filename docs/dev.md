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
| `20_installers_restart.sh` | Xray、sing-box、GeoData 安装与代理内核定时重启 |
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

## Loader 的两条路径

### 本地仓库路径

loader 通过 `BASH_SOURCE[0]` 定位自身目录。相邻 `lib/` 中出现 manifest 或任一
预期模块名时，视为本地 Proxy Hub footprint：此时必须恰好包含 manifest 和预期
的 10 个普通、非 symlink 模块，且 `lib/manifest.sha256` 匹配，才复制私有快照、
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
格式注释。它固定为 14 行：

```text
# proxy-hub-manifest-v1
# api=1
# build-id=HEX
HEX  00_security_state.sh
...其余 9 个有序模块...
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
# module-count=10
# proxy-hub-bundle-end-v1
```

字段契约：

- `header-bytes`/`header-sha256` 绑定 bundle 的生成头；
- `body-bytes`/`body-sha256` 绑定按 manifest 顺序拼接的模块正文；
- `build-id` 必须与 `body-sha256` 完全相同；
- `module-count` 当前必须是 `10`；
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
信号。INT/TERM cleanup 先完成或验证 SSH rollback，再对其他后台进程树 TERM、有界
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

`SIGKILL` 无法执行 shell trap，因此会留下新版锁目录；当前实现
不会根据 PID 自动接管 stale 锁，以免 PID reuse 或伪造元数据导致误删。管理员
核实无写操作后需人工清理。该限制记录在 `docs/audits.md`。

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
- 生成 bundle 与历史基线 `8ca0766e66278ce22377ce81040a98c8159d9c6e` 加显式
  安全补丁的逐字等价性。该字节级门限覆盖
  未单独触发的只读/写命令 dispatch、协议实现和旧节点兼容代码，确保它们没有在
  拆分过程中被改写。

## 关键决策

- 保留一个稳定根入口，避免用户迁移命令。
- 本地使用拆分模块，远程使用单一 bundle，避免逐模块网络请求和跨版本混装。
- 所有远程内容在 source 前完成下载与验证，失败时不产生业务副作用。
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
