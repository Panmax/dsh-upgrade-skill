---
name: dsh-upgrade
version: 1.0.0
description: "安全升级 DeepSeek Harness (dsh)：预检、切换、验证、回滚。Use when upgrading or migrating dsh to a new version, when dsh fails to start after an upgrade (duplicate loader entry id, cannot get property without inject, notarget, UNKNOWN_MODEL), when plugins break after a dsh bump, or when you need to change the Node runtime a dsh install uses."
metadata:
  requires:
    bins: ["node", "npm", "curl", "tar"]
---

# dsh 安全升级

升级 dsh 最常见的失败不是「新版本有 bug」，而是**升级前的状态没检查**。
本 skill 把踩过的坑固化成可执行流程，目标是：**任何一次升级都能在 2 分钟内回滚**。

## 核心心智模型

先记住这四条，绝大多数故障都能定位：

1. **dsh = 一个 CLI + 一堆版本严格对齐的 `@deepseek-ai/*` 包**。
   所有内部包版本必须一致（`0.2.2-rc.1` 的 `dsh-base` 也必须是 `0.2.2-rc.1`），
   所以不要手工混装单个包，一律整体安装。

2. **profile 的加载树 = bundles 的 `cordis.patch.yml` 层层叠加 + 你自己的 patch**。
   每个 patch 行有一个 `id`，**全树 id 必须唯一**，重复即启动失败。

3. **启动有两个独立阶段**：先「组装配置」（`--dump-config` 能跑通），
   再「激活插件」（真正的 `web` 启动）。**前者通过不代表后者通过**，两个都要验。

4. **升级失败时，回滚成本应该接近零**。做不到零回滚，就不要开始升级。

---

## 升级前检查清单

按顺序做，任何一项不过就先解决，别往下走。

- [ ] **1. 版本真的存在吗**（见坑 1：npm 缓存会骗你）
  ```sh
  curl -s "https://registry.npmjs.org/@deepseek-ai%2Fdsh" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(JSON.stringify(j["dist-tags"]))})'
  ```
- [ ] **2. Node 够不够**（见坑 5）
  ```sh
  node -v
  curl -s "https://registry.npmjs.org/@deepseek-ai%2Fdsh/<版本>" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(JSON.parse(s).engines)))'
  ```
- [ ] **3. 会话历史备份了吗**（见坑 6，格式迁移是单向的）
- [ ] **4. 上一个版本的 runtime 还在吗**（回滚用）
- [ ] **5. 当前配置能干净组装吗**
  ```sh
  dsh --profile <name> --dump-config >/tmp/before.txt 2>/tmp/before.err
  cat /tmp/before.err            # 记下升级前就存在的警告，别和升级后混淆
  ```

---

## 标准流程（三阶段）

### 阶段 A：安装到独立 runtime 目录（不动当前版本）

**不要用 `npx` 当长期方案**（见坑 7）。装到版本化目录：

```sh
VER=0.2.2-rc.1
RT="$HOME/.dsh/runtime/$VER"
mkdir -p "$RT" && cd "$RT"
npm install --no-audit --no-fund --cache "$(mktemp -d)" "@deepseek-ai/dsh@$VER"
```

`--cache "$(mktemp -d)"` 是**绕开坑 1 的关键**，用空缓存强制真实拉取。

### 阶段 B：隔离预检（最重要的一步）

**永远不要在生产 DSH_HOME 上第一次启动新版本。**

```sh
SANDBOX=$(mktemp -d)
cp -a "$HOME/.dsh/profiles" "$SANDBOX/"
cp "$HOME/.dsh/settings.yaml.imported" "$SANDBOX/" 2>/dev/null
cp -a "$HOME/.dsh/sessions" "$SANDBOX/" 2>/dev/null   # 验会话兼容性
cp -a "$HOME/.dsh/storages" "$SANDBOX/" 2>/dev/null   # 验定时任务等状态

# B1 只组装配置，先抓结构性错误
DSH_HOME="$SANDBOX" node "$RT/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --dump-config >/tmp/after.txt 2>/tmp/after.err
cat /tmp/after.err

# B2 真启动，换一个空闲端口
DSH_HOME="$SANDBOX" node "$RT/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --no-open --port 3999
# 能一直跑住 = 成功；立刻退出并打印 "startup failed" = 失败，看下面的坑
```

