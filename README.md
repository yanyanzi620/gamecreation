# 净化协议 (Purge Protocol)

2D 俯视动作肉鸽 · 免疫题材 · Godot 4.7.2 / GDScript · PC 单机（后期双人）

你是打进体内的一个免疫单元，靠「清毒、封路、回收」把器官从感染里抢回来。

## 现在能玩到什么

- 一张**程序化生成的肺地图**（左右两叶 + 中间支气管），肺泡连通、腔室有纵深
- 三种病毒粒子：圆盘（圆周扩散）/ 带状（沿轴扩散）/ 跳跃链（单点跳跃、无视阻隔带）
- 手段：左键射流（扇形、被墙与阻隔带截断）、右键阻隔带（闪烁生效、拦人也拦弹道）、空格引信（内圈清场、外圈吸链）、贴身净化场
- 尸体留疤 30 秒 → 自动拾取 → 养分 → 兑换手段
- 相机跟随、战术小地图、可开关的装饰层

## 文档

| 文档 | 内容 |
|---|---|
| [docs/系统设计书.md](docs/系统设计书.md) | **设计基准**：定位 / 核心循环 / 架构分层 / 模块契约 / 扩展接口 / 数值 / 验收 / 多 Agent 协作规范 |
| [docs/任务看板.md](docs/任务看板.md) | 做到了哪、下一步做什么、谁接、任务卡模板 |
| [docs/地图与装饰层.md](docs/地图与装饰层.md) | 地图生成链路、装饰层结构、接美术的四个落点 |
| [docs/病毒模型与攻击机制.md](docs/病毒模型与攻击机制.md) | 三形态扩散规则、尸体/阻隔带/引信、性能预算与实测 |

## 跑起来

```powershell
$exe = 'E:\Godot\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe'
& $exe --path E:\gamecreation 'res://scenes/main.tscn'
```

操作：`WASD` 移动 · 左键射流 · 右键阻隔带(30) · 空格引信(40) · `R` 换一张肺 · `F` 装饰层

## 验收

```powershell
# 地图自测（34 项）
& $exe --headless --path E:\gamecreation 'res://scenes/debug/map_selftest.tscn'
# 实拍四张（射流 / 铺带挡弹道 / 引信 / 小地图）
& $exe --path E:\gamecreation 'res://scenes/main.tscn' -- --shot
# 俯瞰 / 压测 / 贴墙滑行
& $exe --path E:\gamecreation 'res://scenes/main.tscn' -- --overview
& $exe --path E:\gamecreation 'res://scenes/main.tscn' -- --stress
& $exe --path E:\gamecreation 'res://scenes/main.tscn' -- --walk
```

判定口径与实测基线见系统设计书 §9。

## 仓库约定

- 数值**只**改 `scripts/core/balance.gd`
- 依赖方向单向：`main → world → units → ui`，`balance` 谁都能读、它不依赖任何人
- 没有 autoload，跨模块一律显式 `bind(...)` 注入
- 二进制资源走 Git LFS（`.gitattributes` 已配置）

## 历史

`M1 灰盒`（圆环膨胀病毒 + 固定场地 + 数据驱动表）已被 `M2 粒子病毒` 取代并从代码库移除，
代码保留在 git 历史里；当时的设计数据留在 `docs/spec/data/`。
