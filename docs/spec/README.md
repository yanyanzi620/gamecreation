# M1-T1 设计数据（不再被运行时加载）

这六个 json 是第一版灰盒（圆环膨胀病毒 + 固定场地 + 数据驱动）的设计种子：
`organs / pathogens / units / economy / blocks / injectors`。

**当前运行时不用它们**：M2 之后所有数值集中在 `scripts/core/balance.gd`，
地图由 `scripts/world/lung_gen.gd` 程序化生成。

保留原因：
- 里面对「器官三态字段、经济换算、注射点」的定义仍然有参考价值；
- 将来若真要回到数据驱动（`core/content_db.gd`），从这里起步比重写快。

约定：**不要**把它们再放回 `res://data/`，也不要复活旧的 `core/config.gd`。
