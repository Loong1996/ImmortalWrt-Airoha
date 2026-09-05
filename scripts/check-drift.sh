#!/usr/bin/env bash
#
# 上游漂移检查
#
# 解决的问题：git rebase 只在「上游改了 ∩ 我也改了」时报冲突。而本项目大部分
# 内容是往树里新增文件（补丁、dts、preinit 钩子），它们依赖的上游文件我们一行
# 没碰 —— 那些地方上游怎么改，rebase 都不会吭声。25.12 线「编得过、刷上去没网、
# 日志里一个报错都没有」就是这么来的（见 docs/branches.md）。
#
# 子命令
#   watch     upstream.lock 里 pin 的提交 → 上游当前 tip，落在 watch/*.list
#             上的改动全部列出。只读 git，不需要源码树，不需要编译。
#   versions  源码树里的 U-Boot 与内核版本 vs upstream.lock 的预期值
#   refresh   在已编译的源码树里跑 quilt refresh，看本项目的补丁有没有被
#             改写（改写 = 打的时候有 offset/fuzz，patch 命令对此不报错）
#   dtb       把编出来的 dtb 反编译成 dts，与 golden/ 里的基准逐字比
#   all       watch + versions
#
# 用法
#   ./scripts/check-drift.sh watch
#   ./scripts/check-drift.sh watch -o ../openwrt-master-airoha
#   ./scripts/check-drift.sh versions -o ../openwrt-master-airoha
#   ./scripts/check-drift.sh refresh  -o ../openwrt-master-airoha
#   ./scripts/check-drift.sh dtb      -o ../openwrt-master-airoha
#
# 退出码：0 无漂移；1 有漂移（CI 据此开 issue）；2 用法或环境错误

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/upstream.lock"
WATCH_DIR="$REPO_ROOT/watch"
CACHE="${DRIFT_CACHE:-$REPO_ROOT/.drift-cache}"

SRC_DIR=""
CMD=""

die()  { echo "错误: $*" >&2; exit 2; }
info() { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m警告:\033[0m $*" >&2; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# ---------------------------------------------------------------- 参数

[ $# -ge 1 ] || usage
CMD="$1"; shift
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--src-dir) SRC_DIR="${2:-}"; shift 2 ;;
        -h|--help)    usage ;;
        *)            die "未知参数: $1" ;;
    esac
done

[ -f "$LOCK" ] || die "找不到 $LOCK"
# shellcheck disable=SC1090
set -a; . "$LOCK"; set +a
: "${UPSTREAM_REPO:?upstream.lock 缺 UPSTREAM_REPO}"
: "${UPSTREAM_BRANCH:?upstream.lock 缺 UPSTREAM_BRANCH}"
: "${UPSTREAM_COMMIT:?upstream.lock 缺 UPSTREAM_COMMIT}"

# ---------------------------------------------------------------- 工具

# 读清单：去掉注释与空行
read_list() {
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'
}

