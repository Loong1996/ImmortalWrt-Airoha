# 原厂备份与刷回原厂

`tcboot` 与 `ubi` 两个变体会**覆盖原厂引导和整张分区表**，其中 `ri`（MAC、序列号）、`bosa`（光模块校准）、`romfile`（SN、PON 认证）是逐机唯一的出厂数据，**没有任何公开来源，丢了就再也拿不回来**。本文记录怎么完整备份、怎么刷回去，以及这条路上每一个会让你变砖的细节。

> 本文中关于 `tcboot.bin` / `bootext.ram` 的结论均由**对二进制的分析**得出（解压其中的 U-Boot 后提取字符串与命令模板），非厂商文档。分区偏移由 `/proc/mtd` 推导并与 [设备变体](variants.md) 中的 `stock` 布局逐项交叉验证。

## 原厂分区表

`/proc/mtd` 只给出大小不给偏移。按顺序累加推导出的偏移，与 `stock` 变体布局在 `bosa`、`ri`、`config`、`data`、`log` 五个点上逐一吻合，`log` 的结束地址正好等于 `all_flash` 的大小 —— 可以认为这张表是准确的：

| mtd | 名称 | 起始 | 结束 | 大小 |
| --- | --- | --- | --- | --- |
| 0 | `bootloader` | `0x0000000` | `0x0080000` | 512 KiB |
| 1 | `romfile` | `0x0080000` | `0x00c0000` | 256 KiB |
| 2 | `kernel` | `0x00c0000` | `0x0540000` | 4.5 MiB |
| 3 | `rootfs` | `0x0540000` | `0x2940000` | 36 MiB |
| 4 | `kernel_slave` | `0x2940000` | `0x2cef742` | 3.685 MiB |
| 5 | `rootfs_slave` | `0x2d00000` | `0x49b0000` | 28.688 MiB |
| 6 | `bosa` | `0x51c0000` | `0x5200000` | 256 KiB |
| 7 | `ri` | `0x5200000` | `0x5240000` | 256 KiB |
| 8 | `flag` | `0x5240000` | `0x5280000` | 256 KiB |
| 9 | `flagback` | `0x5280000` | `0x52c0000` | 256 KiB |
| 10 | `config` | `0x52c0000` | `0x5cc0000` | 10 MiB |
| 11 | `data` | `0x5cc0000` | `0xdda0000` | 128.875 MiB |
| 12 | `oopsfs` | `0xdda0000` | `0xe1a0000` | 4 MiB |
| 13 | `log` | `0xe1a0000` | `0xeba0000` | 10 MiB |
| 14 | `nsb_master` | `0x00c0000` | `0x2940000` | 40.5 MiB |
| 15 | `nsb_slave` | `0x2940000` | `0x51c0000` | 40.5 MiB |
| 16 | `all_flash` | `0x0000000` | `0xeba0000` | 235.625 MiB |

三个容易踩的点：

* **`nsb_master` / `nsb_slave` 是重叠视图，不是独立分区。** `nsb_master` 就是 `kernel`(4.5M) + `rootfs`(36M) 拼起来的同一片区域。所以**把 mtd0~mtd15 的大小相加会多算 81 MiB**，不能用"相加等于 mtd16"来验证备份完整性。
* **`all_flash` 不是物理整片。** 它是 235.625 MiB，而颗粒是 2 Gbit = 256 MiB，**末尾 20.375 MiB 不在任何 mtd 里**。原厂不使用这段，备份不到不影响回退；但 `tcboot` 变体的 ubi 是 `0x100000 + 255 MB`，**会用满整片**。
* **`kernel_slave` / `rootfs_slave` 的大小不是 128 KiB 擦除块的整数倍**（`0x3af742`、`0x1cb0000`）—— 它们是按镜像实际长度注册的，不是对齐的分区。不要试图单独擦写这两个，要处理就整个 `nsb_slave` 一起。

## 一、备份

**推荐用 U 盘直接 dd**（已有人实测可用）。比走网络省事得多：不依赖原厂 busybox 有没有 `nc`，没有传输时序问题，而且一条命令就把 17 个分区**逐个独立**落盘。

> U 盘需要 **≥ 1 GB**（实际占用 544.1 MiB），建议 **FAT32**。挂载点在本机实测为 `/mnt/UDISK`，若不同请先 `mount` 或 `df -h` 确认。

### 步骤 1：插 U 盘，逐分区备份

telnet 上去后粘贴：

