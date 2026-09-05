# 设备变体（分区布局与刷机方式）

实质是**两种分区布局**。`Run workflow` 时用 **device_variant** 输入选择，workflow 会自动改写 `.config` 的设备符号；两款机型（XG-040G-MD / XG-040G-MF）的变体完全相同。

新刷请用 **`ubi`（作者魔改 OpenWrt U-Boot，带 Airoha Web U-Boot 网页救砖）**。同一套分区布局也能用上游官方 UBI U-Boot 引导，只是没有网页救砖。

| 变体 | 引导程序 | rootfs 空间 | MAC 来源 | 可回退原厂 |
| --- | --- | --- | --- | --- |
| **`ubi`（推荐）** | 作者魔改 OpenWrt U-Boot | **255.875 MB** | ubi 的 `ri` 卷，缺失则随机 | 有整片备份时可在网页里整片写回 |
| `stock` | **原厂，不动** | 129 MB | 原厂 `ri` 分区 | **是** |

Release 的标题、正文与 tag 都会标出本次用的机型与变体，例如 `XG-040G-MD-ubi-auto-20260906-58`。

第三方引导 `tcboot.bin` 的变体已经移除，旧仓库 [ImmortalWrt-XG-040G-MD](https://github.com/Loong1996/ImmortalWrt-XG-040G-MD) 的 `master-XG-040G-MD` 分支还编得出来，也留着对它的二进制分析，这里不再展开。

## `stock` —— 寄生原厂分区，唯一可回退

```
0x00000000   512 KB    bootloader   原厂，不动
0x00080000   256 KB    romfile      不动
0x000c0000   40.5 MB   nsb_1        ← kernel (8 MB) 写这里
0x02940000   40.5 MB   nsb_2        原厂备份 bank，不动
0x051c0000   256 KB    bosa         光模块校准数据，不动
0x05200000   256 KB    ri           MAC / 序列号，不动
0x052c0000   10 MB     config       原厂配置，不动
0x05cc0000   129 MB    data         ← rootfs UBI 写这里
0x0e1a0000   10 MB     log          不动
```

* **不碰引导程序，变砖风险最低**
* MAC 从原厂 `ri` 分区经 nvmem 读取，是真实硬件 MAC，不需要任何脚本
* 保留 `nsb_2` 备份 bank 与全部出厂数据，**是唯一不需要备份就能刷回原厂固件的变体**
* 刷机用附件 `factory-kernel.bin` + `factory-rootfs.bin`
* 代价：rootfs 空间只有 129 MB（`ubi` 是 255.875 MB）

## `ubi` —— 作者魔改 OpenWrt U-Boot，带网页救砖（推荐）

```
0x00000000   128 KB      bl2
0x00020000   255.875 MB  ubi
```

* **会替换引导程序**。附件 `preloader.bin` 与 `bl31-uboot.fip` 需经 USB-TTL 走 BootROM 恢复流程刷入
* 这两个附件由 workflow 自动构建：`uboot-airoha` 的 `BUILD_DEVICES:=nokia_xg-040g-md-ubi` 会在选中该变体时自动勾选 U-Boot 包，它再拉 ATF 的 `trusted-firmware-a-an7581-bl31`，最后由 `fiptool` 打成 FIP
* 额外产出 `*-recovery.itb`，是 initramfs 救援镜像，另外三种变体都没有
* 升级用 `sysupgrade.itb`
* 原厂 `ri` 与 `bosa` 由官方转换流程转存为同名 UBI 卷，MAC 得以保留
* `ri` 的读取由 preinit 钩子在用户态完成，**没转存 `ri` 卷也能正常启动**（退化为随机 MAC）；转存过则拿到真实硬件 MAC。丢了可以在网页救砖的「创建 UBI 卷」页把备份写回去

UBI 里的卷（`fip` 也在其中，不是独立分区）：

```
ubi @ 0x20000  255.875 MB
 ├─ bosa        光模块校准
 ├─ ri          MAC（需从原厂 ri 分区转存）
 ├─ fit         kernel + rootfs，即 rootdisk
 ├─ fip         BL31 + U-Boot
 ├─ ubootenv    ┐ 冗余 env
 └─ ubootenv2   ┘
```

> ⚠️ **上面这条只对本项目编的固件成立。上游官方 snapshot 的 ubi 镜像缺 `ri` 卷会整机失联。**
>
> 硬依赖来自共用 dtsi 里 `&gdm1` / `&gdm4` 的 `nvmem-cells = <&macaddr_factory_3e (0)>`。本项目的 `an7581-nokia_xg-040g-md-ubi.dts` 用 `/delete-property/` 删掉了这两个引用，改由 preinit 在用户态读卷；**上游的同名文件没有这段**，保留着硬依赖。
>
> 卷不存在时 nvmem provider 永不注册，`of_get_ethdev_address()` 返回 `-EPROBE_DEFER`，而驱动对这个错误码是直接 return 的（不会退化为随机 MAC），`airoha_eth` 与其下游的 DSA 交换机永久停在 deferred probe，整机无网络且日志里没有任何线索：
>
> ```text
> mt7530-mmio 1fb58000.switch: Failed to register DSA switch: -517
> platform 1fb58000.switch: deferred probe pending: (reason unknown)
> platform 1fb50000.ethernet: deferred probe pending: (reason unknown)
> ```
>
> 所以要用官方 snapshot，**必须先把 `ri` 卷转存好再刷**。

## 互相能不能升级

| 从 → 到 | 可否 |
| --- | --- |
| `ubi` → `ubi` | 网页救砖「日常刷机」或系统内 `sysupgrade` |
| `stock` → `stock` | 刷 `factory-kernel.bin` + `factory-rootfs.bin` |
| `stock` → `ubi` | 需完整刷机：串口传 BL2 + FIP，网页里「引导升级」勾重建 UBI，见[网页救砖](uboot-http-recovery.md#首次迁移从-tcboot--原厂-换到-ubi-布局) |
| `ubi` → `stock` / 原厂 | 有迁移前的整片备份：网页救砖「刷回原厂」整片写回；没有则只能串口 |
| 第三方 `tcboot` → `ubi` | 与 `stock → ubi` 相同的完整刷机流程 |

> ⚠️ **`ubi` 会覆盖原厂引导和原厂分区表。** 其中 `ri`（MAC、序列号）与 `bosa`（光模块校准）是逐机唯一的出厂数据，没有公开来源。**刷之前务必做整片 flash 备份**，见[原厂备份与刷回原厂](backup-and-restore.md)。
>
> 两个变体都声明了 `all_flash` 分区，在跑着的系统里可以直接 dd 整片 flash。

## 内存容量

原厂是 512M 颗粒。换过 1G / 2G 的机器**不需要单独编固件** —— workflow 的内存上限默认是 **自适应**。

原理：U-Boot 启动时探测实际颗粒容量，`bootm` 时用 `fdt_fixup_memory_banks()` 把它写进传给内核的 DTB，覆盖掉 DTS 里的保底值。**注意这个覆盖是无条件的** —— 内核最终用的是 U-Boot 说的数，在下游怎么改 DTS 的 `memory` 节点都没用。

> ⚠️ **`ubi` 变体的自适应是补出来的，不是白来的。**
>
> 上游 U-Boot 的 `dram_init()` 只有一句 `fdtdec_setup_mem_size_base()`，纯读 DTS，一次探测都没有。它把 DTS 里那个 512M 保底值 fixup 进内核 DTB，**反而把 1G 机器摁回了 512M**。
>
> `206-airoha-an7581-probe-dram-size.patch`（MF 是 `310`，an7583 的同一逻辑）补上真正的探测：用地址回绕（颗粒比所探地址小的时候，高地址的写会绕回低地址锚点）。锚点放在 ATF 保留区之上并在返回前还原，可在重定位前安全运行。

| 变体 | 引导程序 | 自适应 |
| --- | --- | --- |
| `ubi` | OpenWrt 自建 U-Boot | ✅ 打了 `206` / `310` 之后有效；**之前恒为 512M** |
| `stock` | 原厂引导程序 | 未验证，换过颗粒建议手动指定 |

1G 颗粒的机器实测（刷的是 **512M 档**编出来的固件）：

```
U-Boot:  DRAM:  1 GiB
内核:    Initmem setup node 0 [mem 0x0000000080200000-0x00000000bfffffff]
         Memory: 948576K/1046528K available
```

`0xbfffffff` 是 1G 的末地址（512M 会停在 `0x9fffffff`），总量 1022MB —— fixup 确实生效。

### 手动档位是「上限」，不是「容量」

`memory` 节点既然总会被 fixup 覆盖，手动指定就落在另一个属性上：`linux,usable-memory-range`。它走内核的 `memblock_cap_memory_range()`，函数体里全是 remove —— **只能把已注册的内存往少了裁，不会凭空多出来**。

> **上游把这个属性写死成 `0x1fe00000`（512M − 2M）**，本线已经改成 `0x7fe00000`（2G，等于不裁剪）。
>
> workflow 的 `auto` 档仍然会重写一遍这个值 —— 在本线上是等值替换，纯属防御：哪天从上游同步把 dtsi 覆盖回 512M，`auto` 出来的固件也不会突然只认一半内存。**这一步不依赖 dtsi 当前是什么值。**

所以档位是上限语义：

| 选了 | 实际 512M 的机器 | 实际 1G 的机器 |
| --- | --- | --- |
| `auto` | 512M | 1G |
| `512M` | 512M | **512M**（被裁） |
| `1G` | 512M（不裁剪） | 1G |
| `2G` | 512M（不裁剪） | 1G（不裁剪） |

**选大了不会出事**，只是不裁剪；选小了就是故意限制 —— 用于对照实验，比如验证某个故障是否与高区内存有关。

### 两个属性的分工

```
/memory 的 reg                      声明有多少内存   ← 真正决定容量的
chosen/linux,usable-memory-range    最多用到哪一段，取交集，只减不增
```

`usable-memory-range` 走内核的 `memblock_cap_memory_range()`，那个函数体里全是 `memblock_remove_*`，**只能往少了裁，不会凭空多出内存**。所以本项目把它固定在 2G 的值，对任何容量都不构成裁剪，同时保住起点 `0x80200000` —— 那是上游给 ATF 那 2MB 的第一道保护，比 `reserved-memory` 的 `no-map` 更早生效（前者在 `setup_machine_fdt()` 里，后者要等到 `arm64_memblock_init()` 末尾）。

