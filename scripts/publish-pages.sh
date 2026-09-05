#!/usr/bin/env bash
# 把门户、选包页、救砖教程和本次生成的索引推到 gh-pages。
#
# 用法：
#   publish-pages.sh <json 目录> <提交说明>
#
# json 目录可以为空：里面没有 *.json 时只同步网页，gh-pages 上已有的
# 索引原样留着。出固件和「刷新索引」会放进新 json；只改门户文案时不必。
#
# 需要环境变量：GH_TOKEN、GITHUB_REPOSITORY、GITHUB_WORKSPACE、RUNNER_TEMP
#
# index.html 是门户（选包 / 救砖教程 / 仓库三张卡片），选包工具本体在
# packages.html。两条编译线各自一份 json，本脚本只覆盖传入目录里的那些，
# 另一条线的索引原样留着。
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "用法: $0 <json 目录> <提交说明>" >&2
  exit 2
fi
PAGES=$1
MSG=$2

need() { [ -e "$1" ] || { echo "::error::缺少 $1"; exit 1; }; }
need "$GITHUB_WORKSPACE/portal/index.html"
need "$GITHUB_WORKSPACE/selector/index.html"
need "$GITHUB_WORKSPACE/guide/recovery-guide.html"

GH="$RUNNER_TEMP/gh"
REMOTE="https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY.git"
if git clone --depth 1 --branch gh-pages "$REMOTE" "$GH"; then
  echo "已有 gh-pages 分支"
else
  echo "gh-pages 不存在，新建"
  git init -b gh-pages "$GH"
  git -C "$GH" remote add origin "$REMOTE"
fi
cd "$GH"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

stage() {
  cp "$GITHUB_WORKSPACE/portal/index.html" "$GH/index.html"
  cp "$GITHUB_WORKSPACE/selector/index.html" "$GH/packages.html"
  cp "$GITHUB_WORKSPACE/guide/recovery-guide.html" "$GH/recovery-guide.html"
  # 旧版存档：recovery-guide_<版本>.html 一律带上，由新版教程里的「旧版」
  # 卡片链过去。文件名进 URL，改名会断链。
  cp "$GITHUB_WORKSPACE"/guide/recovery-guide_*.html "$GH/"
  # 没有新 json 就不动已有索引，只刷网页
  shopt -s nullglob
  jsons=( "$PAGES"/*.json )
  shopt -u nullglob
  if [ ${#jsons[@]} -gt 0 ]; then
    cp "${jsons[@]}" "$GH/"
  else
    echo "本次不更新索引 json"
  fi
  touch "$GH/.nojekyll"
  git add -A
}

# 两条线同时推时后推的那个会被拒。浅克隆上 rebase 不可靠，
# 改为丢掉本地提交、取回最新的 gh-pages，再把本次文件重新叠上去。
for try in 1 2 3; do
  stage
  if git diff --cached --quiet; then
    echo "页面无变化，跳过提交"
    exit 0
  fi
  git commit -m "$MSG"
  if git push origin gh-pages; then
    break
  fi
  if [ "$try" = 3 ]; then
    echo "::error::推送 gh-pages 连续三次失败"
    exit 1
  fi
  echo "推送被拒，多半是并发构建先提交了，取最新重来"
  git fetch --depth 1 origin gh-pages
  git reset --hard FETCH_HEAD
done

OWNER=$(echo "$GITHUB_REPOSITORY" | cut -d/ -f1 | tr 'A-Z' 'a-z')
NAME=$(echo "$GITHUB_REPOSITORY" | cut -d/ -f2)
echo "门户已更新：https://$OWNER.github.io/$NAME/"
echo "选包页：https://$OWNER.github.io/$NAME/packages.html"
