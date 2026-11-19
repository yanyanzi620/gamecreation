extends Node2D
# ============================================================
# 病毒种群 —— 粒子表示（M1-T2 正式模块）
#
# 一个病毒 = 一堆粒子。三种形态共用同一套复制规则，
# 差别只在「往哪个方向生」的权重表和「每格塞几个」：
#
#   KIND_BLOB  圆周    各向同性，长成不规则圆盘
#   KIND_BAND  带状    主轴优先，主轴缓慢折线，长成条带
#   KIND_CHAIN 跳跃链  单点传播：往前方扇形里随机落点，无视阻隔带
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
const CAP_BLOB := Balance.BLOB_CAP
const CAP_BAND := Balance.BAND_CAP
const CAP_CHAIN := Balance.CHAIN_CAP

# ------------------------------------------------------------ 池
# 病毒不设上限：粒子池按需扩容（_grow_pool），只给尸体留一个「视觉预算」上限
const CAP_INIT := Balance.VIRUS_CAP_INIT
const GROW_STEP := Balance.VIRUS_GROW_STEP
const MAX_CORPSE := Balance.VIRUS_MAX_CORPSE
const WORK_BUDGET := Balance.VIRUS_WORK_BUDGET
const SPAWN_BUDGET := Balance.VIRUS_SPAWN_BUDGET
const QUERY_BUDGET := Balance.VIRUS_QUERY_BUDGET

# ------------------------------------------------------------ 空间
const CELL := Balance.CELL
const GRID_W := Balance.GRID_W
const GRID_H := Balance.GRID_H
const ARENA_W := Balance.ARENA_W
const ARENA_H := Balance.ARENA_H
const ARENA_PAD := Balance.ARENA_PAD

# ------------------------------------------------------------ 生长
const R_MIN := Balance.VIRUS_R_MIN
const R_MAX := Balance.VIRUS_R_MAX
const COOL_MIN := Balance.VIRUS_COOL_MIN
const COOL_MAX := Balance.VIRUS_COOL_MAX
const SPAWN_D_MIN := Balance.BLOB_SPAWN_D_MIN
const SPAWN_D_MAX := Balance.BLOB_SPAWN_D_MAX
const PROBE_DIST := Balance.VIRUS_PROBE_DIST
const ESCAPE_PROBE := Balance.VIRUS_ESCAPE_PROBE
const RETRY_MIN := Balance.VIRUS_RETRY_MIN
const RETRY_MAX := Balance.VIRUS_RETRY_MAX
const Satur_MIN := Balance.VIRUS_SATUR_COOL_MIN
const Satur_MAX := Balance.VIRUS_SATUR_COOL_MAX
const JET_RAYS := Balance.JET_RAYS

# 跳跃链 = 单点传播：不粘连、不稳方向，只保证「整体往前推」
# 每次繁殖在空中随机落一个点，点与点之间天然留空，视觉上不会糊成条带
const CHAIN_SPREAD_DEG := Balance.CHAIN_SPREAD_DEG
const CHAIN_STEP_MIN := Balance.CHAIN_STEP_MIN
const CHAIN_STEP_MAX := Balance.CHAIN_STEP_MAX

# ------------------------------------------------------------ 阻隔带
const BLK_ARM := Balance.BLOCK_ARM
const BLK_LIFE := Balance.BLOCK_LIFE
const BLK_LEN := Balance.BLOCK_LEN
const BLK_RANGE_MIN := Balance.BLOCK_RANGE_MIN
const BLK_RANGE_MAX := Balance.BLOCK_RANGE_MAX
const BLK_MIN_USABLE := Balance.BLOCK_MIN_USABLE
const BLK_SLACK := Balance.BLOCK_SLACK
const BLK_STATE_ARM := 0
const BLK_STATE_ON := 1

# ------------------------------------------------------------ 引信
# 空格放一个引信：小圈里的圆盘/带状直接消融，
# 大圈里的跳跃链被逐帧拽向小圈，进圈即灭。
const FUSE_KILL := Balance.FUSE_KILL
const FUSE_PULL := Balance.FUSE_PULL
const FUSE_SPEED := Balance.FUSE_SPEED
const FUSE_LIFE := Balance.FUSE_LIFE
const MAX_FUSE := Balance.FUSE_MAX
const AXIS_WANDER := Balance.BAND_AXIS_WANDER
const WANDER_DEG_BAND := Balance.BAND_WANDER_DEG

const YOUNG_SEC := 2.0
const DRIFT_SPEED := 24.0
const CORPSE_LIFE := Balance.CORPSE_LIFE

# ------------------------------------------------------------ 颜色
const COL_BLOB := Color(0.30, 0.86, 0.46, 0.90)
const COL_BAND := Color(0.97, 0.73, 0.26, 0.92)
const COL_CHAIN := Color(0.88, 0.38, 0.80, 0.92)
const COL_CORPSE := Color(0.66, 0.70, 0.74, 0.88)