预检通过的标准（全部满足才算过）：

| 检查 | 命令 |
|---|---|
| 无新增警告 | `diff /tmp/before.err /tmp/after.err` |
| 无重复行 id | `grep '^- id:' /tmp/after.txt \| sort \| uniq -d` |
| 你的插件都在 | `grep -c 'id: <你的插件 id>' /tmp/after.txt` |
| provider 还在 | `grep -c '^      <provider>:$' /tmp/after.txt` |
| 默认模型可解析 | 默认 model 必须出现在其 provider 的 models 列表里 |

### 阶段 C：切换 + 重启

用一个**稳定的版本指针**，切版本只改一处：

```sh
ln -sfn "$VER" "$HOME/.dsh/runtime/current"
```

启动器脚本固定 Node 版本，不受 shell 影响：

```bash
#!/bin/bash
# ~/.local/bin/dsh
NODE="$HOME/.nvm/versions/node/v24.22.2/bin/node"
BIN="$HOME/.dsh/runtime/current/node_modules/@deepseek-ai/dsh/lib/bin.js"
[ -x "$NODE" ] || { echo "dsh: node not found: $NODE" >&2; exit 1; }
[ -f "$BIN" ]  || { echo "dsh: runtime not found: $BIN" >&2; exit 1; }
exec "$NODE" "$BIN" "$@"
```

然后：`kill <旧 PID> && dsh web`

> ⚠️ 切换 `current` 后**尽快重启**。用 `current` 路径启动的旧进程，
> 后续懒加载可能穿过软链拿到新版本文件，造成版本混用。

### 重启后验证

```sh
dsh --version                                  # 版本对
lsof -nP -iTCP:3080 -sTCP:LISTEN               # 端口在
dsh --profile web --dump-config 2>&1 >/dev/null # 无警告
```

再肉眼看三项：会话能打开、插件页面在、定时任务有下次运行时间。

### 回滚（10 秒）

```sh
ln -sfn "<旧版本>" "$HOME/.dsh/runtime/current"
kill <新 PID> && dsh web
```

只要旧 runtime 目录没删，回滚永远是这一条命令。

---

## 坑位手册（症状 → 原因 → 修复）

### 坑 1：npm 说版本不存在，但其实存在

**症状**

```
npm error notarget No matching version found for @deepseek-ai/dsh@0.2.2-rc.2.
```

**原因**：`~/.npm/_cacache` 里的 packument 是旧的。若环境里有
`npm_config_prefer_offline=true`（或 `prefer-offline=true`），
npm 会无视 `max-age` 继续用旧数据。**`--prefer-online` 也救不了**。

**判定**

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://registry.npmjs.org/@deepseek-ai/dsh/<版本>"   # 200 = 版本存在，是 npm 的问题
```

**修复**（任选）

```sh
npm install --cache "$(mktemp -d)" @deepseek-ai/dsh@<版本>   # 首选，不污染全局缓存
# 或
npm cache clean --force
```

> 副作用：这个污染同时影响 `npm view`，所以**任何「有没有新版本」的检查都别用 `npm view`**，用 `curl` 直查 registry。

**反向情况也要认：GitHub 有 release，npm 还没发**

实测遇到过：GitHub 上 `dsh-vX.Y.Z` 的 release 已发布（甚至标了 `prerelease`），
但 `https://registry.npmjs.org/@deepseek-ai/dsh/<版本>` 返回 **404**，
npmmirror 也是 404 —— 说明包还没推到 registry。

判定：

```sh
# GitHub 有、npm 没有 = 还不能装
curl -s -o /dev/null -w 'github tag: %{http_code}\n' \
  "https://api.github.com/repos/deepseek-ai/deepseek-harness/releases/tags/dsh-v<版本>"
curl -s -o /dev/null -w 'npm version: %{http_code}\n' \
  "https://registry.npmjs.org/@deepseek-ai/dsh/<版本>"
```

