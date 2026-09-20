# 已知问题：2.5G 口（lan1）偶发收不到包，重启即恢复

> **状态**：偶发，未能稳定复现。重启就好。下方记录了一次完整的现场数据、已排除的方向和下次接手的抓手。
> **记录日期**：2026-09-20
> **机型**：XG-040G-TF 实测遇到；lan1 的硬件与驱动路径 MD、MF、ZN504XG-D 完全相同，理论上都可能出现

## 现象

`lan1`（2.5G 口，外置 EN8811H PHY）链路正常建立，`ethtool` 一切正常，但**数据收不进来**：

- 接在这个口上的电脑拿不到 DHCP 地址，退回 `169.254.x.x`
- 手动配静态 IP 后 ping 网关也不通
- 千兆口（lan2~lan4）同时正常

**重启一次就恢复，之后一直正常。**

## 实测数据

链路本身是好的，`ethtool lan1` 能读出完整能力表，对端是 1G 网卡：

```text
Speed: 1000Mb/s      Duplex: Full     Link detected: yes
Supported link modes:   100baseT/Half 100baseT/Full 1000baseT/Full 2500baseT/Full
Link partner advertised link modes:  10baseT/Half ... 1000baseT/Full
```

关键在收包计数 —— **收到 22 个包，却有 233 个 errors，全部被丢弃**：

```text
3: lan1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br-lan state UP
    RX:  bytes packets errors dropped  missed   mcast
          6347      22     233     233       0       9
    TX:  bytes packets errors dropped carrier collsns
          6833      49       0       4       0       0
```

帧到得了 MAC，但内容是坏的。发送方向没有错误计数。

桥和网口配置都正常，`lan1` 在 `br-lan` 里处于 forwarding：

```text
lan1             UP             2e:1f:19:f4:02:7a
lan2@eth0        DOWN           2e:1f:19:f4:02:7a
br-lan           UP             2e:1f:19:f4:02:7a
```

## 已排除

### 1. 速率适配（2.5G SerDes 对 1G 对端）❌

最初怀疑这个：SerDes 固定在 2500base-x，而链路协商成 1Gbps，中间的速差要靠 PHY 的速率适配填平。但：

- 用 `ethtool -s lan1 advertise 0x008` 把链路压到 **100M，同样不通**。低于 2.5G 的速率全都坏，不是某一档的问题。
- 内核这条路径是对的：`air_en8811h` 的 `en8811h_get_rate_matching()` 恒返回 `RATE_MATCH_PAUSE`；`phylink_link_up()` 遇到它会把 **2500** 而不是媒体速率传给 MAC（`phylink_interface_max_speed()`），`airoha_mac_link_up()` 据此设置 GDM4 的 TX/RX 分片大小。
- 流控由 PCS 驱动在 `pcs_link_up()` 里配（`AIROHA_PCS_XFI_TX_FC_EN` / `RX_FC_EN`），日志里也显示 `flow control rx/tx`。

### 2. PHY 匹配不上 ❌

上游修过一次相近的毛病（immortalwrt `1c68c06b4f`，PR openwrt/openwrt#24624）：DTS 里用通用的 c45 compatible，PHY ID 读成 0，驱动不匹配，**口直接起不来**。修法是按 ID 写死 `ethernet-phy-id03a2.a411`。

那是另一种症状，而且修复在共用 dtsi 里，四个机型都继承着。本问题里驱动匹配正常：

```text
airoha_eth 1fb50000.ethernet lan1: PHY [mt7530-0:0f] driver [Airoha EN8811H] (irq=POLL)
Airoha EN8811H mt7530-0:0f: MD32 firmware version: 25062302
```

### 3. 网络配置 ❌

`board.d/02_network` 把 lan1~lan4 都放进 LAN 桥，`02_network`、`01_leds` 的机型分支都正确，日志显示 `lan1` 进了 forwarding 状态。

### 4. 极性反转 ❌

EN8811H 支持 `rx-polarity` / `tx-polarity`（旧名 `airoha,pnswap-rx/tx`，见内核补丁 `785-v7.0-07`）。本项目的 dtsi 没有声明这两项，而同一份 dtsi 上 MD 在 2.5G 下工作正常，说明默认极性是对的。

## 可疑的时序

两件事都发生在开机那十几秒里，都会改变链路状态：

1. **用户在开机过程中拔插网线**。遇到问题的那次正是这样，事后也没能再稳定复现。
2. **MAC 钩子会把网口 down 再 up 一次**。`base-files/lib/preinit/90_airoha_ubi_mac` 改 MAC 前必须先 down —— 驱动的 `airoha_dev_set_macaddr()` 走 `eth_mac_addr()`，而接口 up 时它直接返回 `-EBUSY`（驱动没有设 `IFF_LIVE_ADDR_CHANGE`）。日志里看得很清楚：

```text
[  12.867] lan1: Link is Up - 1Gbps/Full          ← 网线插着
[  15.009] lan1: Link is Down                     ← 钩子 down 掉它改 MAC
[  15.134] lan1: configuring for phy/2500base-x link mode
- MAC 2e:1f:19:f4:02:7a from no ri volume, random -
```

> ℹ️ **有 `ri` 卷的机器不会被 down/up。** 钩子在 MAC 已经一致时直接跳过。所以这一条只影响**重建 UBI 之后、用随机 MAC 的机器**。

## 恢复方法

**重启。** 千兆口不受影响，可以先用 lan2~lan4。

## 下次从哪接手

**先复现。** 三次开机，每次只改一个条件，起来后用静态 IP ping 网关，并看 `ip -s link show lan1` 的 errors：

| 条件 | 说明 |
| --- | --- |
| 全程插着线不动 | 坏 → 指向钩子那一下 down/up |
| 全程不插线，起来后再插 | 正常则说明开机期间的链路事件是关键 |
| 开机 10~20 秒之间拔一次再插回 | 坏 → 就是拔插时机的问题 |

**复现后要抓的：**

```sh
dmesg | grep -iE 'gdm|pcs|8811|phylink|lan1'
ip -s link show lan1; sleep 10; ip -s link show lan1   # 空闲时错误是否自己涨
```

空闲也在涨，说明 PHY/SerDes 这一层就在收垃圾数据，方向指向 PCS 或 PHY 的状态机；只有发流量时才涨，那是数据通路的问题。

**相关代码位置：**

| 位置 | 内容 |
| --- | --- |
| immortalwrt `target/linux/airoha/patches-6.18/310-09-net-pcs-airoha-add-PCS-driver-for-Airoha-AN7581-SoC.patch` | AN7581 的 PCS 驱动，含 SerDes 与流控配置 |
| immortalwrt `target/linux/airoha/patches-6.18/310-10-net-airoha-add-phylink-support.patch` | `airoha_eth` 的 phylink 支持，GDM4 分片大小按速率设置 |
| immortalwrt `target/linux/airoha/base-files/lib/preinit/90_airoha_ubi_mac` | 开机改 MAC 的钩子，会 down/up 网口 |
| immortalwrt `target/linux/airoha/dts/an7581-nokia_xg-040g-md-common.dtsi` | `en8811` 节点、`gdm4` 的 `phy-mode = "2500base-x"` |
| 内核 `drivers/net/phy/air_en8811h.c` | 速率适配恒为 `RATE_MATCH_PAUSE`，SerDes 固定 2500base-x |

**可以考虑的规避办法**（确认是钩子触发之后再做）：改 MAC 挪到接口被拉起来之前，或者改完之后回读链路状态、必要时复位一次 PHY。
