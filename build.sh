#!/usr/bin/env bash
#
# XG-040G-MD 本地编译脚本
#
# 参数与 .github/workflows/xg-040g-md-immortalwrt.yml 的 Run workflow 输入一一对应，
# 目的是让本地编译和 CI 编出同样的固件。用法见 docs/local-build.md。
#
#   ./build.sh                                  # master 线 + ubi 变体
#   ./build.sh -v stock                         # 换设备变体
#   ./build.sh -D xg-040g-mf                    # 换机型
#   ./build.sh -p "luci-app-passwall -luci-app-ttyd"   # 选包页生成的那串
#
set -euo pipefail

# 英文安装的 Ubuntu 常见 LANG=C / 未设 locale，此时脚本的中文提示会显示成乱码。
# C.UTF-8 在 Ubuntu 20.04+ 一定存在，字符集是 UTF-8 而排序规则仍是 C —— 后者正是
# 编译时想要的，不会像 zh_CN.UTF-8 那样改变 sort/ls 的行为影响构建。
if ! locale charmap 2>/dev/null | grep -qi "utf-*8"; then
    export LC_ALL=C.UTF-8 LANG=C.UTF-8
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/Loong1996/immortalwrt.git"

# 默认值与 workflow 的 workflow_dispatch 默认输入保持一致
BRANCH="master-airoha"
VARIANT="ubi"
DEVICE="xg-040g-md"
DRAM_SIZE="auto"
EXTRA_PACKAGES=""
SRC_DIR=""
JOBS=""
DO_UPDATE=1        # 默认每次都拉最新源码；--no-update 可跳过
DO_MENUCONFIG=0
DO_CLEAN=0
CONFIG_ONLY=0

die() { echo "错误: $*" >&2; exit 1; }
info() { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m警告:\033[0m $*" >&2; }

# 分阶段计时。首次编译一两个小时，事后想知道时间花在哪一段（下载慢还是编译慢），
# 光有总耗时不够用，所以每段单独记一笔。
SCRIPT_START="$(date +%s)"
STAGE_START="$SCRIPT_START"
STAGE_LOG=""
fmt_dur() {
    local s="$1"
    if   [ "$s" -ge 3600 ]; then printf '%d 小时 %d 分' $(( s / 3600 )) $(( s % 3600 / 60 ))
    elif [ "$s" -ge 60 ];   then printf '%d 分 %d 秒'   $(( s / 60 ))   $(( s % 60 ))
    else                         printf '%d 秒' "$s"
    fi
}
stage_done() {
    local now; now="$(date +%s)"
    STAGE_LOG="${STAGE_LOG}    $(printf '%-8s' "$1") $(fmt_dur $(( now - STAGE_START )))\n"
    STAGE_START="$now"
}
report_time() {
    echo
    echo "耗时："
    if [ -n "$STAGE_LOG" ]; then echo -en "$STAGE_LOG"; fi
    echo "    ------------------------"
    echo "    $(printf '%-8s' "合计") $(fmt_dur $(( $(date +%s) - SCRIPT_START )))"
}

usage() {
    cat <<'EOF'
用法: ./build.sh [选项]

  -b, --branch <分支>     源码分支，默认 master-airoha（唯一维护的线）
  -v, --variant <变体>    设备变体 ubi|stock，默认 ubi
  -D, --device <机型>     xg-040g-md|xg-040g-mf，默认 xg-040g-md
  -d, --dram <容量>       内存容量 auto|512M|1G|2G，默认 auto（自适应）
  -p, --packages <串>     附加软件包，格式同选包页：空格分隔，前缀 - 表示移除
  -j, --jobs <n>          并行度，默认按 CPU 与内存自动取较小值
  -o, --src-dir <路径>    源码树位置，默认 <本仓库同级>/openwrt-<分支>
      --no-update         跳过源码与 feeds 更新，编当前这份代码
                          （默认每次都更新到远端最新；本地有调试
                          修改、或要固定基线做对比时加这个）
      --menuconfig        defconfig 之后进入 menuconfig 手动调整
      --clean             编译前 make clean（保留工具链）
      --config-only       只做到配置生成，不编译
  -h, --help              显示本帮助

示例:
  ./build.sh -v ubi -j 4
  ./build.sh -D xg-040g-mf
  ./build.sh -p "luci-app-openclash ruby ruby-yaml"
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--branch)    BRANCH="${2:?缺少分支名}"; shift 2 ;;
        -v|--variant)   VARIANT="${2:?缺少变体名}"; shift 2 ;;
        -D|--device)    DEVICE="${2:?缺少机型}"; shift 2 ;;
        -d|--dram)      DRAM_SIZE="${2:?缺少容量}"; shift 2 ;;
        -p|--packages)  EXTRA_PACKAGES="${2:-}"; shift 2 ;;
        -j|--jobs)      JOBS="${2:?缺少并行度}"; shift 2 ;;
        -o|--src-dir)   SRC_DIR="${2:?缺少路径}"; shift 2 ;;
        --update)       DO_UPDATE=1; shift ;;
        --no-update|--not-update) DO_UPDATE=0; shift ;;
        --menuconfig)   DO_MENUCONFIG=1; shift ;;
        --clean)        DO_CLEAN=1; shift ;;
        --config-only)  CONFIG_ONLY=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "未知选项: $1" ;;
    esac
