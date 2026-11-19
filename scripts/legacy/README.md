# scripts/legacy —— 已下线模块归档

这里的东西**不再被主场景引用**，只作为回归测试的依赖和设计参考保留。

| 文件 | 原用途 | 现状 |
|---|---|---|
| `spread_system.gd` | M1-T1 灰盒的「球状扩散场」：半径随时间线性增长 + 射线求交 | 被 `virus_population.gd`（粒子种群）取代 |
| `block_system.gd` | M1-T1 灰盒的「阻断带」：法向距离判定 + 软硬两种行为 | 被 `virus_population` 内的 `place_block / _block_cross` 取代 |
| `player_unit.gd` | M1-T1 灰盒的玩家单元（移动 + 净化圈） | 主场景里玩家逻辑已并入 `main.gd` |
| `hud.gd` | M1-T1 灰盒 HUD（三条全局条 + 时间缩放） | 主场景 HUD 由 `main.gd._build_hud` 生成 |

## 唯一还在用它们的地方

`scripts/debug/m1_selftest.gd` —— M1-T1 的 9 项验收（A1~A9 + DET）。

```powershell
& 'E:\Godot\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe' `
  --headless --path E:\gamecreation res://scenes/debug/m1_selftest.tscn
```

期望输出末行 `M1 SELFTEST: 9/9 PASS`。

## 为什么留而不是删

它们验证过的两条判定逻辑（软/硬阻断、起效延迟、绕射）与新玩法是同一套游戏规则的不同实现，
出问题时可以直接对照。等新玩法自己长出等价的自动化测试后，这一整个目录可以删掉。