`200 + 404` = **等**，不要反复重试安装。发布顺序不保证，两个方向都出现过。

### 坑 2：duplicate loader entry id —— 升级后起不来最常见的原因

**症状**

```
dsh: plugin tree failed to load: duplicate loader entry id: ui-plugin-manager
```

**原因**：某个第三方 bundle 的 `cordis.patch.yml` 写了
`- insert: [{ id: <X> }]`，而**新版本刚好内置了同名 row**。

经典案例：`@linxin666/dsh-client-ui-plugin-manager` 插入 `ui-plugin-manager`，
而 dsh `0.1.6` 起内置了 `@deepseek-ai/dsh-client-ui-plugin-manager`，同样叫这个 id。

**判定**

```sh
dsh --profile web --dump-config 2>/dev/null \
  | grep '^- id:' | sed 's/^- id: //' | sort | uniq -d
# 有输出 = 撞车
```

**根治**：升级前先算第三方 bundle 会插入哪些 id，和内建 id 求交集。

```sh
# 内建 id（用干净 HOME，避免被自己的插件污染）
CLEAN=$(mktemp -d)
DSH_HOME="$CLEAN" dsh --profile web --dump-default-config 2>/dev/null \
  | grep '^- id:' | sed 's/^- id: //' | sort -u > /tmp/builtin-ids.txt

# 第三方 bundle：解包读它声明的 patch 文件
npm pack <插件名> --silent >/dev/null && tar xzf *.tgz
node -e '
const yaml=require("js-yaml"),fs=require("fs");
const p=JSON.parse(fs.readFileSync("package/package.json","utf8"));
const rel=p.dsh?.bundle?.patch; if(!rel) process.exit(0);
const schema=yaml.DEFAULT_SCHEMA.extend([new yaml.Type("tag:yaml.org,2002:js",{kind:"scalar",construct:d=>d})]);
const doc=yaml.load(fs.readFileSync("package/"+rel.replace(/^\.\//,""),"utf8"),{schema});
for(const e of [].concat(doc)){
  if(Array.isArray(e?.insert)) for(const i of e.insert) if(i?.id) console.log(i.id);
}'
```

**修复**：从 `dsh.profile.bundles` 移除冲突的 bundle（内建版通常已提供同等能力），
或把该插件钉到不冲突的旧版本。

> 注意区分：patch 里 `- id: X` + `disabled: true` 是**覆盖已有 row**（合法），
> 只有 `- insert: [{ id: X }]` 才是**新增 row**（会撞车）。

### 坑 3：`cannot get property "<service>" without inject`

**症状**

```
dsh: startup failed: 1 required plugin did not activate
  connection (required)
    Error: cannot get property "webRuntime" without inject
```

**原因**：你在 `cordis.patch.yml` 里用 `!!js ctx.<service>...` 引用的服务，
在新版本里被**移除或改名**了。典型：`webRuntime` → `webStartup`（dsh `0.2.1-alpha.3`）。

**修复**：改表达式，并在该 row 上**显式声明 `inject`**。

```yaml
# 旧（会挂）
- id: connection
  config:
    trustedHosts: !!js ctx.webRuntime.trustedHosts

# 新
- id: connection
  name: '@deepseek-ai/dsh-client-connection'
  inject: [webStartup]
  config:
    trustedHosts: !!js "[...ctx.webStartup.trustedHosts, 'your.tunnel.host']"
```

**保守做法**：不确定新服务叫什么时，先**删掉那行表达式**跑通启动（功能降级），
再从新版本的 bundle 自带的 `cordis.patch.yml` 里抄正确写法。

> 升级后一定验证这类「部署相关」配置还在：反向代理可信主机、
> TLS、公开 URL。它们通常是 `!!js` 表达式，最容易被服务改名打断。

### 坑 4：settings.yaml 被「静默吞掉」

**症状**：升级后 provider / 模型 / 主题全没了，但启动不报错。

**原因**：dsh 会把 `settings.yaml` **只导入一次**到当前 profile 的 `cordis.patch.yml`，
然后改名为 `settings.yaml.imported`。**校验失败的 section 只写一行 warn，
永远留在 `.imported` 里，不会重试。**

