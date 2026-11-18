extends Node2D
# M1-T2 原型：粒子种群病毒
#   扩散 = 复制（父粒子配额 + 冷却 + 30 单位粗格封顶）
#   边界 = 密度前沿（不存 48 半径 / 200 点路径）
#   消除 = 命中区域内的 live 转 corpse，原地留尸，30 秒衰减
#
# 性能设计：
#   · 全部状态用 Packed 数组，不 new/free，避免每帧分配
#   · 位置相同的粒子只在「年轻期」移动，成熟后冻结
#   · 渲染走单个 MultiMesh，1 次 draw call
#   · 复制不做邻域查询，只查一格占用计数（O(1)）

const MAX_LIVE := 2200
const MAX_CORPSE := 900
const TOTAL := MAX_LIVE + MAX_CORPSE

const CELL := 30.0
const GRID_W := 80
const GRID_H := 50
const CELL_CAP := 7

const R_MIN := 4.5
const R_MAX := 8.0
const QUOTA_ROOT := 4
const QUOTA_CHILD := 2
const COOL_MIN := 0.55
const COOL_MAX := 1.15
const SPAWN_D_MIN := 16.0
const SPAWN_D_MAX := 30.0
const SPAWN_ARC := 60.0
const YOUNG_SEC := 2.0
const DRIFT_SPEED := 24.0
const CORPSE_LIFE := 30.0

const ARENA_W := 2400.0
const ARENA_H := 1500.0
const ARENA_PAD := 40.0

const COL_LIVE := Color(0.30, 0.86, 0.46, 0.90)
const COL_CORPSE := Color(0.66, 0.70, 0.74, 0.88)

var _px := PackedFloat32Array()
var _py := PackedFloat32Array()
var _pr := PackedFloat32Array()
var _page := PackedFloat32Array()
var _plife := PackedFloat32Array()
var _pcool := PackedFloat32Array()
var _ptype := PackedInt32Array()      # 0 = live, 1 = corpse
var _pquota := PackedInt32Array()
var _pvid := PackedInt32Array()
var _alive := PackedInt32Array()
var _free: Array[int] = []
var _cell := PackedInt32Array()

var _n_live := 0
var _n_corpse := 0
var _origins: Array[Vector2] = []

var _rng := RandomNumberGenerator.new()
var _mmi: MultiMeshInstance2D
var _buf := PackedFloat32Array()
var _dirty := true


func _ready() -> void:
	_rng.seed = 20261119
	_init_pool()
	_init_multimesh()


func _init_pool() -> void:
	_px.resize(TOTAL)
	_py.resize(TOTAL)
	_pr.resize(TOTAL)
	_page.resize(TOTAL)
	_plife.resize(TOTAL)
	_pcool.resize(TOTAL)
	_ptype.resize(TOTAL)
	_pquota.resize(TOTAL)
	_pvid.resize(TOTAL)
	_alive.resize(TOTAL)
	_alive.fill(0)
	_cell.resize(GRID_W * GRID_H)
	_cell.fill(0)
	_free.clear()
	for i in range(TOTAL):
		_free.append(i)
	_buf.resize(TOTAL * 12)
	_buf.fill(0.0)


func _init_multimesh() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	var qm := QuadMesh.new()
	qm.size = Vector2(1.0, 1.0)
	mm.mesh = qm
	mm.instance_count = TOTAL
	mm.visible_instance_count = TOTAL

	_mmi = MultiMeshInstance2D.new()
	_mmi.multimesh = mm
	_mmi.texture = _make_dot_texture()
	add_child(_mmi)


func _make_dot_texture() -> ImageTexture:
	var s := 32
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := float(s - 1) * 0.5
	for y in range(s):
		for x in range(s):
			var dx := float(x) - c
			var dy := float(y) - c
			var d := sqrt(dx * dx + dy * dy) / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


# ============================================================ 播种

func seed_blob(center: Vector2, radius: float, count: int) -> void:
	_origins.append(center)
	var vid := _origins.size() - 1
	for k in range(count):
		var ang := _rng.randf() * TAU
		var rr := radius * sqrt(_rng.randf())
		var x := center.x + cos(ang) * rr
		var y := center.y + sin(ang) * rr
		_spawn(x, y, _rng.randf_range(R_MIN, R_MAX), 0, QUOTA_ROOT, vid,
			_rng.randf_range(0.0, 1.2), _rng.randf_range(COOL_MIN, COOL_MAX))


func live_count() -> int:
	return _n_live


func corpse_count() -> int:
	return _n_corpse


# ============================================================ 池操作

func _spawn(x: float, y: float, r: float, type: int, quota: int, vid: int,
		page: float, cool: float) -> int:
	if _free.is_empty():
		return -1
	if type == 0 and _n_live >= MAX_LIVE:
		return -1
	if type == 1 and _n_corpse >= MAX_CORPSE:
		return -1
	var i: int = _free.pop_back()
	_alive[i] = 1
	_px[i] = x
	_py[i] = y
	_pr[i] = r
	_page[i] = page
	_pcool[i] = cool
	_ptype[i] = type
	_pquota[i] = quota
	_pvid[i] = vid
	_plife[i] = CORPSE_LIFE if type == 1 else 0.0
	if type == 0:
		_n_live += 1
		_cell_add(x, y)
	else:
		_n_corpse += 1
	_write_slot(i)
	_dirty = true
	return i


