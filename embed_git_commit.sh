#!/bin/zsh
# 用法: embed_git_commit.sh <输出文件> [仓库目录]
# 将仓库当前 Git 提交短哈希写入输出文件(GitCommitHash.txt),
# 供 App 在"首页设置"右上角显示当前构建对应的提交;仓库不可用时写入 unknown。
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <output-file> [repo-dir]" >&2
  exit 2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

OUTPUT_PATH="$1"
REPO_DIR="${2:-$PWD}"

if ! COMMIT_HASH="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)"; then
  COMMIT_HASH="unknown"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
print -r -- "$COMMIT_HASH" > "$OUTPUT_PATH"
