# 本地编译

不走 GitHub Actions，在自己的机器上编出同样的固件。

`.github/workflows/xg-040g-md-immortalwrt.yml` 里除了「合并磁盘」「缓存工具链」「发 Release」这三件 CI 专属的事，其余步骤都是标准的 OpenWrt 源码树操作，本地可以完整复现。

**什么时候值得这么做**：需要反复改内核补丁、调 DTS、抓 `V=s` 完整日志时。CI 每次都是冷启动，改一行也要重编一两个小时；本地第二次起走增量，通常几分钟。像 [USB2 口带不动 USB3 U 盘](usb2-port-issue.md) 这类要反复试补丁的问题，本地编译基本是必需的。

**什么时候不必**：只是想要一份能刷的固件、或只是想换几个软件包 —— 直接用 [选包页](https://loong1996.github.io/ImmortalWrt-Airoha/packages.html) 加 `Run workflow` 更省事。

## 一、机器要求

| | 最低能跑 | 建议 |
| --- | --- | --- |
| 系统 | Linux x86_64 | **Ubuntu Server 24.04 LTS**（不要用 26.04，见下） |
| 内存 | 4 GB + 4 GB swap，限制 `make -j2` | **8 GB**（4 核）/ 16 GB（8 核以上） |
| 磁盘 | 40 GB 空闲 | **80~100 GB，SSD** |
| CPU | 2 核（首次 4~6 小时） | 4 核以上（首次 1.5~2 小时） |

**系统**：必须是 Linux x86_64。macOS 的文件系统默认大小写不敏感，OpenWrt 构建会在解包阶段就出错；Windows 同理，都得走虚拟机或 Docker。Server 版即可，`make menuconfig` 是 ncurses 界面，SSH 进去就能用，桌面环境白占 1~2 GB 内存。

> ⚠️ **版本要选 24.04 LTS，不要用更新的。** Ubuntu 官网首页默认推最新版，LTS 要去 <https://releases.ubuntu.com/24.04/> 单独下 `ubuntu-24.04.x-live-server-amd64.iso`。
>
> 26.04 上实测第一步就过不去 —— ImmortalWrt 的 `init_build_environment.sh` 按发行版**代号**白名单判断，命中不了就直接退出：
>
> ```
> [ERROR] Unsupported OS, use Ubuntu 20.04 instead.
> ```
>
> 目前认的代号只有 `bionic`(18.04)、`focal`(20.04)、`jammy`(22.04)、`noble`(24.04) 与 Debian 的 `buster`/`bullseye`/`bookworm`/`trixie`；26.04 的代号不在其中。它还要求 `x86_64`，ARM 机器同样会被拒。
>
> 更实质的理由是编译器：26.04 带的 GCC 已是 15 及以上，而 OpenWrt `tools/` 下那批 host 工具（m4、autoconf、elfutils 等）的源码通常滞后于最新编译器，容易在 `-Werror` 上中断，且要一个个单独打补丁绕开。选 24.04 同时也贴近 workflow 里 `ubuntu-latest` 的环境，少一层「新 GCC/glibc 导致某个包编不过」的变量。

> ℹ️ **英文安装的 Ubuntu 要顺手把 locale 设成 UTF-8**，否则 `git log`、`less`、`man`、`vim` 里的中文会显示成 `<E4><B8><AD>` 这类转义。
>
> 容易误判的一点：`echo "中文"` 显示正常**不代表** locale 没问题 —— `echo` 只是把 UTF-8 字节原样丢给终端，由终端自己解码；而 `less` 这类程序是按 locale 决定字节能不能打印的，locale 为 `C` 时就转义掉了。判据看 `locale charmap`，输出 `UTF-8` 才算正常，`ANSI_X3.4-1968` 就是 C locale：
>
> ```bash
> sudo update-locale LANG=C.UTF-8   # 重新登录后生效
> ```
>
> 用 `C.UTF-8` 而非 `zh_CN.UTF-8`：它英文安装也自带、不需要 `locale-gen`，且排序规则仍是 C —— 后者正是编译时想要的，不会改变 `sort`/`ls` 的行为。`build.sh` 自己的输出已内置同样的兜底，不依赖系统设置。

**内存**决定的是并行度而非能否编译。峰值约每个并行任务 1.5~2 GB（链接内核和大型 C++ 包时最高），所以**可用 `-j` 数 ≈ 内存 GB ÷ 2**。4 GB 机器就老实用 `make -j2`：`make -j$(nproc)` 撑爆内存时，OOM killer 会在编译中途杀掉 gcc，报出的错看不出是内存问题，白等几小时。CI 上的 runner 是 4 核 16 GB。

**磁盘** 40 GB 的构成：源码树含 `.git` 约 1.5 GB、`dl/` 上游 tarball 2~4 GB、`build_dir/` + `staging_dir/` + 工具链 25~30 GB、产物 `bin/` 不到 1 GB。建议给到 80 GB 是因为两个变量：三个设备变体和两条源码线若各留一棵树互不干扰（推荐，省得反复 `make clean`），每棵都要 30 GB；选包页勾了 sing-box、xray-core、adguardhome 这类 Go 包的话，要现编 Go 工具链，`build_dir` 再涨 10~15 GB。用 SSD —— OpenWrt 编译是海量小文件读写，机械盘耗时翻倍不止。

## 二、两个仓库

| 仓库 | 作用 | 体积 |
| --- | --- | --- |
| [Loong1996/immortalwrt](https://github.com/Loong1996/immortalwrt) | 源码树，编译在这里跑。**补丁已内置在分支中** | 编完约 30 GB |
| 本仓库 | 只提供 `config/*.config` | clone 后 10 MB |

本仓库其余内容编译都用不到：`docs/`、`selector/`、`portal/`、`guide/`、`img/` 与编译无关。`packages/` 会被挂成 `src-link` feed（`luci-app-airoha-npu` 在里面），`watch/`、`golden/`、`upstream.lock` 只给[漂移检查](upstream-drift.md)用。`config/pkg-versions.txt` 目前没有任何有效行，workflow 里「覆盖软件包版本」那一步整个可以跳过。

推荐 clone 本仓库而不是只拷一个 `.config`：配置会随项目更新，`git pull` 就能同步，只拷文件很容易编出一份和 CI 不一致的固件却不自知。

## 三、完整步骤

以默认组合 `master-airoha` + `xg-040g-md` + `ubi` 变体为例。**全程不要用 root 用户** —— OpenWrt 构建系统会直接拒绝执行。

> 💡 **这一章的全部步骤已封装成仓库根目录的 [`build.sh`](../build.sh)。** 装好第 1 步的依赖后：
>
> ```bash
> git clone https://github.com/Loong1996/ImmortalWrt-Airoha.git
> cd ImmortalWrt-Airoha
> ./build.sh                          # XG-040G-MD + ubi 变体（推荐）
> ./build.sh -v stock -j 4            # 换变体、限制并行度
> ./build.sh -D xg-040g-mf            # XG-040G-MF
> ./build.sh -p "luci-app-passwall"   # 附加软件包，格式同选包页
> ./build.sh -h                       # 全部参数
> ```
>
> 参数与 `Run workflow` 的输入一一对应：
>
> | 脚本参数 | workflow 输入 | 默认 |
> | --- | --- | --- |
> | `-b, --branch` | — | `master-airoha`（唯一维护的线） |
> | `-v, --variant` | 设备变体 `ubi` / `stock` | `ubi` |
> | `-D, --device` | 机型 `xg-040g-md` / `xg-040g-mf` | `xg-040g-md` |
> | `-d, --dram` | 内存容量 | `auto` |
> | `-p, --packages` | 附加软件包 | 空 |
> | `-j, --jobs` | （CI 用 `nproc`） | CPU 与内存推算的较小值 |
> | `-o, --src-dir` | — | 本仓库同级的 `openwrt-<分支>` |
> | `--no-update` | — | 默认每次都把源码与 feeds 更新到远端最新；加这个则编当前这份 |
> | `--menuconfig` `--clean` `--config-only` | — | — |
>
> 脚本做的事和下面逐条列出的完全一致，包含那两处必要的核对。结束时会打印准备／配置／下载／编译四段的分别耗时与合计，用来判断时间花在哪一段（首次编译里下载往往比想象中占得多）。想知道每一步在做什么、或需要手工介入调试时，照下面的手动流程走。

### 1. 装依赖

```bash
sudo bash -c 'bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)'
sudo apt -y install dos2unix libfuse-dev
```

这就是 workflow 里「初始化环境」那一步的原文。用官方脚本而不是手写 apt 列表，是为了和 CI 装的依赖完全一致；ImmortalWrt 上游调整依赖时也会跟着变。

脚本报 `Unsupported OS` 说明系统版本不在它的白名单里（见第一章的说明）。**正确的处理是换成 24.04**，而不是绕过检查 —— 拒绝你的那个版本判断，和后面 GCC 太新编不过是同一个原因。

只在系统版本确实受支持、但你不想让脚本改动 apt 源和 GCC 版本时，才用手动装依赖代替：

```bash
sudo apt update
sudo apt install -y build-essential clang flex bison g++ gawk \
  gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
  python3 python3-dev python3-setuptools rsync swig unzip zlib1g-dev \
  file wget time ccache libelf-dev zstd dos2unix libfuse-dev
```

这是 OpenWrt 官方文档给 Ubuntu 的依赖集，加上 workflow 额外装的 `dos2unix` 与 `libfuse-dev`。真缺什么，`make -j1` 会明确报出缺哪个头文件或命令，不会白编几小时。

### 2. 拉两个仓库

```bash
mkdir -p ~/build && cd ~/build
git clone https://github.com/Loong1996/ImmortalWrt-Airoha.git
git clone https://github.com/Loong1996/immortalwrt.git -b master-airoha openwrt
cd openwrt
```

机型支持与 U-Boot 补丁都在源码分支里，不需要再拷任何补丁。

只维护 `master-airoha` 一条线，见[源码分支与跟进上游](branches.md)。

### 3. feeds

```bash
./scripts/feeds update -a
./scripts/feeds install -a

# 在默认 SSH banner 和 /etc/openwrt_release（LuCI 固件版本）后面追加作者信息（build.sh / CI 会自动跑）
python3 ../ImmortalWrt-Airoha/scripts/inject-author-info.py
```

### 4. 配置

机型决定子目标与配置文件，变体决定设备符号，对应关系和 workflow 的「生成变量」一步一致：

| 机型 | 子目标 | 配置文件 | `device_variant` | 设备符号 |
| --- | --- | --- | --- | --- |
| `xg-040g-md` | `an7581` | `config/xg-040g-md-master.config` | `ubi`（默认，推荐） / `stock` | `nokia_xg-040g-md-ubi` / `nokia_xg-040g-md` |
| `xg-040g-mf` | `an7583` | `config/xg-040g-mf-master.config` | 同上 | `nokia_xg-040g-mf-ubi` / `nokia_xg-040g-mf` |

```bash
DEVICE_SYMBOL=nokia_xg-040g-md-ubi
SUBTARGET=an7581                     # MF 是 an7583，配置文件换 xg-040g-mf-master.config
cp ../ImmortalWrt-Airoha/config/xg-040g-md-master.config .config

# 先清掉配置里这个子目标的所有设备行，再插入选中的那个
sed -i "/^CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_/d" .config
sed -i "/^# CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_/d" .config
sed -i "/^CONFIG_TARGET_airoha_${SUBTARGET}=y/a CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${DEVICE_SYMBOL}=y" .config

make defconfig

# 必须有输出，否则该分支里根本没有这个设备
grep "^CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${DEVICE_SYMBOL}=y" .config
```

子目标必须和机型对上：把 MF 的符号插在 `an7581` 那一行后面，`defconfig` 同样静默丢掉，编出来的是没选中任何设备的空壳。

最后那行 `grep` 不是走形式。`make defconfig` 遇到当前源码树里不存在的符号会**静默删掉**对应行，不报任何错；漏掉这次核对，就要等一两小时编完、发现产物文件名不对才知道选错了变体。workflow 里同样在 `defconfig` 前后各查一次。

各变体的分区布局、刷机方式与能否回退原厂，见[设备变体](variants.md)。

### 5. 附加软件包（可选）

选包页生成的那串包名，本地就是直接改 `.config`：包名前无 `-` 表示编入固件，有 `-` 表示从基础配置中剔除。

```bash
# 加装
echo "CONFIG_PACKAGE_luci-app-passwall=y" >> .config
# 剔除
echo "# CONFIG_PACKAGE_luci-app-ttyd is not set" >> .config

make defconfig
grep "^CONFIG_PACKAGE_luci-app-passwall=y" .config    # 同样要核对
```

改完必须重跑 `make defconfig` 补全依赖。核对一遍的理由和上面相同 —— 包名拼错、或该分支根本没有这个包时，`defconfig` 会安静地把那行丢掉。哪些包能选、刷完机后还能不能 `apk add` 补装，见[自定义软件包](packages.md)。

### 6. 内存容量（一般不用管）

默认「自适应」：U-Boot 探测实际颗粒并 fixup 进 DTB，512M / 1G / 2G 机器刷同一份固件。

探测本身是我们补的（`206-airoha-an7581-probe-dram-size.patch`）—— 上游 U-Boot 只读 DTS 不探测，而它 fixup 时又会覆盖内核的 `memory` 节点，结果 1G 机器被摁回 512M。

> **内存还有第二道闸门**：`linux,usable-memory-range`。U-Boot 探测出 1G，内核仍会按这个属性裁一刀。本线已经把它放到 `0x7fe00000`（2G，等于不裁剪），本地编译不用管。
>
> 但如果你是从**上游 immortalwrt** 直接编，那边还是 `0x1fe00000`（512M − 2M），得自己放开：
>
> ```bash
> sed -i 's/<0x0 0x80200000 0x0 0x1fe00000>/<0x0 0x80200000 0x0 0x7fe00000>/' \
>   target/linux/airoha/dts/an758x-nokia_xg-040g-common.dtsi
> ```
>
> 写 `2G` 只是「不裁剪」的意思 —— 该属性只能往少了裁，写大不会让系统去访问不存在的内存。

想反过来**故意把系统限制到更小**（做对照实验）时，改的也是这个属性：`0x1fe00000` = 512M、`0x3fe00000` = 1G。改 `memory` 节点没用，会被 fixup 覆盖。细节见 [设备变体 → 内存容量](variants.md#内存容量)。

### 7. 编译

```bash
make download -j8
find dl -size -1024c -delete      # 清掉下载失败的残缺文件

make -j$(nproc)                   # 内存不足时改成 -j2 / -j4
```

编译失败要看清楚错在哪时，按 workflow 的兜底顺序重跑：

```bash
make -j1 V=s
```

单线程加 `V=s` 输出完整命令行，日志不会被并行任务打乱。这一步慢，但只重编失败的那个包，不会从头来。

## 四、产物

```bash
ls bin/targets/airoha/an7581/        # MD；MF 在 an7583/
```

关注哪几个文件取决于变体：

| 变体 | 刷机用文件 |
| --- | --- |
| `stock` | `factory-kernel.bin` + `factory-rootfs.bin` |
| `ubi` | `preloader.bin` + `bl31-uboot.fip`（USB-TTL 刷入）、`*-recovery.itb` 救援镜像 |

`bin/packages/` 下是本次编出的全部 `.apk`，刷完机后补装软件包用得上 —— workflow 会把它打包成 `Packages.tar.gz` 传进 Release，本地直接从这个目录取即可。

### 从编译机拉回本机

编译机往往在家里、人在外面 ssh 回去。产物不用先挪到别处，在**本机**上反向拉就行。ssh 端口不一定是 22，rsync 要把它塞进 `-e`，scp 用大写 `-P`：

```bash
# 本机执行；HOST / PORT 换成你 ssh 回去用的那套
mkdir -p ~/Downloads/xg040g && cd ~/Downloads/xg040g

# 整个产物目录，断线可续传（-P）；MF 把 an7581 换成 an7583
rsync -avP -e 'ssh -p PORT' 'user@HOST:~/build/openwrt-master-airoha/bin/targets/airoha/an7581/' an7581/

# 只要某几个文件：通配符放在引号里，让远端展开
rsync -avP -e 'ssh -p PORT' 'user@HOST:~/build/openwrt-master-airoha/bin/targets/airoha/an7581/*xg-040g-md-ubi-*' .

# 没有 rsync 就 scp，断了得重来
scp -P PORT 'user@HOST:~/build/openwrt-master-airoha/bin/targets/airoha/an7581/*xg-040g-md-ubi-*' .
```

目录里的 `sha256sums` 一起拉下来，`sha256sum -c --ignore-missing sha256sums` 能确认外网传输没出错（macOS 用 `shasum -a 256 -c`）。

`~/.ssh/config` 里给编译机写好 `Host` / `Port` 之后，上面的 `-e` / `-P` 都可以省掉。

### MD 与 MF 共用一个源码树

两款机器同属 `airoha`、同一 CPU 架构（`aarch64_cortex-a53`），只是子目标不同，所以 `build.sh -D xg-040g-mf` 用的是同一个 `openwrt-master-airoha`，编完 MD 再编 MF 复用得很多：

| | MD 编完后再编 MF |
| --- | --- |
| 工具链、用户态软件包 | 复用——按架构分目录，两个子目标共用 |
| 内核、kmod | 重编——按子目标分目录 |
| `uboot-airoha`、镜像打包 | 重做 |

大约二三十分钟。交替编两边也不互相踢缓存，各自的内核目录都留着，只有 `.config` 在切换。

## 五、增量重编

本地相对 CI 的真正优势在这里。`build_dir/` 与 `staging_dir/` 都在，改动后只重编受影响的部分：

```bash
# 改了某个包的源码或 Makefile
make package/luci-app-airoha-npu/{clean,compile} -j$(nproc)

# 改了内核补丁或 DTS
make target/linux/{clean,compile} -j$(nproc)

# 重新打包固件（不重编）
make -j$(nproc)
```

几个 clean 的层级，别用错：

| 命令 | 清掉什么 | 下次编译耗时 |
| --- | --- | --- |
| `make clean` | `build_dir/target-*` 与 `bin/`，保留工具链 | 30~60 分钟 |
| `make dirclean` | 连工具链一起清 | 和首次一样，1~2 小时 |
| `make distclean` | 再加上 `dl/` 和 `.config` | 最慢，几乎不需要 |

日常改代码用 `make target/linux/clean` 或 `make package/<name>/clean` 这种带路径的就够了，**不要动不动 `make dirclean`** —— 工具链重编是这里面最耗时的部分，而它几乎从不需要重来。

换设备变体或换源码分支时不必 clean，改完 `.config` 重跑 `make defconfig` 再 `make` 即可；`dl/` 目录可以在多棵源码树之间共享（软链过去），省一次几 GB 的下载。

### 拉取源码更新与强推

`build.sh` **默认每次都把源码与 feeds 更新到远端最新**，编译机的常态就是要最新代码。开始编译前会打印这次的分支、HEAD（短 SHA、日期、提交标题）、设备与配置，日志翻回来时能一眼确认编的是哪份代码。

要固定基线时加 `--no-update`：调内核补丁做前后对比时，基线在不知情中变动会让对比失去意义 —— 否证一个假设的前提是只有一个变量在动。本地有未提交的调试修改而更新又被拦下时，它也是直接往下编的退路。

需要留意的是这条线跟进上游走的是 `rebase` + `push --force-with-lease`（见[源码分支与跟进上游](branches.md)），**远端历史会被重写**，此后普通的 `git pull --ff-only` 必然失败：

```
fatal: Not possible to fast-forward, aborting.
```

`--update` 对此分情况处理：

| 远端状态 | 行为 |
| --- | --- |
| 能快进 | 直接快进 |
| 已分叉，且本地工作区干净、无自己的提交 | 打一个 `backup/<时间戳>` 分支保住旧 HEAD，再 `reset --hard` 对齐远端 |
| 已分叉，但本地有未提交修改或自己的提交 | **停下**并列出来，交给你 stash 或建分支，绝不静默丢弃；想跳过更新直接编就加 `--no-update` |

判断「本地有没有自己的提交」用的是 `git cherry` 的 patch-id 比对，而不是 SHA。因为 rebase 之后本地旧提交的 SHA 在远端已不存在，按 SHA 算会把它误判成你的改动 —— 那样每次跟进上游都会卡住，而这恰恰是最常见的场景。

强推重置之后基线变了，内核补丁或 DTS 若有改动，这次编译建议加 `--clean`。只改了某个包（比如 `uboot-airoha` 的补丁）则不用：包目录内容的 md5 进了 `.prepared` 戳，那个包会自动重新解包、打补丁、编译，其余全部沿用缓存。

**远端把几个提交合并成一个之后**（0.2.0 那次就是把 5 个提交并进了一个），`git cherry` 认不出被合并过的内容，会把它们列成「本地有远端没有的提交」而停下。确认那些就是被并掉的提交后，手工对齐一次：

```bash
cd ~/build/openwrt-master-airoha
git branch backup-$(date +%Y%m%d) HEAD          # 保险，随时可删
git fetch origin master-airoha && git reset --hard origin/master-airoha
```

脚本每次编译都会往 `banner` / `openwrt_release` / `os-release` 三个模板里写作者信息，更新前会先把它们还原，不会被自己的产物拦住；「工作区有未提交的修改」里列出的只会是你自己的改动。

## 六、与 CI 的差异

本地跳过的步骤，以及为什么不需要：

| workflow 步骤 | 本地 |
| --- | --- |
| 合并磁盘 `maximize-build-space` | 不需要，机器磁盘本来就够 |
| 缓存工具链 `cachewrtbuild` | 不需要，本地天然增量 |
| 覆盖软件包版本 | 跳过，`pkg-versions.txt` 当前无有效行 |
| 先编被覆盖的包 | 同上，无覆盖则不触发 |
| 整理文件 / 发布 Release / 更新门户网页 | CI 专属，与固件内容无关 |

**产物是否等价**：以上跳过的步骤都不改变编译输入，同一分支、同一份 `.config`、同一变体编出的固件功能一致。二进制不会逐字节相同（时间戳、构建路径、编译器次版本差异），这属正常。

想让本地编译再快一点，可以在 `make menuconfig` 里开 `Advanced configuration options → Use ccache`，反复重编同一棵树时命中率很高。CI 上刻意关掉了（`ccache: false`），因为每次都是全新环境，缓存没有意义。