实测案例：`settings.yaml` 里多了一个空键

```yaml
llm-pi-ai:
  llm-pi-ai:      # ← 这个 null 让整个 section 校验失败
  providers:
```

结果 7 个 provider 全部没迁移，而日志里只有一行容易忽略的 warn。

**预防**（升级前）

```sh
node -e '
const yaml=require("js-yaml"),fs=require("fs");
const d=yaml.load(fs.readFileSync(process.env.HOME+"/.dsh/settings.yaml","utf8"));
for(const [k,v] of Object.entries(d)){
  const bad=Object.entries(v||{}).filter(([k2,v2])=>v2===null);
  if(bad.length) console.log("危险:", k, "含空键", bad.map(b=>b[0]).join(","));
}'
```

**修复**：删掉空键后重新升级；或手工把该 section 内容粘进 `cordis.patch.yml`。

> 导入是**幂等的一次性动作**：`.imported` 存在后再改 `settings.yaml` 也不会被读。
> 所以升级前一定要备份 `settings.yaml`。

### 坑 5：Node 版本门槛

**症状**：`npm warn EBADENGINE`，或启动时各种莫名其妙的语法/API 错误。

**原因**：新版本提高了最低 Node。例如 dsh `0.2.2` 起要求 **Node ≥ 24.9**。

**修复**：用 nvm 并存安装，**再让启动器固定它**，不要改全局默认 Node
（否则会影响你机器上其他项目）。

```sh
nvm install 24.22.2
# 启动器里写死路径，见「阶段 C」
```

### 坑 6：会话格式迁移是单向的

新版本可能带 `dsh-session-format-vX-to-vY` 迁移包，**升级后旧版本读不了新文件**。

升级前必做：

```sh
tar czf "$HOME/.dsh-backup-$(date +%Y%m%d-%H%M%S)/sessions.tar.gz" -C "$HOME/.dsh" sessions
```

> 备份里**必须包含 sessions**。只备份配置的话，出问题时回滚了版本，
> 但新版本已经改写过的会话文件回不去了。

### 坑 7：`which dsh` 是假象

**症状**：某个终端里 `dsh` 能用，换个终端就 `command not found`。

**原因**：那次实例是用 `npx @deepseek-ai/dsh web` 起的，
**npx 把 `~/.npm/_npx/<hash>/node_modules/.bin` 注入到了该进程及其子进程的 PATH**。
npx 缓存一清、或换成 `node <path>/bin.js` 启动，`dsh` 就消失了。

**修复**：装到你自己的 PATH 目录（见阶段 C 的启动器），别依赖 npx 的临时 PATH。

### 坑 8：改模型 `id` 会打断老会话和定时任务

**症状**

```
turn ended: pi-ai provider "opencode-go" has no configured model "deepseek-flash"
code: UNKNOWN_MODEL
```

**原因**：模型选择会被写进**每个会话的 request header**。你改了 config 里的
`id`，老会话仍指向旧 id，于是解析失败。定时任务到期恢复老会话时同样会中招。

**修复 / 预防**：
- **只改 `name:`（显示名），永远不要改 `id:`**
- 必须改 id 时，改完去每个在用的会话重新选一次模型，并先发一条普通消息让 header 落盘
- 定时任务所在会话尤其要确认

### 坑 9：UI 改配置会重写 `cordis.patch.yml`

**好消息**：现代 dsh 的配置编辑器是**合并式写入**，会保留
注释、`!!js` 表达式和插件私有字段（如 `compat`）。

**仍要小心**：它会把「该行拥有的字段」重写一遍。升级前备份
`cordis.patch.yml`，改完 `diff` 一下，确认没有字段被静默清空。


### 坑 10：registry.npmjs.org / github.com 不通

**症状**

```
curl: (35) ... 000
npm error network ...
```

或者 `curl` 直接返回 `000` / 空响应，而浏览器和域名镜像却正常。

