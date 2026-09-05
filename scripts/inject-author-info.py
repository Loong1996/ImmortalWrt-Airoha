#!/usr/bin/env python3
"""在默认 SSH banner 与 LuCI 概览「固件版本」后面追加作者信息。

全量编译不读 make FILES=（那是 ImageBuilder 的接口，还会和 kmod 的 FILES
变量撞名）。这里直接改 immortalwrt 源码树里的模板：banner 仍走 %D %V %C
替换。

LuCI 概览的「固件版本」= release.description + ' / ' + luciversion。
description 来自 ubus system.board，而 procd 读的是 /usr/lib/os-release 的
OPENWRT_RELEASE（procd system.c 把这个键改名成 description），**不是**
/etc/openwrt_release 的 DISTRIB_DESCRIPTION。后者没有任何 LuCI 路径会读，
这里一并追加只是为了两个文件口径一致（用户 cat 出来不会对不上）。
base-files 打包时从 package/base-files/files/ 现拷现替换，和 banner 同一条路。

不要改 luci-mod-status 的 10_system.js：那份源码会在编包时 minify 进
build_dir，工具链缓存命中后不会重编，补丁进不了固件。曾经这么干过，见下面
strip_legacy_luci()。

幂等：已含仓库 URL 则跳过。feeds 更新 / git reset 之后再跑一次即可。
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

# LuCI 固件版本本来就用 / 分隔，追加时带斜杠；SSH banner 是新起一行，不要斜杠。
BANNER_LINE = " Loong · https://github.com/Loong1996/ImmortalWrt-Airoha"
RELEASE_SUFFIX = " / Loong · https://github.com/Loong1996/ImmortalWrt-Airoha"
# 前缀兼容旧仓库名：已经注入过旧链接的源码树也能认出来，不会写第二行
MARKER = "Loong · https://github.com/Loong1996/ImmortalWrt-"

# 2026-08-31 之前的版本改的是 10_system.js，把后缀拼在 (luciversion || '') 外面。
# 那次改动落在 feeds 源码树里，后来只是让脚本不再去改，没有撤回已经改进去的行——
# 源码树一旦被复用（本地 --no-update、或 feeds update 拉不动已修改的文件），
# 这一行就一直在，导致管理页上作者信息出现两次：一次来自 description，一次
# 来自这里。表现是拔掉网线后两个 ubus 都失败，那一行仍剩「LuCI 未知版本 / 作者」。
LEGACY_LUCI_OLD = "(luciversion || '')"
LEGACY_LUCI_NEW = "(luciversion || '') + '%s'" % RELEASE_SUFFIX

# 编译产物里的 10_system.js 已被 minify，格式和源码不同，不去动它；
# 改完源码后直接删掉这个包的产物，逼它重编重打包。
_SKIP_DIR = {"build_dir", "staging_dir", "staging_dir_host", "tmp", "bin", "dl"}


def die(msg: str) -> None:
    print("错误: %s" % msg, file=sys.stderr)
    sys.exit(1)


def append_banner(root: Path) -> None:
    path = root / "package/base-files/files/etc/banner"
    if not path.is_file():
        die("未找到 %s（不是 OpenWrt 源码树？）" % path)
    lines = path.read_text(encoding="utf-8").splitlines()
    found = changed = False
    for i, ln in enumerate(lines):
        if MARKER not in ln:
            continue
        found = True
        if ln != BANNER_LINE:
            lines[i] = BANNER_LINE
            changed = True
        break
    if not found:
        lines.append(BANNER_LINE)
        changed = True
    if not changed:
        print("    SSH banner 已含作者信息，跳过")
        return
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("    已写入 SSH banner: %s" % path)


def append_quoted_field(path: Path, key: str, label: str) -> None:
    """在 KEY='value' / KEY="value" 的收尾引号前追加 RELEASE_SUFFIX。"""
    if not path.is_file():
        die("未找到 %s" % path)
    lines = path.read_text(encoding="utf-8").splitlines()
    hits = [i for i, ln in enumerate(lines) if ln.startswith(key + "=")]
    if len(hits) != 1:
        die("%s 里 %s 出现 %d 次，期望 1 次" % (path, key, len(hits)))
    i = hits[0]
    line = lines[i]
    if MARKER in line:
        print("    %s 已含作者信息，跳过: %s" % (label, path))
        return
    prefix_sq = key + "='"
    prefix_dq = key + '="'
    if line.startswith(prefix_sq) and line.endswith("'") and len(line) > len(prefix_sq):
        lines[i] = line[:-1] + RELEASE_SUFFIX + "'"
    elif line.startswith(prefix_dq) and line.endswith('"') and len(line) > len(prefix_dq):
        lines[i] = line[:-1] + RELEASE_SUFFIX + '"'
    else:
        die("%s 的 %s 行格式已变，拒绝盲改:\n%s" % (path, key, line))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("    已追加 %s: %s" % (label, path))


def patch_release(root: Path) -> None:
    files = root / "package/base-files/files"
    append_quoted_field(
        files / "etc/openwrt_release",
        "DISTRIB_DESCRIPTION",
        "openwrt_release DISTRIB_DESCRIPTION",
    )
    os_release = files / "usr/lib/os-release"
    append_quoted_field(
        os_release,
        "OPENWRT_RELEASE",
        "os-release OPENWRT_RELEASE",
    )


def _drop_luci_mod_status_artifacts(root: Path) -> None:
    """删掉 luci-mod-status 的编译产物。

    luci.mk 的 Package/install 是从 ${CURDIR}/htdocs 现拷的，但拷进 ipk 之后
    ipk 会被缓存，改回源码并不会让它重新打包。所以撤销时必须连产物一起删。
    只影响这一个包，最坏结果是多编几秒。
    """
    for pat in ("build_dir/*/luci-mod-status*", "bin/packages/*/*/luci-mod-status*"):
        for p in root.glob(pat):
            if p.is_dir():
                shutil.rmtree(p, ignore_errors=True)
            else:
                p.unlink(missing_ok=True)
            print("    已删除产物: %s" % p.relative_to(root))


def strip_legacy_luci(root: Path) -> None:
    """撤销旧版本对 10_system.js 的改动，让残留的源码树自愈。"""
    changed = 0
    seen: set[Path] = set()
    for path in root.glob("**/luci-mod-status/**/view/status/include/10_system.js"):
        if any(part in _SKIP_DIR for part in path.relative_to(root).parts):
            continue
        real = path.resolve()
        if real in seen:
            continue
        seen.add(real)

        text = path.read_text(encoding="utf-8")
        if LEGACY_LUCI_NEW not in text:
            continue
        path.write_text(text.replace(LEGACY_LUCI_NEW, LEGACY_LUCI_OLD), encoding="utf-8")
        print("    已撤销旧版 LuCI 改动: %s" % path)
        changed += 1

    if changed:
        _drop_luci_mod_status_artifacts(root)


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if not (root / "rules.mk").is_file():
        die("%s 不像 OpenWrt 源码树（缺 rules.mk）" % root)
    print("写入作者信息 → %s" % root)
    append_banner(root)
    patch_release(root)
    strip_legacy_luci(root)


if __name__ == "__main__":
    main()