done

# ---------------------------------------------------------------- 环境检查

[ "$(uname -s)" = "Linux" ] || die "只支持 Linux。macOS 的文件系统默认大小写不敏感，OpenWrt 解包阶段就会出错"
[ "$(id -u)" -ne 0 ] || die "不要用 root 运行 —— OpenWrt 构建系统会拒绝执行"

for c in git make gcc python3 curl; do
    command -v "$c" >/dev/null || die "缺少 $c，请先执行 docs/local-build.md 第三章第 1 步安装依赖"
done

# OpenWrt 的 host pkg-config 文件写的是绝对路径。两棵树并排编译时，如果
# shell 里残留 STAGING_DIR / PKG_CONFIG_PATH（或 staging_dir/host 是从
# 另一棵树拷/链过来的），meson 会把那棵树的 libz.a 链进 apk，LTO 链接
# 直接报 htole32 / le32toh undefined。这里先清掉会串树的环境变量。
for v in STAGING_DIR STAGING_DIR_HOST STAGING_DIR_TOOLCHAIN PKG_CONFIG_PATH PKG_CONFIG_LIBDIR; do
    eval "val=\${$v-}"
    if [ -n "$val" ]; then
        warn "环境变量 $v=$val 会串进 host 构建，已取消导出"
        unset "$v"
    fi
done

# ImmortalWrt 的 init_build_environment.sh 按发行版代号白名单判断，26.04 这类新版
# 会被直接拒（Unsupported OS）。更实质的是新 GCC 会让 tools/ 下的 host 工具在
# -Werror 上中断。这里只提醒不拦截 —— 依赖你若已自行处理妥当，仍可继续。
CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || true)"
case "$CODENAME" in
    noble|jammy|focal|bionic|bookworm|bullseye|buster|trixie) ;;
    *) warn "发行版代号 ${CODENAME:-未知} 不在 ImmortalWrt 依赖脚本的支持列表内，建议 Ubuntu 24.04 (noble)。详见 docs/local-build.md 第一章" ;;
esac

if [ "$(uname -m)" != "x86_64" ]; then
    warn "架构 $(uname -m) 非 x86_64，官方依赖脚本不支持，需自行确认依赖齐全"
fi

# 并行度：峰值约每任务 1.5~2 GB，撑爆内存时 OOM killer 会在编译中途杀掉 gcc，
# 报出的错看不出是内存问题。所以默认取「CPU 核数」与「内存 GB ÷ 2」的较小值。
NPROC="$(nproc)"
MEM_GB=$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024))
SAFE_JOBS=$(( MEM_GB / 2 ))
if [ "$SAFE_JOBS" -lt 1 ]; then SAFE_JOBS=1; fi
if [ -z "$JOBS" ]; then
    JOBS=$(( NPROC < SAFE_JOBS ? NPROC : SAFE_JOBS ))
    if [ "$JOBS" -lt "$NPROC" ]; then
        warn "内存 ${MEM_GB} GB，并行度从 $NPROC 降到 $JOBS（每任务约需 2 GB）"
    fi
elif [ "$JOBS" -gt "$SAFE_JOBS" ]; then
    warn "指定的 -j $JOBS 超过内存建议值 $SAFE_JOBS（${MEM_GB} GB），可能触发 OOM"
fi

# ---------------------------------------------------------- 分支与变体映射

