#!/bin/sh
# 验证预检：QA 启动 omp 前运行；任何一项不过就非零退出，不开跑。
# 用法：scripts/verify-preflight.sh <目标SHA> <预期版本号> <预期build号> <轮次slug>
# 例：  scripts/verify-preflight.sh 1a2b3c4 0.6.5 11 r16-v065-sim
# 结果：tmp/verify/r<N>-<slug>/preflight.json（slug 已是 r<N>-xxx 时直接用作轮次目录）。
set -eu
if [ "$#" -ne 4 ]; then
  echo "用法：$0 <目标SHA> <预期版本号> <预期build号> <轮次slug>" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
exec python3 .omp/skills/verify-posture-lab/scripts/verify.py preflight \
  --sha "$1" --version "$2" --build "$3" --slug "$4"