**原因**：本地代理（常见 `127.0.0.1:8899`）或网络策略屏蔽了 `registry.npmjs.org`
和 `github.com`，但国内镜像仍可达。用 `--prefer-online`、清缓存都无效——这是**链路问题**。

> 实测是**间歇性**的：同一台机器几分钟后 npmjs 可能又通了。
> 所以脚本里要做回退而不是直接报错，人也不要看到一次 000 就断定「网络坏了」。

**判定**

```sh
for u in https://registry.npmjs.org/ https://registry.npmmirror.com/ https://github.com; do
  printf '%-38s ' "$u"; curl -s --max-time 8 -o /dev/null -w '%{http_code}\n' "$u"
done
# npmjs / github 返回 000 而 npmmirror 返回 200 = 命中本坑
```

**修复**：改用 npmmirror（完整镜像，integrity 一致）。

```sh
# 查版本
curl -s "https://registry.npmmirror.com/@deepseek-ai%2Fdsh" | node -e '...'

# 装插件时指定 registry（dsh plugin 会把参数透传给 pnpm）
dsh plugin --profile web add <包>@<版本> --registry=https://registry.npmmirror.com
```

**注意**
- 镜像同步有几分钟到几小时延迟，刚发布的版本可能还查不到
- 作用域包（`@scope/name`）在某些镜像上要用**不编码**的斜杠：
  `https://registry.npmmirror.com/@scope/name`，用 `%2F` 可能 404
- `check-update.sh` 已内置回退：npmjs 不通时自动切 npmmirror

### 坑 11：第三方插件写死旧 Remote 契约 —— 手机端弹 `wire field "request" failed boundary validation`

**症状**（手机 App 弹窗原文，桌面 Web 一切正常）

```
gateway/input-invalid: typert gateway: session/attachment: wire field "request" failed boundary validation
```

**原因**：dsh `0.2.2` 改了 `session/attachment` 的请求体——
旧 `{ sessionId, attachmentId }` → 新 `{ sessionId, attachment: ImageAttachmentRef }`
（完整 ref：`attachmentId/mediaType/bytes/width/height[/name/originalDimensions]`），
同时取消了「附件必须被本 Session 引用」的校验，改由 gateway 权限控制。
`dsh-plugin-mobile-gateway@0.11.x`（README 自述基线 `DSH 0.2.1-rc.2`）仍按旧契约转发
`{ sessionId, attachmentId }`，被新 Host 的严格边界校验直接拒绝。

典型表现：**手机能发图（上传契约没变），但读回图片（消息缩略图/大图）就弹窗**；
桌面浏览器同一会话的图片正常 —— 这就是「服务端没坏，是客户端插件契约旧了」的分水岭。

**判定**

```sh
# 1) 手机网关插件版本 vs Host 版本
node -p "require(process.env.HOME+'/.dsh/profiles/web/node_modules/dsh-plugin-mobile-gateway/package.json').version"
node -p "require(process.env.HOME+'/.dsh/runtime/current/node_modules/@deepseek-ai/dsh/package.json').version"

# 2) 插件 README 有没有适配当前 Host（无输出 = 没适配）
grep -n "0\.2\.2" ~/.dsh/profiles/web/node_modules/dsh-plugin-mobile-gateway/README.md

# 3) 新旧契约对照（Host 侧源码即契约）
grep -n "attachmentId" ~/.dsh/runtime/current/node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.host.js | head -3
```

**修复**：把插件升到适配 `0.2.2-rc.x` 的版本（`dsh-plugin-mobile-gateway@0.12.0` 起，
它在 host adapter 里先用会话历史把 `attachmentId` 解析成完整 ref 再调用；
手机 App 协议不变，**不需要升级 App**）。

```sh
dsh plugin --profile web add dsh-plugin-mobile-gateway@0.12.0
# 或直接在 profile 里装
cd ~/.dsh/profiles/web && pnpm add dsh-plugin-mobile-gateway@0.12.0
# 然后重启 dsh web，手机下拉刷新重连
```

注意：`0.12.0` 要求 **Node ≥ 24.9**，先确认再升。

