# 待办

2026-09-24 整理，列的都是还没做完的。来源：pbs05 兼容性对比、1.0.1 代码审查（整理提交前的 `5e364053d6`..`4f250b18e0`）、HG5382A 的讨论。提交号与文件路径指 [Loong1996/immortalwrt](https://github.com/Loong1996/immortalwrt) 的 `main-airoha-1.0.1` 分支；`uboot-airoha/` 即 `package/boot/uboot-airoha/`。

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

- [ ] 串口开机日志里 `EN7581 parallel NAND registered: ECC8/512, spare 28/sector`；打开页面后有 `sample page(s) for the stock flash format` 和 `format(s) tried in … ms, … decode every sample`
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

## 二、HG5382A：ECC4/ECC8 自动兼容（W29N02KVSIAF）

原厂和我们都用 ECC8，pbs05 的 BL2 与 U-Boot 用 ECC4；两边 spare 都是 28、驱动相同，只差校验码长度。PonWrt 内核没有这颗芯片的完整 ID，在 SIAF 板上本来就挂不上 UBI，所以 pbs05 写过的 SIAF 板上基本只有他 U-Boot 写的 ECC4 页。目标：这种 UBI 不用重建，`factory` 卷原地保留。

- [ ] U-Boot：
  - 只在 SIAF（ID `ef:da:10:95:06`）上开启，东芝等其它芯片固定 ECC8
  - 挂 UBI 前读前几个好块的第一页（EC 头），先按 ECC8、再按 ECC4，以 `UBI#` 标记与头 CRC 判定；全空默认 ECC8
  - 认出 ECC4 就把驱动自己的格式切成 ECC4（可复用 `airoha_nfc_apply()`），但第一个块（BL2）读写固定 ECC8
  - 启动内核前往 DTB 的 nand 节点写 `nand-ecc-strength`；主线 mtk_nand 以它为准，内核不改代码（要核实）
  - 重建 UBI 时回到 ECC8
- [ ] BL2（ATF 补丁 100）：找 `fip` 卷时同样识别。风险最高，放最后
- [ ] 上真机：一块 pbs05 写过的 SIAF 板、一块我们写过的 SIAF 板；东芝板确认不受影响

## 三、pbs05 兼容性遗留

- [ ] ZN515XG-D：README 把它列在支持机型里，因为教程写的是「直接用 XG-040G-MD 的固件」。它比 MD 多一块 MT7916 与第二个 USB，MD 固件用不上；装着 pbs05 的 ZN515 U-Boot 时，他的恢复页会以「does not match this board」拒收 MD 固件。待定：README 是否改成「ZN515XG-D（用 XG-040G-MD 固件）」
- [ ] 换 U-Boot 后清环境变量：两边都把环境存在 `ubootenv`、`ubootenv2`，换 U-Boot 后新旧变量混在一起。主线没有自动重置，本分支的 XR1710G 有整套重置（`web_uboot_foreign_env=reset`）；其它机型从 pbs05 换过来时 `bootcmd`、`boot_production` 仍是他的，首次开机初始化被跳过（Nokia 上不建 `ri`、`bosa`）。待定：只写进教程（换完先执行菜单里的「Reset all settings to factory defaults」），还是让 U-Boot 认出外来环境后自动重置
- [ ] ZN504XG-D：整片备份里 `reservearea` 的偏移不明，原厂内核运行时才算分区。要原厂的 `/proc/mtd`，或做一个按内容找的工具（`reservearea` 的 `0x141010` 处是 `ZN504XG-D`，只在那一段没有坏块时成立）
- [ ] 是否告诉 pbs05：PonWrt 内核缺 W29N02KVSIAF 的完整 ID，按 64 字节 OOB 算成 ECC4/spare 16，读不了他 U-Boot 按 spare 28 写的页，在 SIAF 板上起不来——待定

## 四、1.0.1 审查遗留

### 中

- [ ] 补丁 204 发送超窗：设备回的 SYN-ACK 由 `net_set_ack_options()` 构造，不带窗口缩放选项，但上游 `tcp.c` 记下了对端 SYN 里的 wscale（约 798 行）并拿它左移对端通告的窗口（约 987 行）。对端 8 KB 的窗口被读成 1 MB，204 就连发 16 包，超窗部分被丢弃重传。能自行恢复，浪费带宽。改法：把 `rmt_win_scale` 置 0，或在 SYN-ACK 里带上 wscale 选项。改完 tcpsim 要补对应场景

### 低

- [ ] ATF 补丁 100 有三颗芯片的 ECC 强度写成 12，U-Boot 与 Linux 用 8；目前没有板子用这三颗
- [ ] 补丁 102 与 `files/fip/check-bl33.sh` 用的 `BL33_LIMIT`，BL2 的解压函数并不检查，检查的口径不对
- [ ] `chk_item` 往串口打印中文，违反串口只用英文的约定，i18ncheck 抓不到
- [ ] `wr_printf` 日志满时会留下半行，目前走不到
- [ ] `airoha_eth_send` 只等 DMA 100 µs，突发 16 帧时可能丢帧，要上真机看
- [ ] tcpsim：模拟对端只通告 64 KB 窗口、不带 wscale、没有乱序，覆盖不到上面的超窗问题；`run.sh` 里 `dl-old` 没输出速率时第 4 项检查会误判通过；204 的快速重传没检查 `tcp_send_data()` 的返回值
- [ ] 丢包重传时 `dump_tx` 可能反复整窗重读闪存，只影响性能
- [ ] HG5382A 的 dts 注释把芯片 ID 写成 `98:da`，实际是 Winbond `ef:da`

## 五、已写好、没上真机

- `4c213cf74e`：页面忙时误判、红条按部分记账、DHCP 客户端模式保存地址
- ZN504XG-D 的 `factory` 卷（`5515ad1448`、`4c213cf74e`）：首次开机建卷；写回 `reservearea.bin` 后重启，串口应有 `MAC fc:d5:86:3f:ce:00 from factory volume` 这类行
- HG5382A 的 `factory` 卷（`5515ad1448`）：MAC 读 `0x2000`
- 出厂卷长度：`/dump?vol=` 导出截到规定长度（Nokia `ri`、`bosa` 为 256 KiB），写入时超出部分全 `0xff` 照收；已装机器上写不存在的出厂卷，空间不够时在上传前拒收
- TCP 发送窗口补丁 204；DHCP 开机拔插一次端口、REQUEST 回 NAK
- 第一节的并口 NAND 备份与刷回原厂；带 ECC 读页时 `dma_unmap` 改为等全部扇区 DECDONE 之后
- 教程线上版要跑 `publish-pages.sh` 才更新

## 六、XR1710G / W1700K（本分支）

本分支是主线加一个提交（immortalwrt 的 `main-airoha-xr1710g` 同样如此），主线不带这两台。W1700K 的设备支持来自上游 ImmortalWrt，主线照旧保留，这里只有我们对它的改动。

已写好、没上真机（immortalwrt `eb5e4ea753`）：

- 网页写引导改为先 FIP 后 BL2（`httpd_flash_step()`）：XR1710G 从厂商引导迁移时 FIP 写失败，厂商引导仍在
- 串口菜单 TFTP 写 chainloader 槽前先跑 `chaincheck`，与网页上传同一套检查（坏块、大小、uImage/FIT、厂商 bootcmd 读取长度）；`web_uboot_envver` 升到 11，已装机器的 `boot_tftp_write_chain` 随之刷新
- W1700K 的 `fw_setenv` 改用 16 KiB 环境。已装机器的 `/etc/config/ubootenv` 是首次开机生成的，不会自己变，要删掉重新生成
- `chain_check()` 在擦写前比对原厂 bootcmd 读的长度与地址

遗留：

- [ ] `chain_vendor_env` 取窗口里第一个 `bootcmd=`，不区分哪份环境是当前有效的；依赖厂商布局，没证实