# ------------------------------------------------------------ 状态
# 粒子池：连续存储 + 尾部交换删除。没有 free list，也没有固定上限。
var _px := PackedFloat32Array()
var _py := PackedFloat32Array()
var _pr := PackedFloat32Array()
var _pkind := PackedInt32Array()
var _pax := PackedFloat32Array()
var _ptype := PackedInt32Array()      # 0 = live, 1 = corpse
var _pvid := PackedInt32Array()
# 时间一律存「绝对到时」，不再存倒计时：没被扫到的粒子不会算错，也不用每帧逐个减
var _due := PackedFloat32Array()      # 这颗下次可复制的绝对时刻
var _die := PackedFloat32Array()      # 尸体会消失的绝对时刻
var _fade := PackedInt32Array()       # 尸体已写到的淡化档位（避免每帧重写 12 个浮点）
var _cell := PackedInt32Array()       # 粗格占用计数（按位置算，不受索引搬动影响）

# 轻量计时（只在 --stress 里打开，平时全是 0，不影响正式跑）
var prof_enabled := false
var prof_sweep_us := 0
var prof_upload_us := 0
var prof_rep_n := 0
var prof_rep_us := 0
var prof_scan_n := 0

var _n := 0                           # 池里用了多少个槽（live + corpse 连续排在一起）
var _cap := 0
var _now := 0.0
var _cur := 0                         # 模拟轮转游标
var _qc := 0                          # 查询轮转游标（净化 / 拾取共用）

var _n_live := 0
# 最近一次射流被墙截断后的外缘点（世界坐标），jet_system 直接拿来画
var fan_shape := PackedVector2Array()
var fan_origin := Vector2.ZERO
# 上一发有多少条射线是被「玩家放的阻隔带」截断的（不是被肉壁）
var fan_band_clips := 0
var _n_corpse := 0
var _kind_live := PackedInt32Array()
var _v_origin: Array[Vector2] = []
var _v_axis: Array[float] = []
var _v_kind: Array[int] = []

var _rng := RandomNumberGenerator.new()
var _mmi: MultiMeshInstance2D
var _buf := PackedFloat32Array()
var _dirty := true
var _blk: Array = []
var _fuse: Array = []

# 器官地图（OrganMap）。为空时退化成「空旷场地」，老的 demo 场景照常跑
var organ = null

func _ready() -> void:
	_rng.seed = 20261119
	_init_pool()
	_init_multimesh()

func _init_pool() -> void:
	_cell.resize(GRID_W * GRID_H)
	_cell.fill(0)
	_kind_live.resize(KIND_COUNT)
	_kind_live.fill(0)
	_grow_pool(CAP_INIT)

# 扩池：整块 resize（PackedArray 的 resize 会保留旧内容，新尾巴自动填 0）
func _grow_pool(need: int) -> void:
	if need <= _cap:
		return
	var cap := _cap
	var step := GROW_STEP
	if cap <= 0:
		cap = CAP_INIT
		step = GROW_STEP
	while cap < need:
		cap += step
		step = int(float(step) * 1.4)
	_px.resize(cap)
	_py.resize(cap)
	_pr.resize(cap)
	_pkind.resize(cap)
	_pax.resize(cap)
	_ptype.resize(cap)
	_pvid.resize(cap)
	_due.resize(cap)
	_die.resize(cap)
	_fade.resize(cap)
	_buf.resize(cap * 12)
	_cap = cap
	if _mmi != null:
		_mmi.multimesh.instance_count = cap
		_mmi.multimesh.visible_instance_count = cap
		_dirty = true

func _init_multimesh() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	var qm := QuadMesh.new()
	qm.size = Vector2(1.0, 1.0)
	mm.mesh = qm
	mm.instance_count = _cap
	mm.visible_instance_count = _cap

	_mmi = MultiMeshInstance2D.new()
	_mmi.z_index = -1
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
		# 跳跃链的种子就是一小撮点，之后靠「单点传播」往前散开
		var ang := _rng.randf() * TAU
		var rr := a * sqrt(_rng.randf())
		return center + Vector2(cos(ang), sin(ang)) * rr
	var ang2 := _rng.randf() * TAU
	var rr2 := a * sqrt(_rng.randf())
	return center + Vector2(cos(ang2), sin(ang2)) * rr2

# ============================================================ 查询

func live_count() -> int:
	return _n_live


# 池里已经占用了多少个槽（live + 尸体），压力测试用来看扩容效果
func slot_count() -> int:
	return _n

func corpse_count() -> int:
	return _n_corpse

func live_by_kind(kind: int) -> int:
	return _kind_live[kind]

func arena_size() -> Vector2:
	return Vector2(ARENA_W, ARENA_H)


# 接入器官地图：之后病毒的生长、越界、出生都会被肉壁限制
func bind_organ(m) -> void:
	organ = m

# ============================================================ 池操作

# 整场清空（重开用）：池、格子、尸体、阻隔带、引信全部归零
func reset() -> void:
	_n = 0
	_cur = 0
	_qc = 0
	_now = 0.0
	_buf.fill(0.0)
	if _mmi != null:
		_mmi.multimesh.buffer = _buf
	_n_live = 0
	_n_corpse = 0
	_kind_live.fill(0)
	_cell.fill(0)
	_v_origin.clear()
	_v_axis.clear()
	_v_kind.clear()
	_blk.clear()
	_fuse.clear()
	_rng.seed = 20261119
	_dirty = true
	queue_redraw()


