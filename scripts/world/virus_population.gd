extends Node2D
# ============================================================
# 病毒种群 —— 粒子表示（M1-T2 正式模块）
#
# 一个病毒 = 一堆粒子。三种形态共用同一套复制规则，
# 差别只在「往哪个方向生」的权重表和「每格塞几个」：
#
#   KIND_BLOB  圆周    各向同性，长成不规则圆盘
#   KIND_BAND  带状    主轴优先，主轴缓慢折线，长成条带
#   KIND_CHAIN 跳跃链  单轴强推 + 定期跳跃，长成断续的链/枝
#
# 生长机制（三条铁律）
#   1. 复制式扩张：冷却结束后「生一个新粒子」，本体不变大
#   2. 朝最空的邻格生：前沿外推，被咬出的缺口从边缘往里填
#   3. 无终身配额：只受冷却 + 格子容量约束，所以缺口一定能填满
#
# 消除
#   · 区域内 live 全部转 corpse，原地留尸，不扩散
#   · corpse 不占格子、不复生，30 秒衰减消失（战斗疤痕）
#   · 吸附范围内可以收割 corpse -> 养分（巨噬细胞）
#
# 性能
#   · 全 Packed 数组，无 new/free
#   · 复制只查一格占用计数（O(1)），不做邻域扫描
#   · 单个 MultiMesh，1 次 draw call
# ============================================================

# ------------------------------------------------------------ 形态
const KIND_BLOB := 0
const KIND_BAND := 1
const KIND_CHAIN := 2
const KIND_COUNT := 3

# 每格容量：圆盘最密，条带中等，链最瘦
const CAP_BLOB := 7
const CAP_BAND := 4
const CAP_CHAIN := 3

# ------------------------------------------------------------ 池
const MAX_LIVE := 4200
const MAX_CORPSE := 1200
const TOTAL := MAX_LIVE + MAX_CORPSE

# ------------------------------------------------------------ 空间
const CELL := 30.0
const GRID_W := 54          # 1600 / 30
const GRID_H := 34          # 1000 / 30
const ARENA_W := 1600.0
const ARENA_H := 1000.0
const ARENA_PAD := 30.0

# ------------------------------------------------------------ 生长
const R_MIN := 4.5
const R_MAX := 8.0
const COOL_MIN := 1.00
const COOL_MAX := 2.00
const SPAWN_D_MIN := 16.0
const SPAWN_D_MAX := 30.0
const PROBE_DIST := 30.0        # 探一格
const JUMP_DIST := 78.0         # 跳跃链的跳跃距离（约 2.6 格）
const JUMP_CHANCE := 0.55       # 前进方向被堵死时，尝试跳跃的概率
const AXIS_WANDER := 0.12       # 每次繁殖让主轴折一次的概率
const WANDER_DEG_BAND := 20.0
const WANDER_DEG_CHAIN := 8.0
const WANDER_CHANCE_CHAIN := 0.12

const YOUNG_SEC := 2.0
const DRIFT_SPEED := 24.0
const CORPSE_LIFE := 30.0

# ------------------------------------------------------------ 颜色
const COL_BLOB := Color(0.30, 0.86, 0.46, 0.90)
const COL_BAND := Color(0.97, 0.73, 0.26, 0.92)
const COL_CHAIN := Color(0.88, 0.38, 0.80, 0.92)
const COL_CORPSE := Color(0.66, 0.70, 0.74, 0.88)

# ------------------------------------------------------------ 状态
var _px := PackedFloat32Array()
var _py := PackedFloat32Array()
var _pr := PackedFloat32Array()
var _page := PackedFloat32Array()
var _plife := PackedFloat32Array()
var _pcool := PackedFloat32Array()
var _pkind := PackedInt32Array()
var _pax := PackedFloat32Array()
var _ptype := PackedInt32Array()      # 0 = live, 1 = corpse
var _pvid := PackedInt32Array()
var _alive := PackedInt32Array()
var _free: Array[int] = []
var _cell := PackedInt32Array()