**无法升级时的临时回滚**：`ln -sfn 0.2.1-rc.5 ~/.dsh/runtime/current` 并重启
（0.11.3 的基线是 `0.2.1-rc.2`，与 0.2.1-rc.5 同契约）。

> 通用化：任何第三方插件都可能内嵌某版 Remote 契约。升级后**能启动不代表能用**——
> 单项方法报 `gateway/input-invalid` / `gateway/arguments-invalid` 时，
> 去插件的 `lib/*.mjs` 里 grep 端点名（如 `session', 'attachment'`），
> 看它构造的参数形状是否还和新版 `typert.host.js` 一致。

**配套坑：插件小版本与 dsh rc 一一绑定，别只升一边。**
实测 `dsh-plugin-mobile-gateway`：`0.12.0 ↔ DSH 0.2.2-rc.1`、`0.12.1 ↔ DSH 0.2.2-rc.3`
（README 首行 "Targets DSH …" / description 里写明）。包上没有 `engines.dsh`，
所以 `pnpm add` 不会拦你，**只升插件或只升 dsh 都会跨契约**。

判定（版本绑定对照）：

```sh
curl -s --max-time 20 "https://registry.npmmirror.com/dsh-plugin-mobile-gateway" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);const t=j["dist-tags"];console.log("latest:",t.latest);console.log(j.versions[t.latest].description)})'
```

要升级就**成对升**：先按本 skill 流程把 dsh 升到插件声明的那条 rc（rc 线走 `next` tag，
不要用 `npm view` 看，用 curl 查 dist-tags），再升插件，最后重启。


### 坑 12：预检沙箱误报「cannot resolve profile bundle」（本地 `link:` 插件）

**症状**

```
dsh: skipping profile bundle "my-local-plugin": Error: dsh: cannot resolve profile bundle "my-local-plugin"
     from the dsh installation or /var/folders/.../profiles/web
dsh: [ .../profiles/web/cordis.patch.yml] patch: entry "my-patch-row" not found
```

**原因**：pnpm 给 `link:` 依赖（`"my-plugin": "link:/Users/me/Code/my-plugin"`）生成的
软链是**相对路径**（`../../../../Code/my-plugin`）。预检把 profile 复制到 `/tmp/...` 后，
相对路径指到了错误位置，于是解析失败。

**这是沙箱假象，不是真故障。** 生产环境里那个相对路径是对的。

**判定**（确认是相对软链）

```sh
readlink ~/.dsh/profiles/web/node_modules/<包名>
# 输出 ../../../../Code/...  → 命中本坑
# 输出 /Users/.../...        → 绝对链，不受影响
```

**升级版症状：`dsh plugin add` 直接崩**

```
Error: dsh: cannot resolve profile bundle "my-local-plugin" from the dsh installation or /tmp/xxx/profiles/web
    at resolveBundleDir (.../dsh-app-boot/lib/index.js)
    at bundleManifest (.../dsh-plugin-manager/lib/types/operations.js)
    at reconcile (.../dsh-plugin-manager/lib/types/operations.js)
```

pnpm 装包**成功**了，但随后 plugin-manager 的 `reconcile` 阶段要逐个解析 bundle，
遇到断掉的 link 就抛错退出，整个 `dsh plugin add` 失败。

**修复**（任选）

1. `preflight.sh` 已自动处理——复制后把沙箱里的相对软链改写成绝对路径。
   **但注意**：`dsh plugin add` 内部会再跑一次 pnpm，**软链会被重新写成相对形式**，
   所以「先修链再 add」还是会失败。
2. **最省事**：在沙箱 profile 里临时移除所有 `link:` 依赖（`dependencies` + `dsh.profile.bundles`），
   只测 npm 装的插件。本地 link 插件本来也不在这次升级范围内。

```sh
# 在沙箱 profile 的 package.json 里去掉 link: 依赖
node -e '
const fs=require("fs"),p=process.argv[1];const d=JSON.parse(fs.readFileSync(p,"utf8"));
const link=Object.keys(d.dependencies||{}).filter(k=>String(d.dependencies[k]).startsWith("link:"));
link.forEach(k=>delete d.dependencies[k]);
const b=d.dsh?.profile?.bundles; if(b) d.dsh.profile.bundles=b.filter(x=>!link.includes(x));
fs.writeFileSync(p,JSON.stringify(d,null,2));console.log("removed:",link);
' /tmp/sandbox/profiles/web/package.json
```

