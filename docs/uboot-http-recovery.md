# U-Boot 网页救砖

`ubi` 变体的 U-Boot 里内置了一个恢复页面 —— **Airoha Web U-Boot**。**机器刷坏了，插上网线用浏览器就能救回来** —— 不用串口，不用在电脑上架 TFTP 服务器，不用装任何工具。

当前版本 **1.0.0**，在 `master-airoha` 线上维护，XG-040G-MD、XG-040G-MF、XG-040G-TF 与 ZN504XG-D 共用同一份页面。0.1.x 的开发历史归档在 `archive/master-XG-040G-MD-httpd`。

> 想要图文版、从零开始的操作教程（含实拍接线图与串口截图），见 **[网页救砖指南](https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html)**。本文档是技术参考，覆盖设计取舍与踩过的坑。

> 只对 `ubi` 变体有效。`stock` 用原厂引导，不经过这个 U-Boot。

---

## 怎么用

### 进恢复页

四条路，只有最后一条需要串口：

| 什么时候 | 怎么进 |
| --- | --- |
| 想主动刷机 | **按住 reset 上电**，一直按着，等面板灯开始**流水**再松手（约 15 秒） |
| 机器起不来了 | **什么都不用做** —— 从 NAND 引导失败后会自己循环起网页，插上网线即可 |
| 闪存还是原厂布局 | **什么都不用做** —— `_firstboot` 里 `ubi part ubi` 挂不上就走 `web_uboot_no_ubi`，不动闪存直接起网页 |
| 手上接着串口 | 引导菜单上用 ↑/↓ **选到第 9 项** 回车 —— `bootmenu_8` 直接 `httpd`，不经 `_firstboot`，不用掐 reset 的时机 |

这段时间里有一部分是 bootmenu 的等待。`button reset` 读的是那一瞬间的电平，不是累计计时，所以「一直按住」比「按几下」可靠。**流水灯亮起来就是进去了。**

