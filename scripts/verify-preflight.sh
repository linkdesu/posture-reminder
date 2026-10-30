#!/bin/sh
# 验证预检：QA 启动 omp 前运行；任何一项不过就非零退出，不开跑。
# 用法：scripts/verify-preflight.sh <目标SHA> <预期版本号> <预期build号> <轮次slug>
# 例：  scripts/verify-preflight.sh 1a2b3c4 0.6.7 13 r17-v067-sim
# 结果：tmp/verify/<run-id>/preflight.json。slug 是 r<N>-xxx 或 tl-xxx 时直接用作目录名。
# 只用固定模拟器 pl-verify（每轮复用，不新建、不删除）。开跑前有多台或非 pl-verify 的模拟器在
# Booted 就 ENV-BLOCKED。预检结束（通过、失败、INT/TERM/HUP）都只把 pl-verify 关机，up 再开。
set -u
if [ "$#" -ne 4 ]; then
  echo "用法：$0 <目标SHA> <预期版本号> <预期build号> <轮次slug>" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
VERIFY=.omp/skills/verify-posture-lab/scripts/verify.py
RUNFILE=$(mktemp -t pl-preflight-run)
export PL_PREFLIGHT_RUNFILE="$RUNFILE"

cleanup() {
  if [ -s "$RUNFILE" ]; then
    python3 "$VERIFY" preflight-cleanup --run "$(cat "$RUNFILE")" || true
  fi
  rm -f "$RUNFILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

python3 "$VERIFY" preflight --sha "$1" --version "$2" --build "$3" --slug "$4"
