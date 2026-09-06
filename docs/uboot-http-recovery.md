# U-Boot 网页救砖

`ubi` 变体的 U-Boot 里内置了一个恢复页面 —— **Airoha Web U-Boot**。**机器刷坏了，插上网线用浏览器就能救回来** —— 不用串口，不用在电脑上架 TFTP 服务器，不用装任何工具。

当前版本 **0.3.0**，在 `master-airoha` 线上维护，XG-040G-MD 与 XG-040G-MF 共用同一份页面。0.1.x 的开发历史归档在 `archive/master-XG-040G-MD-httpd`。

> 想要图文版、从零开始的操作教程（含实拍接线图与串口截图），见 **[网页救砖指南](https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html)**。本文档是技术参考，覆盖设计取舍与踩过的坑。

> 只对 `ubi` 变体有效。`stock` 用原厂引导，不经过这个 U-Boot。

---

## 怎么用

### 进恢复页

三条路，前两条不需要串口：

| 什么时候 | 怎么进 |
| --- | --- |
| 想主动刷机 | **按住 reset 上电**，一直按着，等面板五个绿灯开始**流水**再松手（约 15 秒） |
| 机器起不来了 | **什么都不用做** —— 从 NAND 引导失败后会自己循环起网页，插上网线即可 |
| 手上接着串口 | 引导菜单上用 ↑/↓ **选到第 9 项** 回车 —— `bootmenu_8` 直接 `httpd`，不经 `_firstboot`，不用掐 reset 的时机 |

这段时间里有一部分是 bootmenu 的等待。`button reset` 读的是那一瞬间的电平，不是累计计时，所以「一直按住」比「按几下」可靠。**流水灯亮起来就是进去了。**

第三条走的是另一条代码路径：`check_buttons` 在 `_firstboot` 里，而第 9 项是 bootmenu 自己的条目，两者互不依赖 —— 所以它在**首次迁移**那种 flash 布局还不对的场景下照样能用，见下面第 ② 步。

### 传文件

1. 网线插到 **LAN 2~4 任意一个**。**LAN 1 无效**：它是 2.5G 口，走 GDM4 接外置 PHY EN8811H，U-Boot 里没有这条通路的驱动，也不带这颗 PHY 每次上电要灌的 MD32 固件；LAN 2~4 挂在 SoC 内置交换机上，U-Boot 只注册了这一个口（串口那行 `Using airoha-gdm1 device`）。换了机型就逐个口试，电脑拿到 `192.168.1.100` 的那个口就是对的
2. 电脑或手机的网口设成自动获取 IP，会拿到 `192.168.1.100`
3. 浏览器打开 **`192.168.1.1`**
4. 左栏「日常刷机」里选 `...-ubi-squashfs-sysupgrade.itb`，点「上传并刷写」
5. 确认框里核对文件名与大小，点「仍要写入」

**不用先配静态 IP** —— U-Boot 里带了个最小 DHCP 服务器，专门为了省掉这一步，那正是救砖流程最容易卡住的地方。

### 页面里有什么

左栏一项一个任务，每页只提交自己那几个字段，所以不存在「这两样不能一起传」的报错：

