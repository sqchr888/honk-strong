# honk-strong 增强点清单（相对上游 v0.1.0-beta.6）

本文件说明相对官方 `daeuniverse/honk@v0.1.0-beta.6` 的源码改动，便于 review 和后续 rebase。

## core（Rust）

| 文件 | 改动 |
| --- | --- |
| `crates/honk-core/src/routing/geo.rs` | 新增 geosite overlay 加载：常量 `GEOSITE_OVERLAY_NAME = "honk-ads.dat"`；`geosite_overlay_bytes()` 从 `data_dir()` / `DAE_LOCATION_ASSET` 读取并混入 fingerprint；`validate_overlay()` 校验；`load_geosite_index` 合并（last-block-wins）；单测覆盖 category 覆盖与 fingerprint 稳定性。 |
| `crates/honk-core/src/routing/mod.rs` | 导出 `GEOSITE_OVERLAY_NAME` / `validate_overlay`。 |
| `crates/honk-core/src/native_api/adblock.rs` | 新增 native API：`POST /api/v1/x-honk/adblock/import`，接收 `{path, sha256}`，校验后原子落盘到 `honk-ads.dat`，再调用 honk 自身 reload；返回 `category: "honk-ads"`。 |
| `crates/honk-core/src/native_api.rs` | 注册 adblock 路由模块。 |
| `crates/honk-core/src/native_api/handlers.rs` | native API 处理增强。 |
| `crates/honk-core/src/readiness.rs` | 新增 readiness 协议：按 `HONK_READY_TOKEN` 原子写 `/var/run/honk/core-ready-<token>`（pid/token/config_hash/api_enabled/...），shutdown 时清理。 |
| `crates/honk-core/src/lib.rs` | 启动 `control_plane.run()` 前写 readiness，退出后清理。 |
| `crates/honk-core/src/dns/forwarder/hosts.rs` | hosts / DNS 处理增强。 |

## 工具链 / 脚本

| 文件 | 用途 |
| --- | --- |
| `honk-adblock/adblock-engine.sh` | 广告订阅刷新引擎（输出 `honk-ads.dat`） |
| `honk-adblock/geosite_gen.lua` | Lua 版 geosite DAT 生成器（category `honk-ads`） |
| `honk-dns/dns-engine.sh` | mosdns 式 DNS 分流清单渲染 |
| `gen_adblock_geosite.py` | Python 版 geosite DAT 生成器（含 encode/decode/self-test） |
| `adzero_honk_channel.py` | 早期通道工具（已改名，内部标识符 honk-ads） |

## 固件集成

`firmware/honk-strong/` 是 OpenWrt/ImmortalWRT package：预编译二进制 + 引擎脚本 + rpcd 权限 + LuCI 中文页 + UCI 默认配置。

## 命名迁移说明

早期版本曾用 `adzero-ads.dat` / category `adzero-ads`（源自与 AdZero 组合的探索）。
现统一迁移为 `honk-ads.dat` / `honk-ads`：core 白名单常量、DAT 内部 category、
配置规则 `qname(geosite:honk-ads) -> reject`、UCI `category`/`output`、所有脚本与 LuCI 页均已同步。
迁移需重新生成 DAT（内部 category 是写入字节的），并重新编译 core（白名单常量是编译期字符串）。
