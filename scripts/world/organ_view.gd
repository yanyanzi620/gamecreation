extends Node2D
# ============================================================
# 器官视图 —— 本质 2D，光影烘焙出 3D 纵深
# ============================================================
# z_index = -2：压在病毒（-1）和玩家（0）下面。
#
# 性能口径：
#   · 有符号距离场只在换图时计算一次；组织厚度、内壁阴影、定向高光全部烘进一张贴图。
#   · 正常战斗只有 1 次地图贴图绘制 + 少量批量线段，不做逐像素、逐肺泡计算。
#   · 肉壁纹理不再每帧调用上千次 draw_arc，预先合并成两批 draw_multiline。
#
# 美术替换说明：
#   1. 挂 tissue_texture 可替换整张地图底图；墙与碰撞仍完全来自 OrganMap。
#   2. 需要手绘地形时可替换本节点，玩法几何不受影响。
# ============================================================

const COL_TISSUE := Color(0.355, 0.205, 0.205)
const COL_TISSUE_DEEP := Color(0.115, 0.070, 0.080)
const COL_LUMEN := Color(0.045, 0.080, 0.098)     # 近壁腔底：深，形成接触阴影
const COL_LUMEN_LIT := Color(0.145, 0.245, 0.255) # 腔心：偏青灰，给病毒留出对比
const COL_WALL := Color(0.72, 0.435, 0.405)
const COL_WALL_BASE := Color(0.15, 0.075, 0.080, 0.72)

var map = null
var decor_on := true

# 腔室内装饰：三批 draw_multiline，线宽压低，让光影而不是线条主导体积感
const DETAIL_COL := [
	Color(0.55, 0.69, 0.70, 0.22),
	Color(0.65, 0.32, 0.30, 0.26),
	Color(0.65, 0.76, 0.73, 0.13),
]
const DETAIL_W := [2.4, 2.8, 1.7]

var _detail_segs: Array = []
var _decor_segs: Array = []
var _wall_rings: Array = []
var _clip_rings: Array = []

# 美术接口：填了就用贴图当组织底，没填就用烘焙的占位贴图
var tissue_texture: Texture2D = null
var _baked: ImageTexture = null
var _baked_on: ImageTexture = null
var _baked_off: ImageTexture = null


func map_texture() -> Texture2D:
	# 小地图用平涂版：缩略图上装饰只会糊成一团，反而看不清病毒分布
	return _baked_off if _baked_off != null else _baked


func set_map(m) -> void:
	map = m
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	if map.clip_loops.is_empty():
		map.build_clip_contours()
	var sdf := _signed_distance_field()
	_baked_off = _bake(false, sdf)
	_baked_on = _bake(true, sdf)
	_baked = _baked_on if decor_on else _baked_off
	_detail_segs = _build_detail()
	_decor_segs = _build_decor()
	_wall_rings = _closed_rings(map.loops, map._loop_closed)
	_clip_rings = _closed_rings(map.clip_loops, map._clip_closed)
	queue_redraw()


func set_decor_on(v: bool) -> void:
	decor_on = v
	if _baked_on != null and _baked_off != null:
		_baked = _baked_on if v else _baked_off
	queue_redraw()


func _closed_rings(src: Array, closed: Array) -> Array:
	var out: Array = []
	for i in range(src.size()):
		var ring: PackedVector2Array = src[i].duplicate()
		if i < closed.size() and bool(closed[i]) and not ring.is_empty():
			ring.append(ring[0])
		out.append(ring)
	return out


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


# 静态肉壁纹理预合并：两批线段代替每帧上千次 draw_arc。
func _build_decor() -> Array:
	var out: Array = [PackedVector2Array(), PackedVector2Array()]
	for d in map.decor:
		_append_arc(out[0], d[0], float(d[1]), 14)
		_append_arc(out[1], d[0], float(d[1]) * 0.62, 10)
	return out


func _append_arc(buf: PackedVector2Array, c: Vector2, r: float, steps: int) -> void:
	for k in range(steps):
		var a0 := TAU * float(k) / float(steps)
		var a1 := TAU * float(k + 1) / float(steps)
		buf.append(c + Vector2(cos(a0), sin(a0)) * r)
		buf.append(c + Vector2(cos(a1), sin(a1)) * r)


# 有符号距离场：流明为正、组织为负，绝对值都是到壁面的世界距离。
# 流明侧直接复用 OrganMap 已算好的场，只额外算组织侧，载入时不重复劳动。
func _signed_distance_field() -> PackedFloat32Array:
	var ms: Vector2i = map.mask_size()
	var w := ms.x
	var h := ms.y
	var free_df: PackedFloat32Array = map.distance_field()
	var wall := PackedFloat32Array()
	wall.resize(w * h)
	var inf := 1.0e6
	for k in range(w * h):
		wall[k] = inf if map.solid_cell(k % w, k / w) else 0.0
	var d1 := 8.0
	var d2 := 8.0 * 1.41421356
	for j in range(h):
		for i in range(w):
			var idx := j * w + i
			var v: float = wall[idx]
			if i > 0:
				v = minf(v, wall[idx - 1] + d1)
			if j > 0:
				v = minf(v, wall[idx - w] + d1)
				if i > 0:
					v = minf(v, wall[idx - w - 1] + d2)
				if i < w - 1:
					v = minf(v, wall[idx - w + 1] + d2)
			wall[idx] = v
	for j in range(h - 1, -1, -1):
		for i in range(w - 1, -1, -1):
			var idx2 := j * w + i
			var v2: float = wall[idx2]
			if i < w - 1:
				v2 = minf(v2, wall[idx2 + 1] + d1)
			if j < h - 1:
				v2 = minf(v2, wall[idx2 + w] + d1)
				if i < w - 1:
					v2 = minf(v2, wall[idx2 + w + 1] + d2)
				if i > 0:
					v2 = minf(v2, wall[idx2 + w - 1] + d2)
			wall[idx2] = v2
	var signed_df := PackedFloat32Array()
	signed_df.resize(w * h)
	for k2 in range(w * h):
		signed_df[k2] = -wall[k2] if map.solid_cell(k2 % w, k2 / w) else free_df[k2]
	return signed_df


