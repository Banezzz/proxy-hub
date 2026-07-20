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
| 运维 | `restart`, `regenerate`/`regen`, `update-ip`, `uninstall`, `test-sni`, `xray-update` |
| 只读状态 | `xray-version` |
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
| `restart` | `daily`, `12h`, `6h`, `weekly`, `no` 及既有布尔别名 |

变量名为既有的小写 shell 环境变量，拆分不能改名或转换为只接受命令行 flag。

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

## 协议运行时契约

| `PROTOCOL_TYPE` | 内核 | 监听 transport | 安装后本机防火墙 |
| --- | --- | --- | --- |
| `vision` | Xray | TCP | `PORT/tcp` |
| `xhttp` | Xray | TCP | `XHTTP_PORT/tcp` |
| `both` | Xray | TCP | `PORT/tcp` 与 `XHTTP_PORT/tcp` |
| `shadowsocks` | Xray | TCP+UDP | `PORT/tcp` 与 `PORT/udp` |
| `anytls`, `anytls_reality` | sing-box | TCP | `PORT/tcp` |
| `hysteria2` | sing-box | UDP/QUIC | `PORT/udp` |

AnyTLS 与 Hysteria2 聚合到同一个 `/usr/local/etc/sing-box/config.json` 和 sing-box
service；Hysteria2 不引入独立二进制或每节点 service。Hysteria2 使用逐节点自签名
证书，分享链接使用 `hysteria2://` 并包含 `insecure=1`。云平台安全组不属于本机
防火墙契约，调用方仍须按上表开放外部入口。

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