# 与 workflow「生成变量」一步一致：机型决定子目标与配置文件，变体决定设备符号
[ "$BRANCH" = "master-airoha" ] || warn "只维护 master-airoha，分支 $BRANCH 按同样的机型/变体规则处理"
case "$DEVICE" in
    xg-040g-md) DEVICE_SUBTARGET="an7581"; CONFIG_FILE="config/xg-040g-md-master.config" ;;
    xg-040g-mf) DEVICE_SUBTARGET="an7583"; CONFIG_FILE="config/xg-040g-mf-master.config" ;;
    *)          die "不支持的机型: $DEVICE（可选 xg-040g-md|xg-040g-mf）" ;;
esac
case "$VARIANT" in
    stock)  DEVICE_SYMBOL="nokia_${DEVICE}" ;;
    ubi)    DEVICE_SYMBOL="nokia_${DEVICE}-ubi" ;;
    *)      die "不支持的变体: $VARIANT（可选 stock|ubi）" ;;
esac

case "$DRAM_SIZE" in
    auto|512M|1G|2G) ;;
    *) die "不支持的内存容量: $DRAM_SIZE（可选 auto|512M|1G|2G）" ;;
esac

[ -f "$REPO_ROOT/$CONFIG_FILE" ] || die "未找到配置文件 $REPO_ROOT/$CONFIG_FILE"
[ -n "$SRC_DIR" ] || SRC_DIR="$(dirname "$REPO_ROOT")/openwrt-$BRANCH"

info "分支 $BRANCH ／ 机型 $DEVICE ／ 变体 $VARIANT ／ 设备 $DEVICE_SYMBOL"
info "配置 $CONFIG_FILE ／ 内存 $DRAM_SIZE ／ 并行 -j$JOBS"
info "源码 $SRC_DIR"

# 磁盘：build_dir + staging_dir + 工具链约 30 GB，编到一半没空间很难收拾
CHECK_DIR="$SRC_DIR"; [ -d "$CHECK_DIR" ] || CHECK_DIR="$(dirname "$SRC_DIR")"
AVAIL_GB=$(( $(df -Pk "$CHECK_DIR" | awk 'NR==2{print $4}') / 1024 / 1024 ))
[ "$AVAIL_GB" -ge 25 ] || die "$CHECK_DIR 只剩 ${AVAIL_GB} GB，至少需要 40 GB"
[ "$AVAIL_GB" -ge 40 ] || warn "$CHECK_DIR 只剩 ${AVAIL_GB} GB，建议 40 GB 以上"

# -------------------------------------------------------------- 获取源码

if [ ! -d "$SRC_DIR/.git" ]; then
    info "克隆源码（补丁已内置在分支中，不需要另外打补丁）"
    git clone "$REPO_URL" -b "$BRANCH" "$SRC_DIR"
    DO_UPDATE=1    # 新树必须装 feeds