func _spawn(x: float, y: float, r: float, type: int, kind: int, axis: float,
		vid: int, page: float, cool: float) -> int:
	if type == 0 and organ != null and organ.solid_point(Vector2(x, y)):
		return -1
	if type == 1 and _n_corpse >= MAX_CORPSE:
		_drop_oldest_corpse()
	if _n + 1 > _cap:
		_grow_pool(_n + 1)
	var i := _n
	_n += 1
	_px[i] = x
	_py[i] = y
	_pr[i] = r
	_ptype[i] = type
	_pkind[i] = kind
	_pax[i] = axis
	_pvid[i] = vid
	_due[i] = _now + cool
	_die[i] = _now + CORPSE_LIFE if type == 1 else 0.0
	_fade[i] = -1
	if type == 0:
		_n_live += 1
		_kind_live[kind] += 1
		_cell_add(x, y)
	else:
		_n_corpse += 1
	_write_slot(i)
	_dirty = true
	return i


# 槽位搬家用：把 src 整块覆盖到 dst（尾部交换删除的核心）
func _copy_slot(dst: int, src: int) -> void:
	_px[dst] = _px[src]
	_py[dst] = _py[src]
	_pr[dst] = _pr[src]
	_pkind[dst] = _pkind[src]
	_pax[dst] = _pax[src]
	_ptype[dst] = _ptype[src]
	_pvid[dst] = _pvid[src]
	_due[dst] = _due[src]
	_die[dst] = _die[src]
	_fade[dst] = _fade[src]


func _kill(i: int) -> void:
	if i < 0 or i >= _n:
		return
	if _ptype[i] == 0:
		_n_live -= 1
		_kind_live[_pkind[i]] -= 1
		_cell_remove(_px[i], _py[i])
	else:
		_n_corpse -= 1
	var last := _n - 1
	if i != last:
		_copy_slot(i, last)
		# 池里数据搬过来了，但 GPU 那一格还是「被删掉那颗」的旧变换 ——
		# 不重写就会出现「尸体已经没了、画面还留着」的鬼影（拾取时尤其明显）
		_write_slot(i)
	_n = last
	_write_slot(last)
	_dirty = true


func _to_corpse(i: int) -> void:
	if i < 0 or i >= _n or _ptype[i] != 0:
		return
	_ptype[i] = 1
	_die[i] = _now + CORPSE_LIFE
	_fade[i] = -1
	_n_live -= 1
	_kind_live[_pkind[i]] -= 1
	_n_corpse += 1
	_cell_remove(_px[i], _py[i])
	_write_slot(i)
	_dirty = true


# 尸体超过上限就丢一颗（从查询游标往后找，避免每次都从 0 开始）
func _drop_oldest_corpse() -> bool:
	var visited := 0
	while visited < _n:
		var i := (_qc + visited) % _n
		visited += 1
		if _ptype[i] == 1:
			_kill(i)
			return true
	return false

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
			return Balance.BAND_W_FRONT      # 正前方：强推
		if diff <= PI * 0.26:
			return Balance.BAND_W_45         # ±45°：慢扩，形成连续带宽
		if diff <= PI * 0.50:
			return Balance.BAND_W_SIDE       # 侧向
		return Balance.BAND_W_BACK           # 反方向：只用于回填

	return 1.0                  # BLOB：各向同性

# ============================================================ 模拟

func tick(dt: float) -> void:
	_now += dt
	_tick_blocks(dt)
	_tick_fuses(dt)
	var t0 := Time.get_ticks_usec() if prof_enabled else 0
	_sweep()
	if prof_enabled:
		prof_sweep_us += Time.get_ticks_usec() - t0
	if _dirty:
		var t1 := Time.get_ticks_usec() if prof_enabled else 0
		_mmi.multimesh.buffer = _buf
		_dirty = false
		if prof_enabled:
			prof_upload_us += Time.get_ticks_usec() - t1


# 每帧只处理「预算内的槽」：不管池里有多少颗，单帧开销都有上限。
# 轮转游标保证被跳过的粒子只是把动作推到下一轮，逻辑不会错、也不会漏。
func _sweep() -> void:
	if _n <= 0:
		_cur = 0
		return
	var budget := clampi(_n / 8, WORK_BUDGET, WORK_BUDGET * 6)
	var spawns := SPAWN_BUDGET
	var visited := 0
	while visited < budget and _n > 0:
		if _cur >= _n:
			_cur = 0
		var i := _cur
		_cur += 1
		visited += 1
		prof_scan_n += 1
		if _ptype[i] == 0:
			if _due[i] <= _now and spawns > 0:
				if prof_enabled:
					var tr := Time.get_ticks_usec()
					spawns -= _replicate(i)
					prof_rep_us += Time.get_ticks_usec() - tr
					prof_rep_n += 1
				else:
					spawns -= _replicate(i)
		else:
			if _die[i] <= _now:
				_kill(i)
				if _cur > _n:
					_cur = 0
			else:
				_fade_corpse(i)


# 尸体淡化只在「档位变了」才重写 12 个浮点，省掉整池每帧重写
func _fade_corpse(i: int) -> void:
	var b := int((_die[i] - _now) / (CORPSE_LIFE / 24.0))
	if b != _fade[i]:
		_fade[i] = b
		_write_slot(i)
		_dirty = true