# 找一个能同时看到 pin 提交与上游 tip 的 git 仓库，回显其路径。
# 优先用 -o 指定的源码树（它本来就有全部历史），否则建一个 blob-less 的镜像缓存。
ensure_repo() {
    local d
    if [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR/.git" ]; then
        d="$SRC_DIR"
        git -C "$d" remote get-url _drift_upstream >/dev/null 2>&1 \
            || git -C "$d" remote add _drift_upstream "$UPSTREAM_REPO" >/dev/null 2>&1
        git -C "$d" fetch -q _drift_upstream "$UPSTREAM_BRANCH" || return 1
        echo "$d"; return 0
    fi
    d="$CACHE/upstream"
    if [ ! -d "$d/.git" ]; then
        mkdir -p "$CACHE"
        # blob:none 只取提交与树，不取文件内容。--name-status 的比较只用树，
        # 所以整个检查不会下载一个 blob，几十兆就够。
        git clone -q --filter=blob:none --no-checkout \
            --origin _drift_upstream "$UPSTREAM_REPO" "$d" || return 1
    fi
    git -C "$d" fetch -q _drift_upstream "$UPSTREAM_BRANCH" || return 1
    echo "$d"; return 0
}

# ---------------------------------------------------------------- watch

cmd_watch() {
    local repo tip n_total=0 rc=0
    repo="$(ensure_repo)" || die "无法访问上游仓库 $UPSTREAM_REPO"
    tip="$(git -C "$repo" rev-parse _drift_upstream/"$UPSTREAM_BRANCH")"

    if ! git -C "$repo" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null; then
        die "pin 的提交 $UPSTREAM_COMMIT 在上游仓库里找不到（被 force-push 了？）"
    fi

    local ahead
    ahead="$(git -C "$repo" rev-list --count "$UPSTREAM_COMMIT".."$tip")"

    echo "上游漂移报告"
    echo "============"
    echo "  上游仓库  $UPSTREAM_REPO ($UPSTREAM_BRANCH)"
    echo "  已验证基线 ${UPSTREAM_COMMIT:0:12}  ${UPSTREAM_DATE:-}"
    echo "  当前 tip   ${tip:0:12}  $(git -C "$repo" log -1 --format=%ad --date=short "$tip")"
    echo "  相差       $ahead 个提交"
    echo

    if [ "$ahead" = "0" ]; then
        echo "上游没动，无需处理。"
        return 0
    fi

    local list name paths out
    for list in "$WATCH_DIR"/*.list; do
        [ -e "$list" ] || continue
        name="$(basename "$list" .list)"
        mapfile -t paths < <(read_list "$list")
        [ "${#paths[@]}" -gt 0 ] || continue

        out="$(git -C "$repo" diff --name-status "$UPSTREAM_COMMIT" "$tip" -- "${paths[@]}")"
        if [ -z "$out" ]; then
            echo "── $name ── 无变化"
        else
            n_total=$(( n_total + $(echo "$out" | wc -l) ))
            rc=1
            echo "── $name ── $(echo "$out" | wc -l) 处变化"
            # A 新增 / M 修改 / D 删除 / R 改名。D 与 R 最值得警惕：
            # 那是「我依赖的东西没了或搬走了」，rebase 对此完全沉默。
            echo "$out" | sed 's/^/    /'
        fi
        echo
    done

    if [ "$rc" = "0" ]; then
        echo "盯梢清单上的路径都没动过。"
    else
        echo "共 $n_total 处变化。列出不等于坏了 —— 是「rebase 之前该看一眼这些地方」。"
        echo "重点看 D（删除）与 R（改名）：那是我依赖的东西没了或搬走了。"
    fi
    return $rc
}

# ---------------------------------------------------------------- versions

cmd_versions() {
    [ -n "$SRC_DIR" ] || die "versions 需要 -o <源码树路径>"
    [ -d "$SRC_DIR" ] || die "源码树不存在: $SRC_DIR"
    local rc=0 got

    if [ -n "${UBOOT_AIROHA_VERSION:-}" ]; then
        got="$(sed -n 's/^PKG_VERSION:=\(.*\)$/\1/p' "$SRC_DIR/package/boot/uboot-airoha/Makefile" 2>/dev/null | head -n1)"
        if [ -z "$got" ]; then
            warn "读不到 uboot-airoha 的 PKG_VERSION"; rc=1
        elif [ "$got" != "$UBOOT_AIROHA_VERSION" ]; then
            echo "✗ uboot-airoha: 预期 $UBOOT_AIROHA_VERSION，实际 $got"
            echo "  202/206/950-954 打在 U-Boot 上，版本变了必须复查"
            rc=1
        else
            echo "✓ uboot-airoha $got"
        fi
    fi

    if [ -n "${KERNEL_VERSION:-}" ]; then
        got="$(sed -n 's/^LINUX_VERSION-\([0-9.]*\).*$/\1/p' "$SRC_DIR/target/linux/airoha/Makefile" 2>/dev/null | head -n1)"
        [ -n "$got" ] || got="$(sed -n 's/^KERNEL_PATCHVER:=\(.*\)$/\1/p' "$SRC_DIR/target/linux/airoha/Makefile" 2>/dev/null | head -n1)"
        if [ -z "$got" ]; then
            warn "读不到 airoha 的内核版本"; rc=1
        elif [ "$got" != "$KERNEL_VERSION" ]; then
            echo "✗ 内核: 预期 $KERNEL_VERSION，实际 $got"
            echo "  patches-6.18/805 与 an7581/config-6.18 都跟版本号绑定"
            rc=1
        else
            echo "✓ 内核 $got"
        fi
    fi
    return $rc
}

# ---------------------------------------------------------------- refresh

# OpenWrt 打包内补丁走 scripts/patch-kernel.sh -> patch -f -p1：整块 reject 才
# 让构建失败，offset 与 fuzz<=2 是静默成功的。quilt refresh 会把补丁按实际打上
# 去的位置重写，于是「偏了」就变成了一个看得见的 diff。

# 但 refresh 还会顺手做一件与位置无关的事：把 git format-patch 风格的补丁
# 规范化成 quilt 风格。uboot-airoha 的 100~106 是从 mainline 直接取来的，带
# `diff --git` / `index` 头和 `-- \n<git 版本>` 邮件签名尾，refresh 一律剥掉 ——
# 补丁落位完全正确时也照剥。只看 `git diff --name-only` 就会把这类纯格式改写
# 报成 offset（2026-09-04 第 53 次编译的误报即出于此：7 个补丁全是这种，
# 零个 @@ 头变化）。所以剥掉这些头尾再比一次，剩下的才是真的偏移。
#
# 不怕漏报：本项目自己的补丁本来就是 quilt 风格，没有这些头；而真实 offset
# 一定体现在 @@ 行号或内容行上，下面的过滤碰不到它们。
#
# sed 表达式一条一行、不用 `\|` 交替：那是 GNU 扩展，BSD sed（macOS）会静默
# 不匹配，于是本地跑出来的结论和 CI 不一样。
_strip_git_patch_meta() {
    sed -e '/^diff --git /d' \
        -e '/^index [0-9a-f]\{7,\}/d' \
        -e '/^new file mode /d' \
        -e '/^deleted file mode /d' \
        -e '/^old mode /d' \
        -e '/^new mode /d' \
        -e '/^similarity index /d' \
        -e '/^rename from /d' \
        -e '/^rename to /d' \
    | awk '{ l[NR] = $0 }
           /^-- $/ { sig = NR }
           END { n = (sig ? sig - 1 : NR); for (i = 1; i <= n; i++) print l[i] }'
    # 签名块只截最后一个 `-- `：补丁正文里理论上也可能出现这行（删掉一行 `- `），
    # 那种在前面，截了会把真实内容也吞掉。
}

cmd_refresh() {
    [ -n "$SRC_DIR" ] || die "refresh 需要 -o <源码树路径>"
    [ -d "$SRC_DIR" ] || die "源码树不存在: $SRC_DIR"
    command -v quilt >/dev/null || warn "宿主没有 quilt，OpenWrt 会用自带的"

    local rc=0
    # clean 是必须的：quilt-check 要求源码目录是用 QUILT=1 解包的，而正常编译
    # 不走 quilt。不先 clean 就会得到
    #   "The source directory was not unpacked using quilt. Please rebuild with QUILT=1"
    # 另外 QUILT=1 必须写在命令行 —— quilt.mk 里是 QUILT?=，只有命令行变量能压过它
    # （它对 MAKECMDGOALS 的自动 override 只认裸的 refresh，不认 package/xxx/refresh）。
    #
    # 代价：内核与 uboot 都要重新解包打补丁，几分钟；且会让已 prepare 的状态失效。
    warn "本检查会 clean 并重新 prepare 内核与 uboot-airoha，源码树状态会变"
    info "刷新 uboot-airoha 补丁"
    ( cd "$SRC_DIR" && make package/boot/uboot-airoha/{clean,refresh} QUILT=1 V=s ) \
        || { warn "uboot-airoha refresh 失败"; rc=1; }
    info "刷新内核补丁"
    ( cd "$SRC_DIR" && make target/linux/{clean,refresh} QUILT=1 V=s ) \
        || { warn "target/linux refresh 失败"; rc=1; }

    info "比对被 refresh 改写的补丁"
    local changed real="" cosmetic="" f
    changed="$(git -C "$SRC_DIR" diff --name-only -- \
        'package/boot/uboot-airoha/patches' \
        'target/linux/airoha/patches-6.18')"

    # 逐个分流：剥掉 git 风格的头尾后还有差异的才是真偏移
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if git -C "$SRC_DIR" show "HEAD:$f" 2>/dev/null | _strip_git_patch_meta \
           | diff -q - <(_strip_git_patch_meta < "$SRC_DIR/$f") >/dev/null 2>&1; then
            cosmetic="$cosmetic$f"$'\n'
        else
            real="$real$f"$'\n'
        fi
    done <<< "$changed"

    if [ -n "$real" ]; then
        echo "✗ 以下补丁被 refresh 改写，说明打上去时有 offset/fuzz："
        printf '%s' "$real" | sed 's/^/    /'
        echo
        # shellcheck disable=SC2086
        git -C "$SRC_DIR" diff -- $(printf '%s' "$real" | tr '\n' ' ') | head -200
        rc=1
    else
        echo "✓ 所有补丁都干净落位，没有偏移"
    fi

    if [ -n "$cosmetic" ]; then
        echo
        echo "· 另有补丁被 refresh 规范化了格式（剥掉 git 风格的头尾），落位是对的："
        printf '%s' "$cosmetic" | sed 's/^/    /'
        echo "  不算漂移，不影响构建；源码树里这些文件已被改动，别顺手提交进去。"
    fi
    return $rc
}

# ---------------------------------------------------------------- dtb

# 编出来的 dtb 反编译成 dts，与 golden/ 里的基准逐字比。
#
# 抓的是「dts 编得过、固件刷得进、开机没网、日志无声」那一类：25.12 线那次
# 上游把 PCS 的属性名从 pcs 改成 pcs-handle，源码层面没有任何冲突，只有把最终
# 产物摊平了看才发现属性对不上。dtsi 的 include 结构、上游改的默认值、被
# /delete-property/ 掉的东西，全都只在这一层现形。
#
# golden/ 为空时不报错，而是把当前产物写进去让人 review 后提交 —— 基准必须来自
# 一次实机验证过的编译，脚本没法凭空造。
cmd_dtb() {
    [ -n "$SRC_DIR" ] || die "dtb 需要 -o <源码树路径>"
    command -v dtc >/dev/null || die "缺少 dtc（apt install device-tree-compiler）"
    local golden="$REPO_ROOT/golden" rc=0 found=0
    mkdir -p "$golden"

    local dtb name cur
    while IFS= read -r dtb; do
        name="$(basename "$dtb" .dtb)"
        case "$name" in *xg-040g*) ;; *) continue ;; esac
        found=1
        cur="$(mktemp)"
        # -s 排序节点与属性，消除编译顺序带来的无意义差异
        dtc -I dtb -O dts -s -q "$dtb" > "$cur" 2>/dev/null || { warn "反编译失败: $dtb"; rc=1; continue; }
        if [ ! -f "$golden/$name.dts" ]; then
            cp "$cur" "$golden/$name.dts"
            echo "· $name 没有基准，已写入 golden/$name.dts"
            echo "  请 review 后提交 —— 基准应当来自一次实机验证过的编译。"
        elif diff -q "$golden/$name.dts" "$cur" >/dev/null; then
            echo "✓ $name 与基准一致"
        else
            echo "✗ $name 与基准不一致："
            diff -u "$golden/$name.dts" "$cur" | head -80 | sed 's/^/    /'
            rc=1
        fi
        rm -f "$cur"
    done < <(find "$SRC_DIR/build_dir" -name '*.dtb' -type f 2>/dev/null)

    [ "$found" = "1" ] || { warn "build_dir 里没找到 xg-040g 的 dtb，是不是还没编译？"; return 1; }
    return $rc
}

# ---------------------------------------------------------------- main

case "$CMD" in
    watch)    cmd_watch ;;
    versions) cmd_versions ;;
    refresh)  cmd_refresh ;;
    dtb)      cmd_dtb ;;
    all)      r=0; cmd_watch || r=1; echo; cmd_versions || r=1; exit $r ;;
    *)        usage ;;
esac
