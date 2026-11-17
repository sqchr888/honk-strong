# honk-strong

增强版 [honk](https://github.com/daeuniverse/honk)（`v0.1.0-beta.6`），面向 OpenWrt / ImmortalWRT 路由器，加入广告拦截、DNS 分流和中文管理界面。

## 相比上游的增强

| 能力 | 说明 |
| --- | --- |
| **geosite overlay 广告拦截** | 运行时读取 `/etc/honk/honk-ads.dat`（v2ray GeoSiteList 格式），category 为 `honk-ads`，与自带 `geosite.dat` 合并。配置一行 `qname(geosite:honk-ads) -> reject` 即在 DNS 层拦截，不写 hosts、不污染原有分流。 |
| **白名单路径** | core 内 `GEOSITE_OVERLAY_NAME = "honk-ads.dat"`，`data_dir`（`/etc/honk`）与 `DAE_LOCATION_ASSET` 下均加载。 |
| **readiness 协议** | 写 `/var/run/honk/core-ready-<HONK_READY_TOKEN>`，供厂商 LuCI 判断核心与 API 就绪，解决 `core_not_ready` 误报。 |
| **广告订阅引擎** | `adblock-engine.sh` + `geosite_gen.lua`：多订阅源抓取、去重、last-known-good 保护、原子落盘、SIGHUP 重载。 |
| **DNS 分流面板** | `dns-engine.sh`：mosdns 式分类清单（白名单/黑名单/重定向），managed block 双写 + validate + rollback。 |
| **中文 LuCI** | 概览、广告订阅、DNS 分流、配置、日志、维护等页面，全中文。 |

> 命名约定：广告规则数据文件统一为 `honk-ads.dat`，geosite category 统一为 `honk-ads`。
> 仓库内已无任何 `adzero` 引用（历史交付文档除外，仅供追溯）。

## 目录结构

```
.
├── crates/                     上游 honk 源码（含本仓库增强改动）
├── ci/                         交叉编译辅助脚本（zig / bpf-linker 包装）
├── firmware/honk-strong/       OpenWrt/ImmortalWRT 集成包（见下）
│   ├── Makefile                package Makefile
│   └── files/                  随包安装的文件（二进制除外）
├── tools/                      DAT 生成与校验工具
├── build_aarch64.sh            本地交叉编译脚本（aarch64 musl）
└── patches/                    增强点说明
```

## 编译

### 1. 编译 core（得到固件包要用的二进制）

```sh
./build_aarch64.sh
# 产物：target/aarch64-unknown-linux-musl/release/honk-core
```

依赖统一在 `~/tools`（Rust 1.99.1 + nightly-2026-10-20 eBPF、zig、bpf-linker、cmake），见脚本头部注释。

### 2. 打进路由器固件

把本仓库整体放到 OpenWrt 源码树的 `package/honk-strong`（或软链 `firmware/honk-strong`），
确认 `target/aarch64-unknown-linux-musl/release/honk-core` 已编译好，然后：

```sh
make menuconfig   # Network → honk-strong，选中
make package/honk-strong/compile -j$(nproc)
```

也可直接放进 `files/` 覆盖分区做固件叠加。安装后核心二进制位于 `/usr/bin/honk-core`，
广告/DNS 引擎在 `/usr/libexec/`，LuCI 页在 `/www/luci-static/resources/view/honk/`。

### 3. 首次启用广告拦截

装好后确保配置里有：

```dae
dns {
  routing {
    request {
      qname(geosite:honk-ads) -> reject
    }
  }
}
```

然后执行一次 `adblock-engine.sh refresh` 生成 `/etc/honk/honk-ads.dat` 并 reload。

## 验证

- `honk-core config validate --config /etc/honk/config.dae`
- 启动日志应出现：`loaded geosite overlay path=/etc/honk/honk-ads.dat bytes=...`
- 广告域名解析应无 A 记录；国内站直连、国外站走代理。

## 许可

上游 honk 为 GPL-3.0-only，详见 `LICENSE`。本仓库的增强改动遵循同一许可。
