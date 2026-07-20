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
| 运维 | `restart`, `regenerate`/`regen`, `update-ip`, `uninstall`, `test-sni` |
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
  manifest 和预期 10 个普通、非 symlink 模块并通过校验；部分、损坏或额外文件
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
`# build-id=HEX`、10 行 `HEX<两个空格>module-name`、end marker，共 14 行。
模块名不得包含目录、空白或 `/`。manifest build ID 是规范字节流 `api=1\n` 加
每个 `module-name NUL module-digest LF` 的 SHA-256。dist 构建器按该顺序合并
模块。manifest 自身禁止 NUL 且必须以 LF 结尾；loader 在行解析前验证原始字节。
构建器在 bundle 文件尾追加以下唯一 trailer：

```text
# proxy-hub-bundle-manifest-v1
# header-bytes=N header-sha256=HEX
# body-bytes=N body-sha256=HEX
# build-id=HEX
# module-count=10
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

## 构建发布锁契约

`scripts/build-bundle.sh` 使用仓库根目录 `.proxy-hub.release.lock` 串行化源快照、
manifest/bundle 双产物 cutover 和 transaction staging 清理。活跃 publisher 持有的
lock 绑定 UID/PID/start-time/token/device/inode；同一 checkout 的第二个 builder 立即
失败关闭。cutover 期间 lock payload 为 `proxy-hub-release-uncertain-v1:*`，该形态即使
PID 已死也不会自动回收；必须把两件 artifact 恢复到同一 generation 并验证后
才可人工移除。完整 rollback 或 commit 且 transaction staging 验证清理后，构建器会自动
释放自己持有且 identity 未变的 lock。