# 返回这一帧真的提交了几个新粒子（0 / 1），供单帧预算记账
func _replicate(i: int) -> int:
	var kind := _pkind[i]
	var axis := _pax[i]
	var cap := _cell_cap(kind)

	# 跳跃链 = 单点传播：往前方扇形里随机落一个点，隔着阻隔带也照样落
	if kind == KIND_CHAIN:
		return _chain_spread(i, axis)
	var best := _pick_dir(i, kind, axis, cap, PI)
	# 塞满和撞墙是两种失败：塞满的地方再等也长不出来，直接长退避，
	# 否则每 0.3 秒重试一次，几万颗时会白白烧掉大量帧时间
	if not best[3]:
		_due[i] = _now + (_saturate_cool() if best[5] == 1 else _retry_cool())
		return 0
	return _do_spawn(i, best[1], best[2], kind, cap, best[4])

# 在 max_diff 夹角范围内，挑「权重 × 剩余容量」最大的方向
# 返回 [score, dx, dy, found]
func _pick_dir(i: int, kind: int, axis: float, cap: int, max_diff: float) -> Array:
	var saw_cap := false
	for pass_i in range(2):
		# 第二遍把探路距离放到 ESCAPE_PROBE：本地格子长满时，还能往远处空位甩一颗，
		# 否则「小股病毒坐在一个塞满的格子里」会一直不长，看起来像卡住
		var pd := PROBE_DIST if pass_i == 0 else ESCAPE_PROBE
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
			var tx := _px[i] + dx * pd
			var ty := _py[i] + dy * pd
			if tx < ARENA_PAD or tx > ARENA_W - ARENA_PAD or ty < ARENA_PAD or ty > ARENA_H - ARENA_PAD:
				continue
			# 器官肉壁：这个方向长不过去。
			# 探路距离 30 比最薄隔膜（46）还短，所以「终点一格是否实心」就等价于「这段没穿墙」，
			# 单点采样足够；只有第二遍 60 的远投才需要沿线段多点采样。
			if organ != null:
				if pd <= 32.0:
					if organ.solid_xy(tx, ty):
						continue
				elif not organ.line_free(_px[i], _py[i], tx, ty):
					continue
			# 生效的阻隔带把外面封死：这个方向不可选，
			# 于是生长会自动沿带子走向两端，形成绕射
			if _block_cross(_px[i], _py[i], tx, ty) == 1:
				continue
			var c := _cell_count(tx, ty)
			if c >= cap:
				saw_cap = true
				continue
			var sc := _dir_weight(kind, axis, ang) * float(cap - c)
			if pass_i == 1:
				sc = _dir_weight(kind, axis, ang) * 0.9
			if sc > best:
				best = sc
				bx = dx
				by = dy
				found = true
			elif absf(sc - best) < 0.01 and _rng.randf() < 0.5:
				bx = dx
				by = dy
		if found:
			return [best, bx, by, true, pass_i == 1, 0]
	return [0.0, 0.0, 0.0, false, false, 1 if saw_cap else 0]

func _chain_spread(i: int, axis: float) -> int:
	# 往主轴前方 ±CHAIN_SPREAD_DEG 的扇形里随机落一个点。
	# 不沿地面走 -> 阻隔带栏不住（这是它和带状病毒最大的区别）；
	# 点与点之间天然留空 -> 不会糊成条带。
	var ang := axis + deg_to_rad(_rng.randf_range(-CHAIN_SPREAD_DEG, CHAIN_SPREAD_DEG))
	var dist := _rng.randf_range(CHAIN_STEP_MIN, CHAIN_STEP_MAX)
	var nx := _px[i] + cos(ang) * dist
	var ny := _py[i] + sin(ang) * dist
	if nx < ARENA_PAD or nx > ARENA_W - ARENA_PAD or ny < ARENA_PAD or ny > ARENA_H - ARENA_PAD:
		_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
		return 0
	# 跳跃链是「空中落点」：能跨阻隔带、也能跨肉壁，
	# 但落点必须被拉回流明里，否则会嵌进组织内部
	if organ != null and organ.solid_xy(nx, ny):
		var free_at: Vector2 = organ.nearest_free(Vector2(nx, ny), 90.0)
		if free_at.x < 0.0:
			_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
			return 0
		nx = free_at.x
		ny = free_at.y
	if nx < ARENA_PAD or nx > ARENA_W - ARENA_PAD or ny < ARENA_PAD or ny > ARENA_H - ARENA_PAD:
		_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
		return 0
	if _cell_count(nx, ny) >= CAP_CHAIN:
		_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
		return 0
	var naxis := axis + deg_to_rad(_rng.randf_range(-14.0, 14.0))
	var child := _spawn(nx, ny, _rng.randf_range(R_MIN, R_MAX), 0, KIND_CHAIN, naxis,
		_pvid[i], 0.0, _rng.randf_range(COOL_MIN, COOL_MAX))
	_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
	return 1 if child >= 0 else 0

