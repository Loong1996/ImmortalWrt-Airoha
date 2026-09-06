# `master-airoha` 迁移说明与验收清单

> 这份文档记录 2026-09-04 那次整理做了什么、为什么这么做，以及编译出来之后要验哪些东西。
> 写给两类读者：过一阵子回头看的自己，以及接手验收的下一个会话。
>
> **当前状态：验收通过。MD 于 2026-09-05、MF 于 2026-09-06 实机验证，master-airoha 已是主线。**

---

## 一、这次要解决什么

原本的分工是：`Loong1996/immortalwrt` 的 `master-XG-040G-MD` 分支放所有源码修改，
`Loong1996/ImmortalWrt-XG-040G-MD` 放编译配置与 CI。想改成「源码仓库尽量干净、修改
尽量集中在配置仓库」，同时要为**后续支持更多机型**做准备。

讨论后确认了两件事，它们决定了最终方案：

**① 多设备不需要多分支。** 一条分支可以同时承载所有机型，公共代码（U-Boot 网页救砖、
MAC 钩子、luci 包）只有一份，各机型只是多几个 `.dts` 和几行镜像定义。所以「怕重复」
这个顾虑本身不成立，不需要为它做仓库搬迁。

**② `git rebase` 的感知能力比想象中低得多。** 它只在「上游改了 ∩ 我也改了」时报冲突。
而本项目九成内容是往树里**新增**文件，它们**依赖**的上游文件我们一行没碰 —— 那些地方
上游怎么改，rebase 一概不报。

`docs/branches.md` 里记的 25.12 事故正是这一类：rebase **没有报任何冲突**，固件编译
成功，刷进去完全没网络，日志里一个报错都没有。

还有个正在发生的例子：本项目的 `patches-6.18/805` 住在 airoha 补丁目录里，上游在
8 月底把同目录的 `801-01`、`801-02`、`802-01`、`802-02`、`802-03`、`804` **整组搬走了**。
rebase 会默默把它们从树里删掉，一个字都不说。

**所以方案是：代码仍留在源码仓库（保留 rebase 的冲突检测），另外补一套漂移检查去覆盖
rebase 的盲区。** 没有做「把所有源码搬进配置仓库」那种大改 —— 那会带来永久性的摩擦
（每次改代码多一道导出手续、GitHub 上没法直接看整棵树），而收益的大头（防事故）靠
漂移检查就能拿到。那条路随时还能走，也随时能撤。

---

## 二、做了什么

### 源码仓库 `Loong1996/immortalwrt` · 分支 `master-airoha`

基线 `db5c5de5`（2026-08-28，与 `master-XG-040G-MD` 同一基线），9 个提交：

```
公共（将来别的 airoha 机型也能用）        Topic: common
  12f86c4  uboot-airoha: 增加 U-Boot 网页救砖 HTTP 服务器      (202)
  d47c106  uboot-airoha: an7581 探测真实内存容量                (206)
  d0df800  uboot-airoha: 支持复旦微 FM25G01B / FM25G02B 闪存    (120/121)
  9ab4183  kernel: nf_conntrack_max 提到 65535
  bbcba30  airoha: an7581 启用 cpufreq 散热设备

XG-040G-MD 专属                          Topic: nokia-xg-040g-md
  2bf45c5  airoha: XG-040G-MD 的 usable-memory-range 固定放到 2G
  4c9a5b0  airoha: XG-040G-MD ubi 变体改由 preinit 钩子读取原厂 MAC
  f3ca99f  airoha: XG-040G-MD 修好 lan1 口灯，面板灯一律不接管
  aa1bbaa  uboot-airoha: XG-040G-MD 接上网页救砖                (950~954)
```

每个提交都带 `Topic:` trailer，加第二款机型时公共部分不用复制第二份。
原来那 15 个提交的完整设计说明保留在 `master-XG-040G-MD` 分支里，新提交注明了出处。

除了重新分组，实质改动有三件：

