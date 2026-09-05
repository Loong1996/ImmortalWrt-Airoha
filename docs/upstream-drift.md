# 跟进上游：漂移检查怎么用

> 适用于 `master-airoha` 线——现在唯一维护的线，见 [源码分支](branches.md)。

## 先讲清楚为什么需要这一套

直觉上「跟上游」就是 `git rebase`，冲突了就解决，不冲突就没事。**这个直觉是错的。**

`git rebase` 只在一种情况下说话：**上游改了某个文件，而我也改了同一个文件。**

但本项目九成内容是往树里**新增**文件——uboot 补丁、内核补丁、dts、preinit 钩子。
这些文件上游根本没有，永远不会冲突。而它们**依赖**的那些上游文件，我们一行没碰，
所以上游怎么改，rebase 都不会吭声。

这不是假想。`docs/branches.md` 里记着 25.12 线那次：rebase **没有报任何冲突**，
固件编译成功，刷进去完全没网络，日志里一个报错都没有。根因是上游把 PCS 的属性名
从 `pcs = <...>` 改成了 `pcs-handle`，而项目自带的旧 PCS 驱动还在用旧名字——三者
错配，`airoha_eth` 探测失败，`-ENODEV` 走的是 `pr_debug`，什么都看不到。

还有一个正在发生的例子：本项目的 `patches-6.18/805` 住在 airoha 补丁目录里，而
上游在 8 月底把 `801-01`、`801-02`、`802-01`、`802-02`、`802-03`、`804`（AS21xxx
那一组）**整组搬走了**。rebase 会默默把它们从你的树里删掉，一个字都不说。

所以这套检查补的就是 rebase 看不见的那部分。

## 四项检查各管什么

| 检查 | 抓什么 | 何时跑 | 要不要编译 |
| --- | --- | --- | --- |
| `watch` | 上游改动了「我依赖但没修改」的路径 | 每周自动 + rebase 前 | 否 |
| `versions` | U-Boot / 内核大版本变了 | 同上 | 否（要源码树） |
| `refresh` | 补丁打上去有 offset / fuzz | CI 里默认**关闭**，需手动勾 | 是 |
| `dtb` | 最终设备树与基准逐字不符 | 每次 CI 编译 | 是 |

`refresh` 那一项值得多说一句：OpenWrt 打包内补丁走 `scripts/patch-kernel.sh` →
`patch -f -p1`。**整块 reject 才会让构建失败；offset 和 fuzz ≤ 2 是静默成功的。**
也就是说补丁可能已经打到错的地方去了，而构建一切正常。`quilt refresh` 会把补丁
按实际落位重写，于是「偏了」变成一个看得见的 diff。

但 refresh 还会顺手做一件与落位无关的事：**把 git 风格的补丁规范化成 quilt 风格**。
`uboot-airoha/patches/100~106` 是从 mainline 直接取来的，带 `diff --git` / `index`
头和 `-- \n<git 版本>` 邮件签名尾，refresh 一律剥掉 —— 位置完全正确时也照剥。
所以脚本会把改动分成两类：

| 分类 | 判据 | 结论 |
| --- | --- | --- |
| **真偏移** | 剥掉那些头尾之后仍有差异（`@@` 行号或内容行变了） | ✗ 报失败，打印 diff |
| **格式规范化** | 剥掉之后逐字相同 | · 只提一行，不算失败 |

2026-09-04 第 53 次编译报的那次 warning 就是后者：7 个补丁全被改写，但**零个 `@@`
头变化、零行内容变化**，纯粹是剥头尾。本项目自己的补丁本来就是 quilt 风格、没有
这些头，所以这个分流不会掩盖它们的真实偏移。

跑完之后源码树里那些补丁文件是被改过的，**别顺手 `git add`** —— 提交进去等于把
上游补丁的格式改掉，下次跟上游 rebase 会平白多出冲突。

`dtb` 那一项是唯一能抓 25.12 那类事故的：把最终产物摊平了看，属性改名、include
结构变化、被 `/delete-property/` 掉的东西，全在这一层现形。

`refresh` 在 CI 里默认不跑，因为它必须先 `clean` 再用 `QUILT=1` 重新 prepare 内核和
uboot-airoha（`quilt-check` 要求源码目录是用 quilt 解包的，而正常编译不走 quilt），
这会拖长本次编译，也让 `cachewrtbuild` 缓存下来的已 prepare 状态失效。需要时在
`Run workflow` 里勾上「补丁偏移检查」，或者本地随时跑。