var _n_live := 0
var _n_corpse := 0
var _kind_live := PackedInt32Array()
var _v_origin: Array[Vector2] = []
var _v_axis: Array[float] = []
var _v_kind: Array[int] = []

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
	_pkind.resize(TOTAL)
	_pax.resize(TOTAL)
	_ptype.resize(TOTAL)
	_pvid.resize(TOTAL)
	_alive.resize(TOTAL)
	_alive.fill(0)
	_cell.resize(GRID_W * GRID_H)
	_cell.fill(0)
	_kind_live.resize(KIND_COUNT)
	_kind_live.fill(0)
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

# 三种形态各自的初始形状
#   BLOB   a = 半径,        b 忽略
#   BAND   a = 半长,        b = 半宽
#   CHAIN  a = 珠子半径,    b = 珠子间距
func spawn_virus(kind: int, center: Vector2, a: float, b: float, count: int, axis: float) -> int:
	var vid := _v_origin.size()
	_v_origin.append(center)
	_v_axis.append(axis)
	_v_kind.append(kind)
	for k in range(count):
		var p := _seed_point(kind, center, a, b, axis)
		_spawn(p.x, p.y, _rng.randf_range(R_MIN, R_MAX), 0, kind,
			axis + _rng.randf_range(-0.10, 0.10), vid,
			_rng.randf_range(0.0, 1.2), _rng.randf_range(COOL_MIN, COOL_MAX))
	return vid


func seed_blob(center: Vector2, radius: float, count: int) -> int:
	return spawn_virus(KIND_BLOB, center, radius, radius, count, 0.0)


func _seed_point(kind: int, center: Vector2, a: float, b: float, axis: float) -> Vector2:
	var ax := Vector2(cos(axis), sin(axis))
	var pp := Vector2(-ax.y, ax.x)
	if kind == KIND_BAND:
		var u := _rng.randf_range(-a, a)
		var v := _rng.randf_range(-b, b)
		return center + ax * u + pp * v
	if kind == KIND_CHAIN:
		var beads := 4
		var bi := _rng.randi_range(0, beads - 1)
		var off := (float(bi) - float(beads - 1) * 0.5) * b
		var ang := _rng.randf() * TAU
		var rr := a * sqrt(_rng.randf())
		return center + ax * off + Vector2(cos(ang), sin(ang)) * rr
	var ang2 := _rng.randf() * TAU
	var rr2 := a * sqrt(_rng.randf())
	return center + Vector2(cos(ang2), sin(ang2)) * rr2


# ============================================================ 查询

func live_count() -> int:
	return _n_live


func corpse_count() -> int:
	return _n_corpse


func live_by_kind(kind: int) -> int:
	return _kind_live[kind]


func arena_size() -> Vector2:
	return Vector2(ARENA_W, ARENA_H)


# ============================================================ 池操作

func _spawn(x: float, y: float, r: float, type: int, kind: int, axis: float,
		vid: int, page: float, cool: float) -> int:
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
	_pkind[i] = kind
	_pax[i] = axis
	_pvid[i] = vid
	_plife[i] = CORPSE_LIFE if type == 1 else 0.0
	if type == 0:
		_n_live += 1
		_kind_live[kind] += 1
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
		_kind_live[_pkind[i]] -= 1
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
	_n_live -= 1
	_kind_live[_pkind[i]] -= 1
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


func _cell_cap(kind: int) -> int:
	if kind == KIND_BAND:
		return CAP_BAND
	if kind == KIND_CHAIN:
		return CAP_CHAIN
	return CAP_BLOB


# ============================================================ 方向权重
# 这个函数决定「长成什么形状」。score = 权重 × 剩余容量，
# 所以：形状由权重主导，但再满的格子也挡不住一个完全空的缺口。

