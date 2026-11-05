#!/usr/bin/env bash
# check-update.sh — 检查 dsh 是否有新版本，并与当前运行版本对比
#
# 用法: ./check-update.sh
#
# 为什么不用 npm view：
#   本机 npm 缓存经常是旧的，`prefer-offline=true` 会让 npm 无视 max-age
#   继续用旧数据，导致「明明有新版本却报 notarget / 看不到新版本」。
#   curl 直查 registry 是唯一可靠的判定方式。

set -uo pipefail

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---- 当前运行版本
say "当前运行版本"
PID=$(lsof -nP -iTCP:3080 -sTCP:LISTEN -t 2>/dev/null | head -1)
CUR="(未运行)"
if [ -n "$PID" ]; then
  CMD=$(ps -o command= -p "$PID" 2>/dev/null)
  BINPATH=$(echo "$CMD" | grep -oE '/[^ ]*/node_modules/@deepseek-ai/dsh/lib/bin.js' | head -1)
  if [ -n "$BINPATH" ]; then
    CUR=$(node -e "try{console.log(require(process.argv[1].replace(/\/lib\/bin\.js$/,'')+'/package.json').version)}catch(e){console.log('?')}" "$BINPATH" 2>/dev/null)
  fi
  echo "  PID $PID  $CUR"
  echo "  $BINPATH"
else
  echo "  3080 端口没有进程在跑"
fi

# ---- registry
say "registry 版本"
DATA=$(curl -s --max-time 25 "https://registry.npmjs.org/@deepseek-ai%2Fdsh" 2>/dev/null)
if [ -z "$DATA" ]; then
  echo "  ❌ 无法访问 registry（网络问题？）" >&2
  exit 1
fi

echo "$DATA" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  const tags=j["dist-tags"]||{};
  for(const t of ["latest","next","alpha","beta"]){
    if(!tags[t])continue;
    const when=(j.time?.[tags[t]]||"").slice(0,16).replace("T"," ");
    console.log(`  ${t.padEnd(7)} ${tags[t].padEnd(18)} ${when}`);
  }
  const vers=Object.keys(j.versions||{});
  console.log(`  (共 ${vers.length} 个版本)`);
})'

# ---- 对比
say "对比"
echo "$DATA" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  const cur=process.argv[1];
  const tags=j["dist-tags"]||{};
  const newer=[];
  for(const [t,v] of Object.entries(tags)){
    if(v===cur) continue;
    newer.push(`${t} = ${v}`);
  }
  if(cur==="(未运行)"||cur==="?"){
    console.log("  （无法确定当前版本，只能列出上方 tag）");
    return;
  }
  console.log(`  当前: ${cur}`);
  const same=Object.values(tags).includes(cur);
  if(same) console.log("  ✓ 当前版本出现在 dist-tags 里");
  for(const n of newer) console.log(`  · ${n}`);
})' "$CUR"

cat <<'EOF'

下一步：
  · 目标是新版本 → 用 scripts/preflight.sh <版本> 做隔离预检
  · 预检通过后再切 ~/.dsh/runtime/current 并重启
  · 详见 SKILL.md
EOF