else
    # 树已存在：先确认它确实在目标分支上，否则会拿着别的源码去编 $DEVICE_SYMBOL
    CURRENT_BRANCH="$(git -C "$SRC_DIR" rev-parse --abbrev-ref HEAD)"
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
        if [ "$DO_UPDATE" = "1" ]; then
            die "源码树在 $CURRENT_BRANCH，与 --branch $BRANCH 不符，不能自动更新。先切换分支，或加 --no-update 编当前这份"
        fi
        warn "源码树当前在 $CURRENT_BRANCH，而不是 $BRANCH —— 编出来的是前者的代码"
    fi

    if [ "$DO_UPDATE" = "1" ]; then
        info "更新源码树"
        # inject-author-info.py 上一轮改过的三个模板是本脚本自己的产物，不算你的
        # 改动。先还原，否则每次远端被强推后都会被它们拦在「工作区有未提交的修改」。
        git -C "$SRC_DIR" checkout -q -- \
            package/base-files/files/etc/banner \
            package/base-files/files/etc/openwrt_release \
            package/base-files/files/usr/lib/os-release 2>/dev/null || true
        git -C "$SRC_DIR" fetch origin "$BRANCH"
        # master 线跟进上游走的是 rebase + force-with-lease（见 docs/branches.md），
        # 远端被强推后本地 HEAD 不再是远端的祖先，--ff-only 会直接失败。分两种情况处理：
        # 本地确实没有自己的东西就重置对齐；有则停下来交给你决定，绝不静默丢弃改动。
        if git -C "$SRC_DIR" merge-base --is-ancestor HEAD "origin/$BRANCH"; then
            git -C "$SRC_DIR" merge --ff-only "origin/$BRANCH" \
                || die "快进失败，工作区可能有与更新冲突的改动。处理后重跑，或加 --no-update 跳过更新"
        else
            warn "远端 $BRANCH 与本地已分叉，多半是跟进上游后强推过"
            DIRTY="$(git -C "$SRC_DIR" status --porcelain)"
            # 不能按 SHA 判断本地是否「多出提交」：rebase / amend 之后，本地那个旧提交
            # 的 SHA 在远端已不存在，rev-list 会把它算成本地独有，于是每次跟进上游后
            # 都误判成有改动。git cherry 按 patch-id 比内容 —— 已被上游包含的标 -，
            # 只有标 + 的才是真正属于你自己的提交。
            OWN="$(git -C "$SRC_DIR" cherry "origin/$BRANCH" HEAD 2>/dev/null | grep '^+' || true)"
            if [ -n "$DIRTY" ] || [ -n "$OWN" ]; then
                if [ -n "$OWN" ]; then
                    echo "    本地有远端没有的提交:"
                    echo "$OWN" | while read -r _ sha; do
                        git -C "$SRC_DIR" --no-pager log -1 --oneline "$sha" | sed 's/^/      /'
                    done
                fi
                if [ -n "$DIRTY" ]; then
                    echo "    工作区有未提交的修改:"
                    echo "$DIRTY" | sed 's/^/      /'
                fi
                die "本地有你自己的改动，不做自动重置。先 git -C $SRC_DIR branch <备份名> 或 stash 再重跑，或加 --no-update 直接编当前这份"
            fi
            # 即便判定为可重置，也先留一个备份 ref —— reset --hard 之后旧 HEAD 只剩
            # reflog 可找，打个分支成本极低，误判时能立刻找回来。
            BACKUP="backup/$(date +%Y%m%d-%H%M%S)"
            git -C "$SRC_DIR" branch "$BACKUP" HEAD
            info "本地无独有改动，重置到 origin/$BRANCH（旧 HEAD 已存为 $BACKUP）"
            git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
            warn "基线已被重写，内核补丁或 DTS 若有变动，建议这次加 --clean 重编"
        fi
    else
        info "源码树保持原样（--no-update）"
    fi
fi

cd "$SRC_DIR"
git --no-pager log -1 --date=short --format="    当前 HEAD: %h %cd %s"

# 工具链若是从另一棵树拷过来的，zlib.pc 的 prefix 仍是那棵树的路径。
# apk 的 meson 会按这个绝对路径去链 libz.a，编到 package/system/apk
# [host] 就炸。查到就停下来，不要带着错前缀继续。
if [ -f staging_dir/host/lib/pkgconfig/zlib.pc ]; then
    ZPREFIX="$(sed -n 's/^prefix=//p' staging_dir/host/lib/pkgconfig/zlib.pc | head -n1)"
    EXPECT_PREFIX="$SRC_DIR/staging_dir/host"
    if [ -n "$ZPREFIX" ] && [ "$ZPREFIX" != "$EXPECT_PREFIX" ]; then
        die "staging_dir/host 的 zlib.pc prefix 是 $ZPREFIX，不是本树 $EXPECT_PREFIX。多半是从另一棵树拷了工具链。在本树执行：make tools/zlib/{clean,compile,install} && make package/system/apk/host/clean"
    fi
fi

# ------------------------------------------------------------ 内存容量改写

# 默认 auto 不动 DTS：memory 节点留 512M 保底，实际容量由引导程序探测后写进 DTB，
# 512M / 1G / 2G 机器刷同一份固件。只有 stock 变体换过颗粒才需要写死。
if [ "$DRAM_SIZE" != "auto" ]; then
    info "改写 DTS 内存容量为 $DRAM_SIZE"
    DTS="$(grep -rl "linux,usable-memory-range" target/linux/airoha/dts/ 2>/dev/null | grep -i "xg-040g" | head -n1)"
    [ -n "$DTS" ] || die "未找到含 usable-memory-range 的 XG-040G dts"
    case "$DRAM_SIZE" in
        512M) MEM_SIZE=0x20000000 ;;
        1G)   MEM_SIZE=0x40000000 ;;
        2G)   MEM_SIZE=0x80000000 ;;
    esac
    # usable-memory-range 走 memblock_cap_memory_range()，只能往少了裁、不会凭空多出来，
    # 固定放到 2G 对任何一档都不构成裁剪，同时保住起点 0x80200000 对 ATF 那 2MB 的保护
    python3 - "$DTS" "$MEM_SIZE" 0x7fe00000 <<'PY'
