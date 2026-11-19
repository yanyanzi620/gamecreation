extends Node2D
# 背景层：底色 + 网格 + 组织质感占位
#
# 单独做成一个节点，是因为病毒的 MultiMesh 在 z_index = -1，
# 如果背景直接画在主节点上（z = 0），会把病毒整个盖住。

const GRID := 100.0
const ALVEOLI := [Vector2(1250.0, 860.0), Vector2(430.0, 900.0), Vector2(1420.0, 180.0),
	Vector2(240.0, 400.0), Vector2(780.0, 800.0)]

var arena := Vector2(1600.0, 1000.0)


func setup(sz: Vector2) -> void:
	arena = sz
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, arena), Color(0.10, 0.13, 0.16), true)

	# 100 单位细网格，给玩家尺度参照
	var x := 0.0
	while x <= arena.x:
		draw_line(Vector2(x, 0.0), Vector2(x, arena.y), Color(0.088, 0.105, 0.130), 1.0)
		x += GRID
	var y := 0.0
	while y <= arena.y:
		draw_line(Vector2(0.0, y), Vector2(arena.x, y), Color(0.088, 0.105, 0.130), 1.0)
		y += GRID

	# 组织质感占位：肺泡参照圈（后续换成真正的器官地形）
	for a in ALVEOLI:
		draw_arc(a, 86.0, 0.0, TAU, 44, Color(0.175, 0.215, 0.265), 2.0)
		draw_arc(a, 86.0 + 22.0, 0.0, TAU, 44, Color(0.128, 0.158, 0.196), 1.0)

	draw_rect(Rect2(Vector2.ZERO, arena), Color(0.30, 0.20, 0.26), false, 3.0)