| 页 | 字段 | C 侧做什么 |
| --- | --- | --- |
| 日常刷机 | `firmware` | `ubi_write_production`：删 `fit` 与 `rootfs_data`，按文件长度重建 `fit` 写入 |
| 引导升级 | `bl2` `fip` `firmware`（可选） `format` | BL2 走 `mtd`；FIP 在位写 `fip` 卷；勾了「重建 UBI」先整个擦掉 `ubi` 分区 |
| 刷回原厂 | `stock` `stockoff` | 裸设备 `mtd erase` + `mtd write`，偏移由 `stockoff` 给，默认 `0x0` 整片 |
| 创建 UBI 卷 | `fvol_<name>`… `ubivol` `ubifile` `stay` | 出厂数据卷按 `HTTPD_FACTORY_VOLS` 校验长度后 `ubi write`；任意卷 `ubi check \|\| ubi create` 再写；`stay` 写完不重启 |
| 设备详情 | — | `GET /info` 返回 JSON：设备树 `model` / `compatible`、DRAM、MTD 几何与分区、MAC、U-Boot 版本、UBI 卷表（含有没有 `fip` 卷）。卷表按卷名排序，ID 列是 UBI 卷号（按创建先后分配，不同迁移路径得到的号不同）；卷没有固定物理地址，所以不列。同一页还有「健康检查」（`GET /check`）与「启动日志」（`GET /log`），见[下一节](#030拦截横幅体检日志) |
| 关于 | — | 静态 |

页面本身**不含任何机型串** —— 机型、闪存、卷表都是请求时读出来的，所以两款机器共用同一份 HTML，第三块板也是。

上传结束设备回一行 `{"ok":1}`，页面自己切到「上传完成」；勾了「写入后不重启」就留在原页、把表单清空。能在上传前查出来的错误 —— 出厂卷长度不对、偏移没按擦除块对齐或超出容量、卷名非法 —— 设备直接回 400，原因显示在进度条下面，此时什么都还没写。

### 0.3.0：拦截、横幅、体检、日志

四样都是同一份用户日志引出来的：机器停在 BL2 报 `No volume named fip` —— BL2 写进去了，`fip` 卷没建。页面当时允许勾「重建 UBI」却只传 BL2，而写入失败只在串口上可见，没串口的用户看到的就是「刷完没反应」。

**两道拦截。** 勾了「重建 UBI」却没选 U-Boot 文件，确认框里不出「仍要写入」；C 侧 `httpd_validate()` 同样拒收（400 `rebuilding UBI without a U-Boot FIP would leave nothing to boot`）—— 页面不是唯一的客户端。另外三条只在页面：闪存里的 UBI 没有 `fip` 卷时，引导升级必须带 U-Boot 文件；UBI 挂不上时，日常刷机与创建 UBI 卷直接拦，引导升级要么勾重建、要么只传 BL2。

**顶部横幅。** `/info` 的 `ubi` 对象多了 `fip` 字段。页面加载后两种情况亮红条：`ubi` 为 `null`（首次迁移：三样一起传并勾重建）；有 UBI 但没 `fip` 卷（现在跑的 U-Boot 只在内存里，断电就没）。串口 xmodem 灌进来的 U-Boot 正是第二种。

**健康检查（`GET /check`）。** 设备详情页一个按钮，C 侧顺序跑：闪存型号；扫全片坏块（`mtd_block_isbad`，落在 `bl2` 分区那块的算异常）；`bl2` 分区 `0x800` 处有没有 FIP 容器头 `0xaa640001` —— BL2 与 FIP 都是 fiptool 打的包，共用这个魔数，原厂与 tcboot 的引导也在同一位置放同一个头，所以它只回答「有没有东西可启动」，分不出是谁的；UBI 能否挂载、卷数、坏块、空闲 LEB；`fip` 卷整卷读一遍（静态卷，UBI 读时校 CRC）再看头；`fit` 卷读头 4 KiB 看 `0xd00dfeed`，并拿 `totalsize` 对卷内长度；`ubootenv` / `ubootenv2` 在不在（名字来自 `CONFIG_ENV_UBI_VOLUME*`）；`HTTPD_FACTORY_VOLS` 里的出厂卷在不在、长度对不对、是不是全 `ff` 的空卷；`HTTPD_FACTORY_MAC`（defconfig 里 `ri:0x3e`）指的出厂 MAC 是否有效、与当前是否一致；`ethaddr` 是否设置。每项绿 / 橙 / 红加一句人话，同一段也打到串口。读取落在 `$loadaddr`，上传进行中回 503。「复制诊断信息」把设备详情与检查结果拼成纯文本，群里求助贴这个。

**启动日志（`GET /log`）。** 打开 U-Boot 自带的 `CONFIG_CONSOLE_RECORD`（64 KiB），把 `gd->console_out` 原样吐出来，页面去掉 ANSI 转义后显示，可复制。`203` 补上一处上游的遗漏：重定位后 `console_record_init()` 重新分配缓冲，重定位前录的横幅、CPU、DRAM 三行会丢，现在先搬过来。缓冲满了不覆盖、只丢新的，末尾标一句「日志缓冲已满」—— 64 KiB 对一次救砖绰绰有余。`/info` 多一个 `log` 字段，没开录制的固件页面不显示这一节。

菜单标题与 `show_about` 跟着升到 0.3.0，`envver` 4 → 5。

### 面板灯是唯一的进度来源

| 面板 | 含义 | 能拔网线吗 |
| --- | --- | --- |
| 五灯**流水** | 在等你上传 | ❌ 还在传 |
| 五灯**齐闪** | 正在写 flash | ✅ 随便拔 |
| 熄灭后重启 | 写完了 | ✅ |

**上传结束后网页就没用了。** `net_loop()` 在写入开始前就返回，连接已经关闭，浏览器和设备之间没有通道 —— 页面上那句「写入期间页面收不到任何消息」说的就是这件事。

拔网线随时安全，写 flash 不经过网络。**要命的是断电** —— 齐闪期间断电才是真的砖。

「写入后不重启」的场合灯会从齐闪回到流水 —— 那就是写完了，可以刷新页面传下一个。写卷期间设备不响应网络，这时再传只会报连接中断。

### 传了固件就等于恢复出厂，只换引导器不是

`ubi_write_production`（写 `fit` 卷）会先删掉 `rootfs_data` 给新卷腾地方，所以**这次上传里只要带了固件，配置必然被清空**，勾没勾别的选项都一样。

**只传 `preloader.bin` / `bl31-uboot.fip`、不传固件**的那种日常更新引导器则不清配置。`954` 之前会 —— 那是个 bug，见补丁清单里 `954` 那节。

系统还能进的话，请用 `sysupgrade -c` 保留配置。这个页面的定位是「系统起不来了」。

---

## 首次迁移：从 tcboot / 原厂 换到 ubi 布局

只有这一次需要串口，之后再也不用。

**① 串口进 BootROM，xmodem 传两个文件**

按住 reset 上电，看到 `Press x` 时按 `x`，依次传：

```
immortalwrt-airoha-an7581-nokia_xg-040g-md-ubi-preloader.bin      ← BootROM 收，进 SRAM
immortalwrt-airoha-an7581-nokia_xg-040g-md-ubi-bl31-uboot.fip     ← BL2 收，进 DRAM
```

传两个是硬约束：BootROM 只把 BL2 收进 SRAM，那里放不下 431 KB，它也不解析 FIP 里的 BL33。

**reset 一直按着不要松** —— 或者想好了走下一步那张表里「菜单上选第 9 项」那一行。

**② U-Boot 在 RAM 里起来，直接进网页**

两种走法，任选一种：

| 走法 | 做什么 | 代价 |
| --- | --- | --- |
| **reset 一直按着** | 让 bootmenu 自己超时进 `_firstboot`，`check_buttons` 接住 | 没有时间窗口，最稳 |
| **菜单上选第 9 项** | `bootmenu_8` 直接 `httpd`，根本不进 `_firstboot` | 只有 `bootdelay=3` 那 3 秒 |

`_firstboot` 的第一件事就是 `run check_buttons` —— 在碰 flash 之前先看按键。这一刀是「一轮 xmodem 就够」的全部依据：没有它，RAM 里的 U-Boot 会直奔 `_init_env`，在异构 flash 布局上建卷失败、回落 `ubi_format` 然后 `reset`，把刚传进来的东西一起丢掉。

> 第 9 项绕开了这整条路径，所以它不需要 `check_buttons` 保护。但**两者必须命中一个** —— 既松了 reset、又没在 3 秒内选中第 9 项回车，菜单超时进 `_firstboot`，`check_buttons` 不成立，上面那条 `ubi_format` + `reset` 的路就走实了，这一轮 xmodem 白传，回 ① 重来。不伤 flash，只伤时间。

看到流水灯就成了（按着 reset 的这时松手）。

**③ 网页一次传完三样**

左栏切到「引导升级」：

| 格子 | 文件 |
| --- | --- |
| BL2 | `...-ubi-preloader.bin` |
| U-Boot | `...-ubi-bl31-uboot.fip` |
| 固件 | `...-ubi-squashfs-sysupgrade.itb` |
| 重建 UBI（开关） | **必须打开** —— 旧布局上没有有效的 UBI，不擦就建不了卷 |

**④ 自动重启，完成**

`_firstboot` 会建出 `ubootenv` / `ubootenv2` / `ri` / `bosa`，然后正常引导。

> ⚠️ **重建 UBI 会擦掉出厂 MAC。** `ri` 卷没了，`ethaddr_factory` 读不到，MAC 变成默认值。从[原厂备份](backup-and-restore.md)里把 `ri` 写回去即可，随时能做，不影响使用。

### 日常更新引导器就不用勾了

BL2 走 `mtd`，完全不碰 UBI；FIP 走 `httpd_write_fip`，它自己只换 `fip` 那一个卷，连 `rootfs_data` 都不动（`954`，见下）。**只要 `ubi part ubi` 挂得上，就不要开重建。**

覆盖正在运行的 U-Boot 是安全的：SPI-NAND 不能 XIP，当前这份早就解压在 DRAM 里跑了，和 flash 上的副本没关系。

---

## 补丁清单

都在 `package/boot/uboot-airoha/patches/`：

| 补丁 | 做什么 |
| --- | --- |
| `202-net-add-httpd-recovery-server` | 全部的 httpd —— 新增 `net/httpd.c`，外加 `net.c` / `Kconfig` / `Makefile` / `net-legacy.h` 四处挂接；`Kconfig` 里四个选项：`CMD_HTTPD`、`HTTPD_FACTORY_VOLS`（出厂数据卷名与长度）、`HTTPD_FACTORY_MAC`（出厂 MAC 在哪个卷的哪个偏移）、`CMD_HTTPD_STOCK_RESTORE`（按板启用裸写） |
| `203-console-record-keep-pre-relocation-output` | 重定位后保留重定位前的 console 录制内容，`GET /log` 才能从横幅看起 |
| `950-configs-xg-040g-md-enable-httpd` | MD defconfig：`PROT_TCP` / `CMD_HTTPD` / `CYCLIC`，`HTTPD_FACTORY_VOLS="ri:0x40000 bosa:0x40000"`，`HTTPD_FACTORY_MAC="ri:0x3e"`，`CMD_HTTPD_STOCK_RESTORE=y`，`CONSOLE_RECORD` 64 KiB |
| `951-defenvs-xg-040g-md-httpd-recovery` | MD 触发路径，与两条 httpd 专用的 env 脚本 |
| `952-xg-040g-md-bootmenu-web-recovery-branding` | MD 引导菜单署名、手动开服务的菜单项、`envver` 自动刷新、`ethaddr` 两道闸 |
| `954-xg-040g-md-httpd-fip-preserve-rootfs-data` | MD defenv 加 `httpd_write_fip`（网页更新引导器不清配置） |
| `960` / `961` / `962` | MF 的同一套：defconfig、触发路径、菜单 |

页面本身不在补丁里手改：源文件是 fork 的 `package/boot/uboot-airoha/files/httpd/page.html`，`gen.py` 把它逐行转成 C 字符串塞进 `net/httpd.c` 的 `PAGE_BEGIN` / `PAGE_END` 之间。改页面 → 跑脚本 → 重新生成 `202`。

0.1.x 里 `953`（刷回原厂）和 `954`（`httpd_write_fip`）各自带的 `net/httpd.c` 片段在 0.2.0 都并回了 `202`，理由和下面那段一样：它们改的是同一个我们自己新增的文件。剩下的按板差异全部退到 defconfig 与 defenv 里。

`206`（DRAM 容量探测）编号挨着但**与网页救砖无关**，是独立的 bug 修复，影响所有 an7581 设备 —— 见[设备变体 → 内存容量](variants.md#内存容量)。分开放是为了以后单独提上游时不用再拆。

> **为什么只有一个 httpd 补丁**
>
> 开发时它是五个（骨架 → 上传 → DHCP 与面板灯 → 引导器 → 页面），合进主线时压成了一个。
>
> `patches/` 目录的语义是「**对上游源码的修改集**」，不是提交历史。`net/httpd.c` 是我们新增的文件，让它被五个补丁层层重写的代价是实打实的：构建时同一个文件反复 apply 五次、想知道最终形态得在脑子里叠四层 diff、上游同步时冲突面变成五份。而且没有哪一层是可以单独回退的 —— 你不会想只去掉「DHCP」或「页面」，它们本来就是一个功能。
>
> 对照同目录里合理的分法：`100`–`111` 是 backport，一个补丁对应上游一个 commit；`200` / `201` 是两件互不相干的事。**分开要有理由，「开发时是分步做的」不算理由。**
>
> 开发过程的原貌（五个补丁、21 个提交）留在 `archive/master-XG-040G-MD-httpd`。

### `951` 改了什么

```
check_buttons=if button reset ; then httpd ; fi              ← 原来是 run boot_tftp
boot_ubi=run boot_production ; run boot_httpd_forever        ← 原来是 boot_tftp_forever
boot_httpd_forever=while true ; do httpd ; sleep 1 ; done    ← 新增
_firstboot=... ; run check_buttons ; run ethaddr_factory ...  ← 开头插入按键检查
httpd_write_bl2=mtd erase bl2 && mtd write bl2 $loadaddr 0x800 $filesize
httpd_format_ubi=ubi detach ; mtd erase ubi && ubi part ubi
```

`httpd_write_bl2` 用 `mtd write` 的 offset 参数让 mtd 自己跳过前 `0x800` 字节（BootROM 在那里找 FIP），省掉官方脚本里 `mw.b $loadaddr 0xff 0x800` 那一步 —— 因为 part 是**就地刷写**的，不搬到 `$loadaddr`。

`httpd_format_ubi` 是去掉 `reset` 的 `ubi_format`，好让同一次会话接着写卷。

**TFTP 一条没删**：bootmenu 的第 2、4、5、6 项照旧，`boot_tftp*` 全套变量都在。自动路径走浏览器，手动路径留 TFTP。

### `952` 改了什么

菜单原来看不出这是哪来的固件 —— 和一份原厂 UBI 引导长得一模一样，进到菜单里的人也没有路径找回项目。

```
bootmenu_title=  \e[1;39mAiroha Web U-Boot 0.2.0\e[0m    ← 加了版本号，并去掉原来的三对括号
bootmenu_8=\e[31mStart web recovery server (http://192.168.1.1)\e[0m=httpd ; run bootmenu_confirm_return
bootmenu_9=About - github.com/Loong1996/ImmortalWrt-Airoha=run show_about ; run bootmenu_confirm_return
show_about=echo ; echo Web recovery U-Boot by Loong ; echo Guide: ... ; echo Project: ... ; echo Author: ... ; echo
```

`httpd_start_server()` 开头也照着打一遍，给看串口、不看网页的人：

```
Airoha Web U-Boot 0.2.0 by Loong
Project https://github.com/Loong1996/ImmortalWrt-Airoha
Guide   https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html
Using airoha-gdm1 device, MAC xx:xx:xx:xx:xx:xx
Listening for HTTP on 192.168.1.1 port 80
Handing out DHCP leases from 192.168.1.1
Press Ctrl-C to abort
```

**那行 MAC 是排障用的，不是装饰。** `net_check_prereq()` 只对 `BOOTP` / `DHCP` / `LINKLOCAL` 那一支校验 MAC，`HTTPD` 走的是 `FASTBOOT_*` / `TFTPSRV` 那一支，只检查 IP。所以出厂 MAC 丢了、`CONFIG_NET_RANDOM_ETHADDR` 顶上随机 MAC 的板子，一样会打印 `Listening for HTTP`，一样什么都不回 —— 浏览器还在按 ARP 缓存里的旧 MAC 发包。**「服务起来了但页面打不开」，先看这一行。**

几处需要知道的：

- **屏幕上显示 9 和 10，env 里是 `bootmenu_8` / `bootmenu_9`。** `cmd/bootmenu.c` 的快捷键是 `'1' + index`，下标 0 那项画成「1.」。
- **第 10 项画出来是「a.」不是「10.」。** 快捷键只有一个字符：1–9 之后接 a–z，0 留给 Exit。所以仓库地址写在标题里而不是藏在按键后面 —— 不按也要能看见，按下去才补上作者页。
- **标题去掉了原来的 `( ( ( ... ) ) )`。** 标题从第 3 列画起（`bootmenu_print_entry` 用 `ANSI_CURSOR_POSITION`），而 `_bootmenu_update_title` 会把完整的 `$ver`（72 字符）追加在后面。80 列下留给 `$ver` 的只有 36 列，版本号后半截连 commit hash 一起被截掉；去掉那三对括号腾出 12 列，r 号和 hash 就都能看全了（日期仍会截，无所谓）。末尾补了 `\e[0m`，免得 `_bootmenu_update_title` 没跑时后面的输出继承亮白。
- **第 9 项是红的**，和写引导器的那两项同色：它是刷机入口，且一旦进去，机器就离开菜单直到被中断。
- **版本号写了两遍**：`bootmenu_title` 里一份（`952`），`net/httpd.c` 的 `WEB_VERSION` 一份（`202`）。env 是纯文本，看不见 C 宏。改版本要同时动这两个补丁（MF 还有 `962`），并把 `envver` 加一 —— 网页侧栏那个 `0.2.0` 用的就是后者。

> **老机器升级引导器后看不到新菜单 —— `envver` 之后会自动处理。**
>
> `CONFIG_ENV_IS_IN_UBI`：`ubootenv` 卷里存的是**完整一份**环境，加载时整个盖掉编译进固件的默认值。已经初始化过 env 的机器换了新 FIP，菜单还是旧的 —— 新加的 `bootmenu_8` / `bootmenu_9` 根本不在它的环境里。
>
> `952` 加了自动刷新（见下一节 [`envver`](#envver-新-u-boot-自己刷新落后的菜单)），**从 `envver=1` 这版固件开始**升级引导器就不用手动做什么了。手动的办法留着备用：菜单选 `0. Exit` 进命令行，跑：
>
> ```
> env default -a -k
> saveenv
> reset
> ```
>
> `-k` 是 `H_NOCLEAR`：**不清空现有环境**，只把默认环境覆盖上去。默认环境里没有 `ethaddr` 这一行，所以 MAC 留得住 —— 这正是它比第 8 项 `Reset all settings to factory defaults` 好的地方，后者把 `ubootenv` 卷整个清零，`ethaddr` 跟着一起没。`env default` 也能把 saved env 里**根本不存在**的变量补进来（`env_set_default_vars()` 直接从 `default_environment` 导入），所以新增的 `bootmenu_8` / `bootmenu_9` 是能这样加进去的。
>
> 只想动某几个变量就点名：`env default -f bootmenu_title bootmenu_8 bootmenu_9`。
>
> 首次迁移过来的机器走 `_firstboot`，直接就是新的，不用管这一段。

### `envver`：新 U-Boot 自己刷新落后的菜单

默认环境里带一个 `envver`，`board/airoha/an7581/an7581_rfb.c` 里挂一个 `EVT_POST_PREBOOT` 钩子：saved env 的 `envver` 落后于编译进去的默认值，就把描述菜单的那几个变量重新导入一遍，然后 `saveenv`。

时机在 `preboot` 跑完之后、`bootdelay_process()` 和 `autoboot_command()` 画菜单之前 —— env 已加载，菜单还没画。

重新导入的**只有**这些：

```
envver  bootmenu_title  bootmenu_1..bootmenu_9  show_about
```

运行时状态刻意不在列表里：`bootdelay` / `bootmenu_delay`（`_switch_to_menu` 把 0 抬到 3，重置会让菜单闪现即超时）、`bootmenu_0`（初始化后被换成 `bootmenu_0d` 的内容）、还有 `ethaddr` —— 它压根不在默认环境里，`env_set_default_vars()` 的 import 碰不到它。**这就是它比 `env default -a -k` 温和的地方**，后者会把 59 个变量全推平。

> **为什么放在启动时，而不是刷 FIP 的时候**
>
> `env default` 导入的是**当前正在运行的**那个 U-Boot 编译进去的 `default_environment`。刷 FIP 时顺手刷新，装进 env 卷的是**旧版**的默认值 —— 菜单会永远落后固件一版。刚写进 flash 的新 FIP 还没运行，它的默认环境此刻根本不在内存里。**只有新 U-Boot 自己能做对这件事。**
>
> 顺带解释了菜单第 5 项 `boot_tftp_write_fip` 为什么刷完要 `run reset_factory`：清空 env 卷不是「导入旧默认值」，是让新 U-Boot 启动时发现 env 无效、回落到自己的默认环境。那条路是对的，代价是 `ethaddr` 跟着一起没。

改菜单时记得 `envver` 加一，否则老机器不会刷新。

> **刷新之后要自己把 `$ver` 补回标题。**
>
> 追加版本号的 `_bootmenu_update_title` 第一件事就是 `setenv _bootmenu_update_title` 把自己清空 —— 它只为「环境首次初始化」而存在。所以钩子重新导入 `bootmenu_title` 之后，saved env 里已经没有任何人能把版本号加回去，菜单会一直显示没有版本的标题。这是从 0.1.0 网页直接升上来的机器踩到的：菜单项全对，标题却光秃秃。
>
> 现在由钩子自己补。两条路不会重复追加：**环境被重建**时跑的是那个 env 脚本，而那种情况下 `envver` 恰好匹配、钩子不触发；**固件升级**时钩子触发，而脚本早已自删除。钩子放在共用的 an7581 board 文件里是安全的：别的板子默认环境里没有 `envver`，`env_get_default_into()` 返回负值就直接 return。`saveenv` 是尽力而为 —— 首次迁移会在 `_init_env` 建出 env 卷之前走到这里，而它本来就跑在默认环境上，不需要这次写入。

### 刷回原厂与写入偏移（`CMD_HTTPD_STOCK_RESTORE`）

回原厂原本是这个页面唯一去不了的方向 —— 要么用 tcboot 自带的 web 界面（迁走之后它就没了），要么串口加 TFTP 服务器，而后者正是这个页面存在的意义所在。

**为什么一个只有 `bl2` + `ubi` 布局的 U-Boot 能刷回原厂布局：** 分区表不在 flash 上，它来自设备树，跟着引导程序和内核一起走。把原厂字节写回原厂偏移，原厂的分区表也就跟着回来了。`mtd write` 对裸设备按字节偏移写，从不过问分区叫什么。

必须用裸设备也是同一个原因：`bl2` 到 `0x20000` 结束、`ubi` 从那里开始，**谁都够不到从偏移 0 起的整片写入**。裸设备不再写死 `spi-nand0`，是运行时取「不属于任何分区的那个 MTD」。

页面上是一个文件加一个「写入偏移」，默认 `0x0`：

| 偏移 | 效果 |
| --- | --- |
| `0x0` + 整片 `all_flash.bin` | 真正退回原厂，本页面随之消失 |
| 某个原厂分区的起始，如 `0xC0000` + 那个分区的备份 | 只写那一段 |

C 侧只查两件事，都在上传时查、查不过回 400：偏移按擦除块对齐，偏移加长度不超过容量。**不校验镜像内容，也不校验机型** —— MD 与 MF 的 `all_flash.bin` 长度相同、布局相同，页面分辨不出来，刷错机型之后只能靠串口。擦除长度按擦除块向上取整（`mtd erase` 拒绝非整数倍的长度），写入长度就是文件长度。

出厂数据 `ri` / `bosa` 不在这一页，在「创建 UBI 卷」页的「出厂数据」组：

> ### ⚠️ 单个出厂数据只能按 UBI 卷写，不能按原厂偏移裸写
>
> 原厂把 `ri` 放在物理偏移 `0x5200000`，而这套布局的 `ubi` 分区是 `0x20000`~`0x10000000` —— **那个偏移在 ubi 肚子里 80 MiB 处**。
>
> 往那儿 `mtd write`：
>
> 1. 会撕掉 UBI 每个 PEB 的 EC / VID header，连卷表一起毁掉；
> 2. **而且根本达不到目的** —— `ethaddr_factory` 执行的是 `ubi read 0x90000000 ri`，读的是**卷**，从来不是那个物理偏移。
>
> 两个 `ri` 只是同名：内容一样、长度一样、MAC 同样在 `+0x3e`，**容器不同**。所以恢复它要用 `ubi write $loadaddr ri 0x40000`。
>
> 同理，原厂那 13 个 mtd 分区在 ubi 布局下**无一例外落在 ubi 区内，没有一个能安全写**。「写入偏移」是给已经退回原厂布局、或者明知自己在干什么的人用的。

哪些卷算出厂数据、各多长，由 defconfig 里的 `CONFIG_HTTPD_FACTORY_VOLS="ri:0x40000 bosa:0x40000"` 说了算；`net/httpd.c` 里没有卷名。页面从 `/info` 拿到这个列表后才画出那两行，字段名是 `fvol_<卷名>`。长度必须正好相等，差一个字节都拒收 —— 这是 MAC 所在的卷。

「任意卷」那一组是 `ubi check <name> || ubi create <name> <文件长度> dynamic` 再 `ubi write`：卷在就在位写，不在就按文件长度建。这里故意不查长度 —— `ubi write` 自己会在动手前拒绝超出预留的写入，它知道真实数字而这里只能猜。

**`UPLOAD_MAX` 按 DRAM 实算。** 上传落在 `$loadaddr` 就地刷写，所以能放多大取决于它上面还剩多少内存：512M 的机器放下 235.6 MiB 后余量约 20 MiB。固定的 96 MiB 会直接拒收原厂镜像，而单纯把常数调大又会让更大的文件写出内存边界。

### `ri` 卷空了会读出一个广播 MAC

`ethaddr_factory` 从 `ri` 卷偏移 `0x3e` 读 6 字节当出厂 MAC。**勾过「先重建 UBI」的机器，`ri` 是 `ubi_create_board_data` 重新建的空卷**，读到的是擦除态 —— `ff:ff:ff:ff:ff:ff`。

它会被一路用下去，因为 `net/eth-uclass.c` 判断环境里的 MAC 时只调 `is_zero_ethaddr()`，不调 `is_valid_ethaddr()`：

```c
if (!is_zero_ethaddr(env_enetaddr)) {
        memcpy(pdata->enetaddr, env_enetaddr, ARP_HLEN);   /* 全 FF 从这里进来 */
} else if (is_valid_ethaddr(pdata->enetaddr)) {
} else if (... !is_valid_ethaddr(...)) {
        net_random_ethaddr(...);      /* 全 FF 走不到，所以没有随机 MAC 警告 */
}
```

于是广播地址被当成**源地址**发出去。症状很有迷惑性：DHCP 那行照常成功（DHCP 本来就是广播），单播回包被对端网卡丢掉，**网页打不开而串口一切正常**。

`952` 从两头堵：

- **`ethaddr_factory` 改成按读到的值判断** —— 读进临时变量 `_mac`，拿到可用的值才赋给 `ethaddr`；读到擦除态就什么都不动。
- **C 侧在 `EVT_SETTINGS_R` 兜底** —— saved env 里已经存着全 FF 的机器，`ethaddr_factory` 早就自删除了、这辈子不会再跑，只能在这里丢掉它，让 U-Boot 自己的随机 MAC 分支接手（会打印 `using random MAC address`）。

> **为什么不能用「`ethaddr` 已有值就不读 `ri`」这种写法**（我先写错过一版）
>
> `_firstboot` 是从 bootmenu 里跑的，**远在 `initr_net()` 之后**。一块没有 MAC 的板子到那时早就被 `eth-uclass` 生成了随机地址，并且由 `eth_env_set_enetaddr_by_index()` **写进了 env**。于是这个判断必然成立，`ri` 里的真地址在 `reset_factory` 之后**永远读不回来**。
>
> 按值判断则两件事一起做到了：`ri` 有真值就盖掉生成的随机地址，`ri` 是擦除态就不动 —— 后者同时保护了手工 `setenv` 进去的 MAC。

出厂 MAC 一旦随 `ri` 卷擦掉就找不回来了，机身标签是唯一的真值来源。

### `954`：日常更新引导器不再清配置

**症状**：从网页 0.1.0 升到 0.1.1，只传了 `preloader.bin` 和 `bl31-uboot.fip`、**没传固件**，
结果 OpenWrt 的设置全没了。固件（`fit` 卷）自始至终没被碰过 —— 消失的是 overlay。

**原因**：网页上「U-Boot」那一格当时借用了板子自己的 `ubi_write_fip`：

```
ubi_write_fip=run ubi_remove_rootfs ; ubi check fip && ubi remove fip ; \
              ubi create fip 0x100000 static && ubi write $loadaddr fip $filesize
```

`ubi_remove_rootfs` 删的 `rootfs_data`，正是 UBIFS 挂在 `fit` 里那个只读 squashfs 上面的
可写层，装着首次启动之后的每一处配置改动。下次开机 `ubi_prepare_rootfs` 发现它不在，
建一个空的顶上 —— 从 OpenWrt 那边看，和恢复出厂一模一样。

**`ubi_write_fip` 本身没有错，也没有被改。** 它是板子的原始脚本（`defenvs` 里的，比网页救砖
这个功能还早），给 bootmenu 第 4 项用，而那一项刷完紧跟着 `run reset_factory` —— 那是一次
**刻意的完整重置**，丢掉 `rootfs_data` 是它的本意。网页把同一个脚本拿去做一次例行的引导器
更新，是两件语义不同的事。**bug 在这次借用，不在被借的脚本。**

而且那对 remove/create 在这里本来就不承重：`fip` 每次都建在固定的 `0x100000`，对一个已经
存在的 `fip` 就地 `ubi write` 装得进它自己现有的预留，不需要先释放什么。删掉再按同样大小
建回来，净收益是零 —— `vmt.c` 里 `ubi_remove_volume()` 把 `reserved_pebs` 还给 `avail_pebs`，
`ubi_create_volume()` 紧接着又原样要回同样多。

所以拆出一条独立的 `httpd_write_fip`（和 `httpd_write_bl2` 挨着 `mtd_write_bl2` 是同一个套路），
将来改动 TFTP 菜单那条重置流程、或是网页这条例行更新流程，都不会悄悄改掉另一条的行为：

```
httpd_write_fip=if ubi check fip ; then ubi write $loadaddr fip $filesize ; else run ubi_write_fip ; fi
```

只有 `fip` **还不存在**时（首次迁移，那时 `rootfs_data` 同样还不存在）才需要建卷，
也只有那时驱逐 `rootfs_data` 是无害的 —— 那一支直接 `run ubi_write_fip` 复用原脚本，
不重复一遍建卷逻辑。走到那里时它自己的 `ubi check fip && ubi remove fip` 恰好是空操作。

> **新的 fip 比旧的小，就地写会不会留下旧数据的尾巴？** 不会。`ubi write` 不是「覆盖前 N
> 个字节」，是 UBI 的 volume update 语义 —— `drivers/mtd/ubi/upd.c` 的 `ubi_start_update()`
> 在写第一个字节之前，先把卷的 `reserved_pebs` 挨个 `ubi_eba_unmap_leb()`，注释写得很直白：
> `/* Before updating - wipe out the volume */`。整卷清空，旧内容一个字节都不剩。
>
> `fip` 是静态卷，收尾的 `clear_update_marker()` 会按新长度重算 `used_bytes` / `used_ebs` /
> `last_eb_bytes`，读的时候只读这么多。
>
> 反方向也有闸：新 fip 要是大过卷的预留，`cmd/ubi.c` 在动手之前就 `size > volume size!
> Aborting!` 退出，不会写一半坏在那儿。加上 `set_update_marker()` 先落盘、写完才清 ——
> 中途掉电下次挂载会认出这个卷无效，不会拿半个 fip 去引导。
>
> 参考量级：`fip` 卷预留 `0x100000`（1 MiB），实际的 `bl31-uboot.fip` 约 318 KiB，用掉 31%。

**BL2 从头到尾不涉及。** `httpd_write_bl2` 是朴素的 `mtd erase bl2 && mtd write bl2`，
操作的是 `bl2` 这个 mtd 分区（`0x0`~`0x20000`），完全在 `ubi` 分区（`0x20000` 往后）之外 ——
而 `rootfs_data` 和其它所有 UBI 卷都住在后者里。升级时连着 FIP 一起刷 BL2，对配置没有风险。

---

## 几个关键决定

### 用 U-Boot 自己的 TCP，不移植 uIP

tcboot 里嵌了 uIP 0.9（响应头 `Server: uIP/0.9`），因为它的基础 U-Boot 还没有 TCP 栈。现代 U-Boot 有 `net/tcp.c`，`net/fastboot_tcp.c` 就是现成的 TCP 服务器模板。

| | 移植 uIP | 用自带 TCP |
| --- | --- | --- |
| 新增代码 | ~4000 行 | ~130 行（202 的规模） |
| 与 tftpboot / dhcp 共存 | 要处理两套栈抢网卡 | 天然共存 |
| 上游可维护性 | 长期背一份 fork | 跟着上游走 |

### 零拷贝

`rx()` 回调给的是**流偏移**，所以可以直接 `memcpy` 到 `$loadaddr + offset`，几十 MB 的镜像不需要第二份内存。各个 part 也是**就地刷写**，不搬移 —— 只在刷之前按 64 字节向前对齐一下，踩到的是它自己的 multipart 头（最短也有 ~90 字节），碰不到前一个 part 的数据。

### 刷写逻辑留在 env 里，但不依赖它

每一步优先跑 env 脚本，找不到就用编译进二进制的等价命令。这不是冗余 —— 见下面的坑。

### 面板灯是刷写阶段唯一的通道

写入是同步阻塞的，`net_loop()` 的 timeout handler 那时已经停了。闪灯靠 cyclic 框架驱动：SPI-NAND 层每写一页调一次 `schedule()`（`drivers/mtd/nand/spi/core.c`），所以 64 MB 的写入过程中灯照样闪。

`CONFIG_CYCLIC_MAX_CPU_TIME_US` 默认 5000 μs，写 5 个 GPIO 够不着。万一超了会打印 `cyclic function httpd-flash took too long` 并注销回调 —— **灯停在某个状态，但刷写完全不受影响，别当成死机去断电。**

### 确认框每次都弹，但只拦真错的

按钮按下去先弹一个框：列出这次要传的文件名与大小，下面是这一页对应的提示 —— 会清 `rootfs_data`、会擦出厂 MAC、写完不重启要手动断电、整片写入之后本页面就没了。红色「仍要写入」才真的发。

拦死（按钮不出现）的只有页面自己能判定的硬错误：没选文件、卷名非法或缺一半、偏移不是十六进制、没按擦除块对齐、超出容量；0.3.0 起还有勾了重建 UBI 却没选 U-Boot、闪存里没 `fip` 卷却没传 U-Boot、UBI 挂不上却要写卷（见[上面](#030拦截横幅体检日志)）。**文件名与常规命名不符只提醒不拦** —— 文件名是可以被改的，而 `.itb` 进了 BL2 格的后果（写到 flash `0x800`，BootROM 认不出，只能串口 xmodem）确实值得一句提醒。

一页一个任务本身就消灭了原来一半的报错：「退回原厂不能和刷固件同时」「写入指定卷不能和其它写入同时」这类互斥不再需要说，因为表单结构上就做不到。

---

## 踩过的坑

### 1. `simple_strtoul()` 不跳前导空白

```
httpd: refusing 0 byte upload
```

`Content-Length: 12345` 从冒号后解析，U-Boot 的 `simple_strtoul()` 遇到空格直接返回 0（`lib/strto.c` 只处理 `0x` 前缀），和 libc 的行为不一样。

**这个坑差点被测试掩盖过去** —— 桩代码用的是 libc 的 `strtoul`，它会跳空白，所以本地全过、真机必挂。后来把桩改成忠实复现 U-Boot 的行为，才在本地复现出同一条错误信息。**桩要模仿被测环境的怪癖，不是模仿正确行为。**

### 2. 救砖工具不能依赖 flash 上的 env

```
## Error: "httpd_write_bl2" not defined
```

机器上一次测试时 `_firstboot` 建过 `ubootenv` 卷并 `saveenv`，那份旧 env 会盖掉 fip 里编译进去的默认值。**救砖工具依赖 flash 上的 env，而 flash 上的 env 恰恰是最可能过时或损坏的那份** —— 需要救砖的时候，正是它靠不住的时候。

现在每步都有内置兜底。

好在 BL2 是第一步，它一失败整个序列就中止，UBI 没被格式化、`fit` 卷完好 —— 「引导器先于固件」这个顺序在这里兜住了。

### 3. 分类要放在 `on_rcv_nxt_update()`，不能放 `rx()`

`rx()` 收到的第一个 TCP 段可能短于 4 字节，`memcmp(buf, "POST", 4)` 就越界了。`on_rcv_nxt_update()` 保证 `[0..rx_bytes-1]` 已经连续到齐。

这个是**测试抓出来的**，用 `chunk=1`（每次只喂 1 字节）跑的时候暴露。

### 4. defenv 的 patch context 要从 fork 里取

从 `openwrt/openwrt` 抄的 context 里 `bootfile*` 是 `openwrt-` 前缀，ImmortalWrt 是 `immortalwrt-` —— `Hunk #1 FAILED`，白等一个半小时。

**改哪棵树就从哪棵树取 context。**

### 5. 编译期宏的中文不要用 `\x` 转义

页脚一度显示 `U-Boot ç½é¡µæç `。生成补丁的脚本里我用了 `'\xe7\xbd\x91'` 写「网」，Python 把它当成三个 Latin-1 字符，写文件时又编了一遍 UTF-8：

```
应该是:  e7 bd 91           网
实际是:  c3 a7 c2 bd c2 91  ç½
```

现在源码里直接写中文，并加了一条检查：不许出现 `c3 a7 c2` 这类双重编码序列。

### 6. 验证判据本身也会错

给 `999` 测试补丁写验证方法时，我说「看串口有没有打印 `*** TEST BUILD ***`」。它永远不会出现 —— `bootcmd` 只有经 bootmenu 第 0 项才会被执行，而那个补丁把 `bootmenu_delay` 设成了 `-1`，菜单根本不往下走。正确判据是「停在菜单上」。

**一个编译要一个半小时，判据写错的代价和代码写错一样大。**

---

## 验证方式

每次改动都跑三层，真机编译一次约 1.5 小时，所以前两层要在本地过：

1. **页面** —— `page.html` 在 jsdom 里跑 20 个用例：`/info` 填表与失败降级、每一页的确认框内容与拦截条件、实际提交的 `FormData` 字段集、多文件上传进度按累计长度定位、200 / 400 / 断网三种结局、「不重启」留页并清空表单、无 `STOCK_RESTORE` 编译时没有那一页。用例在 scratchpad，跑的是真实的页面源文件
2. **编译** —— 整个补丁序列打到纯净的 U-Boot 2026.07 上，在 Docker 里（本机已有的 `ghcr.io/openwrt/buildbot/buildworker` 镜像加 `gcc-aarch64-linux-gnu`）对 MD、MF 两个 defconfig 各编一遍 `net/httpd.o` 与完整 `u-boot.bin`。0.1.x 只做语法级检查，漏过一次把 `flash_part()` 圈进 `#if` 的编译错误，这一层就是为它加的
3. **补丁** —— 53 个补丁 `patch -p1` 顺序应用无 offset / fuzz（`120` / `121` 是 CRLF，macOS 的 patch 要先 `tr -d '\r'`，CI 的 GNU patch 自己处理）

刷之前从 fip 里解出 U-Boot 二进制核对一遍：

```bash
python3 - "$FIP" <<'EOF'
import sys, lzma
d = open(sys.argv[1], 'rb').read()
off = 0x10
while off + 40 <= len(d):
    uuid = d[off:off+16]
    o = int.from_bytes(d[off+16:off+24], 'little')
    sz = int.from_bytes(d[off+24:off+32], 'little')
    if uuid == b'\0' * 16:
        break
    blob = d[o:o+sz]
    if blob[:1] == b'\x5d':                       # FIP 第二段是 LZMA 压的 U-Boot
        open('uboot.bin', 'wb').write(
            lzma.LZMADecompressor(lzma.FORMAT_ALONE).decompress(blob))
    off += 40
EOF
strings -a uboot.bin | grep -E 'U-Boot 20'        # 版本串带源码 commit
strings -a uboot.bin | grep -E '^(check_buttons|boot_ubi|httpd_)'
```

版本串里嵌着源码的 commit sha，可以确认刷的到底是哪一版。中文要按 UTF-8 字节搜（`grep -a`），`strings` 只认 ASCII。

---

## 还没做的

* **刷写进度做不到。** 不是没做，是结构上不行：`net_loop()` 在写入开始前就返回，连接已关，页面轮询没人应答。要做就得把刷写拆进网络循环里分块跑 —— 那是把一条简单可靠的救砖路径换成一个状态机，对救砖场景不划算。
* **写入结果回报。** 「写入后不重启」之后页面不知道写没写成。C 侧存一条结果、加 `GET /status`，页面在服务恢复后轮询一次，就能显示「ri 卷写入成功」或错误 —— 顺带可以给一个「立即重启」按钮。
* **写入前魔数校验。** FIT `0xd00dfeed`、FIP `0xaa640001`、BL2 头，C 侧写之前查一眼。文件名检查是软的，这个是硬的。
* **备份下载。** `GET /dump?vol=ri` 之类。刷回原厂那一页最需要的其实是「先把现在的备份下来」。
* **LAN 1（2.5G 口）。** 要在 U-Boot 设备树里打开 `gdm4`、在 switch 的 mdio 上挂 `0x0f` 的 EN8811H、开 `PHY_AIROHA`，再把 144 KiB 的 MD32 固件放到 U-Boot 读得到的地方（比如一个 UBI 卷）由 env 脚本 `en8811h_load_firmware` 载入。整棵 U-Boot 树里只有 EVB 板用过 `gdm4`，没人在真机上验证过；收益只是多一个口，暂不做。
* **推上游。** `206` 是实打实的 bug 修复，值得提给 immortalwrt；httpd 这套是否适合上游还没想好。