也因此它必须排在 `dtb` 之后 —— `target/linux/clean` 会把 `build_dir` 里的 dtb 删掉。

## 日常：每周报告

`.github/workflows/upstream-drift.yml` 每周一早上跑一次 `watch`，有变化就更新那个
带 `upstream-drift` 标签的常开 issue（只保留一个，不会每周刷新一条）。上游没动就
自动关掉。

**它不会自动改 `upstream.lock`。** 自动 bump 等于没有基线。

报告长这样：

```
上游漂移报告
============
  已验证基线 db5c5de56a4c  2026-08-28
  当前 tip   1aa8ac8d88df  2026-09-04
  相差       85 个提交

── common ── 6 处变化
    D	target/linux/airoha/patches-6.18/801-01-net-phy-add-PHY_DETACH_NO_HW_RESET-PHY-flag.patch
    ...
── nokia-xg-040g-md ── 1 处变化
    M	target/linux/airoha/image/an7581.mk
```

**读法**：`D`（删除）和 `R`（改名）最值得警惕——那是「我依赖的东西没了或搬走了」。
`M` 多数时候无关，比如上面那处 `an7581.mk` 只改了 `nokia_valyrian` 的包列表。

## 手工跑

```bash
# 不需要源码树，自己建一个 blob-less 的镜像缓存（几十兆）
./scripts/check-drift.sh watch

# 已经有源码树的话直接用它，更快
./scripts/check-drift.sh watch -o ../openwrt-master-airoha
./scripts/check-drift.sh versions -o ../openwrt-master-airoha

# 这两项要先编译过
./scripts/check-drift.sh refresh -o ../openwrt-master-airoha
./scripts/check-drift.sh dtb     -o ../openwrt-master-airoha
```

退出码：`0` 无漂移，`1` 有漂移，`2` 用法或环境错误。

## 跟进上游的完整流程

```bash
cd ../immortalwrt
git remote add upstream https://github.com/immortalwrt/immortalwrt.git   # 只需一次
git fetch upstream master
git checkout master-airoha
git rebase upstream/master
```

然后：

1. **rebase 报的冲突照常解决**——那是「上游改了 ∩ 我也改了」，只有 6 个文件会落在
   这一类（见 [源码分支](branches.md)）
2. **看这周的漂移报告**——那是 rebase 不会告诉你的部分，逐条判断有没有影响
3. **编译**，看 CI 的 `dtb` 警告；这一次值得把「补丁偏移检查」也勾上
4. **实机刷一遍**。前面三步只能保证「上游动了什么你都知道」，不能保证刷上去有网。
   这一步任何方案都省不掉
5. 都过了，再手工更新 `upstream.lock` 的 `UPSTREAM_COMMIT` 与 `UPSTREAM_DATE`，
   连同 `golden/` 里更新过的基准一起提交

**节奏建议：小步、定期。** 25.12 那次栽跟头，一半原因是一跳跨过了上游 13 个
airoha 重构补丁。每月一次、每次的漂移清单短到能读完，比半年一次强得多。

## 维护盯梢清单

`watch/*.list` 一行一条路径（文件或目录），`#` 开头是注释。按 topic 分文件，
与源码提交里的 `Topic:` trailer 对应：

- `watch/common.list` —— 与机型无关的依赖（U-Boot 补丁栈、内核补丁目录、
  generic 的 config 与 backport）
- `watch/nokia-xg-040g-md.list` —— 本机型的依赖（SoC 级 dtsi、分区表 dtsi、
  镜像定义、`platform.sh`）

**什么时候该往里加**：每当你新写一个补丁或文件，问一句「它依赖了哪些我没改的上游
东西？」——补丁打在哪个文件上、dts include 了什么、脚本读了哪个 sysfs/debugfs
路径、补丁号段的邻居是谁。加进去的成本是一行，漏掉的成本是一次刷完没网。

加第二款机型时，新建一个 `watch/<机型>.list`。

## golden 基准

`golden/*.dts` 是编出来的 dtb 反编译（`dtc -I dtb -O dts -s`）后的样子。

首次运行时 `golden/` 是空的，`dtb` 检查不会报错，而是把当前产物写进去让你 review。
**基准必须来自一次实机验证过的编译**——脚本没法凭空造一个"正确"的设备树。CI 会把
新写入的基准作为构建产物上传，确认无误后提交进仓库。

之后每次编译都跟它逐字比。基准变化本身不一定是坏事（你自己改了 dts 也会变），
但**每一次变化都应该是你能解释的**。解释不了的那次，就是要查的那次。
