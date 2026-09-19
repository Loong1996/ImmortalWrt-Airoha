# 已知问题：串口迁移后软件重启卡在 Press x

> **状态**：根因已确认，修改暂缓。当前只能断电再上电；下方记录了已验证的事实、试过的路线和待做的修改，可随时接手。
> **记录日期**：2026-09-19

## 现象

经串口 xmodem 进入网页 U-Boot（首次迁移、串口救砖）后，在网页里刷完点「立即重启」，串口停在：

```text
httpd: rebooting on request
resetting ...
Press x
```

此后没有任何输出。**断电再上电就能正常进系统**，刷进去的 BL2、FIP、固件都没有问题。

每台机器都会，MD 和 ZN504XG-D 都复现过。正常上电后再进网页救砖（按键或引导失败），重启不会卡。

## 根因

启动 strap 是**上电时**锁存的，看门狗热复位不会重新采样。

- 进串口 xmodem 需要芯片以「固件升级」strap 上电，这时 `HWTRAP_CONF`（`0x1fb000b4`）的 bit4 = 0。
- 网页里的「立即重启」、U-Boot 的 `reset`、Linux 的 `reboot` 都走同一条路：`psci_system_reset()` → BL31 `plat_system_reset()`，设 100 ms 看门狗后 `wfi`，由看门狗复位整颗芯片。
- 看门狗复位后锁存值不变，BootROM 仍处于升级模式，于是停在 `Press x` 等串口传 BL2。
- 断电后 strap 重新采样，没按键就是正常模式。

卡住时只打印 `Press x`，是 **BootROM** 要 BL2 的提示；我们 BL2 的提示是 `Press x to load BL31 + U-Boot FIP`，两者不同。

## 实测数据

在 U-Boot 命令行读 strap 寄存器，两次会话：

| 会话 | `md.l 1fb000b4 1` | bit4 | 执行 `reset` 后 |
| --- | --- | --- | --- |
| 以升级模式上电 | `0x0000000f` | 0 | **卡在 Press x** |
| 正常上电 | `0x0000001f` | 1 | 正常启动 |

- 低 4 位 `0xf` 是启动介质（ROM NAND 模式），两次相同。
- `md.l 1fbe2e00 1`（`SEC_SSR`）两次都读到 `0xdeadbeef`：这是安全世界专用的寄存器，U-Boot 在非安全世界读不到真实值。

**判断依据就是 `0x1fb000b4` 的 bit4 本身**，与用户是怎么进入网页救砖的无关。

## 代码依据

TF-A 源码：`Ansuel/atf-airoha` `94892b9e42`（`package/boot/arm-trusted-firmware-airoha/Makefile` 里的版本）。

- `plat/ecnt/en7523/ecnt_bl2_setup.c`：
  - `hw_trap_init()`：`fw_upgrade_mode = !(HWTRAP_CONF & BIT(4))`，`skip_fw_upgrade = !(SEC_SSR & BOOT_SEL_BY_HWTRAP)`。BL2 里 `debug_flag` 恒为 0，只看这两个硬件寄存器，**不读任何 GPIO**。
  - `bl2_plat_preload_setup()`：升级模式下不走 UBI，而是按固定偏移裸读 FIP，读不到就打印 `Press x to load BL31 + U-Boot FIP` 等 xmodem。
- `plat/ecnt/en7523/ecnt_bl1_setup.c`：`bl1_plat_handle_pre_image_load()` 同样只在升级模式下等 `x`；非升级模式读不到镜像直接 `panic()`，不会提示。BootROM 应该是同一套逻辑。
- `plat/ecnt/en7523/plat_pm.c`：`plat_system_reset()` 只用 timer3 看门狗复位；`timer_WatchDogConfigure()` 只有开关两个位，没有复位范围可选。
- U-Boot：`arch/arm/mach-airoha/an7581/init.c` 的 `reset_cpu()` 就是 `psci_system_reset()`。
- 网页 U-Boot（`202` 补丁的 `net/httpd.c`）：`/reboot` 等响应送达后执行 `run_command("reset")`，与菜单 Reboot 相同；重启前 `httpd_tick_stop()` 已关掉流水灯，不碰其他引脚。U-Boot 与我们的补丁都没有写 `0x1fb000b4`。

## 已排除的路线

### 1. 直接改写 strap 寄存器 ❌

```text
AN7581> md.l 1fb000b4 1
1fb000b4: 0000000f
AN7581> mw.l 1fb000b4 0000001f
AN7581> md.l 1fb000b4 1
1fb000b4: 0000000f
```

只读，写不进去。

### 2. SCU 软复位 `0x1fb00040` bit31 ❌