func _bake(with_decor: bool, sdf: PackedFloat32Array) -> ImageTexture:
	var ms: Vector2i = map.mask_size()
	var w := ms.x
	var h := ms.y
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for j in range(h):
		for i in range(w):
			if not map.in_organ_cell(i, j):
				img.set_pixel(i, j, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var idx := j * w + i
			var sd: float = sdf[idx]
			var c := COL_TISSUE
			var light := 0.0
			if with_decor:
				# 距离场梯度就是壁面的 2D 法线。光源固定在右上，
				# 组织边缘受光、腔体近壁背光，于是产生厚度而不需要 3D 网格。
				var xl := sdf[j * w + maxi(0, i - 1)]
				var xr := sdf[j * w + mini(w - 1, i + 1)]
				var yt := sdf[maxi(0, j - 1) * w + i]
				var yb := sdf[mini(h - 1, j + 1) * w + i]
				var gx: float = xr - xl
				var gy: float = yb - yt
				var inv := 1.0 / sqrt(gx * gx + gy * gy + 0.0001)
				light = clampf((gx * 0.55 + gy * 0.83) * inv, -1.0, 1.0)

			if not map.solid_cell(i, j):
				var depth := _smooth01(sd / 125.0)
				c = COL_LUMEN.lerp(COL_LUMEN_LIT, depth)
				if with_decor:
					var contact := _smooth01(sd / 25.0)
					var shade := (0.66 + 0.34 * contact) * (0.93 + 0.12 * light)
					var rim := (1.0 - _smooth01(sd / 38.0)) * maxf(light, 0.0) * 0.075
					c = Color(c.r * shade + rim, c.g * shade + rim, c.b * shade + rim, 1.0)
			else:
				var wd := maxf(0.0, -sd)
				var rim_t := 1.0 - _smooth01(wd / 52.0)
				c = COL_TISSUE_DEEP.lerp(COL_TISSUE, 0.36 + 0.64 * rim_t)
				if with_decor:
					var shade_t := 0.92 + rim_t * (0.16 * light + 0.08)
					var spec := rim_t * maxf(light, 0.0) * 0.055
					c = Color(c.r * shade_t + spec, c.g * shade_t + spec, c.b * shade_t + spec, 1.0)

			# 两个尺度的确定性噪声：大尺度像组织色差，小尺度压住色带。
			var n := 0.94 + 0.06 * absf(sin(float(i) * 0.37 + float(j) * 1.13))
			if with_decor:
				# 低频噪声在 8px 掩码放大后仍然柔和；不做逐像素颗粒，避免近看像马赛克。
				var broad := sin(float(i) * 0.055 + float(j) * 0.071) + sin(float(i) * 0.017 - float(j) * 0.023)
				n = 1.0 + broad * 0.020
			img.set_pixel(i, j, Color(c.r * n, c.g * n, c.b * n, 1.0))
	return ImageTexture.create_from_image(img)


func _smooth01(v: float) -> float:
	var t := clampf(v, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _draw() -> void:
	if map == null:
		return
	var rect := Rect2(Vector2.ZERO, map.size)
	if tissue_texture != null:
		draw_texture_rect(tissue_texture, rect, false)
	elif _baked != null:
		draw_texture_rect(_baked, rect, false)

	if decor_on:
		for layer in range(3):
			var segs: PackedVector2Array = _detail_segs[layer]
			if segs.size() >= 2:
				draw_multiline(segs, DETAIL_COL[layer], DETAIL_W[layer])
		if _decor_segs[0].size() >= 2:
			draw_multiline(_decor_segs[0], Color(0.38, 0.22, 0.22, 0.48), 1.5)
			draw_multiline(_decor_segs[1], Color(0.24, 0.13, 0.15, 0.42), 1.1)

	# 深色基底 + 窄高光：轮廓仍与碰撞墙段一致，烘焙贴图负责体积。
	for ring in _wall_rings:
		draw_polyline(ring, COL_WALL_BASE, 5.0, true)
	for ring2 in _wall_rings:
		draw_polyline(ring2, COL_WALL, 1.8, true)

	for pl in _clip_rings:
		draw_polyline(pl, Color(0.20, 0.075, 0.085, 0.65), 9.0, true)
	for pl2 in _clip_rings:
		draw_polyline(pl2, Color(0.88, 0.49, 0.45, 0.88), 2.3, true)
