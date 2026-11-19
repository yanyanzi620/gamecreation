# 净化协议 · UI 美术素材包

所有 UI 图标都在这个目录，**和玩法代码完全解耦**：换图不用改一行脚本。

```
assets/ui/
├─ icons/
│   ├─ manifest.json     key -> 文件名的映射（换文件名/换格式改这里）
│   ├─ nutrient.svg      养分
│   ├─ virus.svg         病毒总量（团簇）
│   ├─ virus_blob.svg    圆盘病毒
│   ├─ virus_band.svg    带状病毒
│   ├─ virus_chain.svg   跳跃链
│   ├─ corpse.svg        病毒尸体（疤）
│   ├─ perf.svg          帧耗时（时钟）
│   ├─ skill_jet.svg     射流
│   ├─ skill_block.svg   阻隔带
│   ├─ skill_fuse.svg    引信
│   └─ lobe.svg          肺叶（小地图左右叶负载）
└─ README.md            本文件
```

## 规格（画新图照着来）

| 项 | 要求 |
|---|---|
| 画布 | **1:1 方形**，透明底，`viewBox="0 0 64 64"`（或等比例 128 / 256） |
| 留白 | 主体占满 ~90%，四边各留 3~4px，别顶到边（描边会被裁） |
| 显示尺寸 | 状态图标 30px / 形态小图标 22px / 技能按钮 36px / 小地图 12~14px |
| 描边 | 2.4~3.4px（64 画布），细了在 22px 下会糊 |
| 格式 | SVG 优先（矢量、可任意缩放）；位图用 PNG，别用 JPG（要透明） |

## 配色（和游戏内实体颜色一致，别自己发明）

| 对象 | 色值 |
|---|---|
| 养分 | `#FFFFFF` 白 |
| 圆盘病毒 | `#4DDC75` 绿 |
| 带状病毒 | `#F7BA42` 琥珀 |
| 跳跃链 | `#E061CC` 品红 |
| 尸体 | `#A8B3BD` 灰 |
| 射流 / 阻隔带 | `#62FAFF` 青 |
| 引信 | `#F28C4D` 橙 + 外圈 `#DB6BF2` 紫 |
| 肺叶 | `#7FD3E8` 淡青 |

## 怎么替换

1. **只换画面**：同名覆盖（比如把 `nutrient.svg` 换成自己的图），`manifest.json` 不用动。
2. **换文件名或换 png**：改 `manifest.json` 里对应的值，例如 `"nutrient": "nutrient_v2.png"`。
3. **加新指标**：在 `manifest.json` 里加一行，再在 `scripts/ui/hud_panel.gd` 的 `_draw_stats()` 里加一项。

## 已知约束

- 图标按 key 加载，缺失时会退化成「一个色点占位」，不会崩 —— 但会很难看，所以别删文件。
- 加载逻辑在 `scripts/ui/ui_icons.gd`（读 `manifest.json`，失败则回退到代码里的默认表）。
- 当前所有图标都是矢量绘制的占位稿，**美术可以整套替换，不用通知程序**。
- 导出时 `.json` 不是资源文件，需要在导出面板把 `*.json` 加进「非资源文件过滤」，否则打进包里读不到。
