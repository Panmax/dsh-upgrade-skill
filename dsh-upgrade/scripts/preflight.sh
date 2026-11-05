#!/usr/bin/env bash
# preflight.sh — 在隔离环境里预检一个 dsh 版本，不碰生产 DSH_HOME
#
# 用法:
#   ./preflight.sh <版本> [profile] [端口]
# 例:
#   ./preflight.sh 0.2.2-rc.1 web 3999
#
# 做的事:
#   1. 装到 ~/.dsh/runtime/<版本>/（空 npm 缓存，绕开缓存过期）
#   2. 把 profiles/settings/sessions/storages 复制到临时 HOME
#   3. --dump-config 检查结构性错误（重复行 id、插件缺失、provider 丢失）
#   4. 真启动一次，看能否稳定跑住
#   5. 打印结论，不切换、不重启
#
# 退出码: 0=预检通过  1=预检失败  2=参数/环境错误

set -uo pipefail

VER="${1:-}"
PROFILE="${2:-web}"
PORT="${3:-3999}"

if [ -z "$VER" ]; then
  echo "用法: $0 <版本> [profile] [端口]" >&2
  exit 2
fi

DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
RT="$DSH_HOME_DIR/runtime/$VER"
BIN="$RT/node_modules/@deepseek-ai/dsh/lib/bin.js"
FAIL=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- 1. 版本存在性
say "检查版本 ${VER} 是否真的发布"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
  "https://registry.npmjs.org/@deepseek-ai/dsh/$VER" 2>/dev/null || echo 000)
if [ "$HTTP" = "200" ]; then ok "registry 返回 200"; else bad "registry 返回 ${HTTP}（版本不存在或网络问题）"; exit 1; fi

# ---------------------------------------------------------------- 2. Node 门槛
say "检查 Node 要求"
NEED=$(curl -s "https://registry.npmjs.org/@deepseek-ai/dsh/$VER" 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(j.engines?.node||"(无声明)")}catch{console.log("(解析失败)")}})')
echo "  该版本要求: $NEED"
echo "  当前 node : $(node -v 2>/dev/null || echo '未安装')"
if ! node -e '
const want=process.argv[1], have=process.version;
if(!want || want.startsWith("(")) process.exit(0);
const seg=s=>s.replace(/[^0-9.]/g,"").split(".").map(Number);
const h=seg(have), floor=seg(want);
for(let i=0;i<3;i++){ if((h[i]||0)>(floor[i]||0)) process.exit(0);
                     if((h[i]||0)<(floor[i]||0)) process.exit(1); }
process.exit(0);' "$NEED" 2>/dev/null; then
  warn "当前 Node 可能低于要求；后续步骤可能失败（用 nvm install <版本> 后再跑）"
fi

# ---------------------------------------------------------------- 3. 安装
say "安装到 ${RT}"
if [ ! -f "$BIN" ]; then
  mkdir -p "$RT" || { bad "无法创建 $RT"; exit 2; }
  ( cd "$RT" && npm install --no-audit --no-fund --cache "$(mktemp -d)" \
      "@deepseek-ai/dsh@$VER" >/tmp/dsh-preflight-install.log 2>&1 )
  if [ -f "$BIN" ]; then ok "安装完成"; else bad "安装失败，见 /tmp/dsh-preflight-install.log"; tail -20 /tmp/dsh-preflight-install.log; exit 1; fi
else
  ok "已存在，跳过安装"
fi

# ---------------------------------------------------------------- 4. 隔离 HOME
say "准备隔离环境"
SB=$(mktemp -d)
cp -a "$DSH_HOME_DIR/profiles" "$SB/" 2>/dev/null || { bad "找不到 $DSH_HOME_DIR/profiles"; exit 2; }
for f in settings.yaml.imported settings.yaml; do
  [ -f "$DSH_HOME_DIR/$f" ] && cp "$DSH_HOME_DIR/$f" "$SB/" && break
done
[ -d "$DSH_HOME_DIR/sessions" ] && cp -a "$DSH_HOME_DIR/sessions" "$SB/"
[ -d "$DSH_HOME_DIR/storages" ] && cp -a "$DSH_HOME_DIR/storages" "$SB/"
ok "沙箱: $SB"

# ---------------------------------------------------------------- 5. dump-config
say "组装配置"
DUMP=/tmp/dsh-preflight-dump.txt
ERR=/tmp/dsh-preflight-err.txt
DSH_HOME="$SB" timeout 120 node "$BIN" --profile "$PROFILE" --dump-config >"$DUMP" 2>"$ERR"
RC=$?
if [ $RC -ne 0 ]; then bad "dump-config 失败 (exit $RC)"; head -20 "$ERR"; else ok "dump-config 成功"; fi

if [ -s "$ERR" ]; then warn "stderr 输出:"; sed 's/^/    /' "$ERR" | head -15; else ok "stderr 为空"; fi

DUP=$(grep '^- id:' "$DUMP" 2>/dev/null | sed 's/^- id: //' | sort | uniq -d)
if [ -n "$DUP" ]; then bad "重复行 id（会导致 duplicate loader entry id）:"; echo "$DUP" | sed 's/^/    /'; else ok "无重复行 id"; fi

say "配置里的 provider"
PROVIDERS=$(awk '
  /^    providers:$/ { inp=1; next }
  inp && /^      [a-z0-9-]+:$/ { gsub(/[: ]/,""); print; next }
  inp && /^    [^ ]/ { inp=0 }
' "$DUMP" 2>/dev/null | sort -u)
if [ -n "$PROVIDERS" ]; then
  echo "$PROVIDERS" | sed 's/^/    /'
else
  warn "没看到 provider —— 检查 settings 是否被静默吞掉（见 SKILL.md 坑 4）"
fi

# ---------------------------------------------------------------- 6. 真启动
say "启动测试（端口 ${PORT}）"
BOOT=/tmp/dsh-preflight-boot.log
DSH_HOME="$SB" timeout 25 node "$BIN" --profile "$PROFILE" --no-open --port "$PORT" >"$BOOT" 2>&1
BRC=$?
if grep -q 'dsh web: http' "$BOOT"; then
  ok "已监听: $(grep -o 'http://[^ ]*' "$BOOT" | head -1)"
else
  bad "未启动成功"
fi
if grep -q 'startup failed' "$BOOT"; then
  bad "启动阶段有插件激活失败:"
  sed -n '/startup failed/,/^$/p' "$BOOT" | head -25 | sed 's/^/    /'
fi
if [ $BRC -ne 124 ] && [ $BRC -ne 0 ]; then warn "进程退出码 $BRC"; fi

# ---------------------------------------------------------------- 结论
say "结论"
if [ $FAIL -eq 0 ]; then
  printf '  \033[32m预检通过\033[0m —— 可以切换：\n\n'
  printf '    ln -sfn %s %s/runtime/current\n' "$VER" "$DSH_HOME_DIR"
  printf '    kill <当前 PID> && dsh web\n\n'
  printf '  回滚：ln -sfn <旧版本> %s/runtime/current\n' "$DSH_HOME_DIR"
  printf '  日志：%s  %s\n' "$DUMP" "$BOOT"
  rm -rf "$SB"
  exit 0
else
  printf '  \033[31m预检未通过\033[0m —— 不要切换。\n'
  printf '  排查顺序见 SKILL.md「故障分诊表」。日志：\n    %s\n    %s\n' "$DUMP" "$BOOT"
  printf '  沙箱保留在 %s（排查完记得删）\n' "$SB"
  exit 1
fi