# 真正落一个子粒子：抖动角度 + 随机步长 + 主轴缓慢折线
func _do_spawn(i: int, bx: float, by: float, kind: int, cap: int, far: bool) -> int:
	var jitter := deg_to_rad(_rng.randf_range(-12.0, 12.0))
	var nd := Vector2(bx, by).rotated(jitter)
	var smin := SPAWN_D_MIN
	var smax := SPAWN_D_MAX
	# 兜底档：本地塞满时往远处甩一颗，落点必须真的跨出拥挤区
	if far:
		smin = ESCAPE_PROBE * 0.85
		smax = ESCAPE_PROBE * 1.15
	elif kind == KIND_BAND:
		smin = Balance.BAND_SPAWN_D_MIN
		smax = Balance.BAND_SPAWN_D_MAX
	var dist := _rng.randf_range(smin, smax)
	var nx := _px[i] + nd.x * dist
	var ny := _py[i] + nd.y * dist
	if nx < ARENA_PAD or nx > ARENA_W - ARENA_PAD or ny < ARENA_PAD or ny > ARENA_H - ARENA_PAD:
		_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
		return 0
	if organ != null and not organ.line_free(_px[i], _py[i], nx, ny):
		_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
		return 0
	if _cell_count(nx, ny) >= cap:
		_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
		return 0
	# 阻隔带：生效后不许穿过；闪烁期内穿过去只会被减速
	# 跳跃链例外 —— 它是空中落点，不沿地面走，所以直接无视封堵
	var bc := 0
	if kind != KIND_CHAIN:
		bc = _block_cross(_px[i], _py[i], nx, ny)
		if bc == 1:
			_due[i] = _now + _rng.randf_range(COOL_MIN, COOL_MAX)
			return 0
	var cool_pen := 2.4 if bc == 2 else 1.0

	# 只有带状会缓慢折线（圆盘各向同性，链走的是 _chain_spread）
	var naxis := _pax[i]
	if kind == KIND_BAND and _rng.randf() < AXIS_WANDER:
		naxis = _pax[i] + deg_to_rad(_rng.randf_range(-WANDER_DEG_BAND, WANDER_DEG_BAND))

	var child := _spawn(nx, ny, _rng.randf_range(R_MIN, R_MAX), 0, kind, naxis, _pvid[i],
		0.0, _rng.randf_range(COOL_MIN, COOL_MAX) * cool_pen)
	# 落子失败（恰好压在组织上 / 池要扩容）：只短暂重试，不能让这一支从此「停住」
	_due[i] = _now + (_rng.randf_range(COOL_MIN, COOL_MAX) if child >= 0 else _retry_cool())
	return 1 if child >= 0 else 0

# 一次没长成时的短暂重试间隔（远小于代际冷却）
	return 1 if child >= 0 else 0


func _retry_cool() -> float:
	return _rng.randf_range(RETRY_MIN, RETRY_MAX)


# 本地密度已经塞满时的长退避：这里再努力也长不出来，等玩家清出空间再说
func _saturate_cool() -> float:
	return _rng.randf_range(Satur_MIN, Satur_MAX)


# 有符号夹角差，落在 [-PI, PI]；扇形左右两侧要分开取各自的射线长度，不能取绝对值
func _ang_signed(a: float, b: float) -> float:
	var d := fmod(a - b + PI, TAU)
	if d < 0.0:
		d += TAU
	return d - PI


# 有符号夹角差，落在 [-PI, PI]；扇形左右两侧要分开取各自的射线长度，不能取绝对值
func _ang_diff(a: float, b: float) -> float:
	var d := fmod(a - b + PI, TAU)
	if d < 0.0:
		d += TAU
	return absf(d - PI)

# ============================================================ 消除

# 扇形清除：锥内 live 全部转尸体，返回命中数
# 扇形清除：锥内 live 全部转尸体，返回命中数
# 判命中与画扇形共用同一份「被墙截断到哪」的表：画得到的地方才清得到。
func clear_fan(origin: Vector2, dir: Vector2, length: float, half_angle: float) -> int:
	var rays := _fan_rays(origin, dir, length, half_angle)
	var dn := dir.normalized()
	var cos_lim := cos(half_angle)
	var len2 := length * length
	var hit := 0
	for i in range(_n):
		if _ptype[i] != 0:
			continue
		var vx := _px[i] - origin.x
		var vy := _py[i] - origin.y
		var l2 := vx * vx + vy * vy
		if l2 > len2:
			continue
		if l2 < 0.0001:
			_to_corpse(i)
			hit += 1
			continue
		# 先做廉价粗筛：背后 / 锥外直接丢，避免对整池调用 atan2
		var dot := vx * dn.x + vy * dn.y
		if dot <= 0.0:
			continue
		if dot * dot < l2 * cos_lim * cos_lim:
			continue
		var l := sqrt(l2)
		var diff := _ang_signed(atan2(vy, vx), dn.angle())
		var bucket := clampi(int(round((diff + half_angle) / (2.0 * half_angle) * float(JET_RAYS - 1))), 0, JET_RAYS - 1)
		if l > rays[bucket]:
			continue
		_to_corpse(i)
		hit += 1
	return hit


# 一条射流 = JET_RAYS 条射线，每条各自打到墙为止；返回每条射线的实际长度。
# 同一份数据既判命中、又画被墙削掉的扇形，视觉和规则不会打架。
func _fan_rays(origin: Vector2, dir: Vector2, length: float, half_angle: float) -> PackedFloat32Array:
	var rays := PackedFloat32Array()
	rays.resize(JET_RAYS)
	var step := 12.0
	var shape := PackedVector2Array()
	fan_band_clips = 0
	for r in range(JET_RAYS):
		var ang := -half_angle + 2.0 * half_angle * float(r) / float(JET_RAYS - 1)
		var d := dir.rotated(ang)
		var t := 0.0
		var reach := length
		while t < length - 0.01:
			var a := origin + d * t
			var b := origin + d * minf(t + step, length)
			if organ != null and organ.blocked(a, b):
				reach = t
				break
			t = minf(t + step, length)
		# 阻隔带也挡射线：带子是一道墙，射流打在上面就停（闪烁期穿过，与「生效前穿越只减速」一致）
		var band_t := _band_reach(origin, d, reach)
		if band_t < reach:
			reach = band_t
			fan_band_clips += 1
		rays[r] = reach
		shape.append(origin + d * reach)
	fan_shape = shape
	fan_origin = origin
	return rays


