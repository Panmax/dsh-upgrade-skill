# dsh-upgrade-skill

一份**经过实战检验的 Agent Skill**，用来安全升级 [DeepSeek Harness（`dsh`）](https://github.com/deepseek-ai/deepseek-harness)，避免升级后起不来。

这里每一条规则都来自**真实失败过的升级**，不是读 changelog 猜的。

[English](README.md) | **简体中文**

---

## 为什么需要它

`dsh` 升级失败的样子通常是：

```
dsh: plugin tree failed to load: duplicate loader entry id: ui-plugin-manager
Error: cannot get property "webRuntime" without inject
npm error notarget No matching version found for @deepseek-ai/dsh@0.2.2-rc.2
```

看起来像「新版本坏了」，但**几乎总是升级前就存在的状态，新版本不再容忍**。
每一个都有明确的成因、一行判定命令和已知修复 —— 都写在 skill 里。

## 覆盖范围

| 模块 | 内容 |
|---|---|
| **升级前关卡** | 5 项检查，在动手前拦下大部分故障 |
| **三阶段流程** | 装到版本化目录 → 隔离预检 → 切换 |
| **9 个坑位** | 症状 → 原因 → 判定 → 修复，报错原文可直接搜 |
| **插件兼容判断** | `engines.dsh` / `dsh.compatibility` / peer 依赖 |
| **故障分诊表** | 现象 → 对应哪个坑 |
| **10 秒回滚** | 切一个软链，不用重装 |

### 9 个坑位速览

1. **npm 会骗你说版本不存在** —— `_cacache` 过期 + `prefer-offline` 会让 `npm view` / `npx` / `npm install` 对一个真实存在的版本报「找不到」。**`--prefer-online` 也救不了。**
2. **行 id 撞车** —— 第三方 bundle 的 `cordis.patch.yml` 插入的 row id，新版本刚好内置了同名 row → 直接启动失败。
3. **`ctx.*` 服务被改名** —— patch 里的 `!!js ctx.webRuntime...` 在服务改名后失效（`webRuntime` → `webStartup`）。
4. **`settings.yaml` 被静默吞掉** —— 只导入一次，校验失败的 section 只记一行日志、永不重试。一个多余的空键就能让你配置的所有 provider 消失。
5. **Node 版本门槛** —— 用启动器固定 Node，别改全局默认。
6. **会话格式单向迁移** —— 备份要含 `sessions/`，不只是配置。
7. **改模型 `id`** 会打断老会话和定时任务（`UNKNOWN_MODEL`）。
8. **`which dsh` 是假象** —— 进程用 `npx` 起的话，PATH 是临时的。
9. **UI 改配置会重写 patch 文件** —— 合并式写入，但仍要 diff 确认。

## 安装

```bash
git clone https://github.com/Panmax/dsh-upgrade-skill.git
cp -r dsh-upgrade-skill/dsh-upgrade ~/.agents/skills/
```

适用于任何加载 **Agent Skills**（`SKILL.md`）的 agent —— [DSH](https://github.com/deepseek-ai/deepseek-harness)、Claude Code 等。脚本是纯 bash，无额外依赖。

## 脚本

```bash
# 有没有新版本？（用 curl，不用 npm view —— 见坑 1）
~/.agents/skills/dsh-upgrade/scripts/check-update.sh

# 在隔离 DSH_HOME 里预检某个版本，绝不碰生产环境
~/.agents/skills/dsh-upgrade/scripts/preflight.sh 0.2.2-rc.1 web 3999
```

`preflight.sh` 会依次做：

1. 确认版本在 registry 上真实存在
2. 对比该版本要求的 Node 和你当前的 Node
3. 装到 `~/.dsh/runtime/<版本>/`，使用**一次性 npm 缓存**（破掉坑 1）
4. 把 `profiles` / `settings` / `sessions` / `storages` 复制到一个临时 `DSH_HOME`
5. 跑 `--dump-config`，检查**重复行 id** 和 provider 是否丢失
6. 在空闲端口真启动一次，盯 `startup failed`
7. 打印「可以切换的确切命令」或「该查哪个坑」

退出码 `0` = 可以切，`1` = **不要切**。

## 一屏看懂完整流程

```sh
VER=0.2.2-rc.1
RT="$HOME/.dsh/runtime/$VER"

# 用一次性缓存安装
mkdir -p "$RT" && cd "$RT"
npm install --no-audit --no-fund --cache "$(mktemp -d)" "@deepseek-ai/dsh@$VER"

# 隔离预检
SB=$(mktemp -d)
cp -a "$HOME/.dsh/profiles" "$SB/"
DSH_HOME="$SB" node "$RT/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --dump-config >/tmp/after.txt 2>/tmp/after.err
cat /tmp/after.err
grep '^- id:' /tmp/after.txt | sort | uniq -d    # 必须为空
DSH_HOME="$SB" node "$RT/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --no-open --port 3999

# 切换
ln -sfn "$VER" "$HOME/.dsh/runtime/current"
kill <旧 PID> && dsh web

# 回滚
ln -sfn "<旧版本>" "$HOME/.dsh/runtime/current"
kill <新 PID> && dsh web
```

## 目录结构

```
dsh-upgrade/
├── SKILL.md                 # 心智模型 / 检查清单 / 三阶段流程 / 9 个坑位 / 分诊表
└── scripts/
    ├── check-update.sh      # 不会被 npm 缓存骗的版本检查
    └── preflight.sh         # 隔离安装 + 组装 + 启动验证
```

## 贡献

如果某个升级坑到了你、而这份 skill 没覆盖，**修好它比报告它更有价值**。格式是故意固定的：

> **症状**（把原始报错串原样贴进来 —— 大家排错时就是拿报错去搜的）→ **原因** → **判定命令** → **修复**

报错原文就是索引，请保持字面一致。

## 许可证

MIT

---

维护者 [@Panmax](https://github.com/Panmax)。由真实的升级事故一点点长出来，一次一个坑。