func _kill(i: int) -> void:
	if _alive[i] == 0:
		return
	if _ptype[i] == 0:
		_n_live -= 1
		_cell_remove(_px[i], _py[i])
	else:
		_n_corpse -= 1
	_alive[i] = 0
	_free.append(i)
	_write_slot(i)
	_dirty = true


func _to_corpse(i: int) -> void:
	if _alive[i] == 0 or _ptype[i] != 0:
		return
	_ptype[i] = 1
	_plife[i] = CORPSE_LIFE
	_page[i] = 0.0
	_pquota[i] = 0
	_n_live -= 1
	_n_corpse += 1
	_cell_remove(_px[i], _py[i])
	_write_slot(i)
	_dirty = true


# ============================================================ 粗格

func _cell_idx(x: float, y: float) -> int:
	var cx := int(clampf(x / CELL, 0.0, GRID_W - 1.0))
	var cy := int(clampf(y / CELL, 0.0, GRID_H - 1.0))
	return cy * GRID_W + cx


func _cell_add(x: float, y: float) -> void:
	_cell[_cell_idx(x, y)] += 1


func _cell_remove(x: float, y: float) -> void:
	var idx := _cell_idx(x, y)
	if _cell[idx] > 0:
		_cell[idx] -= 1


func _cell_count(x: float, y: float) -> int:
	return _cell[_cell_idx(x, y)]


# ============================================================ 模拟

func tick(dt: float) -> void:
	for i in range(TOTAL):
		if _alive[i] == 0:
			continue
		if _ptype[i] == 0:
			_page[i] += dt
			if _page[i] < YOUNG_SEC:
				var ox := _px[i] - _origins[_pvid[i]].x
				var oy := _py[i] - _origins[_pvid[i]].y
				var l := sqrt(ox * ox + oy * oy)
				if l > 0.01:
					_px[i] += ox / l * DRIFT_SPEED * dt
					_py[i] += oy / l * DRIFT_SPEED * dt
					_write_slot(i)
			_pcool[i] -= dt
			if _pquota[i] > 0 and _pcool[i] <= 0.0:
				_replicate(i)
		else:
			_plife[i] -= dt
			if _plife[i] <= 0.0:
				_kill(i)
			else:
				_write_slot(i)

	if _dirty:
		_mmi.multimesh.buffer = _buf
		_dirty = false


func _replicate(i: int) -> void:
	if _n_live >= MAX_LIVE:
		return
	var c := _origins[_pvid[i]]
	var bx := _px[i] - c.x
	var by := _py[i] - c.y
	var base := atan2(by, bx)
	var ang := base + deg_to_rad(_rng.randf_range(-SPAWN_ARC, SPAWN_ARC))
	var dist := _rng.randf_range(SPAWN_D_MIN, SPAWN_D_MAX)
	var nx := _px[i] + cos(ang) * dist
	var ny := _py[i] + sin(ang) * dist

	if nx < ARENA_PAD or nx > ARENA_W - ARENA_PAD or ny < ARENA_PAD or ny > ARENA_H - ARENA_PAD:
		_pquota[i] = 0
		return
	if _cell_count(nx, ny) >= CELL_CAP:
		_pcool[i] = _rng.randf_range(COOL_MIN, COOL_MAX)
		return

	_spawn(nx, ny, _rng.randf_range(R_MIN, R_MAX), 0, QUOTA_CHILD, _pvid[i],
		0.0, _rng.randf_range(COOL_MIN, COOL_MAX))
	_pquota[i] = maxi(0, _pquota[i] - 1)
	_pcool[i] = _rng.randf_range(COOL_MIN, COOL_MAX)


# ============================================================ 消除

# 扇形清除：锥内 live 全部转尸体，返回命中数
func clear_fan(origin: Vector2, dir: Vector2, length: float, half_angle: float) -> int:
	var dx := dir.x
	var dy := dir.y
	var cos_lim := cos(half_angle)
	var l2max := length * length
	var hit := 0
	for i in range(TOTAL):
		if _alive[i] == 0 or _ptype[i] != 0:
			continue
		var vx := _px[i] - origin.x
		var vy := _py[i] - origin.y
		var l2 := vx * vx + vy * vy
		if l2 > l2max:
			continue
		var l := sqrt(l2)
		if l < 0.001:
			_to_corpse(i)
			hit += 1
			continue
		if (vx * dx + vy * dy) / l < cos_lim:
			continue
		_to_corpse(i)
		hit += 1
	return hit


# ============================================================ 渲染

func _write_slot(i: int) -> void:
	var o := i * 12
	if _alive[i] == 0:
		_buf[o] = 0.0
		_buf[o + 5] = 0.0
		_buf[o + 11] = 0.0
		return
	var s := _pr[i] * 2.0
	var col := COL_LIVE
	if _ptype[i] == 1:
		var k := clampf(_plife[i] / CORPSE_LIFE, 0.0, 1.0)
		col = Color(COL_CORPSE.r, COL_CORPSE.g, COL_CORPSE.b, COL_CORPSE.a * (0.35 + 0.65 * k))
	# TRANSFORM_2D：8 浮点（2x3 矩阵按 8 对齐）+ 4 颜色
	_buf[o + 0] = s
	_buf[o + 1] = 0.0
	_buf[o + 2] = 0.0
	_buf[o + 3] = _px[i]
	_buf[o + 4] = 0.0
	_buf[o + 5] = s
	_buf[o + 6] = 0.0
	_buf[o + 7] = _py[i]
	_buf[o + 8] = col.r
	_buf[o + 9] = col.g
	_buf[o + 10] = col.b
	_buf[o + 11] = col.a