func _dir_weight(kind: int, axis: float, ang: float) -> float:
	var d := fmod(ang - axis + PI, TAU)
	if d < 0.0:
		d += TAU
	d -= PI
	var diff := absf(d)
	if kind == KIND_BAND:
		if diff <= PI * 0.13:
			return 5.0          # 正前方：强推
		if diff <= PI * 0.26:
			return 0.7          # ±45°：慢扩，形成带宽
		if diff <= PI * 0.50:
			return 0.5          # 侧向
		return 0.30             # 反方向：只用于回填
	if kind == KIND_CHAIN:
		if diff <= PI * 0.13:
			return 8.0          # 正前方：近乎单线
		if diff <= PI * 0.30:
			return 0.30         # 极轻分叉
		return 0.10             # 反向：只用于回填
	return 1.0                  # BLOB：各向同性


# ============================================================ 模拟

func tick(dt: float) -> void:
	for i in range(TOTAL):
		if _alive[i] == 0:
			continue
		if _ptype[i] == 0:
			_page[i] += dt
			_pcool[i] -= dt
			if _pcool[i] <= 0.0:
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

	var kind := _pkind[i]
	var axis := _pax[i]
	var cap := _cell_cap(kind)

	# 跳跃链：只认正前方 ±23°。前方堵死就跳一段；跳跃失败才允许回填。
	# 这个分支是「链」和「糊成一团」的唯一差别。
	if kind == KIND_CHAIN:
		var fwd := _pick_dir(i, kind, axis, cap, PI * 0.13)
		if fwd[3]:
			_do_spawn(i, fwd[1], fwd[2], kind, cap)
			return
		if _rng.randf() < JUMP_CHANCE and _try_jump(i, axis):
			return
		var anyd := _pick_dir(i, kind, axis, cap, PI)
		if anyd[3]:
			_do_spawn(i, anyd[1], anyd[2], kind, cap)
			return
		_pcool[i] = _rng.randf_range(COOL_MIN, COOL_MAX)
		return

	var best := _pick_dir(i, kind, axis, cap, PI)
	if not best[3]:
		_pcool[i] = _rng.randf_range(COOL_MIN, COOL_MAX)
		return
	_do_spawn(i, best[1], best[2], kind, cap)


# 在 max_diff 夹角范围内，挑「权重 × 剩余容量」最大的方向
# 返回 [score, dx, dy, found]
func _pick_dir(i: int, kind: int, axis: float, cap: int, max_diff: float) -> Array:
	var best := -1.0
	var bx := 0.0
	var by := 0.0
	var found := false
	for k in range(8):
		var ang := float(k) * PI * 0.25
		if _ang_diff(ang, axis) > max_diff:
			continue
		var dx := cos(ang)
		var dy := sin(ang)
		var tx := _px[i] + dx * PROBE_DIST
		var ty := _py[i] + dy * PROBE_DIST
		if tx < ARENA_PAD or tx > ARENA_W - ARENA_PAD or ty < ARENA_PAD or ty > ARENA_H - ARENA_PAD:
			continue
		var c := _cell_count(tx, ty)
		if c >= cap:
			continue
		var sc := _dir_weight(kind, axis, ang) * float(cap - c)
		if sc > best:
			best = sc
			bx = dx
			by = dy
			found = true
		elif absf(sc - best) < 0.01 and _rng.randf() < 0.5:
			bx = dx
			by = dy
	return [best, bx, by, found]


# 真正落一个子粒子：抖动角度 + 随机步长 + 主轴缓慢折线
func _do_spawn(i: int, bx: float, by: float, kind: int, cap: int) -> void:
	var jitter := deg_to_rad(_rng.randf_range(-12.0, 12.0))
	var nd := Vector2(bx, by).rotated(jitter)
	var dist := _rng.randf_range(SPAWN_D_MIN, SPAWN_D_MAX)
	var nx := _px[i] + nd.x * dist
	var ny := _py[i] + nd.y * dist
	if nx < ARENA_PAD or nx > ARENA_W - ARENA_PAD or ny < ARENA_PAD or ny > ARENA_H - ARENA_PAD:
		_pcool[i] = _rng.randf_range(COOL_MIN, COOL_MAX)
		return
	if _cell_count(nx, ny) >= cap:
		_pcool[i] = _rng.randf_range(COOL_MIN, COOL_MAX)
		return

	var naxis := _pax[i]
	if kind != KIND_BLOB:
		var chance := AXIS_WANDER if kind == KIND_BAND else WANDER_CHANCE_CHAIN
		if _rng.randf() < chance:
			var wd := WANDER_DEG_BAND if kind == KIND_BAND else WANDER_DEG_CHAIN
			naxis = _pax[i] + deg_to_rad(_rng.randf_range(-wd, wd))

	_spawn(nx, ny, _rng.randf_range(R_MIN, R_MAX), 0, kind, naxis, _pvid[i],
		0.0, _rng.randf_range(COOL_MIN, COOL_MAX))
	_pcool[i] = _rng.randf_range(COOL_MIN, COOL_MAX)