# 射线在本段距离内最先撞到的「已生效」阻隔带有多远；没有就返回 limit
func _band_reach(origin: Vector2, d: Vector2, limit: float) -> float:
	if _blk.is_empty():
		return limit
	var best := limit
	for blk in _blk:
		if blk["state"] != BLK_STATE_ON:
			continue
		var a: Vector2 = blk["a"]
		var b: Vector2 = blk["b"]
		var n: Vector2 = blk["n"]
		var dd := d.dot(n)
		if absf(dd) < 0.0001:
			continue  # 射线与带子平行，不会穿
		var t_hit := -((origin - a).dot(n)) / dd
		if t_hit < 0.0 or t_hit > best:
			continue
		var hitp := origin + d * t_hit
		var ab := b - a
		var total := ab.length()
		if total < 0.0001:
			continue
		var along := (hitp - a).dot(ab / total)
		if along < -BLK_SLACK or along > total + BLK_SLACK:
			continue
		best = t_hit
	return best


# 净化场：圆形范围内按数量配额逐帧清除（接触即消融）
func purge_circle(center: Vector2, radius: float, max_n: int) -> int:
	if max_n <= 0 or _n <= 0:
		return 0
	var r2 := radius * radius
	var hit := 0
	var visited := 0
	while hit < max_n and visited < QUERY_BUDGET and _n > 0:
		if _qc >= _n:
			_qc = 0
		var i := _qc
		_qc += 1
		visited += 1
		if _ptype[i] != 0:
			continue
		var vx := _px[i] - center.x
		var vy := _py[i] - center.y
		if vx * vx + vy * vy > r2:
			continue
		_to_corpse(i)
		hit += 1
	return hit


# 自动拾取用：吃掉范围内躺够 1 秒的尸体，返回它们的位置（供光点飞行用）
func take_corpse_near(center: Vector2, radius: float, max_n: int) -> Array:
	var out: Array = []
	if max_n <= 0 or _n <= 0:
		return out
	var r2 := radius * radius
	var visited := 0
	while out.size() < max_n and visited < QUERY_BUDGET and _n > 0:
		if _qc >= _n:
			_qc = 0
		var i := _qc
		_qc += 1
		visited += 1
		if _ptype[i] != 1:
			continue
		if _die[i] - _now > CORPSE_LIFE - Balance.CORPSE_PICK_DELAY:
			continue
		var vx := _px[i] - center.x
		var vy := _py[i] - center.y
		if vx * vx + vy * vy > r2:
			continue
		out.append(Vector2(_px[i], _py[i]))
		_kill(i)
	return out


# 巨噬细胞回收：吃掉吸附范围内的尸体，换养分
# 只收割「已经躺了 1 秒以上」的尸体，保证战场还能看到疤
func harvest_circle(center: Vector2, radius: float, max_n: int) -> int:
	if max_n <= 0 or _n <= 0:
		return 0
	var r2 := radius * radius
	var got := 0
	var visited := 0
	while got < max_n and visited < QUERY_BUDGET and _n > 0:
		if _qc >= _n:
			_qc = 0
		var i := _qc
		_qc += 1
		visited += 1
		if _ptype[i] != 1:
			continue
		if _die[i] - _now > CORPSE_LIFE - Balance.CORPSE_PICK_DELAY:
			continue
		var vx := _px[i] - center.x
		var vy := _py[i] - center.y
		if vx * vx + vy * vy > r2:
			continue
		_kill(i)
		got += 1
	return got


# ============================================================ 阻隔带
func add_fuse(center: Vector2) -> bool:
	if _fuse.size() >= MAX_FUSE:
		return false
	_fuse.append({"c": center, "t": 0.0})
	queue_redraw()
	return true


func fuse_count() -> int:
	return _fuse.size()


# ============================================================ 小地图数据
# 把简图要用的东西一次打包：采样点位、左右叶病毒量、阻隔带、引信。
# 采样是「隔几个取一个」，只为了画点，不改变任何真实数据。
func minimap_snapshot(max_pts: int) -> Dictionary:
	var live := PackedVector2Array()
	var corpse := PackedVector2Array()
	var left := 0
	var right := 0
	var mid := ARENA_W * 0.5
	var stride_live := maxi(1, int(ceil(float(maxi(1, _n_live)) / float(max_pts))))
	var stride_corpse := maxi(1, int(ceil(float(maxi(1, _n_corpse)) / float(float(max_pts) * 0.6))))
	var cnt := 0
	var ccnt := 0
	for i in range(_n):
		if _ptype[i] == 1 and _die[i] <= _now:
			continue
		if _ptype[i] == 0:
			if _px[i] < mid:
				left += 1
			else:
				right += 1
			cnt += 1
			if cnt % stride_live == 0:
				live.append(Vector2(_px[i], _py[i]))
		else:
			ccnt += 1
			if ccnt % stride_corpse == 0:
				corpse.append(Vector2(_px[i], _py[i]))
	var blocks: Array = []
	for b in _blk:
		blocks.append([b["a"], b["b"], int(b["state"])])
	var fuses := PackedVector2Array()
	for f in _fuse:
		fuses.append(f["c"])
	return {
		"live": live, "corpse": corpse,
		"left": left, "right": right,
		"blocks": blocks, "fuses": fuses,
	}