老 EcoNet 的 EN7528 用 `CR_AHB_RSTCR`（`0x1fb00040`）bit31 重启（`target/linux/econet/patches-6.18/100-econet-add-en7528-soc.patch`）。在 EN7581 上执行 `mw.l 1fb00040 80000000`：**无反应，直接卡死**，不是整机复位。TF-A 里这个寄存器叫 `RG_RESET_CTRL`，只用到 bit0（DRAM）和 bit8（RBus）。

### 3. 换看门狗复位范围 ❌

BL31 的 `CR_TIMER_CTL` 只有 tick 使能（bit5）和看门狗使能（bit25），代码里找不到可选的复位范围。

### 4. strap 解码寄存器 `0x1fb000b8` ❌

`HWTRAP_DEC` / `BOOT_TRAP_CONF_DEC` 是解码后的只读副本，BL2 只拿它判断 eMMC，不参与升级模式判断。

### 5. 让 BootROM 在升级模式下走旁路 ❌（风险过高）

BL1 在升级模式下，如果闪存里镜像的 FIP TOC 带 `BYPASS_FWUPGRADE` 标志，就不等 `x`。但我们的 BL2 是 BL21 + 头 + BL22 + BL23 + 闪存表 + CRC 拼成的（`scripts/airoha_pack_bl2.sh`），没有 TOC 可放这个标志；BootROM 实际怎么判断看不到源码。硬试要改 BootROM 读的 BL2 格式，**出错就只能上编程器**，按住 reset 走串口传 BL2 的救砖路径也会失效。不做。

## 剩余可能（低概率）

### A. 复位前由 BL31 清掉 `SEC_SSR` 的 `BOOT_SEL_BY_HWTRAP`

BL31 有读写 `SEC_SSR` 的 SMC：`0x82000002`，子命令 `0x55435352` 读、`0x55435357` 写（`plat/ecnt/common/ecnt_plat_common.c`），U-Boot 也开了 `CONFIG_CMD_SMC`。但它被 `#define SR_TEST (0)` 编译掉了，调用只返回参数无效。

要验证得先编一版打开它的 BL31（或者直接在 `plat_system_reset()` 里复位前清这一位），刷进去后在升级模式会话里试。成功的前提是这个值能扛过看门狗复位、且 BootROM 认它，**很可能每次复位都由 BootROM 重新设置**。

## 待做：如实提示用户断电

软件清不掉锁存，就让网页和串口说清楚。设计已定，暂缓：

- **U-Boot（`202` 补丁的 `net/httpd.c`）**
  - 读 `0x1fb000b4`，bit4 为 0 即「热重启会停在 Press x」。需要 `#include <asm/io.h>`；AN7583 的 strap 寄存器地址和位与 AN7581 相同（TF-A `en7523_def.h`）。
  - 启动横幅后在串口打印一行：以升级模式上电，reset 会停在 Press x，请断电。
  - `/info` 增加 `"upg":0|1`。
  - 「诊断」的「引导」组增加「启动方式」：正常为 OK，升级模式为注意并写明寄存器值。
- **页面（`files/httpd/page.html`）**
  - 刷写完成弹框（`wrfin()`）：`INFO.upg` 时隐藏「立即重启」，改说「断电再上电即以新内容启动」。
  - 「启动与重启」页的确认框（`askreboot()`）：`INFO.upg` 时说明原因并不给确认按钮。
  - 顶部红条（`banner()`）：fip 已写好但 `INFO.upg` 时提示需要断电。
- **预览与测试**：`preview.py` 加一个「升级模式上电」的设备状态和「启动方式」检查项；`test/page.test.js` 补对应用例，并把体检计数（组数、项数、正常项数）跟着改。
- 改完照例用 `gen.py` 重新生成 `202` 补丁里的 `httpd.c`，并跑页面测试。

`/stock` 刷回原厂写完会自动重启，在升级模式会话里同样会停在 Press x，提示里也要顾到。

## 相关代码位置

| 位置 | 内容 |
| --- | --- |
| immortalwrt `package/boot/uboot-airoha/patches/202-net-add-httpd-recovery-server.patch` | 网页 U-Boot，`/reboot`、`/info`、体检 |
| immortalwrt `package/boot/uboot-airoha/files/httpd/page.html` | 页面源文件，`gen.py` 生成进 `202` |
| immortalwrt `package/boot/arm-trusted-firmware-airoha/Makefile` | TF-A 源码版本 |
| `atf-airoha` `plat/ecnt/en7523/ecnt_bl2_setup.c` | BL2 升级模式判断与 Press x |
| `atf-airoha` `plat/ecnt/en7523/ecnt_bl1_setup.c` | BL1 的同类逻辑与旁路标志 |
| `atf-airoha` `plat/ecnt/en7523/plat_pm.c` | BL31 看门狗复位 |
| `atf-airoha` `plat/ecnt/en7523/include/en7523_def.h` | `HWTRAP_CONF`、`SEC_SSR` 等寄存器定义 |
