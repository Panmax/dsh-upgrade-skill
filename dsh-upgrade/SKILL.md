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