func _tick_fuses(dt: float) -> void:
	if _fuse.is_empty():
		return
	var kill2 := FUSE_KILL * FUSE_KILL
	var pull2 := FUSE_PULL * FUSE_PULL
	var keep: Array = []
	for f in _fuse:
		f["t"] += dt
		var c: Vector2 = f["c"]
		for i in range(_n):
			if _ptype[i] != 0:
				continue
			var vx := _px[i] - c.x
			var vy := _py[i] - c.y
			var l2 := vx * vx + vy * vy
			if l2 <= kill2:
				_to_corpse(i)        # 小圈：圆盘/带状/链，一律消融
				continue
			if _pkind[i] == KIND_CHAIN and l2 <= pull2:
				_drag_chain(i, c, dt)
		if f["t"] < FUSE_LIFE:
			keep.append(f)
	_fuse = keep
	queue_redraw()


# 把一颗链粒子往引信拽一步（要同步维护粗格占用）
func _drag_chain(i: int, toward: Vector2, dt: float) -> void:
	var dx := toward.x - _px[i]
	var dy := toward.y - _py[i]
	var l := sqrt(dx * dx + dy * dy)
	if l < 1.0:
		return
	var step := FUSE_SPEED * dt
	if step > l:
		step = l
	_cell_remove(_px[i], _py[i])
	_px[i] += dx / l * step
	_py[i] += dy / l * step
	_cell_add(_px[i], _py[i])
	_write_slot(i)


# 规则
#   · 按住右键拖拽定位：拖拽方向 = 来路方向（带子恒垂直于「单元 → 光标」连线）
#   · 距离受 BLK_RANGE_MIN~MAX 限制；长度固定 BLK_LEN，两端被肉壁裁短（不许插进组织）
#   · 释放后先闪烁 BLK_ARM 秒才生效
#   · 生效前已经穿过去的病毒 -> 只有减速（那颗之后繁殖变慢）
#   · 生效后病毒无法穿过；带子有限长，所以病毒从两端绕过去（绕射）
#   · 拦病毒也拦玩家；BLK_LIFE 秒后自溶
#   · 与「器官隔离」是两件事：阻隔带永不断血，不会造成坏死

func block_count() -> int:
	return _blk.size()


# 只给验收用：第 i 条带子的端点与长度（不参与玩法判定）
func block_span(i: int) -> Array:
	if i < 0 or i >= _blk.size():
		return []
	var a: Vector2 = _blk[i]["a"]
	var b: Vector2 = _blk[i]["b"]
	return [a, b, a.distance_to(b)]


# 算出「这条带子会落在哪」 —— 预览和真正落位共用同一份几何，避免看到的和放下的不一样。
# 返回 {ok, a, b, c, len, dist, capped, trim, why}
#   ok=false   : 落点被肉壁怼住 / 裁完太短，放不下来
#   dist       : 实际使用的距离（可能因为撞墙比请求的近）
#   capped     : 距离被 BLK_RANGE_MIN/MAX 夹过，或者被墙推近了
#   trim       : 两端被肉壁吃掉的总长度（给预览提示用）
#   why        : 放不下的原因（"dir" / "too_close" / "solid" / "too_narrow"），诊断用
func resolve_block(origin: Vector2, dir: Vector2, dist: float) -> Dictionary:
	var out := {"ok": false, "a": origin, "b": origin, "c": origin, "len": 0.0, "dist": 0.0, "capped": false, "trim": 0.0, "why": ""}
	var d := dir.normalized()
	if d.length_squared() < 0.0001:
		out["why"] = "dir"
		return out
	var want := clampf(dist, BLK_RANGE_MIN, BLK_RANGE_MAX)
	var capped := absf(want - dist) > 0.5
	# 中心点不能落在肉壁里：从单元往外走，撞墙就停在墙前
	var travel := 0.0
	while travel < want:
		var nxt := minf(10.0, want - travel)
		if organ != null and organ.solid_point(origin + d * (travel + nxt)):
			break
		travel += nxt
	if travel < 12.0:
		out["why"] = "too_close"
		return out               # 贴着墙站，前面塞不下一条带子
	if travel < want:
		capped = true
	var c: Vector2 = origin + d * travel
	var half := BLK_LEN * 0.5
	var perp := Vector2(-d.y, d.x)
	var a: Vector2 = c - perp * half
	var b: Vector2 = c + perp * half
	var trim := 0.0
	if organ != null:
		# 两头往可通行区里裁：带子不许插进肉壁（这就是「加碰撞检测」的落点）
		var sp: Dictionary = organ.clip_span(c, perp, half, 8.0)
		if not bool(sp["ok"]):
			out["why"] = "solid"
			return out
		a = sp["a"]
		b = sp["b"]
		trim = float(sp["trim"])
		if float(sp["len"]) < BLK_MIN_USABLE:
			out["why"] = "too_narrow"
			out["len"] = float(sp["len"])
			return out           # 通道太窄，裁完只剩一小截，堵不住任何东西
	out["a"] = a
	out["b"] = b
	out["c"] = c
	out["len"] = a.distance_to(b)
	out["dist"] = travel
	out["capped"] = capped
	out["trim"] = trim
	out["ok"] = true
	return out


