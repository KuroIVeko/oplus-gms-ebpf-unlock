# oplus-gms-ebpf-unlock

KernelSU 模块：解除 ColorOS / OnePlus（Oplus 系）系统内核 eBPF 层对 Google Play 服务全家桶的联网限制。

## 背景

在部分 OPPO / OnePlus / Realme（ColorOS / Oplus 统一系统）机型上，即使代理配置完全正确、其他 App 翻墙正常，**Google Play 服务（GMS）、Google Play 商店、Google 服务框架（GSF）、GMS 配置更新器（ConfigUpdater）** 这几个谷歌核心组件依然完全无法联网。

**这个问题只在"无感代理"场景下出现**：本机部署 TProxy 透明代理（如 Box for Root / sing-box 的 tproxy 模式）、或连接自带翻墙能力的 WiFi 热点，都会触发；而标准 Android VPN（TUN 代理）、App 内配置的 HTTP/SOCKS 代理这类系统能感知到的联网方式则完全正常。推测 ColorOS 判断"是否处于可信联网环境"依据的是"系统层面能不能检测到 VPN/代理"，而不是实际连通性——TProxy 从设计上就不建 VPN 接口、不改 App 代理设置，对系统来说完全无感，于是被误判为"没代理、连不上 Google"，主动禁用 GMS 联网省电。这个出发点合理，但检测手段太粗糙，误伤了 TProxy 这类必须保持无感的翻墙方式，也没法靠"让系统识别到代理"解决。

根因不是常见的省电策略、AppOps 或 iptables 规则,而是系统在内核 cgroup-eBPF 层维护的一张 **UID 限制名单**（pinned 在 `/sys/fs/bpf/map_oplus-netd_app_wlan_socket_uid_limit_map` 等 map 中），精确记录了这 4 个应用的 UID 并标记为受限。这一层比 `dumpsys netpolicy`、`iptables -L`、标准应用权限页面都更底层，用常规手段完全排查不到。

## 这个模块做什么

- 开机后清空 `map_oplus-netd_app_wlan_socket_uid_limit_map`（WLAN）和 `map_oplus-netd_app_qcom_socket_uid_limit_map`（蜂窝）两张表里对以下几个包对应 UID 的限制记录：
  | 包名                                 | 说明             |
  | ------------------------------------ | ---------------- |
  | `com.google.android.gms`           | Google Play 服务 |
  | `com.android.vending`              | Google Play 商店 |
  | `com.google.android.gsf`           | Google 服务框架  |
  | `com.google.android.configupdater` | GMS 配置更新器   |
- **UID 是运行时动态解析的，不是硬编码**：同一个包名在不同设备、不同安装顺序下分配到的 UID 不一定一样，写死 UID 只对某一台特定设备当时有效。模块用 `包名 → /data/data/<包名> 目录属主 UID → BPF map key` 这条链路现查现算，对每台设备都适用，不依赖任何写死的数字。
- **检查窗口**：系统服务在开机后写入这张表的时机不完全固定，所以模块在开机后 5 分钟内每 5 秒检查一次，确保赶上写入时机后立即清除；实测运行期间不会被重新写回，5 分钟窗口结束后脚本退出，不常驻轮询，不额外占用资源。
- 运行日志记录在 `/data/adb/modules/unblock_gms_ebpf/unblock_gms.log`，方便你确认系统实际的写入时机，以及每个包解析出来的 UID。

## 适用范围

理论上适用于任何存在 `map_oplus-netd_*_socket_uid_limit_map` 这套 eBPF 限制机制的 ColorOS / Oplus 系机型，不依赖某一台设备特定的 UID（UID 是运行时动态解析的）。已在 **OnePlus PJZ110（ColorOS）+ KernelSU** 上验证有效。其他机型/系统版本可能需要自行确认这几张 map 是否存在。

## 安装

1. 从 [Releases](../../releases) 下载最新的 `oplus-gms-ebpf-unlock.zip`
2. `adb push oplus-gms-ebpf-unlock.zip /sdcard/`
3. KernelSU Manager → 模块 → 从本地安装，选择该 zip
4. 重启手机

模块自带一份静态编译的 arm64 `bpftool`（来自 [libbpf/bpftool](https://github.com/libbpf/bpftool) 官方 release），无需额外准备。如果模块包内没带上（比如你自己重新打包源码），`customize.sh` 会退而尝试 `/data/local/tmp/bpftool`。

## 从源码打包

仓库根目录本身就是模块目录结构（`module.prop` / `customize.sh` / `service.sh` / `bpftool`），直接把这几个文件打成 zip 即可：

```bash
zip -r oplus-gms-ebpf-unlock.zip module.prop customize.sh service.sh bpftool
```

## ⚠️ 已知限制

- 实测每次开机都会被重新写入，删除后运行期间不会再恢复；如果你的设备表现不同（比如运行期间又被写回），欢迎提 Issue。
- 未定位到具体是哪个系统服务/进程负责写入这张表（怀疑与 `com.oplus.trafficmonitor` / `OplusCustomizeNetworkManagerService` 相关），也未找到用户可配置的持久化数据源，怀疑是硬编码逻辑。
- 仅在骁龙平台（qcom 蜂窝 map）验证；天玑平台的等价 map 命名可能不同。

## License

MIT，见 [LICENSE](LICENSE)。
