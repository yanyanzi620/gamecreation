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
const COL_LUMEN := Color(0.105, 0.150, 0.198)     # 贴壁处的腔底（暗）
const COL_LUMEN_LIT := Color(0.170, 0.235, 0.292) # 腔心（亮）—— 靠它形成球状纵深
const COL_WALL := Color(0.58, 0.34, 0.38)
const COL_WALL_GLOW := Color(0.70, 0.30, 0.36, 0.20)

var map = null

# 装饰层开关（F 键切换 / Balance.DECOR_ON 定默认）：关掉就是纯灰盒，方便对比与排错
var decor_on := true

# 腔室内装饰的三层配色与线宽：全部用 draw_multiline 一次画完，总共 3 个 draw call
const DETAIL_COL := [
	Color(0.62, 0.74, 0.80, 0.34),   # 0 沿壁弧 + 间隔小突：偏冷的亮线，像间隔上的结缔组织
	Color(0.58, 0.30, 0.32, 0.30),   # 1 毛细血管弧：暗红
	Color(0.66, 0.76, 0.80, 0.16),   # 2 上皮斑点：淡
]
const DETAIL_W := [3.2, 3.6, 2.0]

var _detail_segs: Array = []

# 美术接口：填了就用贴图当组织底，没填就用烘焙的占位贴图
var tissue_texture: Texture2D = null

var _baked: ImageTexture = null        # 当前生效的那张
var _baked_on: ImageTexture = null     # 带装饰（纵深 + 腔内质感）
var _baked_off: ImageTexture = null    # 纯灰盒（平涂，给对比与排错用）


# 给 UI（小地图）用的缩略图
func map_texture() -> Texture2D:
	# 小地图用平涂版：缩略图上装饰只会糊成一团，反而看不清病毒分布
	return _baked_off if _baked_off != null else _baked


func set_map(m) -> void:
	map = m
	# 胸膜线只给渲染用，放在这里算（不进 map.build 的计时预算）
	if map.clip_loops.is_empty():
		map.build_clip_contours()
	# 距离场只算一次，两张贴图共用（两张都算会让载入多花约 200ms）
	var df := _distance_field()
	_baked_off = _bake(false, df)
	_baked_on = _bake(true, df)
	_baked = _baked_on if decor_on else _baked_off
	_detail_segs = _build_detail()
	queue_redraw()


func set_decor_on(v: bool) -> void:
	decor_on = v
	if _baked_on != null and _baked_off != null:
		_baked = _baked_on if v else _baked_off
	queue_redraw()


# 把 detail 里的折线拼成 draw_multiline 需要的「成对点」数组，按层分开
func _build_detail() -> Array:
	var out: Array = [PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]
	for d in map.detail:
		var pts: PackedVector2Array = d[0]
		var layer: int = int(d[1])
		if layer < 0 or layer > 2:
			continue
		var buf: PackedVector2Array = out[layer]
		if pts.size() == 2:
			buf.append(pts[0])
			buf.append(pts[1])
			continue
		for i in range(pts.size() - 1):
			buf.append(pts[i])
			buf.append(pts[i + 1])
		out[layer] = buf
	return out


# 把「实心/流明」掩码烘焙成贴图（占位美术）
# 每个流明格子到最近「墙/体外」的倒角距离（+3 直走、+4 斜走，除以 3 得格数）。
# 有了它，腔室才能做出「近壁暗、腔心亮」的球状纵深，而不是一整片死平的蓝。
func _distance_field() -> PackedInt32Array:
	var ms: Vector2i = map.mask_size()
	var w := ms.x
	var h := ms.y
	var df := PackedInt32Array()
	df.resize(w * h)
	df.fill(9999)
	for j in range(h):
		for i in range(w):
			if (not map.in_organ_cell(i, j)) or map.solid_cell(i, j):
				df[j * w + i] = 0
	for j in range(h):
		for i in range(w):
			var idx := j * w + i
			if df[idx] == 0:
				continue
			var best := df[idx]
			if i > 0:
				best = mini(best, df[idx - 1] + 3)
			if j > 0:
				best = mini(best, df[idx - w] + 3)
				if i > 0:
					best = mini(best, df[idx - w - 1] + 4)
				if i < w - 1:
					best = mini(best, df[idx - w + 1] + 4)
			df[idx] = best
	for j in range(h - 1, -1, -1):
		for i in range(w - 1, -1, -1):
			var idx2 := j * w + i
			if df[idx2] == 0:
				continue
			var best2 := df[idx2]
			if i < w - 1:
				best2 = mini(best2, df[idx2 + 1] + 3)
			if j < h - 1:
				best2 = mini(best2, df[idx2 + w] + 3)
				if i < w - 1:
					best2 = mini(best2, df[idx2 + w + 1] + 4)
				if i > 0:
					best2 = mini(best2, df[idx2 + w - 1] + 4)
			df[idx2] = best2
	return df


func _bake(with_decor: bool, df: PackedInt32Array) -> ImageTexture:
	var ms: Vector2i = map.mask_size()
	var w := ms.x
	var h := ms.y
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for j in range(h):
		for i in range(w):
			if not map.in_organ_cell(i, j):
				img.set_pixel(i, j, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var c := COL_TISSUE
			if not map.solid_cell(i, j):
				c = COL_LUMEN
				if with_decor:
					# 距离换算成世界单位：格数 = df/3，一格 = PIX 世界单位
					var cells := float(df[j * w + i]) / 3.0
					var dw: float = cells * 8.0
					var t := clampf(dw / 58.0, 0.0, 1.0)
					t = t * t * (3.0 - 2.0 * t)          # smoothstep，避免出现明显的同心圈
					c = COL_LUMEN.lerp(COL_LUMEN_LIT, t)
			# 组织/腔底的细微噪声，避免死平（美术到位后可删）
			var n := 0.88 + 0.12 * absf(sin(float(i) * 0.37 + float(j) * 1.13))
			var n2 := 0.96 + 0.04 * absf(sin(float(i) * 0.11 + float(j) * 0.23))
			if with_decor:
				n *= n2
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

	# 腔室内装饰（纯视觉）：三批 draw_multiline，总共 3 个 draw call，
	# 无论有多少肺泡、多少条线都不增加 CPU 绘制开销
	if decor_on:
		for layer in range(3):
			var segs: PackedVector2Array = _detail_segs[layer]
			if segs.size() >= 2:
				draw_multiline(segs, DETAIL_COL[layer], DETAIL_W[layer])

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
	for d in map.decor if decor_on else []:
		var dc: Vector2 = d[0]
		var dr: float = float(d[1])
		draw_arc(dc, dr, 0.0, TAU, 18, Color(0.34, 0.22, 0.25, 0.55), 1.4)
		draw_arc(dc, dr * 0.62, 0.0, TAU, 14, Color(0.30, 0.19, 0.22, 0.40), 1.0)

	# 场地边框
	# 场地边框不画：地图的形状由器官轮廓决定，再画一个方框就把肺形说回来了