func place_block(origin: Vector2, dir: Vector2, dist: float) -> bool:
	var r: Dictionary = resolve_block(origin, dir, dist)
	if not bool(r["ok"]):
		return false
	var d := dir.normalized()
	# a/b 是沿带子长度方向铺开的，所以带子的「法线」是 d，不是 perp
	# （早期这里存成 perp，导致相交判定算的是「沿带子方向」的坐标 -> 带子永远不生效）
	_blk.append({"a": r["a"], "b": r["b"], "n": d, "t": 0.0, "state": BLK_STATE_ARM})
	queue_redraw()
	return true

# 玩家移动用：只有「已生效」的阻隔带才拦人，闪烁期两者都能穿过去
func path_blocked(a: Vector2, b: Vector2) -> bool:
	if organ != null and organ.blocked_body(a, b, Balance.PLAYER_R * 0.72):
		return true
	return _block_cross(a.x, a.y, b.x, b.y) == 1


func _tick_blocks(dt: float) -> void:
	if _blk.is_empty():
		return
	var keep: Array = []
	for blk in _blk:
		blk["t"] += dt
		if blk["state"] == BLK_STATE_ARM and blk["t"] >= BLK_ARM:
			blk["state"] = BLK_STATE_ON
		if blk["t"] >= BLK_ARM + BLK_LIFE:
			continue
		keep.append(blk)
	if keep.size() != _blk.size():
		_blk = keep
	queue_redraw()

# 线段 (x0,y0)->(x1,y1) 与阻隔带的相交判定
#   0 = 没穿   1 = 被生效带拦住   2 = 闪烁期内穿过（减速）
func _block_cross(x0: float, y0: float, x1: float, y1: float) -> int:
	if _blk.is_empty():
		return 0
	var p0 := Vector2(x0, y0)
	var p1 := Vector2(x1, y1)
	for blk in _blk:
		var a: Vector2 = blk["a"]
		var b: Vector2 = blk["b"]
		var n: Vector2 = blk["n"]
		var d0 := (p0 - a).dot(n)
		var d1 := (p1 - a).dot(n)
		if d0 * d1 > 0.0:
			continue
		if absf(d0 - d1) < 0.0001:
			continue
		var tt := d0 / (d0 - d1)
		var hitp := p0.lerp(p1, tt)
		var along := (hitp - a).dot((b - a).normalized())
		var total := (b - a).length()
		if along < -BLK_SLACK or along > total + BLK_SLACK:
			continue
		return 1 if blk["state"] == BLK_STATE_ON else 2
	return 0

func _draw() -> void:
	for blk in _blk:
		var a: Vector2 = blk["a"]
		var b: Vector2 = blk["b"]
		var bt: float = blk["t"]
		var on: bool = blk["state"] == BLK_STATE_ON
		if on:
			var left := BLK_ARM + BLK_LIFE - bt
			var fade := clampf(left / 5.0, 0.35, 1.0)
			draw_line(a, b, Color(0.55, 0.95, 1.0, 0.18 * fade), 16.0)
			draw_line(a, b, Color(0.62, 0.98, 1.0, 0.95 * fade), 3.0)
			draw_circle(a, 5.0, Color(0.62, 0.98, 1.0, 0.95 * fade))
			draw_circle(b, 5.0, Color(0.62, 0.98, 1.0, 0.95 * fade))
		else:
			# 闪烁待生效：一眼看出还没封住
			var blink := 0.35 + 0.65 * absf(sin(bt * 26.0))
			draw_line(a, b, Color(1.0, 0.86, 0.35, 0.90 * blink), 2.0)
			draw_line(a, b, Color(1.0, 0.86, 0.35, 0.20 * blink), 12.0)
	
	for f in _fuse:
		var c: Vector2 = f["c"]
		var life: float = 1.0 - f["t"] / FUSE_LIFE
		var pulse := 0.55 + 0.45 * absf(sin(f["t"] * 9.0))
		# 外圈：只吸引链条的「引力圈」
		draw_arc(c, FUSE_PULL, 0.0, TAU, 48, Color(0.86, 0.42, 0.95, (0.12 + 0.20 * pulse) * life), 1.5)
		# 内圈：真正的杀伤范围
		draw_circle(c, FUSE_KILL, Color(0.95, 0.55, 0.30, 0.10 + 0.10 * pulse))
		draw_arc(c, FUSE_KILL, 0.0, TAU, 40, Color(1.0, 0.72, 0.36, 0.55 + 0.35 * pulse), 2.5)
		draw_circle(c, 6.0, Color(1.0, 0.90, 0.60, 0.95))

# ============================================================ 渲染

func _kind_color(kind: int) -> Color:
	if kind == KIND_BAND:
		return COL_BAND
	if kind == KIND_CHAIN:
		return COL_CHAIN
	return COL_BLOB

func _write_slot(i: int) -> void:
	var o := i * 12
	if i < 0 or i >= _n:
		_buf[o] = 0.0
		_buf[o + 5] = 0.0
		_buf[o + 11] = 0.0
		return
	var s := _pr[i] * 2.0
	var col := _kind_color(_pkind[i])
	if _ptype[i] == 1:
		var k := clampf((_die[i] - _now) / CORPSE_LIFE, 0.0, 1.0)
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