```sh
mkdir -p /mnt/UDISK/xg && cd /mnt/UDISK/xg
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  [ -c /dev/mtd$i ] || continue
  dd if=/dev/mtd$i of=mtd$i.bin bs=128k 2>/dev/null || echo "!!! mtd$i 读取出错"
done
cat /proc/mtd > proc-mtd.txt
dmesg > dmesg.txt
md5sum mtd*.bin > md5.txt
ls -l
sync
```

要点：

* **`bs=128k`** 是擦除块大小，比 `bs=4k` 少 32 倍系统调用，快很多；数据完全一样，用 `4k` 也无害。
* **`md5.txt` 是整套备份的基准**，后面所有校验都靠它。一定要在设备上生成，别等拷到电脑再算 —— 那样就验证不了传输过程。
* **`sync` 不能省**，拔 U 盘前必须落盘。
* 任何一行出现 `!!! mtdN 读取出错` 都要停下来查坏块，别继续。

### 步骤 2：核对文件大小

`ls -l` 的输出对照下表，**必须一字节不差**：

| 文件 | 字节数 | 文件 | 字节数 |
| --- | --- | --- | --- |
| `mtd0.bin` | 524288 | `mtd9.bin` | 262144 |
| `mtd1.bin` | 262144 | `mtd10.bin` | 10485760 |
| `mtd2.bin` | 4718592 | `mtd11.bin` | 135135232 |
| `mtd3.bin` | 37748736 | `mtd12.bin` | 4194304 |
| `mtd4.bin` | 3864386 | `mtd13.bin` | 10485760 |
| `mtd5.bin` | 30081024 | `mtd14.bin` | 42467328 |
| `mtd6.bin` | 262144 | `mtd15.bin` | 42467328 |
| `mtd7.bin` | 262144 | `mtd16.bin` | **247070720** |
| `mtd8.bin` | 262144 | 合计 | 570554178 |

某个文件偏小，说明 `dd` 在那里中断了 —— 通常是坏块导致的读取错误。

### 步骤 3：⚠️ 坏块检查

这一步决定了后面能不能用"整片刷回"这条路：

```sh
grep -i "bad block" /mnt/UDISK/xg/dmesg.txt
```

原因在恢复侧：tcboot 的 U-Boot 里，`mtd erase` 有 `.dontskipbad` 开关，而 **`mtd write` 没有** —— 写入**恒定跳过坏块**，不可关闭，遇到就 `Skipping bad block at 0x...` 然后顺延。而 `dd if=/dev/mtd16` 读出来的是**线性**镜像（mtd 字符设备读取不跳坏块）。

两者一叠加：**只要有一个坏块，整片写入就会从那里开始错位一个擦除块（128 KiB）**，之后的 `ri`、`bosa`、`config` 全部对不上。

* 无坏块 → 线性备份与跳坏块写入结果完全一致，可以整片回刷。
* 有坏块 → **不要整片刷**，改用后文的**单分区精修**逐个恢复 —— 这正是逐分区独立备份的价值所在。

### 步骤 4：拷到电脑并交叉校验

拔下 U 盘插电脑，把 `xg/` 整个拷贝出来，然后跑这个脚本。

它做**两重校验**：一是各文件与设备上算的 `md5.txt` 是否一致（验证 U 盘读写与拷贝过程）；二是 `mtd0`~`mtd15` 这 16 个**独立读取**的文件，与从 `mtd16.bin` **整片切分**出来的对应区段是否吻合（两条独立路径产生同一份数据，互相印证，同时验证分区表推导正确）。

