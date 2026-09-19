# ImmortalWrt-Airoha

给 Airoha 方案光猫编译的 ImmortalWrt 固件，配一个能用浏览器刷机、救砖的 U-Boot（网页 U-Boot）。

**[下载固件](https://github.com/Loong1996/ImmortalWrt-Airoha/releases)** · **[网页 U-Boot 指南](https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html)** · **[工具入口](https://loong1996.github.io/ImmortalWrt-Airoha/)**（选包 / 教程）· QQ 群 **1092754041**

☕ 业余时间维护，全部开源、不收费。觉得有用，**点个 Star** 就是最好的支持；也可以请作者喝杯咖啡：

<img src="guide/img/reward.jpg" width="180" alt="Loong 的赞赏码">

![网页 U-Boot](img/web-uboot.png)

![LuCI 概览](img/immortalwrt.png)

## 支持机型

| 机型 | SoC | 下载时选 | 状态 |
| --- | --- | --- | --- |
| Nokia XG-040G-MD | AN7581 | `XG-040G-MD` | 实机验证 |
| Nokia XG-040G-MF | AN7583 | `XG-040G-MF` | 实机验证 |
| Nokia XG-140G-MD | AN7581 | `XG-040G-MD` | 实测可用 |
| Nokia XG-040G-TF | AN7581 | `XG-040G-TF` | 待实机验证（芯片有安全启动，不能用 MD 的引导文件） |
| ZNXT ZN515XG-D | AN7581 | `XG-040G-MD` | 实测可用 |

其他 AN7581 参考设计的机器大概率也能直接用 MD 固件，试过的请到 Issues 或 QQ 群反馈。

## 刷机之前

> [!WARNING]
> **准备好 USB-TTL 串口，随时准备救砖。** 刷之前务必做整片 flash 备份：`ri`（MAC、序列号）和 `bosa`（光模块校准）每台机器独有，丢了没有地方找回。

- [获取超级密码](https://www.right.com.cn/FORUM/thread-8440823-1-1.html)
- [拆机、刷机、配置、原厂分区备份教程](https://www.right.com.cn/forum/thread-8467912-1-1.html)
- [原厂备份与刷回原厂](docs/backup-and-restore.md)

## 选哪个变体

固件分两种分区布局，Release 标题里带着，例如 `XG-040G-MD-ubi-auto-20260906-58`。

| 变体 | 引导程序 | rootfs 空间 | 能回原厂 |
| --- | --- | --- | --- |
| **`ubi`（推荐）** | 网页 U-Boot，浏览器里刷机、救砖 | **255.875 MB** | 有整片备份时，网页里整片写回 |
| `stock` | 原厂引导，不动 | 129 MB | 能 |

分区表与刷机方式见[设备变体](docs/variants.md)。

## 刷机（`ubi`）

| 情况 | 怎么做 |
| --- | --- |
| 第一次刷 | 接一次串口传两个引导文件，之后全在网页里：[指南第 2 章](https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html#serial) |
| 系统能进，想升级 | 在系统里用 `sysupgrade`，保留配置 |
| 刷坏了 / 起不来 | 上电 1~2 秒后按住 reset，面板灯呈流水效果就进了恢复页，浏览器重刷：[指南第 3 章](https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html#enter) |
| 想回原厂 | 恢复页「刷回原厂」写回整片备份：[指南 3.6](https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html#restore) |

## 自己编译

本仓库只放编译配置、自带软件包、网页与 CI；固件源码在 [Loong1996/immortalwrt](https://github.com/Loong1996/immortalwrt) 的 `master-airoha` 分支（immortalwrt `master`，内核 6.18），机型支持和 U-Boot 补丁都在源码树里。

1. Fork 本仓库，在 Actions 页面启用 workflow。
2. `Actions → ImmortalWrt-Airoha → Run workflow`，选机型（`xg-040g-md` / `xg-040g-mf` / `xg-040g-tf` / `zn504xg-d`，`all` 并行编全部机型）和变体。内存容量默认[自适应](docs/variants.md#内存容量)，不用管。
3. 约 1~2 小时后出固件，去向由「发布方式」决定：
   - `auto`（默认）：main 上编 `master-airoha` 发到本仓库的 Releases；别的分支只传 Artifact。
   - `prerelease`：发 Release 但标 pre-release，不盖 Latest，也不进教程的下载列表。
   - `artifact`：只传 Artifact，适合客户定制。在该次运行页面底部下载（需登录 GitHub），保留 30 天。

有闲置的 Linux 机器，也可以本地一条命令 `./build.sh` 编，参数和 `Run workflow` 一一对应：见[本地编译](docs/local-build.md)。

## 文档

**使用**

| 文档 | 内容 |
| --- | --- |
| [U-Boot 网页救砖](docs/uboot-http-recovery.md) | 网页 U-Boot 的技术细节：页面结构、首次迁移、灯语、补丁清单 |
| [设备变体](docs/variants.md) | `ubi` 与 `stock` 的分区布局、引导差异、内存容量自适应 |
| [自定义软件包](docs/packages.md) | 内置了哪些包、选包页怎么用、刷完还能不能补装 |
| [LED 行为](docs/leds.md) | 面板灯与网口灯的含义，怎么改 |
| [原厂备份与刷回原厂](docs/backup-and-restore.md) | 原厂分区表、整片备份步骤、回原厂的几条路 |
| [已知问题：USB2 口带不动 USB3 U 盘](docs/usb2-port-issue.md) | 已排除的假设、寄存器数据、下次从哪接手 |
| [已知问题：串口迁移后软件重启卡在 Press x](docs/warm-reset-press-x.md) | strap 上电锁存的根因、实测数据、试过的路线、待做的提示 |

**开发与维护**

| 文档 | 内容 |
| --- | --- |
| [本地编译](docs/local-build.md) | 机器要求、完整步骤、增量重编、拉回产物 |
| [源码分支与跟进上游](docs/branches.md) | 只维护一条线；rebase 流程 |
| [跟进上游：漂移检查](docs/upstream-drift.md) | rebase 看不见的上游变动怎么抓 |
| [master-airoha 迁移说明](docs/master-airoha-migration.md) | 这条线是怎么整理出来的，历史参考 |

## 致谢与来源

- 编译脚本最初基于 [dalutou/OpenWrt-for-XG-040G-MD](https://github.com/dalutou/OpenWrt-for-XG-040G-MD)，25.12 线来自 [fzs209](https://github.com/fzs209) 的实测快照，之后持续改写，与两者已相差很大。
- 前身是 [ImmortalWrt-XG-040G-MD](https://github.com/Loong1996/ImmortalWrt-XG-040G-MD)：完整提交历史、25.12 线与 tcboot 变体都留在那边，不再更新。本仓库从一个提交起步，许可证仍是 MIT，保留原作者的版权声明。
- 固件源码 [Loong1996/immortalwrt](https://github.com/Loong1996/immortalwrt) fork 自官方 [immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt)，机型支持叠在上游 master 之上。
- 闪存：内核由上游 6.18 支持 SkyHigh S35ML02G300 与复旦微 FM25G01B / FM25G02B；官方 UBI U-Boot（2026.07）只带 SkyHigh，复旦颗粒的 `120`、`121` 两个补丁在源码树里。
- NPU 固件加载报错（`Direct firmware load for airoha/en7581_npu_rv32.bin failed with error -2`）按 [这篇分析](https://github.com/xiangtailiang/OpenWrt-for-XG-040G-MD/blob/main/docs/npu-firmware-load.md) 修复。
