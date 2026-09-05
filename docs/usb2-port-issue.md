# 待解决：USB2 口带不动 USB3 U 盘

> **状态**：未解决，已搁置。根因未找到，下方记录了全部已排除的假设与原始数据，可随时接手。
> **记录日期**：2026-08-29

## 现象

USB3 U 盘插 **USB2 口**（面板标 USB2，对应 `1fad0000.usb`，bus 3），在 **master 线固件上**无法正常工作；同一个盘同一个口刷 **25.12 线固件就完全正常**。

master 线（内核 6.18）走 UAS 时，枚举能过、盘型号能读出来，第一条批量传输命令就崩：

```text
[ 9.044519] usb 3-1: new high-speed USB device number 2 using xhci-mtk
[ 9.480301] scsi 0:0:0:0: Direct-Access  USB Sandisk 3.2Gen1 1.00 PQ: 0 ANSI: 7
[ 9.685783] sd 0:0:0:0: [sda] tag#26 data cmplt err -75 uas-tag 1 inflight: CMD
                                                    ^^^^^^^ -EOVERFLOW
[40.191626] sd 0:0:0:0: [sda] tag#26 uas_eh_abort_handler 0 uas-tag 1 inflight: CMD
[40.241617] scsi host0: uas_eh_device_reset_handler start
[45.571665] usb 3-1: device descriptor read/64, error -110
[61.087558] scsi host0: uas_eh_device_reset_handler FAILED err -19
[61.093807] sd 0:0:0:0: Device offlined - not ready after error recovery
[89.161923] usb usb3-port1: attempt power cycle
[97.501935] usb usb3-port1: unable to enumerate USB device
```

用 `usb-storage.quirks=0781:55b8:u` 强制退回 BOT 之后**不再直接崩**，但每条 SCSI 命令都要先超时 30 秒、端口 reset 一次才能成功，实际不可用：

```text
[277.8] scsi host0: usb-storage 3-1:1.0
[300.2] usb 3-1: reset high-speed USB device ...  → [300.4] INQUIRY 成功   (等了 22s)
[330.9] usb 3-1: reset high-speed USB device ...  → [331.1] READ CAPACITY 成功 (等了 30s)
[361.6] usb 3-1: reset high-speed USB device ...  → [361.8] Write Protect is off
[392.3] usb 3-1: reset ... → [397.5] device descriptor read/64, error -110
```

同一个盘、同一个口，刷 25.12 线固件：

```text
[118.817454] usb 3-1: new high-speed USB device number 2 using xhci-mtk
[118.970996] scsi host0: uas                      ← UAS 直接就能跑，不用任何 quirk
[118.990453] sd 0:0:0:0: [sda] 120126720 512-byte logical blocks: (61.5 GB/57.3 GiB)
[119.081052] sd 0:0:0:0: [sda] Attached SCSI removable disk
```

**枚举到挂载 0.26 秒。**

## 影响范围

| 组合 | master 线 | 25.12 线 |
| --- | --- | --- |
| USB3 盘 + **USB2 口** | ❌ **故障** | ✅ 正常（UAS） |
| USB3 盘 + USB1 口 | ✅ 正常 | ✅ 正常 |
| USB2 原生盘 + USB2 口 | ✅ 正常 | ✅ 正常 |
| USB2 原生盘 + USB1 口 | ✅ 正常 | ✅ 正常 |

只有「USB3 盘 + USB2 口 + master 线」这一个组合出问题。

## 复现环境