第三条是**首次迁移**唯一不用掐时机的路，见下面第 ② 步。第四条走的是另一条代码路径：`check_buttons` 与 `web_uboot_no_ubi` 都在 `_firstboot` 里，而第 9 项是 bootmenu 自己的条目，互不依赖。

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
| 试跑固件 | `firmware` `tryboot` | 什么都不写：`bootm <part_align(fit)>`，一去不回。`httpd_validate()` 拒绝混装（`up_nparts > 2` 直接 400），因为夹带的东西要么被悄悄丢掉、要么把它变成一次真写入 |
| 引导升级 | `bl2` `fip` `firmware`（可选） `format` | BL2 走 `mtd`；FIP 在位写 `fip` 卷；勾了「重建 UBI」先整个擦掉 `ubi` 分区 |
| 刷回原厂 | — | 单独的 `POST /stock?off=`，**body 就是镜像本身**（不是 multipart）。边收边写，逐块 `mtd_erase()` + `mtd_write()`，**位置保持**；偏移须按擦除块对齐，默认 `0x0` 整片。**没有大小上限** |
| 按卷写入 | `fvol_<name>`… `ubivol` `ubifile` | 出厂数据卷按 `HTTPD_FACTORY_VOLS` 校验长度后 `ubi write`；任意卷 `ubi check \|\| ubi create` 再写。`stay` 字段 0.3.0 起没有了：写完一律不重启，重不重启在页面上点 |
| 备份下载 | — | `GET /dump?vol=<名>` 走 `ubi read`，`GET /dump?off=&len=` 直接调 `mtd_read()`，**位置保持**（文件偏移 == flash 偏移，与 `dd` 同格式）。流式，只在内存里拿一个窗口；`len` 留空表示读到片尾；`GET /dumpinfo` 回最近一次的 crc32 与读不出的块数，见[下下节](#030-续心跳备份环境重启) |
| 写入进度 | — | `GET /wr?from=` 回写到哪了，形状同 `/log?from=`：首行是新偏移，其后是新增的行。写一个卷的那几秒设备不应答，页面轮询、漏了就漏了，每行自带绝对值 |
| 设备详情 | — | 三段。网络那段另有 `GET /netmode?mode=server|static|client&ip=&mask=&save=`：三种模式互斥，一个请求说完，答复是 `ok <模式> <地址> <掩码> <saved|ram>`（客户端档地址与掩码位为 `-`）。延后到答复发出之后才动手 —— 答复必须从旧地址发出去。网络那段露在前台时每 3 秒问一次 `GET /net`，回的就是 `/info` 里 `net` 与 `ports` 那两个对象 —— 换个网口端口表跟着变，不必为此重挂一次 UBI；见[网络那段会自己刷新](#网络那段会自己刷新dhcp-开关会自己存)。`GET /info` 返回 JSON：设备树 `model` / `compatible`、DRAM、MTD 几何与分区、MAC、U-Boot 版本、UBI 卷表（含有没有 `fip` 卷）。卷表按卷名排序，ID 列是 UBI 卷号（按创建先后分配，不同迁移路径得到的号不同）；卷没有固定物理地址，所以不列。表上方一条占用条按预留容量分段，`fit` 与 `rootfs_data` 打斜纹 —— 它们是刷写时先删后建的，容量算在「可写空间」里。`ubi` 对象为此多一个 `avail`（`ubi->avail_pebs`）：光靠 `pebs` 减各卷大小，分不出「还没分出去的」与「UBI 留给自己的」（卷表 2 块加坏块替换预留），条上那两段就并成一段 |
| 系统诊断 | — | 三段。「快速检查」`GET /check`，16 项分五组，见[下一节](#030拦截横幅体检日志)与[下下节](#030-续心跳备份环境重启)；「全片扫描」`GET /scan?off=`，一次 4 MiB，页面累加；「串口日志」`GET /log`，`?from=` 只回新字节、正文第一行是新偏移 |
| 环境变量 | — | `GET /env` 只读列出全部 env；`GET /envreset` 跑 `env default -a && saveenv` |
| 启动与重启 | — | `GET /reboot` 答复发出并被确认之后才 `reset`；`GET /boot` 执行 `bootcmd`；`GET /bootonce` 让下次开机停在本页 |
| 关于 | — | 静态 |

页面还在后台每 3 秒问一次 `GET /ping`，那是它判断设备还在不在的唯一依据。

页面本身**不含任何机型串** —— 机型、闪存、卷表都是请求时读出来的，所以两款机器共用同一份 HTML，第三块板也是。

`/info` 里的 `uploadmax` 是 `httpd_parse()` 拿来卡 `Content-Length` 的那个上限（`upload_max()`，512 MiB 板子约 248.8 MiB）。报出来是为了让页面在**文件还在磁盘上的时候**就说不，而不是传了两百多兆之后才被 400。

它只管**要先整个进内存才写**的那几页（引导升级、日常刷机、按卷写入、试跑固件），那些文件本来就只有几兆到十几兆。「刷回原厂」不受它管 —— 见下面的 `POST /stock`。

上传结束设备回一行 `{"ok":1}`，那只是「收下了」；写入随后开始，页面靠 `GET /wr?from=` 跟着看，写完弹框问要不要重启（见[写入分步进行](#写入分步进行回读校验之后由页面决定重启)）。能在上传前查出来的错误 —— 出厂卷长度不对、偏移没按擦除块对齐或超出容量、卷名非法 —— 设备直接回 400，原因显示在进度条下面，此时什么都还没写。

### 1.0.0：整页中英双语

侧栏左下角深浅色按钮旁边多一颗分两半的胶囊（`中` / `EN`），点一下整页换语言，不刷新、不丢正在选的文件。选择存 `localStorage.xglang`；**没选过就照 `navigator.language` 挑一次**，不是 `zh` 开头直接给英文。设备上不留任何东西，也不占环境变量。

**中文原文就是字典的键。** 页面里那几百处文案一处都没改，也没有引入 `data-i18n` 之类的标记 —— 切到英文时把整棵 DOM 走一遍，每个文本节点和几个属性（`title`、`aria-label`、`placeholder`、`data-l`）查一次表。这样做的直接好处是**设备回报的中文也一并翻掉**：`/check` 的检查项与结论、`/wr` 报的写入步骤、各种错误正文，都是 `net/httpd.c` 里的 C 字符串，它们进了 DOM 就跟页面自己的文案走同一条路，C 侧一行不用动。

字典分两层：

| | 数量 | 用途 |
| --- | --- | --- |
| `I18N` | 415 | 整段匹配。绝大多数文案是完整的一句，优先查它 |
| `I18P` | 226 | 按片段替换。只给中间夹着数字、容量、卷名的句子用 |

分两层是因为片段替换会乱咬。`无`、`通过`、`设置` 这类短词如果进了片段表，会在任何一句没被整段命中的话里替换掉那两个字；反过来，`已发出 3 个地址，最近一次分配给 …` 这种拼出来的句子又只能按片段来。所以短词一律只走整段，片段表里的键都带着标点或空格、足够长。片段表按长度从长到短排成一条正则，同一个位置上长的先匹配。

**踩到过一次：** `dur()` 输出的 ` 分`、` 秒` 当片段太短，`擦除 UBI 分区…` 被咬成 `Erasing UBI min区…`。这两个词退出字典，改成 `dur()` 自己按 `LANG` 分语言。

**后插进来的节点交给 `MutationObserver`。** 页面大量用 `innerHTML` / `textContent` 拼内容，逐个调用点去包一层函数要改两百多处。观察器盯着 `document.body` 的 `childList` / `characterData` / `attributes`，英文模式下新插进来的中文当场换掉。替换本身是幂等的（英文再查一遍不含中文，不产生新的变更记录），所以不会自激。

**切回中文不做英译中。** 翻译时把原文存在节点上（`node.zh0`），切回来照它还原。串口日志、环境变量的值、卷名、文件名这些设备数据里全是英文单词，按英文反查会把它们一起换成中文。唯一的例外是几处「先把当时的文字存进变量、过后再写回去」的按钮（复制按钮、提交按钮的原标题）—— 那份文字在英文下存的就是英文，写回来是个新节点、身上没有原文，所以还原时对**整段相等**的再按英文反查一次；为此字典里每条英文都是唯一的。

**不翻的地方**：`script` / `style` 的正文（注释里全是中文，翻了没用还费时），以及标了 `data-raw` 的子树（语言胶囊自己、`preview.py` 加的预览工具条）。

**顺带修了三处会被语言切换弄坏的地方：**

- 串口日志的占位文字 `未读取` 原本被拿来做字符串比较（`if(l.textContent=='未读取')`），翻掉之后判断失效 —— 改成 `data-ph` 属性。
- 拖拽提示 `松手放到这里` 在 CSS `content` 里，DOM 翻译够不着 —— 改成 CSS 变量，`[lang=en]` 下换一份。
- 「下载诊断包」导出的文本不进 DOM，显式过一道 `T()`。

**覆盖率有脚本卡着。** 从 `page.html` 和 `net/httpd.c` 里把所有会进 DOM 的中文片段抽出来，跑一遍字典，剩中文就报出来。当前漏译 0。

**两个与指南同步有关的约束**（`ImmortalWrt-Airoha/scripts/sync-guide-page.py` 会把 `page.html` 原样嵌进教程）：

- 那个脚本按行剔掉含 `localStorage.getItem` 的行（教程里的示意框不该跟着访客的本地设置走），所以 `<head>` 里读取主题与语言的那段必须**自己占满一整行**，跨行会被截成语法错误。
- 脚本在替换完 `@@NAME@@` 宏之后断言页面里不再有 `@@`，所以字典块的起止标记写成 `/* i18n-dict begin */`，不能用 `@@` 包起来。

体积：页面 100 KB → 156 KB（字典要同时存中文键和英文值）。FIP 目前 325 KB，`fip` 卷预留 1.1 MB，放得下。

页面测试加了 28 项：切过去每一项是不是英文、切回来是不是原文、属性有没有跟着变、英文下新插进来的内容（`/check` 结果、UBI 卷表）有没有漏、以及「整页不剩中文」。`boot()` 里把 `navigator.language` 钉死 —— 不钉的话跑在英文系统上的 node 会拿英文页面去对中文断言，整套用例一起红。共 544 项通过。

### 0.4.0：流水灯由板子声明、TF 的安全启动证书、ZN504 的 fip 保护

**流水灯由板子声明。** 0.3.0 的流水列表写死在 `net/httpd.c` 里：`green:power`、`green:wan`、`green:wan-online`、`green:usb-1`、`green:usb-2`，按标签找，找不到的跳过。三个问题都出在「按名字猜」上：ZN504XG-D 的灯是蓝色的，一盏都找不到；MF 的上网灯叫 `green:online`，从来不在流水里；找不到的灯仍占一拍，那一拍全黑。现在由板子在 U-Boot 设备树里用 phandle 列出，放在与 `boot-led` 同一个节点：

```dts
options {
	u-boot {
		compatible = "u-boot,config";
		httpd-chase-leds = <&led_power &led_wan &led_wan_online>;
	};
};
```

按列出的顺序流水，与名字、颜色无关；列表里找不到的灯直接去掉，不留黑帧。属性名不带厂商前缀，照 `boot-led` 的写法，名字里的 `httpd-chase` 说明它只管网页救砖的流水，不是网页 U-Boot 的全部 LED。MD、MF 在各自的 `950` / `960` 里声明，ZN504、TF 在各自的 U-Boot DTS 里。

**没有回退。** 没声明的板子不流水，而不是退回去按名字猜 —— 两套机制并存，新板子忘了声明也不会有人发现。发现靠三处：`uboot-airoha` 的 Makefile 在 U-Boot 编完后查控制 dtb（`dts/dt.dtb`，DTS 放在哪都不影响），`CONFIG_CMD_HTTPD=y` 而里面没有 `httpd-chase-leds` 就编译失败；运行时串口打一行；「系统诊断 → 快速检查」最后一组「指示灯」列出参与流水的灯，未声明或有灯没找到时亮黄灯。

**写入开始时两灯同亮。** 网络循环的 tick 点亮 `led_pos` 后把它挪到下一盏；写入期间的 cyclic 原来只熄 `led_pos`（那一盏还没亮），刚点亮的那盏就一直亮着，直到流水绕回来。现在 cyclic 直接画 tick 的同一帧。

**文案。** 「引导升级」页的备份提示和「备份下载」页不再点名 `ri` / `bosa`：出厂卷由 `CONFIG_HTTPD_FACTORY_VOLS` 决定，ZN504 这类机型没有它们。

**写入进度慢一拍。** 每一步先在 `/wr` 宣布（`s 重建 UBI` 之类），过一轮 tick 再执行，好让页面在设备不再应答之前知道它在做什么。可一轮 tick 只有 120 ms，页面 700 ms 才轮询一次：长的步骤常常在页面听到之前就开始了，整段时间里页面显示的是上一步。最明显的是首刷重建 UBI —— 串口在擦整片 `ubi` 分区，网页却一直是「写入 BL2」。现在宣布之后，下一步要等某次 `/wr` 应答把这一行带出去，再留 250 ms 让它到达浏览器；页面关掉了也最多等 1.5 秒。

**XG-040G-TF 的安全启动证书。** TF 的芯片 efuse 烧了根密钥，两级都要证书：BootROM 只运行带 Trusted Boot FW Certificate 的 BL2（证书里的公钥与 efuse 中的哈希比对、验签、再核对扩展 `1.3.6.1.4.1.4128.2100.201` 里 BL2 的 SHA-512）；BL2 加载 BL31 与 U-Boot 前还要走完 TBBR 证书链。atf-airoha 默认开着 `TRUSTED_BOARD_BOOT`，没烧密钥的芯片由闭源部分在运行时关掉认证，所以 MD 等机型不查；TF 上 FIP 里少了证书，BL2 就报 `ERROR: BL2: Failed to load image id 3 (-2)`（找不到 BL31 的内容证书）。efuse 里是 SDK 默认根密钥：第三方引导 tcboot 的各级证书公钥都是 atf-airoha 自带的 `plat/ecnt/key/rot_key_4096.pem`。证书由 `arm-trusted-firmware-airoha/scripts/airoha_tbbr_cert.py` 生成（只用 Python 标准库，格式与 TF-A `cert_create` 一致：RSA-PSS / SHA-512，盐长 32，ASN.1 结构与 tcboot 里的原厂证书逐项相同）：`tb-fw` 在安装 BL2 时生成 BL2 的证书，配方 `an7581-preloader-signed` 打进 preloader；`fip` 生成 Trusted Key、SoC/NT FW Key、SoC/NT FW Content 五张，全部用根密钥签，配方 `an7581-bl31-uboot-signed` 打进 FIP。只有 TF 用这两个配方，其他机型的引导文件不变。

**ZN504XG-D 的 fip 保护。** ZN504 的原厂系统本身就是整片 UBI，从内存起来的 U-Boot 能挂上它，`_init_env` 会在用户备份之前往原厂 UBI 里建 env 卷，卷建不出来还会 `ubi_format` 整片擦除。它的 `_firstboot` 挂上 UBI 后先查 `fip` 卷，没有就当作不是自己的，像 `web_uboot_no_ubi` 一样不写任何东西，直接进网页救砖。

`web_uboot_envver` 7 → 8，升级上来的机器第一次开机刷新菜单标题与 `web_uboot_show_about`（1.0.0 再进一位到 9）。

### 0.3.0：拦截、横幅、体检、日志

四样都是同一份用户日志引出来的：机器停在 BL2 报 `No volume named fip` —— BL2 写进去了，`fip` 卷没建。页面当时允许勾「重建 UBI」却只传 BL2，而写入失败只在串口上可见，没串口的用户看到的就是「刷完没反应」。

**拦截。** 页面与 C 侧 `httpd_validate()` 各拦一遍：页面不是唯一的客户端，而且页面只认自己那份 `/info`，拿不到或过期了就形同虚设。C 侧在回 200 之前查。查的顺序：勾了「重建 UBI」却没带 U-Boot 文件，400 `rebuilding UBI without a U-Boot FIP would leave nothing to boot`；勾了「重建 UBI」却没带 BL2，400 `rebuilding UBI erases what a factory BL2 loads after itself; upload the BL2 preloader too`（见下）；不重建、也不是整片刷回原厂时，按 `/info` 的方式先挂一次 UBI。挂不上，凡是要写卷的（固件、U-Boot、出厂卷、任意卷）都拒。另有两条只有 curl 会撞上：出厂卷或任意卷与 BL2 / U-Boot / 固件 / 重建放进同一次上传，400 `volumes and the boot chain are written by two different paths; send them as two uploads` —— 状态机一次只走一种形状，卷那条路写完卷就直接去回读，同来的引导文件一个都不写，回读再拿没写过的目标去比，报出来像是闪存坏了；整片刷回原厂再带别的东西，400 `a whole-flash restore replaces everything; nothing else can come with it` —— 那条路写完直接结束、连回读都不做，别的东西是静默丢掉。页面的四个表单各自分开，产生不了这两种组合。0.3.0 起少了两条：「只写 BL2」和「没有 `fip` 卷又不带 U-Boot」原来也拒，理由都是「写完一重启就起不来」—— 现在写完不重启了，拒下来只是拦住用户把两份文件里的第一份放进去，所以改成页面上的一句提醒。页面的确认框仍把这几条做成硬错误（不出「仍要写入」）：引导升级没有 UBI 时必须勾重建，有 UBI 没 `fip` 卷时必须带 U-Boot 文件，勾了重建时 BL2 与 U-Boot 都必须带。

**BL2 与 FIP 的尺寸门。** 出厂卷一直有精确尺寸门（`ri` / `bosa` 差一个字节都拒），这两个到 0.3.0 才有。两条写入配方都是**先擦后写** ——
`web_uboot_write_bl2=mtd erase bl2 && mtd write bl2 $loadaddr 0x800 $filesize` —— 所以装不下的文件不是「拒绝写入」，是「擦完了才失败」，留下半截引导器。判据两边一样：BL2 比 `bl2` 分区自 `0x800` 起放得下的多就拒；FIP 比 `fip` 卷的预留多就拒，勾了重建时按 `ubi_write_fip` 的创建尺寸 `0x100000` 算 —— 现存那个卷马上要被抹掉，它的预留说明不了什么。数是 `/info` 给的，所以页面也拦得住，不必等设备回 400。

**出厂卷不存在时会建出来。** `fvol_*` 原来传 `create=0`，只 `ubi write`。但重建 UBI 留下的是一片空 UBI —— `ri` / `bosa` 要等下次开机 `_init_env` 里的 `ubi_create_board_data` 才会出现，而「把备份写回去」恰恰发生在那次开机之前。于是文档里那条「备份 → 重建 → 写回 → 重启」的流程，第三步必失败。现在和别的卷一样按需创建，尺寸由上面那道精确尺寸门管着。

**重建 UBI 为什么连 BL2 一起要。** 这条是后补的，补之前那个组合是必砖：

| | 本布局 | 原厂 |
| --- | --- | --- |
| `bl2` / `bootloader` | `0x0`–**`0x20000`** | `0x0`–**`0x80000`** |
| `ubi` | `0x20000` 起 | — |

重建就是 `mtd erase ubi`，从 `0x20000` 开始擦 —— 而原厂 `bootloader` 分区跨过了这条线，`0x20000`–`0x80000` 那 384 KiB 连同原厂 BL2 要加载的下一级一起没了。于是「原厂布局 + 勾重建 + 只传 FIP 和固件」写完是：`0x0`–`0x20000` 还是原厂 BL2（BootROM 从 `0x800` 找得到它，起得来），`0x20000` 起变成 UBI，而我们的 FIP 躺在一个它从没听说过的卷里。**BootROM 起了原厂 BL2，BL2 找不到下一级，停在那儿，只能拆串口。** 而校验放行了，因为它只数了 FIP。

无条件要求，而不是「只在 UBI 挂不上时才要」：后者得在上传处理里再挂一次 UBI（整片扫描、几秒、串口刷屏），换来的只是那个罕见情况（已经在本布局上、只想重建 UBI）里少传一个 120 KiB 的文件。教程里首次迁移本来就写着「同时上传 BL2、U-Boot 与固件」，这条只是让页面和教程说同一句话。

**顶部横幅。** `/info` 的 `ubi` 对象多了 `fip` 字段。页面加载后两种情况亮红条：`ubi` 为 `null`（首次迁移：三样一起传并勾重建）；有 UBI 但没 `fip` 卷（现在跑的 U-Boot 只在内存里，断电就没）。串口 xmodem 灌进来的 U-Boot 正是第二种。

**健康检查（`GET /check`）。** 在「系统诊断」页的「快速检查」段，进入该页时自动跑一次，C 侧顺序跑：闪存型号；扫全片坏块（`mtd_block_isbad`，落在 `bl2` 分区那块的算异常）；`bl2` 分区 `0x800` 处有没有 FIP 容器头 `0xaa640001` —— BL2 与 FIP 都是 fiptool 打的包，共用这个魔数，原厂与 tcboot 的引导也在同一位置放同一个头，所以它只回答「有没有东西可启动」，分不出是谁的；UBI 能否挂载、卷数、坏块、空闲 LEB；`fip` 卷整卷读一遍（静态卷，UBI 读时校 CRC）再看头；`fit` 卷读头 4 KiB 看 `0xd00dfeed`，并拿 `totalsize` 对卷内长度；`ubootenv` / `ubootenv2` 在不在（名字来自 `CONFIG_ENV_UBI_VOLUME*`）；`HTTPD_FACTORY_VOLS` 里的出厂卷读不读得到、是不是全 `ff` 的空卷，`HTTPD_FACTORY_MAC`（defconfig 里 `ri:0x3e`）指到的那个卷顺带把里面的 MAC 显示出来；最后一行是 U-Boot 自己的 `ethaddr`（MAC 用十六进制手拼，`%pM` 与中文混在一个格式串里会乱码）。每项绿 / 橙 / 红加一句人话，同一段也打到串口。读取落在 `$loadaddr`，上传进行中回 503。「复制诊断信息」把设备详情与检查结果拼成纯文本，群里求助贴这个。

**启动日志（`GET /log`）。** 打开 U-Boot 自带的 `CONFIG_CONSOLE_RECORD`（64 KiB），把 `gd->console_out` 原样吐出来，页面去掉 ANSI 转义后显示，可复制。`203` 补上一处上游的遗漏：重定位后 `console_record_init()` 重新分配缓冲，重定位前录的横幅、CPU、DRAM 三行会丢，现在先搬过来。缓冲满了不覆盖、只丢新的，末尾标一句「日志缓冲已满」—— 64 KiB 对一次救砖绰绰有余。侧栏单独一页，进入时自动读。`/info` 多一个 `log` 字段，没开录制的固件不显示这一页。重定位前那段录在早期 malloc 区的小缓冲里，显式设为 2 KiB（`CONSOLE_RECORD_OUT_SIZE_F`，上游默认 1 KiB；实机重定位前只打横幅、CPU、DRAM 约 120 字节），搬完后清掉它留下的溢出标志，免得 64 KiB 的缓冲被误报为满。

菜单标题与 `web_uboot_show_about` 跟着升到 0.3.0。环境变量这一版全部改名到 `web_uboot_` 前缀（唯一的例外是 `ubi_write_production`：它和串口 TFTP 升级共用同一条脚本，改名就是分叉），版本号自己也从 `envver` 变成 `web_uboot_envver`（值 5 → 6）—— 名字换掉本身就是迁移信号：老环境里只有 `envver`，新代码读不到 `web_uboot_envver` 就判定落后，当场刷新并写进新名字。旧的那几个留着不删，无害。

**先看再写。** `files/httpd/preview.py page.html` 生成一个能直接在浏览器里打开的预览：所有请求由页内的桩应答，右下角切换设备状态（正常 / 没有 UBI / 没有 `fip` 卷 / 不带日志 / `/info` 失败）与提交结局（成功 / 400 / 断线）。改页面先在这里对齐布局与措辞，再进 C。桩给的数据就是真实端点给的数据，所以对齐的是同一份东西。

### 0.3.0 续：心跳、备份、环境、重启

**心跳（`GET /ping`）。** 上一轮把「设备到底还在不在」留给了用户自己猜 —— 页面是静态的，路由器重启了、正在写、网线松了，看上去全都一样。现在页面每 3 秒问一次 `/ping`，回的是 `{"up":<开机毫秒数>}`，单次超时 2.5 秒，**连续两次失败**才算断。侧栏左下角一颗点（绿 已连接 / 黄 无响应 / 红 已断开），断了才弹全屏说明框。

弹框只在页面确实做不了任何事的时候出现，而且分口径 —— 因为「断开」的原因决定了用户该不该慌：

| 情形 | 说什么 | 有没有「重新连接」 |
| --- | --- | --- |
| 不知道为什么 | 已断开与路由器连接。检查网线与电源。面板还在流水说明设备还活着 | 有，另外每 2 秒自动重试 |
| 刚点了重启 | 设备正在重启，约 1–2 分钟，回来后自动刷新 | 没有 |

**自己发起的读取不弹框。** 体检和整片备份会让设备静默几十秒，但那两页上本来就写着在读什么 —— 再盖一层框是噪音。这两种情况只让左下角的点变色、写「设备忙…」，超过约两分钟还不回来才退回通用提示。

**`up` 倒退就是重启过了。** 恢复时如果 `up` 比上次小，页面 `location.reload()`：卷表、env、体检结果全是重启前的，留着比没有更坏。同一次上电内恢复则不刷新，不打断手上的事。

「写入结果回报」在 0.2.x 那轮设计里被删过一次：那时正常路径写完就 `reset`，静态变量随之清零，回报只有勾了「写入后不重启」才看得见，不值一个端点。0.3.0 把 `reset` 从写入路径上拿掉之后，它成了必需品 —— 见下一节。

**备份下载（`GET /dump`）。** 侧栏单独一页。UBI 卷逐个一行，`ri` / `bosa` 排最前并标「出厂数据」；下面一块按 flash 偏移与长度取任意区段，「整片下载」把偏移归零、长度留空。

**原厂机能不能用它备份？** 能，但要先有串口。原厂跑的是 tcboot，那里面没有这个页面 —— 得先做[首次迁移](#首次迁移从-tcboot--原厂-换到-ubi-布局)的 ①②，串口 xmodem 把 preloader 与 fip 送进 RAM，让我们的 U-Boot 在内存里起来。**这两步一个字节都不写闪存**，所以进到网页那一刻闪存还是完整的原厂内容。原厂布局没有 UBI，卷列表会直接说「UBI 未挂载，只能用下面的原始区段」——而原始区段读的是**裸 mtd 主设备，不经过 UBI，也不看分区表**，所以私有布局照样读得出来，`romfile`、`config` 这些也都在里面。偏移 0、长度 `0xEBA0000` 就是原厂的 `all_flash`；连原厂不用的尾部一起要就把长度留空（等同 `0x10000000`）。原厂系统还进得去的话，[U 盘 dd](backup-and-restore.md) 那条路更全（逐分区、带 md5）；`/dump` 补的是「系统进不去、但还能接串口」的那一档。

要紧的是**它补上的那个时间窗**：首次迁移的 ① ② 两步全在 RAM 里跑，进到网页那一刻闪存还是完整的原厂内容，而下一步勾「重建 UBI」就把 `ri`（MAC、SN）、`bosa`（光模块校准）一起擦了。[原厂备份](backup-and-restore.md)那条 telnet + U 盘 dd 的路更全（还能拿到 `romfile`、有 md5），但前提是原厂系统还进得去。`/dump` 服务的是**系统已经进不去、或者当时忘了备份、人已经站在网页上**的情况 —— 那时它是唯一还能抢救出厂数据的机会。「引导升级」的重建开关旁和「刷回原厂」的说明里各有一句话指向它。

实现上**它是流式的**：只在内存里拿一个
窗口（最大 8 MiB），浏览器抽多少就补多少。
`Content-Length` 给的是完整长度，**多大都是一个文件**。

一开始不是这么写的 —— 最早的版本把整段读进内存再发，
而 512 MiB 的板子上 `$loadaddr` 之上只剩约 248 MiB，256 MiB 的整片
放不下，于是页面把它切成两段让用户分两次下。
**那不是功能，那是把我们的内存预算搬给了用户看。**
改成流式之后分块只是 `dump_fill()` 内部的事，页面上连个开关都没有。

三件事让流式可行：

* **`httpd_tx()` 本来就是按偏移拉的。** 命中窗口就是一次 memcpy；
  落在窗口后面（重传）就按那个窗口的**检查点**重读一次。
* **坏块让「输出偏移 → flash 偏移」不是一个乘法。**
  所以向前跑的时候把每个窗口起点的 flash 偏移记下来
  （`dump_ckpt[]`，512 项够 4 GiB 的片子），往回跳直接查表。
* **crc32 只在向前那一遍累加**，重传不会把同一段算两次。
  好处是它算的是**真正发出去的字节**，比对一个暂存区做校验和
  说得更多；代价是它要等传完才有，所以 `/dumpinfo` 的序号是在
  **传完**时才跳的 —— 页面能拿到这个数，本身就证明传到了头。

填一个窗口会把网络循环堵一下（几百毫秒），TCP 等得起；
副作用是设备不再「先静默几十秒再开始传」，第一个窗口填完就开始发。

落点仍然不能用 `$loadaddr`：`httpd_rx()` 会把每一个新连接的
请求头写进那里。现在只要空出一个窗口，所以从可用内存顶部
往下取一小块就够，间隔 2 MiB 招呼住请求头和体检在 `$loadaddr`
上的读取。上传会冲穿任何间隔，所以下载期间的 POST 直接回 400 ——
悄悄截断会让用户拿到一份自以为好的坏备份。同一时刻只允许一个
下载，第二个从**另一个**缓冲区回 503（用 `dump_fail()` 会写坏正在传的
那份的响应头）。

**被放弃的下载得能收回来。** 用户在浏览器里点取消、关掉标签页、网线一
松 —— 传输永远到不了末尾，`dump_busy` 就一直挂着，之后**每一次上传都会
被 503 挡掉**；而页面是个单页应用、正常操作不会重新加载，用户只能自己
按 F5。所以 `dump_tx()` 每发出一次就记一下时间，`DUMP_IDLE_MS`（15 秒）
内一个字节都没出去，下一个请求就把缓冲区接管过去。误伤一个只是暂停了的
下载也不会让谁拿到坏备份：crc32 只在向前那一遍累加，接管之后序号根本
不会跳，`/dumpinfo` 就是不报。

### 刷回原厂是流式的：`POST /stock`

整片镜像放不进内存。`$loadaddr` 到 U-Boot 重定位后的落脚点之间，512 MiB
的板子只有约 249 MiB，而 256 MiB 芯片的裸镜像正好 256 MiB。**分段是我们
的问题，不是用户的问题** —— 所以这条路不再把镜像留在内存里：字节一边到
一边往闪存写，上传多大就不再是个问题。

它**故意不是 multipart**。页面上别的表单都带好几个字段、也都小到可以整个
暂存，那套代码一行没动。流式解 multipart 意味着增量扫 boundary、还要推断
负载在哪里结束 —— 而结尾定界符判断错两个字节，最后一个擦除块里就是两个
字节的脏数据。裸 body 没有这个问题：**偏移在请求行里、长度在 Content-Length 里，第一个包到手就全知道了**。

环形缓冲只需要吸收乱序。栈自己会把 `[rcv_nxt, rcv_nxt + rcv_wnd)` 之外的
段丢掉（`net/tcp.c`），而 `rcv_wnd` 是 `PKTBUFSRX * TCP_MSS`，只有几十 KiB
—— 四个擦除块就够，代码里取到 4 MiB 封顶。`rx()` 返回值就是"从这一段开头
算起收下了多少字节"，放不下就返回 0，对方自然会重传：

```c
tmp_len = tcp->rx(tcp, buf_offs, buf, len);
if (tmp_len < 0) { RST; destroy; }
if (tmp_len) tcp_hole(tcp, tcp_seq_num, tmp_len);
```

**代价是：传失败不再意味着闪存没动过。** 这是流式的定义，辩不掉，所以改成
让失败可以活下来：出错**不重启**，页面还在内存里跑着。

既然如此，**两种失败就必须分开说**，`st_fail()` 按有没有动过第一个擦除块
挑状态码：

| | 何时 | 闪存 | 页面 |
|---|---|---|---|
| `400` | 头还没解完就挡下（偏移没对齐、超容量、接收环放不下） | 未改动 | 「设备拒绝了上传（400）」，改完重来 |
| `500` | 开始写之后擦除或写入失败 | **不一致** | 「设备写入失败（500）」，顶部挂常驻红条 |

连接直接断掉时页面并不知道写到哪儿了，所以**按 500 处理**。

成功的响应体是一行，页面把它拆开摆在自己的完成页上：

```
ok 268435456 bytes crc32 3f2a91c4 skipped 0
```

`crc32` 算的是**设备实际收到的字节**，跟 `/dumpinfo` 备份时报的是同一个
算法同一段数据 —— 备份记一次、写回核一次，读出到写回这条链路就闭合了。
`skipped` 是路上跳过的坏块数，镜像里对应那几块的内容没有落盘（也落不了，
见下一节）。

页面这一侧对应的是单独一页 `p13`：拿到 200 的时候镜像已经整份落盘、设备
正要重启，落回「上传完成」页（那上面写着"设备正在自行写入"，还列一张未来
时的步骤清单）是说反了。

### 位置保持：文件偏移就是 flash 偏移

坏块的处理有两种做法，差别不在代码量而在**这份文件跟谁通用**。

`cmd/mtd.c` 里 `mtd read` / `mtd write` 共用的那个循环是**压缩式**的：

```c
if (mtd_is_aligned_with_block_size(mtd, off) && mtd_block_isbad(mtd, off)) {
        off += mtd->erasesize;
        continue;              /* io_op.datbuf 不动 */
}
```

flash 偏移前进而内存指针不动，于是文件里第 N 个字节落在哪，取决于它
前面有几个坏块。0.3.0 起初两侧都照着它做，结果是**只和自己通用**：
社区里流传的原厂 `all_flash.bin` 基本都是 `dd if=/dev/mtd0` 出来的
（坏块在文件里占着位子），这种文件写进一台有坏块的机器，坏块之后的
一切整体前移一个擦除块 —— 而原厂引导按绝对偏移找东西。

现在两侧都是**位置保持**，和 `dd` 同格式：

| | `dd if=/dev/mtd0` | `/dump` 与「刷回原厂」 |
| --- | --- | --- |
| 文件偏移 ↔ flash 偏移 | 恒等 | 恒等 |
| 读到坏块 | 照读 | **照读**，读失败才填 `0xff` 并记一笔 |
| 写到坏块 | 照写（写不进去） | 跳过不写，**源指针照常前进** |
| 带外区（OOB） | 不含 | 不含 |

两边都不含 OOB，这正是它们能互换的原因；OOB 里只有 ECC（重写自动重算）与出厂坏
块标记（刷回同一块颗粒时它自己还在），出厂数据一个字节都不在里面。展开见[原厂备
份与刷回原厂](backup-and-restore.md#备份里没有-oob--这是对的不是漏了)。

读侧因此**根本不看坏块标记** —— `mtd_read()` 自己不跳，跳过的逻辑
本来就是我们加的。被软件标坏但内容还在的块（用久了磨损标坏的那种）
也就跟着捞回来了。只有 `mtd_read()` 真的失败（`-EBADMSG`，ECC 纠不
回来）才填 `0xff`，那时本来也没有别的东西可给。这同时修掉一个毛病：
以前一个块读不出，整份 235 MiB 的备份直接中止。

写侧那道 `mtd_block_isbad()` 则不能省，而且是**承重**的。`nanddev_erase()`：

```c
if (nanddev_isbad(nand, pos) || nanddev_isreserved(nand, pos)) {
        if (nanddev_isreserved(nand, pos)) return -EIO;
        /* remove bad block from BBT */
        nanddev_bbt_set_block_status(nand, entry, NAND_BBT_BLOCK_STATUS_UNKNOWN);
}
return nand->ops->erase(nand, pos);
```

对坏块它**把 BBT 条目摘掉再照擦不误** —— 擦除连 OOB 一起擦，出厂坏块
标记就在 OOB 第 0 字节。那块从此被当好块用，以后往里存的东西会静静
地坏掉。命令层的 `mtd erase` 有 isbad 保护，`mtd_erase()` 这个 API
没有，所以逐块循环里那道检查是唯一的防线。

剩下不完美的一点是物理性的：**块死了就是死了**。备份之后新坏一块，
它的内容取不回来 —— 但损伤是局部的（丢那一块），而不是压缩式下的
全局错位。串口日志里会列出跳过的块地址。

**进度条给不出字节数，这不是偷懒。** `net/tcp.c` 里只有一个
`static struct tcp_stream`，`tcp_stream_add()` 在旧流没进 `TCP_CLOSED` 之前对新
SYN 直接 `return NULL` —— 而下载那条连接从浏览器点「保存」一直开到文件传完。所
以这期间 `/dumpinfo` **根本连不上设备**，页面问不到「传了多少」。设备侧
`dump_sent` 照样在数、`/dumpinfo` 照样在报，只是送不出去。

这一条是 0.3.0 之后才发现的，而它一度被判据自己盖住了：预览桩的假 XHR 是并发应
答的，`dlstart` 又只静默 900 ms，于是页面那套百分比、速率、剩余时间在 jsdom 里
一路全绿，在真设备上一次都没出现过。**判据自己错了，比没有判据更坏** —— 这是
[踩过的坑](#6-验证判据本身也会错)那一条的又一例，而且这次错的是自己写的判据。

现在桩整段传输都不应答，页面那套永远收不到数的轮询（`dlprog()`、`DLRATE`）删
掉了，进度条保持不确定态，底下一句话说清为什么没有数字、去哪儿看（浏览器自己的
下载栏），传完照旧给 crc32。`dump_sent` 留着不删：它是对的，等哪天 `tcp.c` 长出
第二条流，页面改回轮询即可。

顺带一提，同一个原因让心跳在下载期间也打不通 —— 左下角的点会转黄、写「设备
忙…」，但因为是自己发起的读取（`silent()`），不弹断开框。

**能核对的备份才是备份。** 传完后 `GET /dumpinfo` 回报名字、长度与
crc32。页面读不到隐藏 frame 的**响应头**，所以它先问一次记下序号、再开始
下载、然后轮询到序号变化为止，把每一份追加成一行（不覆盖，
因为一次备多个卷的人需要每一份的 crc32）。本地 `crc32 文件名`
一比就知道有没有坏。

响应**体**倒是读得到，这正好解决了另一个问题：下载走隐藏 frame，设备的
400 / 503 / 507 全都渲染在里面、用户一个字也看不见，只能等轮询在四分钟
后放弃。而**真下载会被浏览器接走、frame 不触发 `load`，只有错误页会**
—— 那就是信号。`dlrefused()` 拿这个事件把 frame 里的文字读出来贴到状态
行上，顺手停掉轮询。四行代码，把所有拒绝从「静默四分钟」变成当场看见。

**环境变量（`GET /env`）。** 只读，按名字排序，页面上带过滤框和「只看关键项」开关（`bootcmd` / `bootdelay` / `bootmenu_*` / `web_uboot_*` / `ethaddr*` / `boot_*` / `ubi_*` / `check_buttons` 与网络那几个；改名前的 `envver` 与 `httpd_*` 也留在过滤器里，好让升级上来的机器看得见自己那几条遗留）。**不做编辑** —— 一个救砖页面把 `bootcmd` 改坏是很差的交易；唯一提供的写入是下面那个整体恢复，它不可能让环境落到这一版没见过的状态。

**恢复默认环境（`GET /envreset`）。** `env default -a && saveenv`，走确认框。`ethaddr` 是手工放回去的：`env default -a` 会连它一起清掉，出厂 MAC 在 `ri` 卷里、下次启动时脚本会重新导出，但**这一次启动**不会 —— 页面上写着「出厂 MAC 不受影响」，所以代码得让这句话是真的。UBI 挂不上时 `saveenv` 会失败，回 `ok` 而不是 `ok saved`，页面据此说「已恢复，但保存失败，断电即失」。

**重启（`GET /reboot`）。** 侧栏最下面一页。答复发出并被 TCP 确认之后才 `reset`，和刷写走同一个形状（`reboot_pending` + `net_set_state(NETLOOP_SUCCESS)`，回到 `do_httpd` 再动手）—— 在 tx 回调里 `reset` 会把响应丢掉，页面看到的就成了「连接中断」而不是「正在重启」。

**体检长到 16 项、分五组。** 平铺 16 行已经读不动，所以 `/check` 的每一项多回一个 `g` 字段，页面按它插分组标题。新增的六项都是「没有串口就查不出来」的那类：

| 组 | 新增项 | 查的是什么 |
| --- | --- | --- |
| 引导 | `web_uboot_envver` | 闪存里的值 vs **这一版编进去的默认值**，落后就说下次正常启动会自动刷新 |
| 引导 | `bootcmd` | 同上逐字比对，不同就是被人改过，原文一并列出 |
| 引导 | 引导菜单 | 条目数 vs 默认条目数 |
| UBI | 磨损 | `ubi->max_ec` / `mean_ec`，超过 20000 次转黄 |
| UBI | 固件 | FIT 里的 `description` 与 `timestamp` —— 回答「现在闪存里躺的是哪一版」，求助贴里最值钱的一行 |
| 环境 | `ubootenv` / `ubootenv2` | 各读头 4 字节（U-Boot 自己的环境 CRC）比对，说得出两份是不是同一个环境 |

外加「U-Boot MAC」现在会和出厂卷里读到的 MAC 对一遍，不同就提示「重建 UBI 后常见，将备份的出厂卷写回即可」。

**「可写空间」算的是刷机可用量，不是 `avail_pebs`。** 只报 `avail_pebs` 的话，一台正常跑着的机器永远是 0 MiB 并顶着黄条：OpenWrt 首次启动会把 `rootfs_data` 铺满 `fit` 没占的每一块。而写固件的两条路（板子自己的 `ubi_write_production` 和内置的 `DEF_WRITE_FIT`）都是**先删 `fit` 与 `rootfs_data`、再建新 `fit`**，所以这两个卷是可用量而不是占用量。现在把它们的 `reserved_pebs` 计进去，并把「其中现在空闲多少、多少是写入时腾出来的」一并写在那一行上，好和上面的卷表对得起来。引导器不在这个名单里：写 `fip` 是在卷自己的预留里原地写，不需要腾任何东西。

**「引导菜单预览」的序号是串口上的按键，不是变量名里的 `n`。** U-Boot 的 bootmenu 只有一位快捷键（`1`~`9`，然后 `a`~`z`，`0` 留给 Exit），所以 `bootmenu_0` 在屏幕上是 `1.`、`bootmenu_9` 是 `a.`。照变量名从 0 标起会跟用户眼前的菜单差一位。

两处实现上的坑：

* **`env_get_default()` 不能用来比 `bootcmd`。** 它在环境未就绪的路径上答复，而那条路走的是一个 **32 字节的静态缓冲区** —— `bootcmd` 和菜单条目回来时是截断的，拿它比「改没改过」永远是「改过」。改成直接扫 `default_environment[]`（`name=value` 平铺、空串结尾）。
* **读 FIT 的描述不能只读头 4 KiB。** sysupgrade 的 FIT 有十几 MB，是因为镜像数据就存在 struct block 里，于是 strings block 被顶到了文件末尾 —— 而 libfdt 解一个属性名要同时用到两头。所以分两次读（头部最多 128 KiB + strings block）拼到一起，再改写头里的偏移让它自洽。拼不出来就只报「是一个 FIT」，不猜。

**内存推导过程也进日志了。** `206` / `310` 的地址混叠探测原本一声不吭，只有最后 `DRAM: 512 MiB` 一行。现在每一步都打：锚点地址与原值、每个候选写到哪、写完锚点读回什么、结论和 dts 是否一致。`dram_init()` 跑在 `console_init_f` 之后，所以这几行落在重定位前的录制缓冲里，**没有串口也能在「诊断」的「串口日志」段看到**。写的过程里顺手补了个洞：探测循环从 512 MiB 起，真装了更小颗粒的板子每个候选都会绕回、答出 512 MiB，U-Boot 就会把不存在的内存交给内核 —— 现在 dts 低于 512 MiB 时直接采信 dts、跳过探测。

### 写入分步进行，回读校验之后由页面决定重启

0.2.x 的顺序是：收完 → 回 200 → 关连接 → `httpd_flash()` 一口气写完 → `reset`。
页面只说得出「传完了」；写得对不对、写没写完，只有串口看得见，而救砖的人手边
通常就是没有串口。

0.3.0 把 `reset` 从这条路上拿掉，顺序变成：收完 → 回 200 → **一步一步写** →
回读校验 → 停在恢复页等页面决定。

**怎么做到一步一步的。** `httpd_flash()` 拆成 `httpd_flash_step()`，每次只干一
件事就返回 `FLASH_MORE`。推它的是 `httpd_tick()` —— `net_loop()` 的超时回调，
每 120 ms 醒一次走一格流水灯，顺手取一步。**这条时钟不依赖浏览器** —— 关掉页
面、拔掉网线，写照样一步步走完。

**整个写入过程都在同一次 `net_loop()` 里。** U-Boot 的每个协议都是这么干的：
TFTP 传 12 MiB、DHCP 四次握手，全靠包到达时的 handler 加
`net_set_timeout_handler()` 在一次 `net_loop()` 里跑完，`NETLOOP_SUCCESS` 的含
义是「这个协议干完了」，不是「等下再来」。0.3.0 的第一版拿它当 yield 用，每步
出去一次再进来 —— 而 `net_loop()` 开头无条件 `eth_halt()` + `eth_init()`，一次
刷写要来二十几遍，每遍丢掉驱动里排队的包。现在只在最后一步之后出去一次。

（那二十几遍其实伤不到什么：`an7581.dtsi` 里 `gdm1` 的 `reg = <1>`，
`airoha_eth_init()` 中带 `phy_startup()` 的分支要 `port->id > 1` 才走，所以链
路不会重新协商；`tcp_init()` 只在 `net_init()` 的 `first_call` 里跑，连接状态
不动；`net_ip` 只在 `DHCP`/`BOOTP`/`RARP` 三个分支里清零。真丢的是至多 8 个
排在 RX 环里的包，`/wr` 轮询下次再要就是。改掉它是因为「借用终态当 yield」本
来就不是这套 API 的用法，顺带把「反复开关 QDMA 那两个 DMA 位有没有硅片层面副
作用」这个从源码里查不出答案的问题一起消掉。）

`httpd_tick()` 故意定义在 LED 那个 `#if CONFIG_IS_ENABLED(LED)` 之外。它原本就
是 LED tick，于是不带 LED 的编译配置根本没有超时回调 —— 步进一挂上去，那种配
置会走完一步就停在那儿服务，闪存写了一半。面板是可选的那一半，时钟不是。

`flash_stepper` 是个函数指针，在 `do_httpd()` 里赋值：`httpd_tick()` 在文件顶
上，`httpd_flash_step()` 在四千行之后，而这个文件不写前向声明。`flash_in_step`
挡住唯一一条递归 —— 有人在 env 配方里塞了网络命令，`run_command()` 会重入
`net_loop()` 再回到这里。

每件事分两拍：先报 `s <文字> [字节]` 再返回，下一拍才真动手。中间隔着一轮
`net_loop()` 的收发，那一行才来得及送出去 —— 否则页面会顶着上一步的文字干等
十秒。

**写入期间设备还活着，于是要挡住七个端点。** 0.2.x 从回 200 到 `reset` 之间它
不服务，谁也插不进来；现在它一边写一边应答，这几条第一次变得可达，全部回 503：

| 端点 | 挡它的理由 |
| --- | --- |
| `/envreset` | `env default -a` 把 `ipaddr` 打回默认，页面当场失联；还要 `saveenv` |
| `/netmode` | 改地址与模式，可能顺带写环境变量卷 |
| `/bootonce` | `saveenv` 写环境变量卷 |
| `/reboot`、`/boot` | 会结束 `net_loop()`，而写入正住在里面 |

`/check`、`/scan`、`POST`、`/dump` 早先就挡了。页面那一侧 `busy()` 把整个侧栏
真禁掉（不只是 `pointer-events`，键盘 Tab 过去也按不动），所以正常路径碰不到；
这七道挡的是第二个标签页和 curl。`do_httpd()` 另有一道兜底：拿到 `FLASH_MORE`
却发现自己已经出了 `net_loop()`，就回去接着写，而不是把写了一半的闪存当成写完。

**进度怎么报。** `wr_log[3072]`，一行一件事，页面用 `GET /wr?from=` 取新的部
分（形状同 `/log?from=`）。行协议：

```
s <文字> [字节]        步骤开始，带字节数时页面按上次实测速度倒计时
v <已完成> <总数>       回读校验的实时进度
r <名> <字节> <crc32>   一个部分写完了
c ok | c bad <说明>     回读校验的结论
t <字节> <秒>           本次实测写入速度，页面存进 localStorage 给下次估算
done | f <说明>
```

**写那一步报不出中间态**，这是刻意的代价：它走 `run_step()` → `run_command()`
执行板子自己的配方（`ubi_write_production` 等），一进去就不回来。而那正是要
的 —— 网页刷固件和串口 TFTP 刷固件必须是同一条脚本，`954` 那次「网页借用板子
的 `ubi_write_fip` 把用户配置抹了」就是分叉的代价。所以写入段只有估计，回读
校验段（这个文件自己的循环）才有真进度。

**回读校验。** 写完按 `up_parts` 走一遍：UBI 卷用 `vf_ubi_read()`，BL2 用
`mtd_read()` 从 `BL2_IMAGE_OFF` 起读；每次进来读 1 MiB（内部 4 KiB 一段），
`crc32` 滚着算，和内存里那份的 `crc32` 比。不一致就 `c bad`，**不弹框、不重
启**，页面顶上挂红条。

**`vf_ubi_read()` 是自己写的 LEB 循环，不走 `ubi_volume_read()`。** 那个封装每
调一次就 `printf("Read 4096 bytes from volume fit to ...")`，回读一份固件要调七
千多次：串口刷一分钟，`CONFIG_CONSOLE_RECORD` 那 64 KiB 缓冲被冲干净 —— 而
「系统诊断」里的串口日志正是写入出问题时要看的东西。它还每次 `malloc` 一个回弹缓
冲再 `free`，并把 `$filesize` 留成最后一段的长度。它底下本来就是
`ubi_eba_read_leb()`，直接调就是同一次读，只是不吵。`check` 传 0：紧接着要拿整
份 `crc32` 和上传的那份比，比 UBI 自己那个逐 LEB 校验说得更死，这本来就是回读
的意义。`vf_buf` 同时按 64 字节对齐 —— 它现在是 `mtd_read()` 的直接落点，不再
只是 `memcpy` 的目的地。

**页面这一半。** POST 的 200 只表示「收下了」，之后 `wrpoll()` 每 700 ms 取一
次；写一个卷的那几秒设备不应答，取不到就下次再取，每行自带绝对值所以漏了不
影响。写完弹「写入完毕」，列出每个部分的长度与 crc32、校验结论、用时，两个按
钮：「留在恢复页」和「立即重启」。

**连带删掉的三样：**

* **`stay` 字段与「写入后不重启」开关。** 每次写完都问，开关就是它的残缺版本。
* **齐闪。** 见上一节。
* **两条硬拒。** 「只写 BL2」「没有 `fip` 卷又不带 U-Boot」原来会被 400 挡下，
  理由都是「写完一重启就起不来」。现在不重启了。

**刷回原厂（`POST /stock`）没有跟着改。** 它本来就边收边写、200 里带 crc32
与坏块数，也本来就全程流水；写完仍然自动重启 —— 整片写完之后这个 U-Boot 已经
被覆盖，留在页面上没有意义。

### 试跑固件：唯一一条不落闪存的路

左栏单独的一页（`p14`）。字段还是 `firmware`，只是多带一个 `tryboot=1`；页面
上没有开关，那个 `checked hidden` 的字段就是这一页的全部身份。0.3.0 早期它是
「日常刷机」上的一个勾，撤掉了 —— 一个 checkbox 扛不动这么大的语义差：文件类
型、动作、按钮文字、结果页，勾上之后全变。

C 侧走的是 `do_httpd()` 里 `tryboot_pending` 那条分支，一句 `bootm`：

```c
snprintf(cmd, sizeof(cmd), "bootm 0x%lx", part_align(fit));
run_command(cmd, 0);
printf("httpd: that image did not boot; the flash was not touched\n");
```

`part_align()` 是每条刷写路径都会过的那一下：libfdt 要求 FIT 落在 8 字节边界
上，而 multipart 的分段落在表单数据把它放到的地方。答复**先发后动手** —— 引导
成功之后就没有谁再能回这个 200 了。

**必须是 `-initramfs-recovery.itb`，不能是 sysupgrade。** 这一条页面上说了两
遍，因为它不显然：sysupgrade 的 FIT 是 `external-static-with-rootfs`，内核起来
之后根文件系统由 `fitblk` 去底层块设备上找，而 `an758x-nokia_xg-040g-ubi-parts.dtsi`
里写着 `rootdisk = <&ubi_fit>` —— 那是**闪存里的 `fit` 卷**，不是 `bootm` 用的
那块内存。试跑不写闪存，也就没换过它：内核是新的、根还是旧的，多半起不来；重
建过 UBI、`fit` 卷压根不在的机器上直接 panic。恢复固件的根随镜像一起进内存，
跟闪存无关，所以它才是这一页要的东西。页面按文件名兜一道（名字里没有
`recovery` 就在确认框里说一句），但不拦 —— 文件名不是凭据。

**交出去之后不再盖遮罩。** `p7` 那一页本身就是说明：闪存动没动、起不来断电就
回来、失败时设备会自己回到恢复页。再叠一个「设备正在启动系统」的框只是挡住
它，所以这段时间 `offline()` 直接返回（`TRYB` 标志），连静默久了本该冒出来的
「与设备的连接已断开」也一并压掉。设备真回来了就整页刷新 —— 那正是 `p7` 上写
着的那一行。判据不能用「uptime 倒退」：`bootm` 失败是 `run_command()` 原地返
回，设备根本没重启，uptime 只增不减。

### 面板灯只回答一个问题：设备还活着吗

| 面板 | 含义 | 能拔网线吗 |
| --- | --- | --- |
| 面板灯**流水** | 设备在工作：等上传、正在写、正在回读校验 | 可以，写照样走完，只是看不到进度 |
| 熄灭后重启 | 你在页面上点了「立即重启」 | ✅ |

0.3.0 之前是两种图形：流水＝网线还在用，齐闪＝上传结束、设备自己在写、网线随便拔。齐闪的含义整个建立在「连接已经关了」之上，而 A1 之后连接不关 —— 从第一个字节到那个重启框，页面一直连着。于是齐闪没有可说的话，删掉了，`httpd_blink()` 变成 `httpd_chase()`：写一个卷的那十秒是同步的，`httpd_tick()` 不跑，改由 cyclic 驱动同一条流水，图形不变。

哪几盏灯参与流水、按什么顺序，由板子在 U-Boot 设备树的 `/options/u-boot` 里用 `httpd-chase-leds` 列出（见上面 [0.4.0](#040流水灯由板子声明tf-的签名-bl2zn504-的-fip-保护)），与灯的名字、颜色无关。

**进度看页面，不看灯。** 灯只说「还在动」；写到哪一步、校验到百分之几，都在进度条上。

拔网线随时安全，写 flash 不经过网络。**要命的是断电**，这一条不靠灯区分，页面上每一处写入前都写着。

### 网络那段会自己刷新；地址与 DHCP 合成一个三选一

**端口表原来是「打开页面那一刻」的快照。** `ports` 装在 `/info` 里，而页面在
`nav()` 里只有 `!INFO` 时才去取一次 —— 网线换个口再回到这一页，看到的还是上一
次的链路状态。改成每次进来都重取 `/info` 是不行的：`ubi_part()` 每调一次都先
`ubi_exit()` 再重新 attach，2047 个擦除块整片扫一遍，几秒钟，串口还跟着刷一
屏。「哪个口亮着」不值这个价钱。

所以把会变的那一半单独开成 `GET /net`：`info_net()` 同时供 `/info` 和它使用，
回 `net` 与 `ports` 两个对象，不碰设备树、不碰 MTD、不挂 UBI。页面在「设备详情
→ 网络」这一段露在前台时每 3 秒问一次，切走就 `clearInterval`，`gone()`（设备
已经搬到别的地址去了）也停。`netfill()` 优先用这一份，没有才退回 `/info` 里那
一份；表单只在第一次照着设备填，之后归用户，轮询回来不许覆盖。

**体检结果同样会过期。** `CHK` 也只在 `nav()` 里 `!CHK` 时跑一次，而体检读的是
闪存 —— 刚把 `ri`、`bosa` 写进去，再进「系统诊断」却还摆着写之前那句「不存在」，看
上去就像没写成。现在凡是动过闪存或环境的动作都把它作废：`wrfin()`（写完）、
`stdone()`（刷回原厂）、`envdef()`（恢复默认环境）、`bootonce()`（改
`bootcmd`，连 `ENV` 一起作废）。下次进「系统诊断」自然重跑，不必再去点「重新检
查」。

#### 两个维度并成一个

原来是「静态地址 or 自动获取」再叠一个独立的 DHCP 服务开关。两个维度四种组合，
三种含义，多出来的那一种（**向上级路由要地址的同时自己也在发地址**）是纯粹的
错。代码只能在背后偷偷把开关关掉来避免它 —— 而「关掉」这个动作又存不进闪存，于
是这个开关是只写 `0` 的：`httpd_dhcpd` 的两个写处里，`netchange_apply()`（改地
址时顺手关）只写 0 且只有它跟着 `saveenv`，`/netdhcpd`（页面上那个开关）只
`env_set()` 从不存盘。**保存过一次静态地址之后，闪存里就永远是 0，开关再怎么点
都只管这一次开机。**

现在是一个值三个取值，那种组合根本表达不出来：

| 模式 | 含义 | 地址 | 掩码 |
| --- | --- | --- | --- |
| `server` | 本机发地址，电脑直连时插上就有 IP | 用户填，**末位强制为 1** | **固定 `255.255.255.0`** |
| `static` | 本机用固定地址，不发地址 | 用户填 | 用户填 |
| `client` | 向上级路由要地址，不发地址 | 由租约决定 | 由租约决定 |

`server` 那两个「固定」不是限制，是把一直以来的隐含前提写下来：
`dhcp_client_ip()` 发出去的一直是 `(net_ip & 0xffffff00) | 100`、网关指向本设
备，所以任何别的掩码描述的都是一个租约并不属于的网络。页面在输入框还在打字的时
候就把 `x.x.x.1` 与 `x.x.x.100` 两个结果摆出来，不留到按下按钮之后才纠正。

#### 「不保存」是结构上的，不是靠标志位

存进闪存的是 `web_uboot_netmode` / `_ipaddr` / `_netmask`，只在开机时由
`netmode_load()` 读一次；`ipaddr` 与 `netmask` 是运行时状态。**不保存的改动只写
后者。** 于是别处出于自己的理由跑的 `saveenv`（`/bootonce`、`/envreset`）没法顺
手把一个临时地址变成永久的，而下次开机 `netmode_load()` 又会拿
`web_uboot_ipaddr` 把 `ipaddr` 盖回去 —— 就算真被存进去了也不算数。

「地址填错了就拔电源」是这个页面唯一的退路，这条得靠结构保证，不能靠一个记着
「现在是不是临时状态」的标志位。

从没设过 `web_uboot_netmode` 的板子（没进过这个页面）走默认：`server` 模式，
`ipaddr` **原样不动** —— 那个值很可能是串口上手工设的，这个页面在被用到之前没有
理由对它有意见。实践中就是默认环境里的 `192.168.1.1/24`。

`client` 存下来的只有「模式」这一个决定，地址与掩码不存：租约不是这块板子的东
西，下次开机重新要一个，而不是顶着别人的地址起来。

页面上那行「**下次开机：……**」直接把 `/info` 回的 `saved` 对象念出来，没设过就
念出厂默认。不保存要付什么代价，不用用户自己推。

#### 一个端点

`/netset` + `/netdhcp` + `/netdhcpd` 合成 `GET
/netmode?mode=&ip=&mask=&save=`，答复 `ok <模式> <地址> <掩码> <saved|ram>`。
仍然是延后执行的：答复必须从旧地址发出去，浏览器正连在那上面，从新地址发的包会
被直接丢掉。

### 传了固件就等于恢复出厂，只换引导器不是

`ubi_write_production`（写 `fit` 卷）会先删掉 `rootfs_data` 给新卷腾地方，所以**这次上传里只要带了固件，配置必然被清空**，勾没勾别的选项都一样。

**只传 `preloader.bin` / `bl31-uboot.fip`、不传固件**的那种日常更新引导器则不清配置。`954` 之前会 —— 那是个 bug，见补丁清单里 `954` 那节。

系统还能进的话，请用 `sysupgrade -c` 保留配置。这个页面的定位是「系统起不来了」。

---

## 首次迁移：从 tcboot / 原厂 换到 ubi 布局

只有这一次需要串口，之后再也不用。**刷了第三方 tcboot 引导的机器连这一次都不用**，
见下面的[从 tcboot 迁移不用串口](#从-tcboot-迁移不用串口)。

**① 串口进 BootROM，xmodem 传两个文件**

按住 reset 上电，看到 `Press x` 时按 `x`，依次传：

```
immortalwrt-airoha-an7581-nokia_xg-040g-md-ubi-preloader.bin      ← BootROM 收，进 SRAM
immortalwrt-airoha-an7581-nokia_xg-040g-md-ubi-bl31-uboot.fip     ← BL2 收，进 DRAM
```

传两个是硬约束：BootROM 只把 BL2 收进 SRAM，那里放不下 431 KB，它也不解析 FIP 里的 BL33。

reset 按不按都行 —— 下一步不需要掐时机。

**② U-Boot 在 RAM 里起来，直接进网页**

`_firstboot` 在碰 flash 之前连着两道闸，任意一道拦下都落到网页：

```
_firstboot=setenv _firstboot ; run check_buttons ; ubi part ubi || run web_uboot_no_ubi ; run ethaddr_factory ; ...
web_uboot_no_ubi=echo ; echo "This flash carries no usable UBI. Leaving it alone." ; echo "..." ; setenv bootmenu_0 "Continue to web recovery at http://$ipaddr=run web_uboot_boot_forever" ; bootmenu 3 ; run web_uboot_boot_forever
```

**两句 echo 的引号是必须的，不是排版。** 这两块板的 defconfig 都是 `CONFIG_SYS_MAXARGS=8`，而 `echo` 是按 `CONFIG_SYS_MAXARGS` 注册 `maxargs` 的：`cmd_process()` 见 `argc > maxargs` 就直接回 `CMD_RET_USAGE`，于是串口上打出的是 `echo` 的用法说明而不是那句话。不加引号时这两条分别是 10 个和 15 个参数，两条都中招 —— 首刷实测就是两坨 usage。加引号后整句是一个 argv，`argc=2`，与句子长短无关。

`web_uboot_no_ubi` 里那句 `setenv bootmenu_0` 是这段能成立的关键（标题写成「Continue to web recovery」而不是照抄第 9 项，否则菜单上会并排出现两条同名条目）：`bootmenu_default=0`，而未初始化环境里的 `bootmenu_0` 是「Initialize environment.=run _firstboot」—— 菜单一超时就会绕回 `_firstboot`，再挂不上 UBI、再进菜单，转圈。把第 1 项当场换成「起网页」，超时执行的就是我们要的那条，且它 `while true` 不返回。改的是内存里的副本，没有 `saveenv`，下次开机不留痕。结尾那句 `run web_uboot_boot_forever` 是兜底：用户在菜单上选了 Exit 或选了一条会返回的条目时，仍然落到网页，而不是继续往下走进 `ubi_format`。

| 走法 | 做什么 | 代价 |
| --- | --- | --- |
| **什么都不做** | `ubi part ubi` 在原厂布局上挂不上 → `web_uboot_no_ubi` 把菜单停 3 秒，超时自动进 `web_uboot_boot_forever` | 不用抢，超时就是你要的 |
| **reset 一直按着** | `run check_buttons` 接住，同样进 `httpd` | 没有时间窗口 |
| **在那 3 秒里按任意键** | 停在菜单上，可以改走 TFTP 或进命令行 | 只给串口用户 |

第一道是按键。第二道是 flash 自己，也是首次迁移真正靠得住的那道：没有它，RAM 里的 U-Boot 会直奔 `_init_env`，在异构 flash 布局上建卷失败、回落 `ubi_format`（`ubi detach ; mtd erase ubi && ubi part ubi ; reset`），于是**两件事同时发生** —— 刚传进来的 U-Boot 随 `reset` 一起没了，而 `ubi` 分区已经被擦干净：`bl2` 分区里的原厂 BL2 还在，可它要加载的 FIP 没了，下一次上电停在 `ERROR: Failed to decompress image` 然后 PANIC。只能再走一轮 xmodem。

> 早先只有 `check_buttons` 这一道，文档也写着「松了 reset 就在 3 秒里选第 9 项」—— 那条路在**首次迁移这一轮根本不存在**：没初始化过的机器默认环境里 `bootdelay=0`、`bootmenu_delay=0`，菜单不停顿，而把它们抬到 3 的 `_switch_to_menu` 在 `_firstboot` 里边，来不及。第 9 项要等迁移完成、环境存下来之后才用得上。
>
> 擦 flash 从此只发生在用户在网页上勾了「重建 UBI」的时候 —— 那时该写回去的镜像已经在这次上传里了。启动流程不再替他做这个决定。

看到流水灯就成了（按着 reset 的这时松手）。

**③ 网页一次传完三样**

左栏切到「引导升级」：

| 格子 | 文件 |
| --- | --- |
| BL2 | `...-ubi-preloader.bin` |
| U-Boot | `...-ubi-bl31-uboot.fip` |
| 固件 | `...-ubi-squashfs-sysupgrade.itb` |
| 重建 UBI（开关） | **必须打开** —— 旧布局上没有有效的 UBI，不擦就建不了卷 |

**④ 写完弹框，点「立即重启」**

写完设备会把每个文件读回来核对一遍再弹框；重启后 `_firstboot` 会建出 `ubootenv` / `ubootenv2` / `ri` / `bosa`，然后正常引导。

> ⚠️ **重建 UBI 会擦掉出厂 MAC。** `ri` 卷没了，`ethaddr_factory` 读不到，MAC 变成默认值。从[原厂备份](backup-and-restore.md)里把 `ri` 写回去即可，随时能做，不影响使用。

### 日常更新引导器就不用勾了

BL2 走 `mtd`，完全不碰 UBI；FIP 走 `web_uboot_write_fip`，它自己只换 `fip` 那一个卷，连 `rootfs_data` 都不动（`954`，见下）。**只要 `ubi part ubi` 挂得上，就不要开重建。**

覆盖正在运行的 U-Boot 是安全的：SPI-NAND 不能 XIP，当前这份早就解压在 DRAM 里跑了，和 flash 上的副本没关系。

### 从 tcboot 迁移不用串口

tcboot 的 web 恢复界面（按住 reset 上电，`http://192.168.1.1/spinand.html`）内部是
`mtd erase spi-nand0` + `mtd write spi-nand0 <addr> 0x0 <len>` —— **写裸设备、按字节
偏移、从物理 0 起**，绕开分区名。把 BL2 和一个含 `fip` 卷的 UBI 一起铺进去，机器
重启就直接是本布局，一次串口都不用接。

镜像结构（五个机型通用，几何一致：PEB 128 KiB、page 2048、`bl2` 0x0–0x20000）：

| 偏移 | 内容 |
| --- | --- |
| `0x00000` | `0xff` × `0x800` —— BootROM 在 `0x800` 找 FIP 头 |
| `0x00800` | `preloader.bin`，补 `0xff` 到 `0x20000` |
| `0x20000` | UBI 镜像：PEB 0/1 卷表，之后 static 卷 `fip` |

**只写 BL2 是必砖**：BL2 按卷名去 UBI 里找 `fip`，而 tcboot 的 ubi 起点在 `0x100000`、
本布局在 `0x20000`，挂不上就停在 `No volume named fip`，只能接串口。所以两样必须
一次写完，而 tcboot 的 `/uboot` 端点只写 `bootloader` 分区、偏移还是 0，做不到。

**闪存容量不影响。** 镜像只占开头几个 PEB，spinand 整片擦之后余下的块都是擦除态，
`ubi part ubi` 挂上来直接登记为空闲；UBI 的坏块预留是 attach 时从空闲池里自己划的，
不需要镜像事先留。

**首次开机串口会刷一屏 `UBI: Bad EC magic`。** 那是 tcboot 整片擦之后剩下的两千来个
裸空块（没有 EC 头），BL2 全片扫时每个叫一声。**只有这一次**：U-Boot 挂上 UBI 时会把
所有无头空块丢进 erase list，`ubi_wl_init` 挨个擦一遍并补上 EC 头，所以第二次开机就
安静了。正常走首刷的机器不吵，也是同一个原因 —— `ubi_format` 里那句 `ubi part ubi`
已经替它补过了。

> 要连第一次都安静，只能把 `uboot-mediatek` 的
> `100-26-mtd-ubi-add-support-for-UBI-end-of-filesystem-marker.patch` 移植进
> `uboot-airoha`，让两边对标记的理解一致。没做：换来的只是一次开机的串口噪音，而这条路
> 的意义就是不接串口；代价却是动所有机器都要走的引导路径。

**不写 EOF 标记块（ubinize 的 `-E`）。** 那是让 BL2 提前结束扫描的优化，在这里是陷阱：
UBI 改卷表是换一个 PEB 重写、再放掉旧的，所以首次启动跑完 `_init_env` 建出 `ubootenv`
之后，卷表就搬到标记块后面去了。下次上电 BL2 扫到标记停手，卷表落在范围外，报
`No volume named fip` —— 第一次能起、重新上电就砖，只能接串口。`ubi_format` 建出来的
UBI 本来也没有标记，BL2 每次全片扫，迁移镜像跟它保持一致。

**迁移之后按日常刷机走，不是首刷。** `_firstboot` 的两道闸都过得去（`ubi part ubi`
挂得上、`ubi check fip` 找得到），于是 `_init_env` 建出 `ubootenv` / `ubootenv2`，
落到网页。这时只传固件那一格即可，**不要勾「重建 UBI」** —— 重建是 `mtd erase ubi`，
从 `0x20000` 开始擦，会把刚写进去的 `fip` 卷一起抹掉。`ubi_write_production` 里两个
`ubi remove` 都被 `ubi check` 守着，`fit` 和 `rootfs_data` 还不存在也不会中断。

镜像由两条路产出，内容一致：

* **CI** —— `Pack Bootloader Kit` 步骤用 build tree 里带 `-E` 补丁的 ubinize 生成
  `tcboot-to-ubi-uboot.bin`，随 Release 和 Artifact 一起发。发行版自带的 ubinize
  没有 `-E`，不能拿来代替。同一步还打一个 `<RELEASE_TAG>-bootloader.zip`
  （preloader + fip + `教程链接.txt`）。
* **网页** —— `guide/migrate-image.html` 在浏览器里重跑一遍 ubinize（EC 头、VID 头、
  卷表记录、CRC32 用 zlib 多项式但**末尾不取反**），给手里已有引导文件、或想用旧版本
  的人用。文件不上传，全在本地算。

---

## 补丁清单

都在 `package/boot/uboot-airoha/patches/`：

| 补丁 | 做什么 |
| --- | --- |
| `202-net-add-httpd-recovery-server` | 全部的 httpd —— 新增 `net/httpd.c`，外加 `net.c` / `Kconfig` / `Makefile` / `net-legacy.h` 四处挂接；`Kconfig` 里四个选项：`CMD_HTTPD`、`HTTPD_FACTORY_VOLS`（出厂数据卷名与长度）、`HTTPD_FACTORY_MAC`（出厂 MAC 在哪个卷的哪个偏移）、`CMD_HTTPD_STOCK_RESTORE`（按板启用裸写） |
| `203-console-record-keep-pre-relocation-output` | 重定位后保留重定位前的 console 录制内容，`GET /log` 才能从横幅看起 |
| `950-configs-xg-040g-md-enable-httpd` | MD defconfig：`PROT_TCP` / `CMD_HTTPD` / `CYCLIC`，`HTTPD_FACTORY_VOLS="ri:0x40000 bosa:0x40000"`，`HTTPD_FACTORY_MAC="ri:0x3e"`，`CMD_HTTPD_STOCK_RESTORE=y`，`CONSOLE_RECORD` 64 KiB（重定位前 2 KiB） |
| `951-defenvs-xg-040g-md-httpd-recovery` | MD 触发路径，与两条 httpd 专用的 env 脚本 |
| `952-xg-040g-md-bootmenu-web-recovery-branding` | MD 引导菜单署名、手动开服务的菜单项、`web_uboot_envver` 自动刷新、`ethaddr` 两道闸 |
| `954-xg-040g-md-httpd-fip-preserve-rootfs-data` | MD defenv 加 `web_uboot_write_fip`（网页更新引导器不清配置） |
| `960` / `961` / `962` | MF 的同一套：defconfig、触发路径、菜单 |

页面本身不在补丁里手改：源文件是 fork 的 `package/boot/uboot-airoha/files/httpd/page.html`，`gen.py` 把它逐行转成 C 字符串塞进 `net/httpd.c` 的 `PAGE_BEGIN` / `PAGE_END` 之间。改页面 → 跑脚本 → 重新生成 `202`。

0.1.x 里 `953`（刷回原厂）和 `954`（`web_uboot_write_fip`）各自带的 `net/httpd.c` 片段在 0.2.0 都并回了 `202`，理由和下面那段一样：它们改的是同一个我们自己新增的文件。剩下的按板差异全部退到 defconfig 与 defenv 里。

`206` / `310`（DRAM 容量探测）编号挨着但**与网页救砖无关**，是独立的 bug 修复，影响所有 an7581 / an7583 设备 —— 见[设备变体 → 内存容量](variants.md#内存容量)。分开放是为了以后单独提上游时不用再拆。它们现在会把整个推导过程打到 console，所以「系统诊断」的串口日志段看得到 —— 唯一的交集就是这个。

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
boot_ubi=run boot_production ; run web_uboot_boot_forever        ← 原来是 boot_tftp_forever
web_uboot_boot_forever=while true ; do httpd ; sleep 1 ; done    ← 新增
_firstboot=... ; run check_buttons ; run ethaddr_factory ...  ← 开头插入按键检查
web_uboot_write_bl2=mtd erase bl2 && mtd write bl2 $loadaddr 0x800 $filesize
web_uboot_format_ubi=ubi detach ; mtd erase ubi && ubi part ubi
```

`web_uboot_write_bl2` 用 `mtd write` 的 offset 参数让 mtd 自己跳过前 `0x800` 字节（BootROM 在那里找 FIP），省掉官方脚本里 `mw.b $loadaddr 0xff 0x800` 那一步 —— 因为 part 是**就地刷写**的，不搬到 `$loadaddr`。

`web_uboot_format_ubi` 是去掉 `reset` 的 `ubi_format`，好让同一次会话接着写卷。

**TFTP 一条没删**：bootmenu 的第 2、4、5、6 项照旧，`boot_tftp*` 全套变量都在。自动路径走浏览器，手动路径留 TFTP。

### `952` 改了什么

菜单原来看不出这是哪来的固件 —— 和一份原厂 UBI 引导长得一模一样，进到菜单里的人也没有路径找回项目。

```
bootmenu_title=  \e[1;39mAiroha Web U-Boot 0.2.0\e[0m    ← 加了版本号，并去掉原来的三对括号
bootmenu_8=\e[31mStart web recovery server (http://192.168.1.1)\e[0m=httpd ; run bootmenu_confirm_return
bootmenu_9=About - github.com/Loong1996/ImmortalWrt-Airoha=run web_uboot_show_about ; run bootmenu_confirm_return
web_uboot_show_about=echo ; echo Web recovery U-Boot by Loong ; echo Guide: ... ; echo Project: ... ; echo Author: ... ; echo
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
- **版本号写了两遍**：`bootmenu_title` 里一份（`952`），`net/httpd.c` 的 `WEB_VERSION` 一份（`202`）。env 是纯文本，看不见 C 宏。改版本要同时动这两个补丁（MF 还有 `962`），并把 `web_uboot_envver` 加一 —— 网页侧栏那个 `0.2.0` 用的就是后者。

> **老机器升级引导器后看不到新菜单 —— `web_uboot_envver` 之后会自动处理。**
>
> `CONFIG_ENV_IS_IN_UBI`：`ubootenv` 卷里存的是**完整一份**环境，加载时整个盖掉编译进固件的默认值。已经初始化过 env 的机器换了新 FIP，菜单还是旧的 —— 新加的 `bootmenu_8` / `bootmenu_9` 根本不在它的环境里。
>
> `952` 加了自动刷新（见下一节 [`web_uboot_envver`](#envver-新-u-boot-自己刷新落后的菜单)），**从 `envver=1` 这版固件开始**升级引导器就不用手动做什么了。手动的办法留着备用：菜单选 `0. Exit` 进命令行，跑：
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

### `web_uboot_envver`：新 U-Boot 自己刷新落后的菜单

默认环境里带一个 `web_uboot_envver`，`board/airoha/an7581/an7581_rfb.c` 里挂一个 `EVT_POST_PREBOOT` 钩子：saved env 的 `web_uboot_envver` 落后于编译进去的默认值，就把描述菜单的那几个变量重新导入一遍，然后 `saveenv`。

时机在 `preboot` 跑完之后、`bootdelay_process()` 和 `autoboot_command()` 画菜单之前 —— env 已加载，菜单还没画。

重新导入的**只有**这些：

```
web_uboot_envver  bootmenu_title  bootmenu_1..bootmenu_9
web_uboot_show_about
web_uboot_write_bl2  web_uboot_write_fip  web_uboot_format_ubi
boot_ubi  web_uboot_boot_forever  check_buttons
```

运行时状态刻意不在列表里：`bootdelay` / `bootmenu_delay`（`_switch_to_menu` 把 0 抬到 3，重置会让菜单闪现即超时）、`bootmenu_0`（初始化后被换成 `bootmenu_0d` 的内容）、`ethaddr` —— 它压根不在默认环境里，`env_set_default_vars()` 的 import 碰不到它 —— 还有 `web_uboot_netmode` 那三个，它们是**用户自己选的网络设置**，不是这一版编译进去的默认值，导进来就等于把人家存好的地址推平。**这就是它比 `env default -a -k` 温和的地方**，后者会把 59 个变量全推平。

最后那三个是 0.3.0 才补进去的，补之前版本号那一下对它们是空转：升级上来的机器拿到了新菜单项，可**引导失败仍然回退 TFTP、复位键仍然进 TFTP** —— 而这两条恰好是没有串口的人唯一能用的入口。它们和 `web_uboot_write_*` 同类，是固件默认值而不是用户设置，所以进列表；`bootdelay`、`bootmenu_0`、`ethaddr` 是用户那一侧的，仍然不进。

三个 `web_uboot_write_*` 在列表里，因为它们确实是默认值：存在的意义就是让人能从串口看见并改写刷写步骤。跨过改名升级上来的机器，saved env 里只有旧的 `httpd_write_*`，新代码找不到就退回 `net/httpd.c` 里的内建副本 —— 行为一样，但那个「可以改写」的口子会悄悄消失，所以让刷新把新名字补进去。旧的那几个留着不动，无害。

> **为什么放在启动时，而不是刷 FIP 的时候**
>
> `env default` 导入的是**当前正在运行的**那个 U-Boot 编译进去的 `default_environment`。刷 FIP 时顺手刷新，装进 env 卷的是**旧版**的默认值 —— 菜单会永远落后固件一版。刚写进 flash 的新 FIP 还没运行，它的默认环境此刻根本不在内存里。**只有新 U-Boot 自己能做对这件事。**
>
> 顺带解释了菜单第 5 项 `boot_tftp_write_fip` 为什么刷完要 `run reset_factory`：清空 env 卷不是「导入旧默认值」，是让新 U-Boot 启动时发现 env 无效、回落到自己的默认环境。那条路是对的，代价是 `ethaddr` 跟着一起没。

改菜单时记得 `web_uboot_envver` 加一，否则老机器不会刷新。

> **刷新之后要自己把 `$ver` 补回标题。**
>
> 追加版本号的 `_bootmenu_update_title` 第一件事就是 `setenv _bootmenu_update_title` 把自己清空 —— 它只为「环境首次初始化」而存在。所以钩子重新导入 `bootmenu_title` 之后，saved env 里已经没有任何人能把版本号加回去，菜单会一直显示没有版本的标题。这是从 0.1.0 网页直接升上来的机器踩到的：菜单项全对，标题却光秃秃。
>
> 现在由钩子自己补。两条路不会重复追加：**环境被重建**时跑的是那个 env 脚本，而那种情况下 `web_uboot_envver` 恰好匹配、钩子不触发；**固件升级**时钩子触发，而脚本早已自删除。钩子放在共用的 an7581 board 文件里是安全的：别的板子默认环境里没有 `web_uboot_envver`，`env_get_default_into()` 返回负值就直接 return。`saveenv` 是尽力而为 —— 首次迁移会在 `_init_env` 建出 env 卷之前走到这里，而它本来就跑在默认环境上，不需要这次写入。

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

出厂数据 `ri` / `bosa` 不在这一页，在「按卷写入」页的「出厂数据」组：

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

所以拆出一条独立的 `web_uboot_write_fip`（和 `web_uboot_write_bl2` 挨着 `mtd_write_bl2` 是同一个套路），
将来改动 TFTP 菜单那条重置流程、或是网页这条例行更新流程，都不会悄悄改掉另一条的行为：

```
web_uboot_write_fip=if ubi check fip ; then ubi write $loadaddr fip $filesize ; else run ubi_write_fip ; fi
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

**BL2 从头到尾不涉及。** `web_uboot_write_bl2` 是朴素的 `mtd erase bl2 && mtd write bl2`，
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

拦死（按钮不出现）的只有页面自己能判定的硬错误：没选文件、卷名非法或缺一半、偏移不是十六进制、没按擦除块对齐、超出容量；0.3.0 起还有勾了重建 UBI 却没选 U-Boot、闪存里没 `fip` 卷却要做会重启的写入而没带 U-Boot、UBI 挂不上却要写卷（见[上面](#030拦截横幅体检日志)，这几条 C 侧也查）。**文件名与常规命名不符只提醒不拦** —— 文件名是可以被改的，而 `.itb` 进了 BL2 格的后果（写到 flash `0x800`，BootROM 认不出，只能串口 xmodem）确实值得一句提醒。

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
## Error: "web_uboot_write_bl2" not defined
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

第二次栽在同一件事上，这次是页面：备份下载的进度条报百分比、速率、剩余时间，
jsdom 里四条断言全绿 —— 而它们验的是**预览桩**，桩的假 XHR 是并发应答的。真设备
上 `net/tcp.c` 只有一条流，下载那条连接一开到底，`/dumpinfo` 连不上，那三个数一
次都没出现过。是用的人报上来才发现的。

绿灯来自一个和设备行为不一致的替身，那它证明的就只是替身。**桩要先像设备，用例
才谈得上像现实**；桩已经改成整段传输都不应答。

---

## 验证方式

每次改动都跑三层，真机编译一次约 1.5 小时，所以前两层要在本地过：

1. **页面** —— `files/httpd/test/` 里的 jsdom 用例，482 个，`cd files/httpd/test && npm install && npm test`（用例自己会先跑 `preview.py` 渲染，不会拿到过期的 HTML）。改动落在 httpd 目录时 CI 跟着跑，见 `.github/workflows/uboot-check.yml`（同一个 workflow 还会真把两块板的 U-Boot 交叉编出来）。覆盖：`/info` 填表与失败降级、每一页的确认框内容与拦截条件、实际提交的 `FormData` 字段集、多文件上传进度按累计长度定位、200 / 400 / 断网三种结局、「不重启」留页并靠心跳回报、备份下载的 URL 与越界拦截、环境变量的过滤与恢复默认、体检分组、心跳的两次失败判定与三种覆盖层、长时间静默只变点不弹框、整片下载是一个文件、传完报出 crc32 且多份往下排不覆盖、重建 UBI 必须 BL2 与 U-Boot 一起传的四种组合（只带一个的两种都拦且不给「仍要写入」、都带放行、不勾重建时单独换 U-Boot 不误伤）、备份下载的进度条不假装知道字节数（进度条是 ind、不摆百分比、说明指向浏览器下载栏）与下载期间心跳转黄但不弹框、端口链路轮询（切到网络那一段才开始、切走就停、桩里改了链路状态表跟着变、轮询回来不覆盖正在编辑的表单）、三种网络模式互斥与各自的字段显隐、服务器档把末位改成 .1 且掩码定成 /24（页面预览与设备回执两处都验）、「不保存则下次开机回到 X」那句话跟着 `saved` 走、`/netmode` 五种回执、写完与改过环境之后体检结果作废并重跑、作者链接。跑的是真实的页面源文件，不是复制品
2. **编译** —— 整个补丁序列打到纯净的 U-Boot 2026.07 上，在 Docker 里（本机已有的 `ghcr.io/openwrt/buildbot/buildworker` 镜像加 `gcc-aarch64-linux-gnu`）对 MD、MF 两个 defconfig 各编一遍 `net/httpd.o` 与完整 `u-boot.bin`。0.1.x 只做语法级检查，漏过一次把 `flash_part()` 圈进 `#if` 的编译错误，这一层就是为它加的

   没有 Docker 的机器上还有一层兜底：`net/httpd.c` 从 `202` 里抽成真正的 `.c` 文件来改（`+` 行进出，行数由脚本重算，round-trip 逐字节比对过），再跑一个不需要编译器的静态检查 —— 去掉注释与字符串后的括号配对、`printf` 族的格式符与实参个数、有没有定义了没用到的 static 函数。先在改动前的版本上跑一遍当对照组。**这不能替代第 2 层**，它查不出 U-Boot API 的签名对不对
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

* ~~**刷写进度做不到。**~~ 0.3.0 做了一半：拆进网络循环里分块跑（见[写入分步进行](#写入分步进行回读校验之后由页面决定重启)）。写入那一步仍然报不出中间态 —— 它在板子自己的 env 配方里，而那条不能分叉；回读校验段有真进度。
* **写入前的机型与魔数校验。** 现在「刷回原厂」那页明写着不校验镜像内容与机型。sysupgrade 的 `.itb` 里 FIT config 带 `compatible`，写之前和 `/info` 的 `model` 比一遍，能挡住「MD 的固件刷进 MF」这类砖 —— 比只认魔数（`0xd00dfeed` / `0xaa640001`）有用得多，两条一起做成本几乎一样。体检里读 FIT 描述那段代码正好可以复用。
* ~~**写完回读校验。**~~ 0.3.0 做了，并且它决定的是要不要重启：对不上就停在恢复页报错，不重启。
* **失败给一个独立灯语。** 灯现在只有流水一种，**写成功和写失败看起来一样**。0.3.0 起页面会说清楚，但那要页面还连得上；灯不需要 —— 两者互补。
* **LAN 1（2.5G 口）。** 要在 U-Boot 设备树里打开 `gdm4`、在 switch 的 mdio 上挂 `0x0f` 的 EN8811H、开 `PHY_AIROHA`，再把 144 KiB 的 MD32 固件放到 U-Boot 读得到的地方（比如一个 UBI 卷）由 env 脚本 `en8811h_load_firmware` 载入。整棵 U-Boot 树里只有 EVB 板用过 `gdm4`，没人在真机上验证过；收益只是多一个口，暂不做。
* **推上游。** `206` 是实打实的 bug 修复，值得提给 immortalwrt；httpd 这套是否适合上游还没想好。