import re, sys
path, mem, usable = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()
s, n1 = re.subn(r"(reg\s*=\s*<0x0\s+0x80000000\s+0x0\s+)0x[0-9a-fA-F]+(\s*>\s*;)",
                lambda m: m.group(1) + mem + m.group(2), s)
s, n2 = re.subn(r"(linux,usable-memory-range\s*=\s*<0x0\s+0x80200000\s+0x0\s+)0x[0-9a-fA-F]+(\s*>\s*;)",
                lambda m: m.group(1) + usable + m.group(2), s)
if n1 != 1 or n2 != 1:
    sys.exit("替换次数异常 memory=%d usable=%d（期望各 1 次）" % (n1, n2))
open(path, "w", encoding="utf-8").write(s)
print("    已改写 %s" % path)
PY
fi

# ---------------------------------------------------------------- feeds

# 本仓库 packages/ 下的包（目前只有 luci-app-airoha-npu）挂成一个 src-link feed，
# 不进源码仓库。src-link 建的是符号链接不复制，所以改完包直接重编即可。
# feeds.conf 优先于 feeds.conf.default，没有就先复制一份再追加。
if [ ! -f feeds.conf ]; then
    cp feeds.conf.default feeds.conf
fi
if ! grep -q "^src-link loong " feeds.conf; then
    info "挂载本地 feed loong -> $REPO_ROOT/packages"
    echo "src-link loong $REPO_ROOT/packages" >> feeds.conf
fi

if [ "$DO_UPDATE" = "1" ] || [ ! -d package/feeds ]; then
    info "安装 feeds"
    ./scripts/feeds update -a
    ./scripts/feeds install -a
else
    info "跳过 feeds 更新（--no-update）"
fi

# 在默认 SSH banner 和 /usr/lib/os-release（procd 把 OPENWRT_RELEASE 报成
# ubus system.board 的 description，LuCI 概览「固件版本」读的是它）末尾追加
# 作者信息。不能用 make FILES=：全量编译读的是源码树里的 files/，FILES 是
# ImageBuilder 的接口，写成命令行变量还会盖掉 kmod 打包用的同名变量。
# 顺带撤销 2026-08-31 之前留在 feeds 里的 10_system.js 改动，否则作者信息
# 会在管理页上出现两次。
info "写入作者信息"
python3 "$REPO_ROOT/scripts/inject-author-info.py" "$SRC_DIR"
stage_done "准备"

# ---------------------------------------------------------------- 配置

info "生成配置"
cp "$REPO_ROOT/$CONFIG_FILE" .config

# 先清掉配置里这个子目标的所有设备行，再插入选中的那个。子目标跟机型走
# （MD an7581 / MF an7583），写错子目标的符号会被 defconfig 静默丢弃，
# 编出来的是没选中任何设备的空壳，所以随后要 grep 确认。
sed -i "/^CONFIG_TARGET_airoha_${DEVICE_SUBTARGET}_DEVICE_/d" .config
sed -i "/^# CONFIG_TARGET_airoha_${DEVICE_SUBTARGET}_DEVICE_/d" .config
sed -i "/^CONFIG_TARGET_airoha_${DEVICE_SUBTARGET}=y/a CONFIG_TARGET_airoha_${DEVICE_SUBTARGET}_DEVICE_${DEVICE_SYMBOL}=y" .config
grep -q "^CONFIG_TARGET_airoha_${DEVICE_SUBTARGET}_DEVICE_${DEVICE_SYMBOL}=y" .config \
    || die "设备符号写入失败: $DEVICE_SYMBOL（配置里没有 CONFIG_TARGET_airoha_${DEVICE_SUBTARGET}=y？）"

# 附加软件包：pkg 编入固件，-pkg 从基础配置剔除。这里只改写 .config，
# 依赖交给随后的 defconfig 补全，是否真生效在下一步核对。
EXTRA_PACKAGES="$EXTRA_PACKAGES" python3 - <<'PY'
import os, re, sys
raw = os.environ.get("EXTRA_PACKAGES") or ""
add, rm, bad = [], [], []
for t in re.split(r"[\s,]+", raw.strip()):
    if not t:
        continue
    neg = t.startswith("-")
    n = t[1:] if neg else t
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$", n):
        bad.append(t)
    elif neg:
        rm.append(n)
    else:
        add.append(n)
if bad:
    sys.exit("非法软件包名: %s" % " ".join(bad))
