# 本地软件包

放在这里的包由 `src-link` 挂成源码树的一个 feed，不进源码仓库。这样
`Loong1996/immortalwrt` 只承载「对上游源码树的修改」，第三方包与自带包都留在本仓库。

编译时 `build.sh` 与 CI 会往源码树的 `feeds.conf` 追加一行：

```
src-link loong <本仓库绝对路径>/packages
```

之后 `./scripts/feeds update loong && ./scripts/feeds install -a -p loong`。
`src-link` 用符号链接，不复制，改完源码直接重编即可。

## luci-app-airoha-npu

AN7581 的 NPU / CPU 频率 / Frame Engine / PPE 流表监控面板。

| | |
| --- | --- |
| 原作者 | Ryan Chen（[rchen14b/luci-app-airoha-npu](https://github.com/rchen14b/luci-app-airoha-npu)），Apache-2.0 |
| 本仓库这份 | `PKG_VERSION` **1.0.3** |
| 直接来源 | fzs209 的 25.12 快照（fork 时就带着，本项目未改动） |

### 注意：这份比原作者仓库新

原作者仓库 `main` 停在 2026-04-19、`PKG_VERSION` 1.0.1，且**没有发布过任何
Release**（GitHub Releases API 返回空）。本仓库这份 1.0.3 多出 VLAN 与 PPPoE
卸载的读写接口，这些代码在原作者仓库里不存在：

```
acl.d:  getVlanOffload  getPPPoEOffload  setVlanOffload  setPPPoEOffload
```

差异规模：`status.js` 52 行、`root/usr/libexec/rpcd/luci.airoha_npu` 72 行、
`acl.d/*.json` 4 行。

**因此不能改成 submodule 指向原作者仓库** —— 那会降级到 1.0.1 并丢掉上述功能。
要跟进原作者的更新，得手工合并，或者先把 1.0.3 推到自己的 fork 再 pin。

包内 `README.md` 是 1.0.1 时代的，`RPC Methods` 一节没有列 VLAN/PPPoE 那几个方法；
原文里的 `screenshots/` 三张截图（约 3 MB）只是 README 插图、不会装进固件，已删除，
对应的引用也一并去掉。其余内容保持原样。
