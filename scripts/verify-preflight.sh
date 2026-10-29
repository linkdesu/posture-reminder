#!/bin/sh
# 验证预检：QA 启动 omp 前运行；任何一项不过就非零退出，不开跑。
# 用法：scripts/verify-preflight.sh <目标SHA> <预期版本号> <预期build号> <轮次slug> [--keep-sim]
# 例：  scripts/verify-preflight.sh 1a2b3c4 0.6.5 11 r16-v065-sim --keep-sim
# 结果：tmp/verify/<run-id>/preflight.json。slug 是 r<N>-xxx 或 tl-xxx 时直接用作目录名。
# 本轮专用模拟器：默认（只跑预检 / dry-run）跑完即关闭并删除；--keep-sim 时仅在预检通过后保留给
# up/drive。正常退出、失败、收到 INT/TERM/HUP 都会经 trap 兜底清理。
set -u
if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "用法：$0 <目标SHA> <预期版本号> <预期build号> <轮次slug> [--keep-sim]" >&2
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

KEEP=""
if [ "${5:-}" = "--keep-sim" ]; then KEEP="--keep-sim"; fi
python3 "$VERIFY" preflight --sha "$1" --version "$2" --build "$3" --slug "$4" $KEEP