# 先把该符号已有的行全部删掉，再按意图追加，免得同一个包留下两条互相矛盾的记录
targets = set(add) | set(rm)
kept = []
for ln in open(".config", encoding="utf-8").read().splitlines():
    m = re.match(r"^(?:# )?CONFIG_PACKAGE_(\S+?)(?:=[ymn]| is not set)\s*(?:#.*)?$", ln)
    if m and m.group(1) in targets:
        continue
    kept.append(ln)
kept += ["CONFIG_PACKAGE_%s=y" % n for n in add]
kept += ["# CONFIG_PACKAGE_%s is not set" % n for n in rm]
open(".config", "w", encoding="utf-8").write("\n".join(kept) + "\n")
with open(".build-extra.json", "w", encoding="utf-8") as f:
    import json; json.dump({"add": add, "rm": rm}, f)
if add or rm:
    print("    追加: %s" % (" ".join(add) or "(无)"))
    print("    移除: %s" % (" ".join(rm) or "(无)"))
PY

make defconfig

if [ "$DO_MENUCONFIG" = "1" ]; then
    make menuconfig
fi

# make defconfig 遇到源码树里不存在的符号会静默删行、不报任何错。漏掉这次核对，
# 就要等一两小时编完、发现产物文件名不对才知道选错了变体或写错了包名。
grep -q "^CONFIG_TARGET_airoha_${DEVICE_SUBTARGET}_DEVICE_${DEVICE_SYMBOL}=y" .config \
    || die "defconfig 后设备符号丢失，$DEVICE_SYMBOL 在分支 $BRANCH 中可能不存在"
info "已选定设备: $DEVICE_SYMBOL"
stage_done "配置"

python3 - <<'PY'
import json, os, re, sys
if not os.path.exists(".build-extra.json"):
    sys.exit(0)
want = json.load(open(".build-extra.json"))
os.remove(".build-extra.json")
cfg = open(".config", encoding="utf-8").read()
miss = []
for n in want["add"]:
    if not re.search(r"^CONFIG_PACKAGE_%s=[ym]$" % re.escape(n), cfg, re.M):
        miss.append(n)
for n in want["rm"]:
    if re.search(r"^CONFIG_PACKAGE_%s=[ym]$" % re.escape(n), cfg, re.M):
        miss.append("-" + n)
if miss:
    sys.exit("附加软件包未生效: %s\n包名可能拼错，或该分支没有这个包（defconfig 会静默丢弃）" % " ".join(miss))
PY

if [ "$CONFIG_ONLY" = "1" ]; then
    info "已生成 $SRC_DIR/.config（--config-only，不编译）"
    report_time
    exit 0
fi

# ---------------------------------------------------------------- 编译

if [ "$DO_CLEAN" = "1" ]; then
    info "make clean（保留工具链）"
    make clean
fi

info "下载软件包源码"
make download -j8
find dl -size -1024c -delete 2>/dev/null || true   # 清掉下载失败的残缺文件
stage_done "下载"

info "开始编译（-j$JOBS，首次约 1~2 小时）"
# 编译前把这次的输入摊开：日志翻回来时能一眼确认编的是哪份代码
echo "    分支   $BRANCH"
echo "    HEAD   $(git log -1 --date=short --format='%h %cd %s')"
echo "    设备   $DEVICE_SYMBOL"
echo "    配置   $CONFIG_FILE"
if ! make -j"$JOBS"; then
    warn "并行编译失败，改用单线程重跑以定位问题（只重编失败的包，不会从头来）"
    make -j1 V=s
fi
stage_done "编译"

# --------------------------------------------------------------- 产物

OUT="$SRC_DIR/bin/targets/airoha/$DEVICE_SUBTARGET"
info "编译完成"
echo
echo "固件目录: $OUT"
ls -lh "$OUT"/*.bin "$OUT"/*.itb "$OUT"/*.fip 2>/dev/null || ls -lh "$OUT"
echo
case "$DEVICE_SYMBOL" in
    nokia_xg-040g-md)
        echo "刷机用: factory-kernel.bin + factory-rootfs.bin" ;;
    nokia_xg-040g-md-ubi|nokia_xg-040g-mf-ubi)
        echo "刷机用: preloader.bin + bl31-uboot.fip（USB-TTL 刷入）、*-recovery.itb 救援镜像" ;;
    nokia_xg-040g-mf)
        echo "刷机用: factory-kernel.bin + factory-rootfs.bin" ;;
esac
echo "软件包: $SRC_DIR/bin/packages/"
echo "刷机方式详见 docs/variants.md"
report_time
