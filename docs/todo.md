# 待办

2026-09-24 整理，列的都是还没做完的。来源：pbs05 兼容性对比、1.0.1 代码审查（整理提交前的 `5e364053d6`..`4f250b18e0`）、HG5382A 的讨论。提交号与文件路径指 [Loong1996/immortalwrt](https://github.com/Loong1996/immortalwrt) 的 `main-airoha-1.0.1` 分支；`uboot-airoha/` 即 `package/boot/uboot-airoha/`。

## 〇、`ubi part` 擦掉原厂裸分区：已改，待真机

- [ ] 补丁 205（immortalwrt `b630f9c59c`）：挂 UBI 时两个头都认不出、又不是全 FF 的块超过 2 块，且卷表里没有 `fip` 卷，就拒绝挂载、什么都不擦。原来 U-Boot 当场把这些块擦掉，我们的 `ubi` 分区从 `0x20000` 起，原厂机器第一次 `ubi part`（开机读环境时就会发生）就丢了 ZN504 的 `reservearea`、Nokia 原厂引导器的后半截，早于用户能备份。证据是那份装过 0.3.0 的 ZN504 整片备份：原厂 UBI 以外 1151 块全是被 UBI 擦过的样子
  - 真机：一台还是原厂系统的 ZN504 或 Nokia，串口载入后应看到 `PEBs hold data that UBI did not write`，恢复页按没有 UBI 处理；整片备份里原厂裸分区还在；「重建 UBI」照常
  - tcboot-to-ubi-uboot.bin（UBI 带 fip 卷、后面留着原厂数据）第一次开机仍应照旧擦掉残留、能直接「日常刷机」
- [ ] `docs/uboot-http-recovery.md` 里「ZN504 的原厂系统本身就是整片 UBI」与那份备份对不上，真机确认后改

## 一、HG5382A 并口 NAND：原厂备份与刷回原厂

并口 NAND 的 ECC 由 SoC 控制器按软件设定计算，原厂与我们的设定不同：只读写数据的整片备份在原厂闪存上读出来几乎全是 `0xff`，刷回原厂写进去的原厂读不了。SPI NAND 是芯片自带 ECC，不受影响。

已写好、没上真机（`6f9d7d441b`）：

- 整片备份连 OOB 原样读出：`/dump?oob=1`，每页 2176 字节，整片 272 MiB，按芯片上的字节顺序
- 原样写回：`/stock?fmt=oob`
- 原厂闪存格式：首次迁移、UBI 挂不上时在 `/info` 里自动识别；可手动填参数、试读、保存；可用 dd 备份核对。接口 `/sfmt`，存在环境变量 `web_uboot_stock_nand`（`ecc=8,spare=28,inv=0,fdm=8,fecc=1,swap=0,src=dd,n=48`，`swap=-` 表示未确认）
- 按原厂格式写回 dd 备份：`/stock?fmt=dd&p=ecc,spare,inv,fdm,fecc,swap`
- 重建 UBI 后自动保存：当场建 env 卷，把 `_firstboot` 恢复为默认值再 `saveenv`

### 真机验证

要一台还是原厂系统的 HG5382A，串口接好。用 CI 编出的 HG5382A 的 `preloader.bin` 与 `bl31-uboot.fip`，按教程第二章经 BootROM 串口载入内存，闪存不动。

- [ ] 串口开机日志里 `EN7581 parallel NAND registered: ECC4/512, spare 28/sector`；打开页面后有 `sample page(s) for the stock flash format` 和 `format(s) tried in … ms, … decode every sample`
- [ ] 「备份下载 → 原厂格式」显示已识别，记下参数；再用原厂系统 dd 的整片备份点「核对」，应一致
- [ ] 「原始区段」整片下载，文件 285212672 字节（272 MiB），`/dumpinfo` 没有读取失败的块。若串口出现 `EN7581 read DMA incomplete`，说明自定义扇区整页 DMA 在并口上不成立，要改回按格式化扇区读、页尾 16 字节另用 PIO 读
- [ ] 把这份带 OOB 的整片备份用「刷回原厂」写回，拔电重启能进原厂系统
- [ ] 再迁移一次，改用原厂 dd 备份按原厂格式写回，能进原厂系统
- [ ] 首次迁移勾「重建 UBI」写完后，串口有 `stock flash format saved`；重启后首次初始化照常（`factory` 卷建出来），`fw_printenv web_uboot_stock_nand` 有值

### 验证之后

- [ ] 原厂格式写进 HG5382A 的板级默认值，以后的用户只需核对。C 侧还不支持：要在 `uboot-airoha/files/web-uboot/boards/an7581_fiberhome_hg5382a` 加一项（如 `stock_nand=ecc=8,...,src=board`），`assemble.py` 把它写进默认环境；页面已认 `src=board`（显示「本机型的已知格式」「内置于本 U-Boot」）
- [ ] 教程 `guide/recovery-guide.html` 机型表 HG5382A 那一行：不再写「原厂备份请在原厂系统里做」，改为在网页里带 OOB 整片下载；刷回原厂章节补两种镜像格式
- [ ] `docs/backup-and-restore.md` 同步

### 坏块标记位置（先定方向）

- [ ] 现状：BL2（ATF 补丁 100）、U-Boot（`airoha_en7581_nand.c` 的 `airoha_nfc_block_bad()`）、Linux（补丁 903）都读原始 OOB 第 0 字节，也就是物理列 512（sector 0 的 FDM0）；W29N02KV 的出厂坏块标记在列 2048，落在 sector 3 的数据区。三级一致，但出厂坏块会被当成好块，首次重建 UBI 时擦掉就永久丢了。`airoha_nfc_block_bad()` 上面那句「在物理标记位置读」的注释与实际不符
- 可选方向：
  - A：三级都做 BBM swap（数据里第 1964 字节与 FDM0 对调，MediaTek 驱动的做法）。页面布局变了，已装机器的 UBI 要重建
  - B：布局不动，首次迁移、重建 UBI 前先原样读一遍每块第一页的列 2048，出厂坏的块在我们的 FDM0 位置写上坏块标记
  - C：维持现状，只改注释并在教程里说明
- 带 OOB 的原样写回会把原厂备份里列 2048 的出厂标记一起写回去，这一点不受影响

## 二、HG5382A：改为 ECC4，与 pbs05 一致（待真机）

W29N02KVSIAF 的 BL2（ATF 补丁 100）、U-Boot（补丁 123）、Linux（补丁 904）都从 ECC8 改为 ECC4、spare 28，与 pbs05 的 BL2 和 U-Boot 相同（数据取反、FDM 8 字节纳入 ECC 本来就一致）。pbs05 自己的内核缺这颗的完整 ID，按 spare 16 读，所以他那边内核读不了他 U-Boot 写的页；我们的 904 保留完整 ID。原厂是 ECC8，照旧要重建 UBI。

- [ ] 上真机：串口载入新 preloader 与 fip，BootROM 能起 ECC4 写的 BL2（pbs05 的板子上一直是 ECC4，推断没问题）；日志 `ECC4/512, spare 28/sector`
- [ ] 一块 pbs05 写过的 SIAF 板：不重建 UBI 能挂上，`factory` 卷原地可读
- [ ] 装过本项目 ECC8 版本的机器只能走串口换引导再重建 UBI（旧 U-Boot 按 ECC8 写 fip，新 BL2 读不出），Release 说明与教程已写；看要不要在网页上拦
- [ ] 挂 UBI 前抽样（immortalwrt `227b0a0069`，补丁 205 与并口驱动）：ECC8 写过的机器（原厂或本项目旧版）串口载入 ECC4 的 U-Boot，开机读环境、`_firstboot`、恢复页 `/info` 应各只有十几行 `Uncorrectable ECC error at page … (n of 4 sectors)` 加一行 `… sampled PEBs do not decode with this ECC layout; … refusing to attach, nothing erased`，一秒左右结束，不再刷屏几分钟；识别原厂格式时不再打 ECC 错误。「重建 UBI」后照常挂载
- [ ] 别的 ECC 格式写的块不再被擦（immortalwrt `60bf43fc10`，补丁 205、恢复页）：两个头都是 ECC 错误的块数到全部块的 5%（HG5382A 为 102 块）就停扫、拒绝挂载，不管有没有 fip，什么都不擦；恢复页横幅给出备份、重建 UBI、强制挂载（`/ubiforce`，即 `ubi_force=1`）。那台 ECC8/混合状态的 HG5382A 串口载入这版：每次挂载一两秒内以 `refusing to attach` 结束、不再有 `ubi_eba_copy_leb`；强制挂载能挂上就照常；正常 ECC4 机器与 SPI NAND 机器开机不变。原厂格式识别在 ECC8 时期写过的闪存上应报 `former ECC8 format, not stock`
  - 复审修正 `304ee21c7d`：整片 ECC8（抽样就拒）的机器横幅不给强制挂载、只给备份与重建；混合状态强制挂载成功后弹框要求先重启，重启后开机能读到闪存里的环境变量；`setenv ubi_force 1; ubi part ubi` 之后 `printenv ubi_force` 应为空（用一次即删）；同一片闪存第二次挂载串口应有 `the 8 PEBs checked from the last refusal still fail ECC`、不再扫到 5%；「诊断」体检 UBI 一项说「没有挂载 … 为保护数据一块都没擦」

## 三、pbs05 兼容性遗留

- [ ] ZN515XG-D：README 把它列在支持机型里，因为教程写的是「直接用 XG-040G-MD 的固件」。它比 MD 多一块 MT7916 与第二个 USB，MD 固件用不上；装着 pbs05 的 ZN515 U-Boot 时，他的恢复页会以「does not match this board」拒收 MD 固件。待定：README 是否改成「ZN515XG-D（用 XG-040G-MD 固件）」
- [ ] 是否告诉 pbs05：PonWrt 内核缺 W29N02KVSIAF 的完整 ID，按 64 字节 OOB 算成 ECC4/spare 16，读不了他 U-Boot 按 spare 28 写的页，在 SIAF 板上起不来——待定

## 四、1.0.1 审查遗留

### 低

- [ ] ATF 补丁 100 有三颗芯片（MT29F02G08ABAGA、MT29F08G08ABACA、TC58NVG4S0HTA20）的控制器 ECC 写成 12，U-Boot 与 Linux 按芯片要求选 8。12 与 pbs05 的 `tf-a/.../parallel_nand_flash_table.c` 逐字一致，他的 U-Boot 同样选 8，所以他那边也不一致；这张表对 W29N02KVSIAF 写的是 4、原厂实为 8，不能当原厂依据。目前没有板子用这三颗；有了先看原厂引导打印的 ECC，再让三级统一
  - 2026-09-25 复审（`5e364053d6`..`47e5f400be`）再次确认：U-Boot 补丁 123 没有这三颗的完整 ID，退回 ONFI 声明的强度，`airoha_nfc_calc_ecc_strength()` 取不低于它的最小一档即 8，按 ECC8 写 fip 卷；BL2 按 ECC12 读，这类板子第一次迁移后就起不来。修法二选一：ATF 补丁 100 的表改成 8，或在 U-Boot 补丁 123（Linux 补丁 904 同步）补上 ECC12 的完整 ID

## 五、已写好、没上真机

- `4c213cf74e`：页面忙时误判、红条按部分记账、DHCP 客户端模式保存地址
- ZN504XG-D 的 `factory` 卷（`5515ad1448`、`4c213cf74e`）：首次开机建卷；写回 `reservearea.bin` 后重启，串口应有 `MAC fc:d5:86:3f:ce:00 from factory volume` 这类行
- HG5382A 的 `factory` 卷（`5515ad1448`）：MAC 读 `0x2000`
- 出厂卷长度：`/dump?vol=` 导出截到规定长度（Nokia `ri`、`bosa` 为 256 KiB），写入时超出部分全 `0xff` 照收；已装机器上写不存在的出厂卷，空间不够时在上传前拒收
- TCP 发送窗口补丁 204；DHCP 开机拔插一次端口、REQUEST 回 NAK
- 第一节的并口 NAND 备份与刷回原厂；带 ECC 读页时 `dma_unmap` 改为等全部扇区 DECDONE 之后
- 补丁 204：被动建连时清掉对端 SYN 里的窗口缩放（SYN-ACK 不带，按 RFC 7323 两边都不缩放），SYN 自己的窗口不缩放；快速重传时 `tx()` 失败照首发一样复位连接。tcpsim 新增第 5 项（8 KiB 小窗口、应用慢读、带或不带 wscale、丢包、乱序），修前的 204 在这组里掉到约 4 KiB/s、上千段发到窗口外，修后为 0；第 4 项没取到速率时不再误判通过
- `/dump` 换窗口时往回留 64 KiB 重叠，窗口边上丢的段重传不再把前后两个窗口来回重读；校验和只折叠没算过的部分
- 系统诊断的串口输出只打英文汇总（不 OK 的按序号列出），i18ncheck 新增一条：函数收到中文参数后不许再把它打到串口
- BL33 大小检查：BL2 只检查压缩包（缓冲区 0x58000 / pnand 0x80000，减去约 16 KiB 解码器状态），解压后大小它不管（`lzmaBuffToBuffDecompress()` 不看传进去的上限）；`BL33_MAX` 改为 U-Boot 自己的界限 0x1f0000（TEXT_BASE + 2 MiB 以下留 64 KiB 给早期栈与 malloc），补丁 102 去掉不起作用的 `BL33_LIMIT` 放大，`check-bl33.sh` 另查 LZMA 的 lc+lp
- 换 U-Boot 后清环境变量：只写进教程 2.4（没勾「重建 UBI」、从 pbs05 换过来的，写完先在「U-Boot 环境变量」里「恢复默认」再重启）
- `scripts/find-reservearea.py`：按内容（第 10 块 `0x1010` 的型号与 MAC、第 14 块 `0x400` 的光模块校准页）从整片备份里找出 ZN504XG-D 的 `reservearea` 并导出 0x240000 字节，能跳过插进来的坏块；手上这份备份里已被擦掉（见第〇节），只用合成数据验证过
- HG5382A 的 dts 注释改为 Winbond `ef:da`
- 补丁 207：`airoha_eth_send()` 等描述符完成从 100 µs 放宽到 10 ms。原来超时返回却不挪 head，下一帧会改写 QDMA 可能还在读的描述符
- `wr_printf()` 日志满时整行丢弃、之后不再写入，不再留半行
- 教程线上版要跑 `publish-pages.sh` 才更新
- 1.0.1 复审修正（immortalwrt `7e5826a6b8`、`5ee749ce78`）：重建 UBI 后当场建 env 卷并保存原厂格式——建卷时临时把 `ubi_format` 换成 echo，免得 `|| run ubi_format` 在 BL2 已写、fip 未写时擦 UBI 并重启；保存前把默认环境里有的变量恢复成默认值（带回调的如 `ipaddr` 不动，页面设的保留），否则会把原厂开机时 `web_uboot_no_ubi` 改掉的 `bootmenu_0` 存下去，以后每次开机直奔恢复页、`_firstboot` 不再跑；已存过格式的机器再重建 UBI 也照样保存。上传或 `/stock` 刷回进行中，拒绝 `/envreset`、`/bootonce`、`/netmode`、`/reboot`、`/boot`、`/wipecfg`、`/dhcpgw`、`/sfmt` 与 `/dump`，`/info` 回 503 不再重挂 UBI。「自动识别」找到多组、找到与已记录相同的一组、或已记录的是 dd 核对过的，都保留原记录。补丁 204 的 `TCP_SND_WND_SIZE` 注释更新
  - 真机：原厂 HG5382A 首次迁移勾「重建 UBI」，串口有 `stock flash format saved`；重启后进的是「Initialize environment」而不是恢复页，`factory` 卷建出来，`fw_printenv web_uboot_stock_nand` 有值；已迁移的机器再重建一次 UBI，重启后该变量仍在
- 恢复页换成液态玻璃主题（immortalwrt `235d1d725a`）：只改 `page.html` 的 CSS，HTML 与脚本不动
  - 真机：刷 SPI NAND 板子（XG-040G-MF 余量最紧）能正常进恢复页；手机 Safari、Chrome、Firefox 各开一次，浅色深色都看，毛玻璃卡片上的橙色、红色警告字要看得清；上传大固件时页面不卡
  - CI 实测 LZMA 各板多 1.1–1.8 KB（到 `07e4bde87d` 为止），XG-040G-MF 余 3118 B、ZN504XG-D 4695 B、XG-040G-MD 4443 B、XG-040G-TF 4035 B（CI 的 xz 比 OpenWrt 的大 1% 左右，真编余量略多）
  - 深浅色跟随系统（`7b934d8073`、`07e4bde87d`）：没手动选过按系统，开着时系统切换也跟；切回与系统相同的一边即回到跟随。真机：系统深色时首次打开是深色；浏览器禁用网站数据时，英文浏览器仍显示英文
  - 不做：灵动岛式状态提示、完成时的圆环进度、分段控件滑块动画