**删除 `tcboot` 变体** —— dts、分区表 dtsi、镜像定义，以及为它写的 291 行
`patches-6.18/608`（tcboot 的 ATF 没实现 Airoha 的 AVS SIP 调用，靠它直接编程 ARMPLL
兜底）。理由：刷机早已不再维护，而 608 打在上游正在活跃改动的 `airoha-cpu-pmdomain`
上，是整棵树里维护成本最高的单项。

**`luci-app-airoha-npu` 出树** —— 移到配置仓库 `packages/`，`src-link` 挂成 feed。
顺带删掉 3 张约 3 MB 的 README 截图（Makefile 根本不安装它们）。

**复旦闪存补丁收编** —— `120`/`121` 原先放在配置仓库 `patch/uboot-airoha/`、编译时
`cp` 进源码树，现在是源码树里正常的补丁。

收缩效果：

| | `master-XG-040G-MD` | `master-airoha` |
| --- | --- | --- |
| 文件数 | 35 | **18** |
| 行数 | +4782 / -10 | **+2713 / -3** |
| 改动上游已有文件 | 10 个 | **6 个** |

删 tcboot 顺带回收了一笔额外的：`an7581.mk`、`target.mk`、`02_network`、
`airoha_an7581` **四个文件整个回到上游原样**。其中 `an7581.mk` 原本为了给 tcboot
剔除 `uboot-envtools`，往 evb、gemtek w1700k、nokia valyrian 这些跟本项目无关的机型
定义里各插了一行 —— 那正是每次跟上游都会撞车的地方。

**剩下这 6 个文件就是 rebase 会报冲突的全部范围：**

```
package/kernel/linux/files/sysctl-nf-conntrack.conf
target/linux/airoha/an7581/base-files/etc/board.d/01_leds
target/linux/airoha/an7581/config-6.18
target/linux/airoha/dts/an7581-nokia_xg-040g-md-common.dtsi
target/linux/airoha/dts/an7581-nokia_xg-040g-md-ubi.dts
target/linux/airoha/dts/an758x-nokia_xg-040g-common.dtsi
```

其余 12 个是纯新增文件，它们的依赖漂移交给下面那套检查。

### 配置仓库 `Loong1996/ImmortalWrt-XG-040G-MD` · 分支 `master-airoha`

6 个提交：

```
926fdac  luci-app-airoha-npu 出树，改由本仓库 packages/ 提供
f5caf3c  新增上游漂移检查
0c6f89a  build.sh 与 CI 接入 master-airoha、本地 feed 与漂移检查
1fe0726  文档：master-airoha 与 tcboot 的移除
3d22823  补丁偏移检查改为按需开启，并修正 refresh 的调用方式
5b17460  配置：更正 uboot-envtools 那段注释
```

新增的东西：

| 路径 | 作用 |
| --- | --- |
| `packages/luci-app-airoha-npu/` | 出树的 luci 包，`src-link` 挂成名为 `loong` 的 feed |
| `packages/README.md` | 来源说明（重要，见下） |
| `upstream.lock` | 记录当前基线是哪个上游提交、预期的 U-Boot 与内核版本 |
| `watch/common.list`<br>`watch/nokia-xg-040g-md.list` | 盯梢清单：本项目**依赖但没有修改**的上游路径 |
| `scripts/check-drift.sh` | 四项漂移检查 |
| `.github/workflows/upstream-drift.yml` | 每周一自动跑 `watch`，更新一个常开 issue |
| `docs/upstream-drift.md` | 这套东西怎么用、盯梢清单怎么维护 |
| `.gitattributes` | `packages/` 与 `scripts/` 强制 LF（见下） |

四项检查：

| 检查 | 抓什么 | 何时跑 | 要编译 |
| --- | --- | --- | --- |
| `watch` | 上游动了「我依赖但没改」的路径 | 每周自动 + rebase 前 | 否 |
| `versions` | U-Boot / 内核大版本变了 | 同上 | 否 |
| `refresh` | 补丁打上去有 offset / fuzz | CI 里默认关，需手动勾 | 是 |
| `dtb` | 最终设备树与基准逐字不符 | 每次 CI 编译 | 是 |

`watch` 已实测跑通，当场抓到上面说的那 6 个补丁被搬走。

---

## 三、几个关键决策，以及它们的代价

### 删 tcboot 的代价：25.12 用户失去平滑升级路径