> 移除 bundle 后，`cordis.patch.yml` 里针对它的 patch 行会报 `entry "xxx" not found`，
> 这条告警在沙箱里属预期，**不影响结论**。

### 坑 13：插件升级后「UI 在、功能不能用」——宿主半没重载（客户端/宿主版本错位）

**症状**

- 插件管理页显示 `enabled: true`、`fiberPhase: active`；浏览器里按钮和 `/rewind` 命令都还在。
- 点按钮或确认回退时失败；DevTools Network 里 `POST /api/<plugin>/v1/preview`、`/v1/commit` 返回 `404 not found`。
- 实测：`dsh-rewind-plugin` 从 `0.22.2` 升到 `0.23.0` 后，
  `POST /api/dsh-rewind/v1/health` / `v1/preview` → `HTTP 404 not found`，
  而旧路由 `POST /api/dsh-rewind/preview` → `HTTP 200`。

**原因**：`dsh web` 进程启动早于插件升级。dsh 的 HMR 只热更新**浏览器客户端 bundle**（轮询 `lib/client.js` 的 stat）；
宿主 Node 半的 `lib/index.js` 不会因 profile `package.json` 里的插件版本变化自动重载——
profile manifest watcher 只比较 `dsh.profile.bundles` 的名单，版本变化不触发 reconcile。
结果：浏览器拿到 0.23.0 的 client，Node 里仍是 0.22.2 的 host；client 调用 0.23.0 新增的
`/api/dsh-rewind/v1/*`，宿主没有这些路由，于是 404。

**判定**