| 项 | 值 |
| --- | --- |
| 设备 | Nokia XG-040G-MD，`tcboot` 变体 |
| 内存 | **已把原 512M 颗粒换成 1G**（这点很重要，见[剩余嫌疑](#剩余嫌疑)） |
| 故障固件 | ImmortalWrt SNAPSHOT，内核 6.18.44（实测固件 banner 为 `r40926-8b82ee2970`，该 commit 含后来移除的无效补丁；因其是死代码，行为与不含它的固件一致）|
| 正常固件 | ImmortalWrt 25.12-SNAPSHOT `r37817-993fee8c34`，内核 6.12.85 |
| 故障 U 盘 | SanDisk 3.2Gen1，VID:PID `0781:55b8`，61.5 GB，`ANSI: 7`（支持 UAS） |
| 正常 U 盘 | SanDisk Ultra，15.4 GB，`ANSI: 6`（**不支持 UAS**，只能 BOT） |
| 故障控制器 | `1fad0000.usb`（bus 3/4），DTS 里 `mediatek,u3p-dis-msk = <0x1>`，只挂 `PHY_TYPE_USB2` |
| 正常控制器 | `1fab0000.usb`（bus 1/2），完整 USB3 |

## 已排除的假设

每一条都有实测依据，**不要重复走**。

### 1. UAS 协议本身 ❌

强制退回 BOT（`usb-storage.quirks=0781:55b8:u`）之后仍然每条命令超时 30 秒。协议层不是原因。

### 2. 缺少内核模块 / 固件 ❌

`usb-storage`、`uas` 都正常注册；盘完整识别到 SCSI 层（`Direct-Access USB Sandisk 3.2Gen1`）；`30-fs-exfat`/`30-fs-vfat`/`30-fs-ext4`/`80-fs-ntfs3` 全在。故障发生在比这些低得多的 USB 传输层，连 `READ CAPACITY` 都过不去，装包救不了。

### 3. 盘本身不耐 USB2 ❌

同一个盘、同一个口，刷 25.12 就能跑 UAS 且 0.26 秒挂载。硬否证。

### 4. SerDes 归属（`REG_NP_SCU_SSTR` bit3） ❌

**这条走了最久的弯路，重点记录。**

25.12 线有一个 master 线没有的补丁 `patches-6.12/910-02-usb-pcie.patch`，把 `REG_NP_SCU_SSTR`(0x9c) 的 `BIT(3)` 一起清零。这一位决定 USB/PCIe 共用的那组 SerDes 归谁。当时看着极像根因，实际三重否定：

* **语义是反的**。`phy-airoha-an7581-usb.c` 里 `AIROHA_SCU_SSTR_USB_PCIE_SEL_PCIE = 0`、`..._SEL_USB = 1`，清零是划给 **PCIe** 不是 USB。
* **那段补丁是死代码**。真正写这一位的是 `airoha_usb_phy_u3_set_mode()`；`usb0` 声明了 `PHY_TYPE_USB3` 实例，xhci-mtk probe 时对它调 `phy_set_mode(PHY_MODE_USB_HOST)`，走 `else` 分支把 bit3 写回 1，把 clk 驱动清的零盖掉。**两条线实测都读出 `0x109`（bit3=1）**，25.12 的补丁同样没生效。
* **bit3=0 的场景已经验过**。运行时 `devmem` 清零（读回 `0x101`）、重新 `bind 1fad0000.usb` 之后，U 盘照样 30 秒超时。

曾据此往 `patches-6.18/` 加过一个 `914-clk-en7523-route-shared-serdes-to-USB.patch`，把 `REG_USB_PCIE_SEL` 一并清零。编固件实测无效（刷上去后 `0x1fb0009c` 仍读出 `0x109`），相关提交已从分支上移除，不要再试。

### 5. `pcie2` 占用 `usb1_phy` 的 USB3 lane ❌

`an7581.dtsi` 里 `pcie2` 确实写着 `phys = <&usb1_phy PHY_TYPE_USB3>`，但**两条线的板级 DTS 都没有启用 pcie**（`grep '^&pcie'` 无匹配），这条 lane 处于闲置状态。

### 6. `vusb33-supply` 供电 ❌

master 的 `&usb1` 多了 `vusb33-supply = <&reg_3p3v>`（25.12 是 dummy regulator）。但 `reg_3p3v` 是 `regulator-fixed` + `regulator-always-on` 且无 GPIO，enable 它是空操作，与 dummy 等价。

### 7. `reg_usb_5v`（GPIO 24）供电 ❌

master 独有这个 regulator，但其 DTS 注释明写 `Controls both USB ports at once` —— 两个口共用一路 5V。而 USB1 口一切正常，供电不可能是两个口之间的差异。

### 8. AN7581 USB PHY 驱动本体 ❌

两条线的 `220-07-phy-airoha-Add-support-for-Airoha-AN7581-USB-PHY.patch` **逐字相同**，只有 MAINTAINERS 的行号偏移不同。

### 9. AN7583 USB PHY 补丁引入回归 ❌

master 独有 `607-01`/`607-02`，但 `607-02` 只新增 `phy-airoha-an7583-usb.c` 与 Kconfig/Makefile 条目，`grep '^-[^-]'` 零匹配 —— 一行现有代码都没改。

### 10. PHY 信号参数 / slew rate 校准 ❌

驱动会跑一次 slew rate 校准（`FMCR0`/`FMMONR0`/`FMMONR1` 测频率 → 算出 `SRCTRL` 写 `USBPHYACR5`），本以为两个内核可能算出不同结果。**实测两条线全部寄存器逐位相同**，见下方数据。

### 11. 内存容量差异 / 高区 DMA ❌

曾经是最优先的嫌疑（两条线内存布局不同，见下），2026-08-30 用一版**内存布局与 25.12 完全一致的 master 固件**证伪。

对照组是意外来的：`ubi` 变体用官方自建 U-Boot，而上游 `dram_init()` 只读 DTS 不探测，于是 1G 机器被 fixup 摁回 512M —— 正好就是「真正只认 512M 的 master 固件」，不用专门编。

```text
内核 6.18 + 512M 布局：Zone DMA [mem 0x0000000080200000-0x000000009fffffff]
                        ← 与 25.12 线逐字相同
```

故障依旧：

```text
[87.795996] usb 3-1: new high-speed USB device number 3 using xhci-mtk
[88.040709] scsi host0: uas
[88.182399] scsi 0:0:0:0: Direct-Access  USB  Sandisk 3.2Gen1 1.00 PQ: 0 ANSI: 7
[88.381840] sd 0:0:0:0: [sda] tag#6 data cmplt err -71 uas-tag 1 inflight: CMD
[88.389176] sd 0:0:0:0: [sda] tag#6 CDB: opcode=0x28 28 00 00 00 00 00 00 00 01 00
```

枚举过、型号读得出、第一条 `READ_10` 就崩 —— 和 1G 布局下的症状一模一样（错误码 `-75`/`-71` 的差别只是 uas 上报路径不同，都是传输失败）。**内存/DMA 不是根因**，剩下 B 和 C。

> 曾有的不利证据也对得上：`DCBAAP = 0x8A5AD000` 本来就在低区。当时的辩解是「真正的数据缓冲区动态分配、未观测」，现在整个高区都不存在了，故障却没走。

## 原始寄存器数据

**master 线与 25.12 线读数完全一致**，以下每个值两边都相同。盘拔出、系统空闲时采集。

### xhci `1fad0000`

```text
0x1fad0000 = 0x01100020     0x1fad0004 = 0x0200010F
0x1fad3e00 = 0x10411020     0x1fad3e04 = 0x00000000
0x1fad3e30 = 0x0000020F     0x1fad3e34 = 0x00000000
```

### USB PHY：`usb1_phy`(1fae0000) 对照 `usb0_phy`(1fac0000)

```text
偏移     usb1_phy(故障口)   usb0_phy(正常口)   备注
0x000  = 0x1E1E1700        0x1E1E1700
0x004  = 0x001F0001        0x001F0001
0x008  = 0x00000000        0x00000000
0x00c  = 0x00001F00        0x00001F00
0x010  = 0x00000000        0x00000000
0x018  = 0x00000000        0x00000000
0x068  = 0x00000000        0x00000000
0x06c  = 0x00000000        0x00000000
0x070  = 0x00000000        0x00000000
0x100  = 0x08000400        0x04000400        FMCR0，MONCLK_SEL=2 vs 1，DTS 指定，正常
0x10c  = 0x0000006E        0x0000006F        FMMONR0 频率计读数，差 1 属正常抖动
0x110  = 0x00000001        0x00000001        FMMONR1
0x300  = 0x0000486A        0x0000486A
0x304  = 0x00C44400        0x00CC4400        bit19 口间差异，两条线都一样，与故障无关
0x308  = 0x00020044        0x00020044
0x30c  = 0x00000000        0x00000000
0x310  = 0x00004652        0x00004652        USBPHYACR4
0x314  = 0x10205000        0x10205000        USBPHYACR5：SRCAL_EN=0, SRCTRL=5(默认值)
0x318  = 0x001004A9        0x001004A9        USBPHYACR6：DISCTH=0xA(600mV), SQTH=0x9(130mV)
0x36c  = 0x00000101        0x00000101        U2PHYDTM1
0x80c  = 0x40000000        0x00000000        GPIO_CTLD，usb1 的 bit30 MCU_BUS_CK_GATE_EN 置位
```

### SCU 与 DMA

```text
0x1fb0009c = 0x00000109     SCU SSTR，bit3=1（两条线相同）
0x1fad0050 = 0x8A5AD000     DCBAAP 低 32 位 —— 落在低区，25.12 的 512M 范围也覆盖得到
0x1fad0054 = 0x00000000     DCBAAP 高 32 位
0x1fad0038 = 0x00000000     CRCR 低（xHCI 规范规定读回 0，正常）
```

## 剩余嫌疑

按优先级排列。原 A（内存容量差异）已于 2026-08-30 证伪，移入[已排除的假设 #11](#11-内存容量差异--高区-dma-)。

### B. 内核 6.12 → 6.18 的上游变化（未缩小范围）

所有静态配置（DTS、PHY 寄存器、xhci 寄存器、SCU）两条线完全相同，行为却不同，说明差异在**驱动代码路径**而非寄存器配置。嫌疑落在上游 `xhci-mtk` / `usb core` 在 6.12→6.18 之间的改动上。范围很大，需要 bisect 或逐项回退，成本高 —— 但 A 已经排除，这条现在是最优先的。

### C. master 的 `&usb1` 多出的 DTS 子节点（未单独验证）

```dts
/* master 线的 an7581-nokia_xg-040g-md-common.dtsi */
&usb1 {
	status = "okay";
	mediatek,u3p-dis-msk = <0x1>;
	phys = <&usb1_phy PHY_TYPE_USB2>;
	vusb33-supply = <&reg_3p3v>;      /* 已排除，见假设 6 */

	#address-cells = <1>;             /* ← 25.12 没有 */
	#size-cells = <0>;                /* ← 25.12 没有 */

	usb_port2: port@1 {               /* ← 25.12 没有，为 usbport LED trigger 而加 */
		reg = <1>;
		#trigger-source-cells = <0>;
	};
};
```

25.12 那边只有三行：`status` + `phys` + `u3p-dis-msk`。`port@1` 会让 USB core 走 DT port 节点的解析路径，理论上只影响 LED trigger，但没有单独验证过。**代价很低**：编一版把 `&usb1` 改成与 25.12 逐字相同的固件即可排除。既然 C 比 B 便宜得多，建议先做 C 再啃 B。

## 临时缓解

* **USB2 口插 USB2 原生盘**（如 SanDisk Ultra），完全正常
* **USB3 盘插 USB1 口**，完全正常
* 不推荐 quirks 方案：`usb-storage.quirks=0781:55b8:u` 只能把「直接崩」缓成「每条命令 30 秒」，仍然不可用

## 排查命令速查

**`devmem` 不接受 `0x` 前缀**，用 `$(( ))` 让 shell 先算成十进制。

```sh
# PHY 关键寄存器，usb1(故障口) 对照 usb0(正常口)
for o in 0x100 0x10c 0x110 0x310 0x314 0x318 0x36c 0x80c; do
  printf 'off=0x%03x  usb1=%s  usb0=%s\n' $o \
    "$(devmem $((0x1fae0000+o)))" "$(devmem $((0x1fac0000+o)))"
done

# SCU SSTR（SerDes 归属所在，bit3）
devmem $((0x1fb0009c))

# xhci DMA 结构落点（operational base = 0x1fad0000 + CAPLENGTH 0x20）
for a in 0x1fad0038 0x1fad003c 0x1fad0050 0x1fad0054; do
  printf '%s = %s\n' "$a" "$(devmem $((a)))"
done

# 串口下 dmesg 会打断输入，先关掉再操作
dmesg -n 1
# ... 操作 ...
dmesg -n 7
```

## 相关代码位置

| 内容 | 位置（`Loong1996/immortalwrt`） |
| --- | --- |
| USB PHY 驱动 | `target/linux/airoha/patches-6.18/220-07-phy-airoha-Add-support-for-Airoha-AN7581-USB-PHY.patch` |
| 板级 DTS | `target/linux/airoha/dts/an7581-nokia_xg-040g-md-common.dtsi`（`&usb0` / `&usb1`） |
| SoC DTS | `target/linux/airoha/dts/an7581.dtsi`（`usb0`/`usb1`/`usb0_phy`/`usb1_phy`） |
| 内存节点 | `target/linux/airoha/dts/an758x-nokia_xg-040g-common.dtsi`（`linux,usable-memory-range`） |
| 25.12 独有补丁 | `target/linux/airoha/patches-6.12/910-02-usb-pcie.patch`（已证实是死代码） |
| 错误的修复尝试 | 曾加过 `patches-6.18/914-clk-en7523-route-shared-serdes-to-USB.patch`，实测无效，提交已移除 |
| 内存上限处理 | 本仓库 `.github/workflows/xg-040g-md-immortalwrt.yml` 的 `Patch DRAM Size` 步骤 |
| 内存容量探测 | `package/boot/uboot-airoha/patches/206-airoha-an7581-probe-dram-size.patch` |

## 排查方法备忘

* **运行时 `devmem` 改寄存器后故障依旧，要当作有效否证**，别用「这一位得在驱动 probe 早期就位、事后补写不等价」轻易解释掉。SerDes 那条弯路就是这么白编了一版固件。
* **改寄存器前先 grep 内核源码里还有谁写它**。bit3 实际由 `airoha_usb_phy_u3_set_mode()` 掌管，提交前 grep 一次就能发现补丁是死代码。
* **对比两条线的补丁列表产出的是候选，不是结论**。比对时先把文件名里的序号和 `vX.Y` 前缀剥掉再 `comm`，否则 backport 噪音会淹没结果 —— 只有非 backport 的功能性补丁才是真差异。
* **决定性判据是「同板、同盘、同口，只换固件」**，别靠回忆，实刷一次。
