extends Node2D
# ============================================================
# 器官视图 —— 把 OrganMap 画出来
# ============================================================
# z_index = -2：压在病毒（-1）和玩家（0）下面。
#
# 画法（为什么不做多边形填充）：
#   流明轮廓在「细隔膜」处会自交，Godot 的三角化填不出来。
#   所以改成：把掩码烘焙成一张小贴图，拉伸盖满场地（1 次 draw call），
#   再把精确的轮廓线描上去做锐边。既稳又快。
#
# 美术替换说明（给后期准备）：
#   1. 挂 tissue_texture 就能整张替换组织底（贴图优先）
#   2. 或者把本节点换成 Sprite2D + 手绘地形 —— 因为墙的判定完全来自 OrganMap，
#      画法怎么换都不影响玩法
# ============================================================

const COL_TISSUE := Color(0.285, 0.175, 0.200)
const COL_TISSUE_DEEP := Color(0.125, 0.09, 0.105)
const COL_LUMEN := Color(0.125, 0.180, 0.230)
const COL_WALL := Color(0.58, 0.34, 0.38)
const COL_WALL_GLOW := Color(0.70, 0.30, 0.36, 0.20)

var map = null

# 美术接口：填了就用贴图当组织底，没填就用烘焙的占位贴图
var tissue_texture: Texture2D = null

var _baked: ImageTexture = null


# 给 UI（小地图）用的缩略图
func map_texture() -> Texture2D:
	return _baked


func set_map(m) -> void:
	map = m
	# 胸膜线只给渲染用，放在这里算（不进 map.build 的计时预算）
	if map.clip_loops.is_empty():
		map.build_clip_contours()
	_baked = _bake()
	queue_redraw()


# 把「实心/流明」掩码烘焙成贴图（占位美术）
func _bake() -> ImageTexture:
	var ms: Vector2i = map.mask_size()
	var img := Image.create(ms.x, ms.y, false, Image.FORMAT_RGBA8)
	for j in range(ms.y):
		for i in range(ms.x):
			if not map.in_organ_cell(i, j):
				img.set_pixel(i, j, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var c := COL_TISSUE
			if not map.solid_cell(i, j):
				c = COL_LUMEN
			# 一点随机的组织暗部，避免死平（美术到位后可删）
			var n := 0.88 + 0.12 * absf(sin(float(i) * 0.37 + float(j) * 1.13))
			img.set_pixel(i, j, Color(c.r * n, c.g * n, c.b * n, 1.0))
	return ImageTexture.create_from_image(img)


func _draw() -> void:
	if map == null:
		return

	var rect := Rect2(Vector2.ZERO, map.size)
	if tissue_texture != null:
		draw_texture_rect(tissue_texture, rect, false)
	elif _baked != null:
		draw_texture_rect(_baked, rect, false)

	# 精确轮廓：外发光（肉壁厚度感）+ 实线（锐边）
	# 不闭合的轮廓（被场地边缘切开的）不能首尾相连，否则会多出一条假墙
	for i in range(map.loops.size()):
		var loop: PackedVector2Array = map.loops[i]
		var ring: PackedVector2Array = loop.duplicate()
		if map.loop_is_closed(i):
			ring.append(Vector2(loop[0]))
		draw_polyline(ring, COL_WALL_GLOW, 9.0, true)
	for i in range(map.loops.size()):
		var loop2: PackedVector2Array = map.loops[i]
		var ring2: PackedVector2Array = loop2.duplicate()
		if map.loop_is_closed(i):
			ring2.append(Vector2(loop2[0]))
		draw_polyline(ring2, COL_WALL, 2.5, true)

	# 胸膜线：器官本体的外轮廓（肺泡贴着它长，所以线条压在最外圈肺泡上）
	for i in range(map.clip_loops.size()):
		var pl: PackedVector2Array = map.clip_loops[i]
		var pr: PackedVector2Array = pl.duplicate()
		if map.clip_loop_is_closed(i):
			pr.append(pl[0])
		draw_polyline(pr, Color(0.62, 0.30, 0.36, 0.35), 12.0, true)
	for i in range(map.clip_loops.size()):
		var pl2: PackedVector2Array = map.clip_loops[i]
		var pr2: PackedVector2Array = pl2.duplicate()
		if map.clip_loop_is_closed(i):
			pr2.append(pl2[0])
		draw_polyline(pr2, Color(0.86, 0.46, 0.52, 0.85), 2.6, true)

	# 肉壁里的小肺泡纹理（纯视觉，美术到位后可以换成贴图）
	for d in map.decor:
		var dc: Vector2 = d[0]
		var dr: float = float(d[1])
		draw_arc(dc, dr, 0.0, TAU, 18, Color(0.34, 0.22, 0.25, 0.55), 1.4)
		draw_arc(dc, dr * 0.62, 0.0, TAU, 14, Color(0.30, 0.19, 0.22, 0.40), 1.0)

	# 场地边框
	# 场地边框不画：地图的形状由器官轮廓决定，再画一个方框就把肺形说回来了
