# 源码分支与跟进上游

只维护一条线：**`master-airoha`**。

| 分支 | 源码基线 | 设备定义 | 内核 | 配置文件 |
| --- | --- | --- | --- | --- |
| `master-airoha` | immortalwrt `master`，跟进上游 | 上游原生 `nokia_xg-040g-md-ubi` / `nokia_xg-040g-md`，本项目加 `nokia_xg-040g-mf-ubi` / `nokia_xg-040g-mf` | 6.18 | `config/xg-040g-md-master.config` / `config/xg-040g-mf-master.config` |

旧仓库 [ImmortalWrt-XG-040G-MD](https://github.com/Loong1996/ImmortalWrt-XG-040G-MD) 里的 `master-XG-040G-MD`（同一基线的零散提交版）、`openwrt-25.12-XG-040G-MD`（fzs209 的固定快照，内核 6.12）与 `tcboot` 变体都不再维护；`master-airoha` 是从 `master-XG-040G-MD` 整理出来的，整理过程见 [master-airoha 迁移说明](master-airoha-migration.md)。

## 这条线上有什么

上游 master 已内核 6.18 且原生支持 XG-040G-MD，闪存、cpufreq、pcs-airoha 等补丁全部由上游承担。本项目在它之上叠的东西按主题分两组，每个提交都带 `Topic: common` / `Topic: nokia-xg-040g-md` 标记：

* **U-Boot**（`package/boot/uboot-airoha/`）：Airoha Web U-Boot 网页救砖（`202`）、DRAM 容量探测（`206` / `310`）、复旦颗粒（`120` / `121`）、菜单环境刷新（`210`）、两款机型各自的 defconfig 与 defenv（`95x` / `96x`）
* **内核与设备**：`luci-app-airoha-npu`（由本仓库 `packages/` 以 `src-link` feed 提供）、一行 `nf_conntrack_max`、XG-040G-MF 的 dts 与镜像定义、an7583 的散热配置

改动上游已有文件的只有这几个，也就是 rebase 会报冲突的全部范围：

```
package/kernel/linux/files/sysctl-nf-conntrack.conf
target/linux/airoha/an7581/base-files/etc/board.d/01_leds
target/linux/airoha/an7581/config-6.18
target/linux/airoha/an7583/config-6.18
target/linux/airoha/dts/an7581-nokia_xg-040g-md-common.dtsi
target/linux/airoha/dts/an7581-nokia_xg-040g-md-ubi.dts
target/linux/airoha/dts/an758x-nokia_xg-040g-common.dtsi
```

> ⚠️ **rebase 只覆盖上面这几个文件。** 其余都是纯新增，它们依赖的上游文件上游怎么改，rebase 都不会吭声——那部分交给[漂移检查](upstream-drift.md)。

## 怎么跟进上游

```bash
git clone https://github.com/Loong1996/immortalwrt.git -b master-airoha
cd immortalwrt
git remote add upstream https://github.com/immortalwrt/immortalwrt.git
git fetch upstream master
git rebase upstream/master
git push --force-with-lease
```

rebase 报的冲突照常解决；然后看这周的[漂移报告](upstream-drift.md)，逐条判断有没有影响；编译，看 CI 的 `dtb` 警告；实机刷一遍——前面三步只能保证「上游动了什么你都知道」，不能保证刷上去有网。都过了再更新 `upstream.lock`。

**节奏建议：小步、定期。** 旧的 25.12 线栽跟头，一半原因是一跳跨过了上游 13 个 airoha 重构补丁（PCS 属性从 `pcs = <...>` 改成 `pcs-handle`，dts 编得过、固件刷得进、开机没网、日志无声）。每月一次、每次的漂移清单短到能读完，比半年一次强得多。

远端被强推之后，`build.sh` 会自己判断本地有没有独有改动再决定是否重置，见[本地编译 → 拉取源码更新与强推](local-build.md#拉取源码更新与强推)。
