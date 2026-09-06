# LED 行为

XG-040G-MD 是光猫改的路由器，**面板丝印还是光猫那套**，而 DTS 里套的是 OpenWrt 的通用命名，两者对不上号。下面按实机 `/sys/class/leds/` 的名字列。

## 面板灯

| 面板丝印 | sysfs 名 | GPIO | 现在的行为 |
| --- | --- | --- | --- |
| 电源 | `green:power` | 17 | 常亮 |
| **注册** | `green:wan` | 18 | **不接管，常灭** |
| **光信号** | `red:wan` | 19 | **不接管，常灭** |
| **上网** | `green:wan-online` | 20 | **不接管，常灭** |
| USB1 | `green:usb-1` | 35 | `usbport` trigger |
| USB2 | `green:usb-2` | 34 | `usbport` trigger |

「注册」「光信号」「上网」这三个是光猫的灯，当路由器时没有对应状态，固件**一律不接管**，保持出厂行为不动。想自己派用场见下方[自定义](#自定义)。

## 网口灯

| 口 | sysfs 名 | PHY | 备注 |
| --- | --- | --- | --- |
| lan1 | `mt7530-0:0f:green:lan-1` | Airoha EN8811H | 2.5G 口，外置 PHY 芯片 |
| lan2 | `mt7530-0:0a:green:lan-2` | mt7530 内置 | SoC gpio44 复用 `phy2_led0` |
| lan3 | `mt7530-0:0b:green:lan-3` | mt7530 内置 | SoC gpio45 复用 `phy3_led0` |
| lan4 | `mt7530-0:0c:green:lan-4` | mt7530 内置 | SoC gpio46 复用 `phy4_led0` |

四个都由 [`board.d/01_leds`](https://github.com/Loong1996/immortalwrt/blob/master-airoha/target/linux/airoha/an7581/base-files/etc/board.d/01_leds) 绑 `netdev` trigger，模式 `link tx rx` —— 有链路常亮，收发时闪。

> ℹ️ **PHY LED 的 `brightness` 恒为 0 是正常的。** 它们工作在 PHY 硬件控制模式，亮灭由芯片自己驱动，不经过 sysfs 的软件亮度。判断是否配好要看 `trigger` 是不是 `netdev`，不是看 `brightness`。

```sh
for l in /sys/class/leds/*/; do n="${l#/sys/class/leds/}"; n="${n%/}"
  printf '%-28s b=%-3s t=%s\n' "$n" "$(cat "$l/brightness" 2>/dev/null)" \
    "$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$l/trigger" 2>/dev/null)"; done
```

## lan1 口灯曾经常灭

2026-08 之前的固件上，2.5G 口的灯插网线也不亮。根因在 EN8811H 驱动：LED 引脚只在 `.probe()` 里配过一次输出方向

```c
/* Configure led gpio pins as output */
ret = air_buckpbus_reg_modify(phydev, EN8811H_GPIO_OUTPUT,
                              EN8811H_GPIO_OUTPUT_345,
                              EN8811H_GPIO_OUTPUT_345);
```

而 `.config_init()` 除首次外每次都重启 MD32 MCU，**重启会把引脚方向复位回输入**，之后没有任何地方配回来。于是 PHY 每被 re-attach 一次，灯就永久灭掉 —— 而正常启动时 lan1 要 attach 三次。

两个佐证：写 sysfs 的 `brightness` 强制点亮无效（规则确实写进了 PHY 寄存器，但引脚是输入）；failsafe 下灯却正常（那条路径不跑 MAC 钩子，lan1 只 attach 一次）。

修复在 [`patches-6.18/805`](https://github.com/Loong1996/immortalwrt/blob/master-airoha/target/linux/airoha/patches-6.18/805-net-phy-air_en8811h-reconfigure-LED-gpio-direction-af.patch)，把引脚方向配置移进 `config_init`，放在 MCU 重启之后。

> ℹ️ 修好之后 `dmesg` 里**仍然会有两三次 attach**，那是正常的。patch 解决的是「每次 attach 之后引脚方向都重新配上」，不是消除 attach。

上游主线 2026-08-23 合入了同一个修复（[`03b4702f` net: phy: air_en8811h: move LED GPIO configuration to config_init](https://github.com/torvalds/linux/commit/03b4702fc5e311cbac9ba8654021a88f0dac914c)），做法与 805 相同，只是写在 `config_init` 末尾。等它进 6.18 stable 或 OpenWrt 的 backport 后，805 可以直接删掉。

### 已知问题：启动过程中插网线，灯可能不亮

805 解决的是确定性的那部分。还剩一个时序窗口：**上电后、系统起来前这段时间里插上 lan1 的网线**，灯有一定概率整次启动都不亮，同一份固件下一次启动又正常。原因是 link Up/Down 事件插进了三次 attach 之间，最后一次写引脚方向不一定排在最后一次 MCU 重启之后。上游那个修复同样没有覆盖这个窗口，所以先记着，等上游。

| 情况 | 结果 |
| --- | --- |
| 网线插好再上电 | 每次都亮 |
| 系统起来后再插 | 亮 |
| 上电后、起系统前插 | 有概率不亮 |

灭了之后**重新插拔网线救不回来**，链路变化不会重跑 `config_init`；`ifdown lan; ifup lan` 或重启即可。已经确认与固件版本、配置文件无关：2026-09-06 在 master-airoha 上复现，内核补丁、DTS、`01_leds` 与旧线逐字节相同。

如果以后要自己堵这个窗口，方向是在驱动的 `.read_status` 里链路 Up 时再写一次 `EN8811H_GPIO_OUTPUT`，改动只影响 EN8811H 这颗 PHY（MD、MF、an7583 EVB 都用它），不碰数据面。

## 自定义

LED 配置由 `01_leds` 生成到 `/etc/config/system`，**只在首次启动或恢复出厂设置时跑一次**。保留配置 sysupgrade 不会重新生成，改完直接 `uci` 就行。

拿「注册」灯当第二个 WAN 指示：

```sh
uci -q delete system.led_wan
uci set system.led_wan=led
uci set system.led_wan.name='wan'
uci set system.led_wan.sysfs='green:wan'
uci set system.led_wan.trigger='netdev'
uci set system.led_wan.dev='lan1'
uci set system.led_wan.mode='link tx rx'
uci commit system
/etc/init.d/led restart
```

`mode` 可用 `link`、`tx`、`rx`、`link_10`、`link_100`、`link_1000`、`link_2500` 组合。LuCI 里在**系统 → LED 配置**也能改。

「上网」和「光信号」想跟着 wan 接口走的话，`netdev` trigger 不合适 —— 它只能跟到网卡的 carrier，网线插上就算亮，表达不了「地址已经拿到」；PPPoE 下 wan 的 netdev 还会变成 `pppoe-wan`，绑死物理口也不对。用 hotplug：

```sh
cat > /etc/hotplug.d/iface/99-panel-leds <<'EOF'
[ "$INTERFACE" = "wan" ] || exit 0

case "$ACTION" in
	ifup)
		echo 1 > /sys/class/leds/green:wan-online/brightness   # 上网灯亮
		echo 0 > /sys/class/leds/red:wan/brightness            # 光信号灯灭
		;;
	ifdown)
		echo 0 > /sys/class/leds/green:wan-online/brightness
		echo 1 > /sys/class/leds/red:wan/brightness            # 掉线亮红
		;;
esac
EOF
ifup wan     # 触发一次
```

hotplug 脚本放在 overlay 里，`sysupgrade` 保留配置时会跟着留下。