func _ang_diff(a: float, b: float) -> float:
	var d := fmod(a - b + PI, TAU)
	if d < 0.0:
		d += TAU
	return absf(d - PI)


# 跳跃：沿主轴跳过一段已经长满的区域，在对面重新落点
func _try_jump(i: int, axis: float) -> bool:
	var jx := _px[i] + cos(axis) * JUMP_DIST
	var jy := _py[i] + sin(axis) * JUMP_DIST
	if jx < ARENA_PAD or jx > ARENA_W - ARENA_PAD or jy < ARENA_PAD or jy > ARENA_H - ARENA_PAD:
		return false
	if _cell_count(jx, jy) >= _cell_cap(KIND_CHAIN):
		return false
	_spawn(jx, jy, _rng.randf_range(R_MIN, R_MAX), 0, KIND_CHAIN, axis, _pvid[i],
		0.0, _rng.randf_range(COOL_MIN, COOL_MAX))
	_pcool[i] = _rng.randf_range(COOL_MIN, COOL_MAX)
	return true


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


# 净化场：圆形范围内按数量配额逐帧清除（接触即消融）
func purge_circle(center: Vector2, radius: float, max_n: int) -> int:
	if max_n <= 0:
		return 0
	var r2 := radius * radius
	var hit := 0
	for i in range(TOTAL):
		if hit >= max_n:
			break
		if _alive[i] == 0 or _ptype[i] != 0:
			continue
		var vx := _px[i] - center.x
		var vy := _py[i] - center.y
		if vx * vx + vy * vy > r2:
			continue
		_to_corpse(i)
		hit += 1
	return hit


# 巨噬细胞回收：吃掉吸附范围内的尸体，换养分
# 只收割「已经躺了 1 秒以上」的尸体，保证战场还能看到疤
func harvest_circle(center: Vector2, radius: float, max_n: int) -> int:
	if max_n <= 0:
		return 0
	var r2 := radius * radius
	var got := 0
	for i in range(TOTAL):
		if got >= max_n:
			break
		if _alive[i] == 0 or _ptype[i] != 1:
			continue
		if _plife[i] > CORPSE_LIFE - 1.0:
			continue
		var vx := _px[i] - center.x
		var vy := _py[i] - center.y
		if vx * vx + vy * vy > r2:
			continue
		_kill(i)
		got += 1
	return got


# ============================================================ 渲染

func _kind_color(kind: int) -> Color:
	if kind == KIND_BAND:
		return COL_BAND
	if kind == KIND_CHAIN:
		return COL_CHAIN
	return COL_BLOB


func _write_slot(i: int) -> void:
	var o := i * 12
	if _alive[i] == 0:
		_buf[o] = 0.0
		_buf[o + 5] = 0.0
		_buf[o + 11] = 0.0
		return
	var s := _pr[i] * 2.0
	var col := _kind_color(_pkind[i])
	if _ptype[i] == 1:
		var k := clampf(_plife[i] / CORPSE_LIFE, 0.0, 1.0)
		col = Color(COL_CORPSE.r, COL_CORPSE.g, COL_CORPSE.b, COL_CORPSE.a * (0.35 + 0.65 * k))
	# TRANSFORM_2D：8 浮点变换 + 4 浮点颜色
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