```python
#!/usr/bin/env python3
# verify.py —— 放在拷贝出来的 xg/ 目录下执行
import hashlib, os, sys

# (名称, 物理偏移, 大小)；顺序即 /proc/mtd 中 mtd0..mtd15 的顺序
LAYOUT = [("bootloader",0x0,0x80000),("romfile",0x80000,0x40000),("kernel",0xc0000,0x480000),
("rootfs",0x540000,0x2400000),("kernel_slave",0x2940000,0x3af742),("rootfs_slave",0x2d00000,0x1cb0000),
("bosa",0x51c0000,0x40000),("ri",0x5200000,0x40000),("flag",0x5240000,0x40000),
("flagback",0x5280000,0x40000),("config",0x52c0000,0xa00000),("data",0x5cc0000,0x80e0000),
("oopsfs",0xdda0000,0x400000),("log",0xe1a0000,0xa00000),
("nsb_master",0xc0000,0x2880000),("nsb_slave",0x2940000,0x2880000)]
FLASH_LEN = 0xeba0000
md5 = lambda b: hashlib.md5(b).hexdigest()

# 设备上生成的基准
dev = {}
for ln in open("md5.txt"):
    p = ln.split()
    if len(p) == 2: dev[os.path.basename(p[1].lstrip('*'))] = p[0]

flash = open("mtd16.bin","rb").read()
assert len(flash) == FLASH_LEN, f"mtd16.bin 长度 {len(flash)}，应为 {FLASH_LEN}"

print(f"{'':<6}{'分区':<14}{'大小':>10}  {'独立读 md5':<34}{'设备':<6}{'整片切':<8}")
bad = 0
for i,(name,off,size) in enumerate(LAYOUT):
    fn = f"mtd{i}.bin"
    data = open(fn,"rb").read()
    if len(data) != size:
        print(f"mtd{i:<3} {name:<14}{len(data):>10}  ❌ 长度应为 {size}"); bad += 1; continue
    h = md5(data)
    d_ok = dev.get(fn) == h                      # 与设备端基准比对
    c_ok = md5(flash[off:off+size]) == h         # 与整片切分比对
    if not (d_ok and c_ok): bad += 1
    print(f"mtd{i:<3} {name:<14}{size:>10}  {h:<34}{'✔' if d_ok else '✘':<6}{'✔' if c_ok else '✘':<8}")

hf = md5(flash)
f_ok = dev.get("mtd16.bin") == hf
if not f_ok: bad += 1
print(f"mtd16  all_flash    {FLASH_LEN:>10}  {hf:<34}{'✔' if f_ok else '✘':<6}{'—':<8}")
print(f"\n{'✅ 全部校验通过，备份可用' if bad==0 else f'❌ {bad} 处不一致，请重做备份'}")
sys.exit(1 if bad else 0)
```

```sh
cd /path/to/xg && python3 verify.py
```

**独立读 md5** 列就是每个分区的指纹；**设备**列验证 U 盘读写与拷贝无误；**整片切**列验证独立备份与整片备份互相吻合。三者全绿，这套备份才算真正可用。

其中这 6 个是**逐机唯一、丢了再也拿不回来**的，务必额外单独存一份（云盘、另一块盘都行）：

| 文件 | 分区 | 内容 |
| --- | --- | --- |
| `mtd0.bin` | `bootloader` | 原厂引导，回退原厂的命根子 |
| `mtd1.bin` | `romfile` | SN、PON 认证、超级密码 |
| `mtd6.bin` | `bosa` | 光模块校准，丢了光口就废了 |
| `mtd7.bin` | `ri` | MAC / 序列号 |
| `mtd8.bin` | `flag` | 主备 bank 启动标志 |
| `mtd9.bin` | `flagback` | 同上，备份 |

### 备选：没有 U 盘时走网络

原厂 busybox 若有 `nc`，可以流式传出（整片 235 MiB **放不进 `/tmp`**，tmpfs 吃内存，必须边读边传）。

电脑端监听、路由器端发送，逐个分区重复即可：

```sh
# 电脑端
nc -l 5555 > mtd7.bin
```

```sh
# 路由器端
dd if=/dev/mtd7 bs=128k | nc 192.168.1.100 5555
```

先用 `busybox --list | tr ' ' '\n' | grep -E '^(nc|tftp|wget)$'` 确认可用工具。`tftp` 走 UDP 传大文件不可靠，不推荐。

## 二、引导程序：tcboot.bin 与 bootext.ram