`an7581.mk` 里 tcboot 那段有一行 `SUPPORTED_DEVICES += bell,xg-040g-md`，它让 25.12 线
的机器能直接 `sysupgrade` 到 master 线。**删掉 tcboot 之后这条路没了。**

还需要的话，用 `master-XG-040G-MD` 的 tcboot 固件当跳板 —— 那条分支没动，照样编得出来。

顺带更正一处旧文档说法：`variants.md` 曾把「95°C 被动降频档位失效」列为 tcboot 的缺陷，
但 `cpu-thermal` 那个 trip 是 `type = "hot"`，而 `step_wise` governor 明确跳过 HOT 与
CRITICAL —— **该档位本来就只发通知、不降频**。所以删 608 并没有额外损失降频保护。
本板无散热器，烤机实测 59°C。

### npu 包为什么不用 submodule

原计划是改成 submodule 指向原作者 [rchen14b/luci-app-airoha-npu](https://github.com/rchen14b/luci-app-airoha-npu)。
查下来不行：

| | 本项目这份 | 原作者 `main` |
| --- | --- | --- |
| `PKG_VERSION` | **1.0.3** | 1.0.1 |
| 最后提交 | — | 2026-04-19 |
| Release | — | **一个都没有**（API 返回空数组） |
| VLAN / PPPoE 卸载接口 | 有 | **无** |

1.0.3 来自 fzs209 的 25.12 快照（fork 时就带着），比原作者仓库新，多出
`getVlanOffload` / `getPPPoEOffload` / `setVlanOffload` / `setPPPoEOffload`，
差异规模 `status.js` 52 行、rpcd 脚本 72 行、acl 4 行。**挂 submodule 会降级到 1.0.1
并丢掉这些功能。** 所以改成配置仓库里的本地 feed，来源记在 `packages/README.md`。

### 120/121 为什么必须收编 —— 一个静默失效的坑

`build.sh:275` 和 CI 里拷贝这两个补丁的判断条件是：

```bash
case "$BRANCH" in
    master-XG-040G-MD*|xpon-test)
```

**新分支名 `master-airoha` 匹配不上这个前缀。** 如果不收编进源码树，编译会照常成功，
只是复旦颗粒的机器引导不了 —— 又一个「编得过、刷不了」。已收编，两处都留了注释。

### `.gitattributes` 为什么要加

`packages/luci-app-airoha-npu/root/usr/libexec/rpcd/luci.airoha_npu` 是要装进路由器的
shell 脚本。仓库里存的一直是 LF，CI 在 Linux 上检出也是 LF，所以 CI 编的固件没问题。
但 Windows 上 `core.autocrlf=true` 检出会拿到 CRLF，而 `src-link` 指向的正是**工作区
那份** —— 本地编译就会把 CRLF 的脚本装进固件，在路由器上跑不起来。

---

## 四、与 `master-XG-040G-MD` 的 ubi 变体比对

已做源码级比对。**不是 bit-identical，但功能应当一致。**

| 差异 | 影响 ubi 产物？ | 说明 |
| --- | --- | --- |
| tcboot 的 dts / parts dtsi 删除 | 否 | 设备未选中，不参与编译 |
| `an7581.mk` 的 tcboot Device 块删除 | 否 | 同上 |
| **`608` 内核补丁删除** | **是 · 内核二进制变了** | 见下 |
| `uboot-envtools` 挪位还原 | 否 · **包集合相同** | 原先从 `DEVICE_PACKAGES` 拿，现在从 `DEFAULT_PACKAGES` 拿 |
| `01_leds` 少一行 tcboot case | 文件内容变，**功能相同** | ubi 仍匹配，lan1~lan4 的 LED 配置一字未动 |
| `02_network` 少一行 | 同上 | ubi 的网口划分不变 |
| `airoha_an7581` 少 3 行 env 条目 | 同上 | ubi 的条目不变 |
| MAC 钩子少一个板名 + 注释 | 同上 | `nokia,xg-040g-md-ubi` 分支逻辑一致 |
| `ubi.dts` 改 1 行注释 | 否 | 注释不进 dtb |
| npu 包出树 | 否 · **8 个文件逐字节一致** | 只是构建路径从 `package/` 变成 `package/feeds/loong/` |
| `120`/`121` 收编 | 否 · **逐字节一致** | 与配置仓库 `patch/uboot-airoha/` 那两份完全相同 |

**唯一实质差异是 608。** 它只改 `drivers/pmdomain/mediatek/airoha-cpu-pmdomain.c`
一个文件，而回退逻辑是完全门控的：

```c
if (airoha_cpu_smc_available()) {
        priv->use_smc = true;
} else {
        priv->pll_base = devm_platform_ioremap_resource(pdev, 0);
        ...
}
```

ubi 用官方 ATF，实现了 AVS SIP 调用（`0x82000301`），走 `use_smc = true` 那一支，
`else` 里的直接编程 PLL 一次都不会执行；而且它需要的两段 `reg` 本来只加在 tcboot 的
dts 里，ubi 的 dts 根本没有。

**结论：内核二进制不同（少了 291 行代码），ubi 上运行时行为不变。**

---

## 五、验收清单

> **进度：阶段 1~3 于第 53 次编译（2026-09-04）通过，阶段 4 实机验证已完成——MD 2026-09-05（U-Boot 0.2.0，首刷、断电重启、写回 ri 三项通过），MF 2026-09-06。**
> 详见下面的「第 53 次编译的结果」。

### 第 53 次编译的结果

参数：分支 `master-airoha` · 变体 `ubi` · 内存 `auto` · 勾了补丁偏移检查。耗时 1h36m，编译成功。

阶段 2、3 逐条核过，全过：

| 项 | 实际 |
| --- | --- |
| `src-link loong` | `Updating feed 'loong' from .../packages` → `Installing package 'luci-app-airoha-npu' from loong` |
| 设备符号 | `设备: nokia_xg-040g-md-ubi`，defconfig 后仍在 |
| `CONFIG_PACKAGE_luci-app-airoha-npu` | `=y`，无 `option missing` |
| `Patch U-Boot SPI-NAND` | 步骤未出现（条件跳过）—— `120`/`121` 收编生效 |
| `.manifest` | `uboot-envtools - 2026.07-r1`、`luci-app-airoha-npu - 1.0.3-r1` |
| `build.config` | 只有 `..._DEVICE_nokia_xg-040g-md-ubi=y`，无 tcboot |
| `golden/*.dts` | 3 个首次生成；`usable-memory-range = <0x0 0x80200000 0x0 0x7fe00000>`、`pcs-handle` 在位、lan1 走 `openwrt,netdev-name`、lan2~4 有 label |

**最硬的一条证据 —— manifest 与老分支比对**（53 号 vs 52 号 `master-XG-040G-MD`+ubi）：

```
291 行 vs 291 行，唯一差异：
< base-files - 1940~1a9a9615df
> base-files - 1940~aa1bbaafa9
```

只是分支 HEAD 的 hash 标记。**四节结尾「理论上只有内核 hash 会不同」那句要更正**：
`kernel - 6.18.44~b3bdd222…-r1` 两边**完全相同**，因为那个 `~hash` 是上游内核 tarball
的 hash，不反映本地补丁集。所以 manifest **证明不了** 608 移除后的内核差异 —— 那一项
只能靠阶段 4 的 cpufreq 实测。

发现并已修掉两个问题：

**① workflow 漏设 `FLAVOR` / `VARIANT_LABEL`（已修）**

新增的 `master-airoha)` case 只设了 `CONFIG_FILE` 和 `DEVICE_SYMBOL`，漏了
`master-XG-040G-MD*)` 那边有的另外两行。后果三处：

| 后果 | 第 53 次的实际表现 |
| --- | --- |
| tag 丢变体段（`${FLAVOR:+-$FLAVOR}`） | `XG-040G-MD-auto-20260904-53`，少了 `ubi`。以后编 stock，两个变体的 tag 只差 run 号 |
| Release 正文 | 标题「内存 自适应 · **空** 变体」、「🧩 编译变体：`****`」 |
| **转正后救砖页列不出固件** | 见下 |

第三条是本文档原先漏掉的一层：阶段 5 只说要改 ③ 的分支正则，但 ② 的
`/ubi-auto/i.test(rel.tag_name)` 对这个 tag 也匹配不上。转正后 ① 失效、③ 就算改对，
② 仍然拦住 —— 页面不报错、不空白，一条固件都列不出来。修了 `FLAVOR` 这条才消失。

**注意：第 53 次的产物 tag 仍是错的**，要拿到正确 tag 得重编一次。但**固件本身可以直接刷**
—— `FLAVOR`/`VARIANT_LABEL` 只参与 tag 拼接和 Release 正文渲染，不进 `.config`、
不进任何编译步骤。

**② `Patch Fuzz Check` 的 warning 是误报（已修）**

完整 `refresh.log`（drift-53 产物，7291 行）逐行核过：被改写的只有 7 个补丁，全是上游
自带的 `uboot-airoha/patches/100~106`，改动只有 `diff --git` 14 行、`index` 13 行、
`new file mode` 6 行、`-- \n2.53.0` 尾 6 行 —— **零个 `@@` hunk 头变化，零行内容变化**。
本项目自己的补丁（`120`/`121`/`202`/`206`/`805`/`950~954`）一个都没进这份 diff。

`scripts/check-drift.sh` 已改成剥掉这些头尾再比一次，真偏移与格式规范化分开报。
详见 `docs/upstream-drift.md`。

顺带修的：Release 正文里「`tcboot` / `ubi` 变体都会做这个探测」在这条线上已经没有
tcboot 了，改成「除 `stock` 外的变体」，两条线共用不会说错。

### 阶段 1 · 触发编译

Actions 里有个**必须先做**的动作：

1. Actions → 选编译 workflow
2. **`Use workflow from` 先切到 `master-airoha`** —— `master-airoha` 这个分支选项写在
   workflow 文件里，`main` 上那份还没有它，不切就看不到
3. 参数：

| 输入 | 填 |
| --- | --- |
| 选择编译分支 | `master-airoha` |
| 设备变体 | `ubi` |
| 内存上限 | `auto` |
| 补丁偏移检查 | 第一次建议勾上（这次本来就没缓存，等于免费） |

### 阶段 2 · 看 CI 日志

- [ ] **`Install Feeds` 里出现 `src-link loong`** —— feed 挂上了
- [ ] **`Generate Variables` 里 `设备: nokia_xg-040g-md-ubi`** —— 设备符号对
- [ ] **不报 `设备符号写入失败` / `defconfig 后设备符号丢失`**
- [ ] **`Patch U-Boot SPI-NAND` 这步被跳过** —— 正常，补丁已在源码树里
- [ ] **不出现 `WARNING: option missing!`**（`CONFIG_PACKAGE_luci-app-airoha-npu` 那处）
- [ ] **勾了偏移检查的话，看 `Patch Fuzz Check` 有没有 warning** ——
      有 warning 说明某个补丁打上去时位置偏了，要看是哪个。
      注意区分「真偏移」和「格式规范化」，脚本现在会分开列，详见
      `docs/upstream-drift.md`

### 阶段 3 · 看产物（刷机前）

Release 会标成 **pre-release**，这是故意的（`master-airoha` 不在
`IS_PRERELEASE=false` 白名单里）。选包页也会跳过更新，同理。

- [ ] **下载 `drift-<run_number>` 构建产物**，里面有 `dtb.log` 和首次生成的
      `golden/*.dts`。**review 之后提交进仓库** —— 基准必须来自你认可的那次编译
- [ ] **`.manifest` 里有 `uboot-envtools`** —— 证明包集合和老分支一致
- [ ] **`.manifest` 里有 `luci-app-airoha-npu` 且版本是 `1.0.3`**
- [ ] **`build.config` 里 `CONFIG_TARGET_airoha_an7581_DEVICE_nokia_xg-040g-md-ubi=y`**，
      且**没有** tcboot 那一行

比源码推断更硬的证据就是 `.manifest`：把它和老分支同参数编出来的那份 diff 一下，
理论上只有内核 hash 会不同。

### 阶段 4 · 实机

按这个顺序验，先验最可能出问题的：

- [ ] **能起来、有网** —— 最基本的一关。MAC 钩子和 ubi.dts 的 nvmem 去依赖都动过
- [ ] **CPU 调频正常**
      ```sh
      cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq
      cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
      ```
      **这是 608 移除后最该看的一项。** 频率应该能随负载变，而不是恒定卡在某个值
- [ ] **散热设备注册了**（`bbcba30` 那两个 config 保留着）
      ```sh
      ls /sys/class/thermal/
      ```
      应该能看到 `cooling_device*` 而不只是 `thermal_zone0`
- [ ] **MAC 地址来源正确** —— 启动日志里找
      ```
      - xg-040g-md: MAC xx:xx:xx:xx:xx:xx from ri -
      ```
      转存过 `ri` 卷的机器应该是 `from ri`（真实硬件 MAC）而不是 `from random`
- [ ] **lan1 口灯** —— 805 补丁和 `01_leds` 的 lan1 行都保留了，插网线应该亮。
      这条容易被忽略，但它正是当初写 805 的原因
- [ ] **lan2~lan4 灯正常**
- [ ] **面板三个灯保持出厂行为**（不接管，是预期）
- [ ] **luci-app-airoha-npu 页面能打开、数据正常** —— 包内容一字未改，但构建路径变了，
      主要验 feed 安装位置对不对（`/usr/libexec/rpcd/luci.airoha_npu` 要有执行权限）
- [ ] **复旦颗粒的机器能引导** —— 如果你的是复旦颗粒，这条验的就是 `120`/`121` 收编
- [ ] **U-Boot 网页救砖能进**（`952` 的第 9 项菜单，或按住 reset 上电）
- [ ] **`sysupgrade` 后 `/etc/xg-040g-md-mac` 还在**（keep.d 生效）

### 阶段 5 · 全过之后

- [x] 提交 `golden/*.dts` 基准（2026-09-06，取自 rebase 到 `a6215104` 后 MD/MF 各一次实机验证过的编译）
- [ ] `docs/branches.md` 里 `master-airoha` 的状态从 ⚠️ 改成 ✅
- [ ] 考虑把 `master-airoha` 加进 CI 的 `IS_PRERELEASE=false` 白名单
      （`xg-040g-md-immortalwrt.yml` 里搜 `IS_PRERELEASE`）
- [ ] 考虑把它加进选包页索引白名单（同文件搜 `跳过选包页更新`）
      和 `update-package-index.yml` 的分支列表
- [ ] 考虑把 `build.sh` 的默认分支 `BRANCH=` 改成 `master-airoha`
- [ ] **改救砖页的分支过滤** —— `guide/recovery-guide.html:872` 的正则，以及
      `<footer class="credit">` 里「只覆盖 `master-XG-040G-MD` 分支的 `ubi` 变体」
      那句。**不改的话救砖页会继续发已停更分支的固件，而且不会报任何错。** 详见下节
- [ ] 合并进 `main`

#### 关于救砖页那份「下载最新 ubi-auto 固件」列表

[recovery-guide.html](https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html)
拉的是 `/releases?per_page=100`（**列全部 release，含 pre-release**），不是
`/releases/latest`，所以过滤完全靠页面里的 JS（`guide/recovery-guide.html:867`）：

```js
function isMasterUbiAuto(rel){
  if (!rel || rel.draft || rel.prerelease) return false;              // ①
  if (!/ubi-auto/i.test(rel.tag_name || "")) return false;           // ②
  return /目标分支：master-XG-040G-MD\s*(?:\r?\n|$)/.test(rel.body || "");  // ③
}
```

对 `master-airoha` + `ubi` + `auto` 编出来的 release：

| 过滤 | 效果 | 原因 |
| --- | --- | --- |
| ① `prerelease` | **拦住** | `master-airoha` 不在 `IS_PRERELEASE=false` 白名单，落进 `*` → `true` |
| ② tag 含 `ubi-auto` | **拦不住** | tag 是 `XG-040G-MD-ubi-auto-<日期>-<run>`，确实含这个串 |
| ③ 正文分支名整段匹配 | **拦住** | 正文是 `- 💻 目标分支：master-airoha`，正则要 `master-XG-040G-MD` 后紧跟换行 |

所以**迁移期间是安全的**，①③ 两层各自都能单独挡住，新分支的 release 不会顶掉救砖页
上给别人下载的那份。

> ② 的「拦不住」有个前提：tag 里那个 `ubi` 段来自 `FLAVOR`，而 workflow 的
> `master-airoha)` case 原先漏设了它 —— 第 53 次编译的 tag 是
> `XG-040G-MD-auto-20260904-53`，**不含 `ubi-auto`**，于是 ② 也跟着拦住了。
> 那是个 bug 不是防线：转正后 ① 一失效，② 反倒会让救砖页**一条固件都列不出来**，
> 页面同样不报错。已修（补上 `FLAVOR` / `VARIANT_LABEL` 两行），修完 ② 才回到
> 表里写的行为。

**但转正之后方向反过来了**：`master-airoha` 一旦进了 `IS_PRERELEASE=false` 白名单，
① 失效；而 ③ 仍然只认 `master-XG-040G-MD`，于是救砖页会**继续指向那条已经停更的线**，
页面不报错、不空白，只是安安静静地发老固件。所以上面那两处必须一起改。

③ 的那条注释里写着它当初为什么要做整段匹配 ——「否则会误收
`master-XG-040G-MD-httpd` 这类开发分支」。改的时候保持同样的严格度，别改成宽松的
`test(/master-airoha/)`，不然将来 `master-airoha-xxx` 之类的试验分支又会漏进来。

另外两个页面不受影响：`portal/index.html` 根本不查 release API；
`recovery-guide_0_1_0.html` 用的是 `/releases/tags/<固定 TAG>`。

---

## 六、已知未完成 / 已知风险

| 项 | 说明 |
| --- | --- |
| ~~`golden/` 仍是空的~~ | 2026-09-06 已提交 6 个基准（MD、MF 各 3 个），取自 rebase 到上游 `a6215104`（2026-09-04）后实机验证过的两次编译；`upstream.lock` 同步更新到该基线 |
| ~~从未实机验证~~ | MD、MF 都已实机刷过，通过 |
| ~~`refresh` 检查从未真跑过~~ | 第 53 次编译已实跑，调用方式（`clean` + 命令行 `QUILT=1`）正确，能产出 diff。当时报的 warning 是格式规范化误报，脚本已修 |
| 每周漂移 workflow 没跑过 | 逻辑本地验过（能抓到 801~804 被搬走），但 issue 创建那段没在 GitHub 上跑过 |
| 25.12 升级路径断了 | 见上文「删 tcboot 的代价」 |
| 救砖页的分支过滤是硬编码的 | 迁移期间安全（两层各自能挡住），但**转正时必须改**，否则会静默地继续发停更分支的固件。见阶段 5 |

---

## 七、回滚

**什么都没删。** `master-XG-040G-MD`、`master`、`main` 一字未动，`master-airoha` 是
新分支。验收不通过就继续用老分支，改回 `Run workflow` 里选 `master-XG-040G-MD` 即可。

配置仓库的 `master-airoha` 也没合进 `main`，`patch/uboot-airoha/` 保留着，老分支的
编译路径完全没变。

---

## 八、给下一个会话的定位信息

```
源码仓库   D:\Code\immortalwrt              分支 master-airoha   基线 db5c5de5
配置仓库   D:\Code\ImmortalWrt-XG-040G-MD   分支 master-airoha

看这次改了什么
  cd D:\Code\immortalwrt
  git log --oneline db5c5de5..master-airoha
  git diff --stat master-XG-040G-MD master-airoha     # 与老分支的差异

跑漂移检查
  cd D:\Code\ImmortalWrt-XG-040G-MD
  ./scripts/check-drift.sh watch -o ../immortalwrt
  ./scripts/check-drift.sh versions -o ../immortalwrt

相关文档
  docs/upstream-drift.md    漂移检查怎么用、盯梢清单怎么维护
  docs/branches.md          分支对比、rebase 覆盖范围
  docs/variants.md          设备变体，tcboot 移除说明
  packages/README.md        npu 包的来源与分叉说明
```