```sh
# 1) 进程启动时间 vs 插件文件 ctime（进程早于文件 = 可疑）
pgrep -fl 'dsh.*web'
ps -o lstart= -p <PID>
stat -f '%Sm %Sc %N' ~/.dsh/profiles/web/node_modules/dsh-rewind-plugin/lib/index.js

# 2) 客户端 bundle 实际调用的路由（新）
grep -o 'api/dsh-rewind[^"`]*' ~/.dsh/profiles/web/node_modules/dsh-rewind-plugin/lib/client.js | sort -u
# 对照运行中宿主实际注册的路由（旧）：
grep -o '"/api/dsh-rewind[^"]*"' ~/.dsh/profiles/web/node_modules/dsh-rewind-plugin/lib/index.js | sort -u
```

> `dsh web` 的 API 有进程 token，命令行直接 `curl` 会 401；在浏览器 DevTools 的 Network 面板看
> `v1/preview` 是否 404 最直接。

**修复**：重启 `dsh web`，让宿主半和客户端半加载同一份新文件——只刷新浏览器不够。

```sh
# 在运行 dsh web 的终端 Ctrl+C，然后重新启动
dsh web
# 或
kill <PID> && dsh web
```

**预防**：插件升级后一定重启 `dsh web`。从插件页执行更新会尝试 `publishAndReload`，
但 `pnpm add`、`dsh plugin` CLI 或手工改 profile 都不会通知正在运行的进程。

> 通用化：任何同时有 Host 半和 client 半（`dsh.client` 声明）的第三方插件都可能中招，
> 典型症状是「UI 在、接口 404」。对比 client bundle 的 fetch 路径和宿主 `lib/index.js`
> 的 `registerRoute` 路径即可确认。

---

## 插件兼容性判断

升级 dsh 时插件是第二个故障源。按优先级看这三个声明：

| 字段 | 含义 | 处理 |
|---|---|---|
| `engines.dsh` | 插件支持哪些 dsh 版本 | 优先看它，不满足就别装 |
| `dsh.compatibility.dshReleases` | 作者实测过的版本表 | 只列旧版本的，属于「未测」而非「不兼容」 |
| `peerDependencies` | 需要哪些 `@deepseek-ai/*` | 注意跨大版本的核心包 |

```sh
node -e '
const p=require(process.argv[1]+"/package.json");
console.log("version:", p.version);
console.log("engines:", JSON.stringify(p.engines||null));
console.log("compat:", JSON.stringify(p.dsh?.compatibility||null));
' "$HOME/.dsh/profiles/web/node_modules/<插件名>"
```

**装插件时钉精确版本**，防止将来被 `^` 带到要求更高 Node 的新大版本：

```sh
dsh plugin --profile web add "some-plugin@1.2.3"     # 不加 ^
```

→ 有些 CLI 会自动写成 `^1.2.3`，**装完检查 `package.json`**，需要时手工去掉 `^`。

---

## 故障分诊表

| 现象 | 先查 |
|---|---|
| `notarget` / 版本不存在 | 坑 1（curl registry 验证） |
| `duplicate loader entry id` | 坑 2（dump-config 找重复 id） |
| `cannot get property ... without inject` | 坑 3（`!!js ctx.*` 引用的服务） |
| `N required plugin did not activate` | 看 stderr 里第一个失败插件的完整堆栈 |
| 能启动但 provider/模型全没了 | 坑 4（`settings.yaml.imported`） |
| 会话能开但请求报 `UNKNOWN_MODEL` | 坑 8（模型 id 改名） |
| `EBADENGINE` 或诡异语法错误 | 坑 5（Node 版本） |
| 升级后旧会话读不出来 | 坑 6（会话格式，回滚或迁移） |
| 换了终端 `dsh` 就没了 | 坑 7（npx PATH） |
| `curl` 返回 000 / `npm error network` | 坑 10（换 npmmirror 镜像） |
| 预检里 `cannot resolve profile bundle` | 坑 12（本地 link 插件，沙箱假象） |
| 插件升级后 UI 在但功能报错、`/api/<plugin>/v1/*` 404 | 坑 13（宿主半没重载，重启 dsh web） |
| 手机端弹 `gateway/input-invalid ... wire field "request" failed boundary validation` | 坑 11（第三方网关插件写死旧 Remote 契约） |

---

## 每次升级的固定动作（可复制）

```sh
VER="<目标版本>"
STAMP=$(date +%Y%m%d-%H%M%S)
RT="$HOME/.dsh/runtime/$VER"
BK="$HOME/.dsh-backup-$STAMP"

# 0) 备份（配置 + 会话）
mkdir -p "$BK" && cp -a "$HOME/.dsh/profiles/web"/{package.json,cordis.patch.yml,cordis.yml,pnpm-lock.yaml} "$BK/" 2>/dev/null
cp "$HOME/.dsh/settings.yaml.imported" "$BK/" 2>/dev/null
tar czf "$BK/sessions.tar.gz" -C "$HOME/.dsh" sessions

# 1) 安装（空缓存，绕开坑 1）
mkdir -p "$RT" && cd "$RT" && npm install --no-audit --no-fund --cache "$(mktemp -d)" "@deepseek-ai/dsh@$VER"

# 2) 隔离预检（坑 2/3/4/5 都在这步暴露）
SB=$(mktemp -d) && cp -a "$HOME/.dsh/profiles" "$SB/" && cp "$HOME/.dsh/settings.yaml.imported" "$SB/" 2>/dev/null
DSH_HOME="$SB" node "$RT/node_modules/@deepseek-ai/dsh/lib/bin.js" --profile web --dump-config >/tmp/after.txt 2>/tmp/after.err
cat /tmp/after.err
grep '^- id:' /tmp/after.txt | sort | uniq -d      # 必须为空
DSH_HOME="$SB" node "$RT/node_modules/@deepseek-ai/dsh/lib/bin.js" --profile web --no-open --port 3999

# 3) 切换（确认预检全绿再执行）
ln -sfn "$VER" "$HOME/.dsh/runtime/current"
# kill <旧 PID> && dsh web
```

---

## 维护说明

这份 skill 来自真实升级事故的复盘，会持续追加。
新增坑位时保持同一个格式：**症状（可搜索的报错原文）→ 原因 → 判定命令 → 修复**。
症状优先写完整报错串，因为人排错时是拿报错去搜的。