两个文件均由 [Nwrt](https://nwrt.kuroneko.host/flashdocs/XG-040G-MD.html) 提供（下载地址见 [README](../README.md#项目说明)），不随本仓库分发。

### tcboot.bin（512 KiB）

| | |
| --- | --- |
| 基础 | [pepe2k/u-boot_mod](https://github.com/pepe2k/u-boot_mod) 的 Web 恢复界面移植到 Airoha AN7581 |
| U-Boot 版本 | 2025.01，自定义版本号 `uboot2.0 version:25.10.01` |
| 结构 | ATF FIP @ `0x800`：BL2 + 6 个签名证书 + BL31(LZMA) + U-Boot(LZMA @ `0x2a400`，解压后 752272 字节) |

**分区表来自设备树，不在 flash 上。** U-Boot 里能看到 `fixed-partitions` 与 `Failed parsing MTD %s OF partitions!` —— 分区定义是 OF(OpenFirmware/DTB) 节点，跟着引导程序和内核走。这一点是后面"分区表不同也能刷回去"的根据。

### Web 恢复界面

**按住 reset 键上电**，U-Boot 在 `192.168.1.1` 启动 HTTP 服务器。四个上传端点，各自执行的命令模板是：

| 端点 | 实际执行 | 写入范围 |
| --- | --- | --- |
| `/uboot` | `mtd write bootloader <addr> 0x0 <len>` | 仅 bootloader 分区 |
| `/firmware` | `mtd write ubi <addr> 0x0 <len>` | 仅 ubi 分区（刷 ImmortalWrt 走这里） |
| `/spinand.html` | `mtd write spi-nand0 <addr> 0x0 <len>` | **整片裸设备，从偏移 0** |
| `/art` | — | 该平台用不到 |

`spi-nand0` 是父设备（整片 256 MiB）而非分区。除 `request for upload < 10 KB data!` 这个下限外**没有大小校验**，长度直接取上传文件的字节数。流程内部是 `mtd erase spi-nand0` + `mtd write` 两步。

**`spinand` 端点就是为整片回刷准备的入口。**

### bootext.ram（127 KiB）

文件头 `01 00 64 aa` 是 ATF 的 FIP magic `0xAA640001`。内容只有 **BL2 + Trusted Boot FW Certificate + 一个 LZMA 解压器**，没有 U-Boot。

它是**最小可用的第一阶段引导**：当 flash 上的引导已被写坏、芯片起不来时，BootROM 从串口把这 127 KiB 收进片上 SRAM 执行，由它**把 DDR 初始化起来**，之后才有几百 MB 内存去装完整 U-Boot。

> ⚠️ **xmodem 只用来传 `bootext.ram` 这种 KB 级的东西，绝不用来传 235 MiB 的整片镜像**（115200 bps ≈ 11 KB/s，要 6 小时以上，且一次 CRC 错就得重来）。

正确的救砖顺序是：**串口注入 `bootext.ram` → DDR 起来 → 灌入完整 U-Boot → 从网口 tftp 刷 flash**。

tcboot 的 U-Boot 里可用的传输手段：

| 方式 | 命令 | 适合 |
| --- | --- | --- |
| xmodem / ymodem / kermit | `loadx` / `loady` / `loadb` | 仅 KB 级 |
| TFTP | `tftpboot`（传完自动设 `$filesize`） | 大镜像的正路 |
| HTTP | `httpd 192.168.1.1` | web 救砖界面 |

## 三、刷回原厂

### 为什么分区表不同不构成障碍

这是最容易被误解的一点。**分区表根本不存在于 flash 上**，它是设备树里的 `fixed-partitions` 节点，跟着引导程序和内核走。同一片 flash，两套尺子：

| 物理偏移 | tcboot 的视角 | 原厂的视角 |
| --- | --- | --- |
| `0x000000` | bootloader (512K) | bootloader (512K) |
| `0x080000` | env (512K) | romfile (256K) |
| `0x0c0000` | ↑ 同上 | kernel / rootfs … |
| `0x100000` | ubi（255 MB，一整块） | bosa / ri / config / data / log … |

而 `mtd write spi-nand0` 写的是**裸设备、按字节偏移**，整个操作**绕开了分区名的概念**。灌进去的就是从物理地址 0 开始的字节流，tcboot 认不认识 `romfile`、`bosa` 这些名字完全无关。

```
写完整片 → reset → 原厂 bl2 起来 → 原厂内核带原厂 DTS
        → 用原厂的尺子去量这片 flash → 数据也是原厂的 → 对得上
```

**分区表是随引导 + 内核一起换回去的，不需要单独刷。**

### 会不会把 tcboot 自己覆盖掉？会，而且这正是目的

回刷原厂本来就要求把 tcboot 换回原厂 bl2。**它不会搞崩当前这次操作**，因为 SPI-NAND **不能 XIP（片上执行）**：开机时 BL2 已把 U-Boot 从 LZMA 解压进 DRAM，此刻整个 U-Boot 在内存里跑，与 flash 上那份副本再无关系。擦掉、覆盖它自己，当前进程毫发无伤，能一路写完再 `reset`。

### ⚠️ 危险窗口

从 `mtd erase spi-nand0` 执行完，到写入完成之前，**flash 上没有任何可引导的东西**。这段时间断电 = 硬砖，只能靠 USB-TTL + `bootext.ram` 从 BootROM 救。

**这就是 USB-TTL 必备的真正理由。** 动手前先确认串口能出日志。

### 路线 A：Web 界面（最省事）

哪个页面取决于机器现在跑的是什么引导器 —— 两个都是按住 reset 上电、浏览器开 `http://192.168.1.1`，内部也都是 `mtd erase spi-nand0` + `mtd write spi-nand0 <addr> 0x0 <len>`：

| 当前引导器 | 页面 | 怎么做 |
| --- | --- | --- |
| `tcboot` | 它自带的 `spinand` 页 | 上传 `all_flash.bin` → 等自动重启 |
| `ubi` | [网页救砖](uboot-http-recovery.md)（`953` 起） | 展开**退回原厂** → 整片恢复选 `all_flash.bin` → 确认 |

`ubi` 那条还能**只恢复一个分区**：下拉选分区名、传对应的那个文件即可，不必刷满 235 MiB。`ri`（256 KiB）是最常用的一个 —— 勾过「先重建 UBI」把出厂 MAC 擦掉之后，写回它就能找回来。

> ⚠️ 235 MiB 要**先整个收进 DRAM**。512M 颗粒等于 U-Boot 加 235 MiB 挤在 512 MiB 里，偏紧；换过 1G/2G 的机器宽裕得多。网页救砖会按实际 DRAM 算上限，放不下会当场拒绝而不是写飞。

### 路线 B：U-Boot 命令行 + TFTP（可控性最好）

串口进命令行（`Hit any key to stop autoboot` 时按键），电脑上开 tftp 服务器：

```
setenv ipaddr 192.168.1.1
setenv serverip 192.168.1.10        # 你电脑的 IP
tftpboot 0x81800000 all_flash.bin   # 传完自动设置 $filesize
mtd erase spi-nand0
mtd write spi-nand0 0x81800000 0x0 $filesize
reset
```

### 路线 C：单分区精修（有坏块时的唯一选择）

web 端点写死了 `0x0` 偏移只能整片，但命令行里 `mtd write` **可以指定偏移**。想只救某几个分区，不必刷整片。以 `ri`（256 KiB）为例：

```
loady 0x81800000                          # 终端侧用 ymodem 发 parts/mtd7-ri.bin
mtd erase spi-nand0 0x5200000 0x40000
mtd write spi-nand0 0x81800000 0x5200000 0x40000
```

按前面的分区表取偏移与大小即可，例如：

```
mtd write spi-nand0 $loadaddr 0x0080000 0x040000    # romfile
mtd write spi-nand0 $loadaddr 0x51c0000 0x040000    # bosa
mtd write spi-nand0 $loadaddr 0x5200000 0x040000    # ri
```

### 三个必须注意的操作细节

* **`mtd write` 不会自动擦除。** U-Boot 的 mtd 命令没有隐式 erase，漏了这步写进去的是脏数据。web 端点内部替你做了，**手动操作时必须自己补上 `mtd erase`**。
* **`off` 和 `size` 都要按 128 KiB 擦除块对齐**，照上面的分区表取值。
* **校验时内存不够。** `mtd read` 回来对比需要第二块等大内存，235 MiB × 2 在 512M 颗粒上放不下。整片刷完建议**只抽查关键分区**：

```
mtd read spi-nand0 0x82000000 0x5200000 0x40000
crc32 0x82000000 0x40000
crc32 0x81800000 0x40000      # 两个值应当一致
```

`romfile`(`0x80000`)、`bosa`(`0x51c0000`)、`ri`(`0x5200000`) 这三个逐机唯一的分区值得逐个这样验一遍。

### 刷完之后

整片写入 235.625 MiB 后，末尾 20.375 MiB 是擦除态（原 tcboot 时代的 ubi 尾巴）。**原厂不使用这段，无影响。**

## 一个更省心的选择

如果主要诉求就是"保留随时刷回原厂的能力"，不该选 `tcboot` 或 `ubi`，而该选 [`stock` 变体](variants.md#stock--寄生原厂分区唯一可回退)：

* 不碰引导程序，变砖风险最低
* `nsb_2` 备份 bank 与全部出厂数据原样保留
* MAC 从原厂 `ri` 经 nvmem 直接读，是真实硬件 MAC

代价只有 rootfs 空间 129 MB（其余三种是 255 MB）。

**要空间选 `ubi`，要退路选 `stock`。`tcboot` 变体已移除，下面关于它的分析只作历史参考。**
