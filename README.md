# 净化协议 — 灰盒工程 v0.1

Godot 4.7（Standard，GDScript）。已在 Godot 4.7.stable 实机跑通：无脚本报错、可渲染、核心循环可玩。

## 一、放进你的仓库

1. 解压本包，把 **内容**（不是外层文件夹）拷到 `E:\gamecreation\`，与已有的 `.git` / `.gitattributes` / `.gitignore` 同级。
2. 确认 `E:\gamecreation\project.godot` 存在 —— 这个文件在，Godot 才认这个目录是工程。
3. 不要提交 `.godot/`（你的 `.gitignore` 已经覆盖）。

## 二、用 Godot 打开

1. Godot 4.7 启动 → Import → 选 `E:\gamecreation\project.godot` → Import & Edit。
2. 首次打开会导入 `icon.svg`、编译脚本，几秒钟。
3. 按 **F5** 直接跑（主场景已设为 `res://scenes/main.tscn`）。

## 三、操作

| 键 | 作用 |
|---|---|
| WASD / 方向键 | 移动免疫单元（速度 320 u/s） |
| 按住 鼠标左键 / 空格 | 净化（半径 250，咬住边界才消耗酶） |
| `[` `]` | 变速 0.25× / 0.5× / 1× / 2× / 4× |
| P | 暂停 |
| N | 暂停时单步一帧（1/60 s） |
| R | 重播种，回到开局状态（同 seed 必得同一局面） |
| TAB / F1 | 显示/隐藏 HUD |

## 四、目录

```
project.godot            工程配置：1600x1000 视口、4 个 Autoload、60 tick、gl_compatibility
scenes/main.tscn         只有一个 Node2D + 挂 main.gd（其余节点全部代码创建）
scripts/main.gd          主循环：固定 tick 累加器、输入、时间缩放、竞技场绘制
scripts/core/game_state.gd   G / 血氧 / 毒素 / 意识 / 酶 + 器官三态（i, p, d）
scripts/core/rng_service.gd  三条独立随机流（spread / drop / events），种子化
scripts/core/event_bus.gd    13 个全局信号，与总纲 §16.2 的契约一致
scripts/core/config.gd       读 data/*.json，加内容不改代码
scripts/world/spread_system.gd  扩散场：球状增长 + 净化推边 + 抖动边界绘制
scripts/units/player_unit.gd    免疫单元：直径 90、净化半径 250
scripts/ui/hud.gd             HUD（全 ASCII，规避默认字体缺中文）
data/*.json                  器官 / 病毒 / 部队 / 经济 / 注射点 的数值表
```

## 五、已实现 / 未实现

已实现：
- 固定 60 tick 逻辑 + 时间缩放 + 暂停单步（保证可复现）
- 球状扩散场：半径每秒 +3，边界带抖动
- 净化推边：距离越近效率越高，仅在咬住时扣酶
- 器官三态 → G 加权计算（含 I>60% 权重翻倍、坏死不计入）
- 血氧 / 毒素 / 意识三条派生条随器官状态联动
- 种子化 RNG：同 seed 同局面

未实现（M1 待做，按总纲的任务卡拆）：
- 带状 / 辐射 / 随机三种扩散形状
- 阻断带、器官隔离、缺血债、坏死
- 多部队与血管调度、瞬移接管
- 反扑期、阶段目标、养分商店
- 存档与双人分屏

## 六、调试约定

- 逻辑一律走 `_simulate(STEP)`，`STEP = 1/60`；`Engine.time_scale` 不参与逻辑，避免物理帧漂移。
- 复现一个 bug：记下 HUD 里的 `SEED` + `TICK`，用 R 重播种、`[` 降速、N 单步贴近现场。
- 新增内容优先写进 `data/*.json`，代码只读表。

## 七、常见问题

- 打开报 "没有 project.godot"：解压层级多了一层，把内层内容提上来。
- 画面糊/字体方块：HUD 是英文，属预期；中文留给正式 UI 字体阶段处理。
- 显卡很老导致启动报 Forward+ 相关错误：本项目已设 `gl_compatibility`，一般不会碰到。
