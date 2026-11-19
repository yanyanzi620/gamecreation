# -*- coding: utf-8 -*-
import io, sys

def T(n):
    return "\t" * n

def blk(items):
    return "\n".join(T(lv) + txt for lv, txt in items)

# ---------------------------------------------------------------- 病毒侧：加查询接口
P = r"E:\gamecreation\scripts\world\virus_population.gd"
s = io.open(P, encoding="utf-8").read()

anchor = "func _tick_blocks(dt: float) -> void:"
if s.count(anchor) != 1:
    print("MISS anchor"); sys.exit(1)
s = s.replace(anchor,
    blk([(0, "# 玩家移动用：只有「已生效」的阻隔带才拦人，闪烁期两者都能穿过去"),
         (0, "func path_blocked(a: Vector2, b: Vector2) -> bool:"),
         (1, "return _block_cross(a.x, a.y, b.x, b.y) == 1"),
         (0, ""),
         (0, "")]) + "\n" + anchor)
io.open(P, "w", encoding="utf-8").write(s)
print("pop: path_blocked ok")

# ---------------------------------------------------------------- 演示场景
P2 = r"E:\gamecreation\scripts\demo\virus_showcase.gd"
d = io.open(P2, encoding="utf-8").read()

def rep(old, new, tag):
    global d
    if d.count(old) != 1:
        print("MISS [%s] count=%d" % (tag, d.count(old))); sys.exit(1)
    d = d.replace(old, new)

# 1) 抽出 _move_step：撞带就沿带滑
rep(blk([(1, "if mv.length() > 0.0:"),
         (2, "player += mv.normalized() * SPEED * delta")]),
    T(1) + "_move_step(mv, delta)", "move_call")

rep("func _process(delta: float) -> void:",
    blk([(0, "func _move_step(dir: Vector2, delta: float) -> void:"),
         (1, "if dir.length() < 0.001:"),
         (2, "return"),
         (1, "var step := dir.normalized() * SPEED * delta"),
         (1, "var np := player + step"),
         (1, "if not pop.path_blocked(player, np):"),
         (2, "player = np"),
         (2, "return"),
         (1, "# 撞上已生效的阻隔带：只走分量大的那一个轴，沿带子滑过去"),
         (1, "if absf(step.x) >= absf(step.y):"),
         (2, "if not pop.path_blocked(player, player + Vector2(step.x, 0.0)):"),
         (3, "player += Vector2(step.x, 0.0)"),
         (1, "elif not pop.path_blocked(player, player + Vector2(0.0, step.y)):"),
         (2, "player += Vector2(0.0, step.y)"),
         (0, ""),
         (0, ""),
         (0, "func _process(delta: float) -> void:")]), "move_fn")

# 2) 验收：脚本化往带子上撞
rep('''	_save("res://shot_c.png")
	get_tree().quit()''',
'''	_save("res://shot_c.png")
	# 再验一次：往阻挡带方向硬走 3 秒，看玩家是不是被挡住
	for i in range(180):
		_move_step(Vector2(1.0, -0.30), 1.0 / 60.0)
	print("[MOVE] player=(%.1f, %.1f)" % [player.x, player.y])
	await get_tree().create_timer(0.10).timeout
	_save("res://shot_d.png")
	get_tree().quit()''', "walk_test")

io.open(P2, "w", encoding="utf-8").write(d)
print("showcase: move ok")
