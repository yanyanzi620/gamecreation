extends Node2D
# ============================================================
# 主场景 —— 只做三件事：装配、输入、主循环
#
# 这层刻意保持"薄"：具体逻辑都在下面这些地方，main 不做玩法决策
#   scripts/core/balance.gd          唯一数值入口（改数字只改这里）
#   scripts/world/lung_gen.gd        肺地图生成（轮廓 / 肺泡 / 支气管 / 装饰几何）
#   scripts/world/organ_map.gd       地图数据与碰撞判定
#   scripts/world/organ_view.gd      地图渲染（含可开关的装饰层）
#   scripts/world/virus_population.gd 病毒粒子池：扩散 / 尸体 / 阻隔带 / 引信 / 查询
#   scripts/units/player_unit.gd     免疫单元（位置 / 绘制 / 贴墙滑行）
#   scripts/units/tools/*            手段：射流、净化场 + 养分拾取
#   scripts/ui/*                     HUD、小地图
#   scripts/debug/*                  自测、探针、自动验收
#
# 操作
#   WASD 移动（肉壁和阻隔带都挡人，撞上沿墙滑动）
#   左键 射流 / 右键 阻隔带(30) / 空格 引信(40) / R 换一张肺 / F 装饰层
# 命令行：--seed=NNN 固定地图；--shot / --overview / --stress / --walk 见 scripts/debug/auto_sequence.gd
# ============================================================

const STEP := 1.0 / 60.0
const MAX_CATCHUP := 8              # 单帧最多补几次模拟，防止失焦回来疯狂追帧
const Virus = preload("res://scripts/world/virus_population.gd")

var pop
var player_unit
var cam: Camera2D
var view: Node2D
var jet
var aura
var hud
var auto_seq

var map_seed := Balance.DEFAULT_SEED

var _map = null
var _rng := RandomNumberGenerator.new()
var _spawn_pts: Array[Vector2] = []
var _acc := 0.0
var _blk_cd := 0.0
var _fuse_cd := 0.0
var _tick_us := 0


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.06, 0.08, 0.10))
	# 窗口失焦 / 空闲时不要被降频（否则会「画面冻住，动一下鼠标才继续」）
	OS.low_processor_usage_mode = false
	Engine.max_fps = 0
	map_seed = _parse_seed()

	_build()
	_build_hud()
	_reseed(false)

	if auto_seq != null and auto_seq.wants_run():
		auto_seq.run()


func _parse_seed() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			return int(a.substr(7))
	return Balance.DEFAULT_SEED


# ============================================================ 装配

func _build() -> void:
	# 器官视图压在病毒(z=-1)下面
	view = load("res://scripts/world/organ_view.gd").new()
	view.name = "OrganView"
	view.z_index = -2
	# -- --decor-off 出纯灰盒底图；F 键可在运行时切换
	view.decor_on = Balance.DECOR_ON and not OS.get_cmdline_user_args().has("--decor-off")
	add_child(view)

	pop = load("res://scripts/world/virus_population.gd").new()
	pop.name = "Virus"
	add_child(pop)

	jet = load("res://scripts/units/tools/jet_system.gd").new()
	jet.name = "Jet"
	add_child(jet)
	jet.bind(pop)

	aura = load("res://scripts/units/tools/purge_aura.gd").new()
	aura.name = "Aura"
	add_child(aura)
	aura.bind(pop)

	player_unit = load("res://scripts/units/player_unit.gd").new()
	player_unit.name = "Unit"
	player_unit.z_index = 0
	add_child(player_unit)

	cam = Camera2D.new()
	cam.name = "Cam"
	cam.zoom = Vector2(Balance.CAM_ZOOM, Balance.CAM_ZOOM)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 9.0
	add_child(cam)
	cam.make_current()

	auto_seq = load("res://scripts/debug/auto_sequence.gd").new()
	auto_seq.name = "AutoSequence"
	auto_seq.setup(self)
	add_child(auto_seq)


func _build_hud() -> void:
	hud = load("res://scripts/ui/hud.gd").new()
	hud.name = "HUD"
	add_child(hud)
	hud.build(get_viewport().get_visible_rect().size, load("res://scripts/ui/minimap.gd"))


# ============================================================ 地图与开局

func _gen_map() -> void:
	var t0 := Time.get_ticks_usec()
	var gen := LungGen.new()
	_map = gen.build(map_seed, pop.arena_size())
	pop.bind_organ(_map)
	player_unit.bind(_map, pop)
	view.set_map(_map)
	if hud != null and hud.mini != null:
		hud.mini.map = _map
		hud.mini.pop = pop
		hud.mini.tex = view.map_texture()
	if cam != null:
		# 限位到「器官本身」的范围，别让镜头跑到体腔外的空地上
		var ob: Rect2 = _map.organ_bounds
		cam.limit_left = int(maxf(0.0, ob.position.x - 60.0))
		cam.limit_top = int(maxf(0.0, ob.position.y - 60.0))
		cam.limit_right = int(minf(_map.size.x, ob.end.x + 60.0))
		cam.limit_bottom = int(minf(_map.size.y, ob.end.y + 60.0))
		cam.position = player_unit.position
		cam.reset_smoothing()
	# 可达率用「真实碰撞口径」：玩家碰撞按 0.72R 算，这里阈值同步
	var rep: Dictionary = _map.walk_report(Balance.PLAYER_R * 0.72)
	print("[MAP] seed=%d shapes=%d loops=%d(open %d) segs=%d build=%dms free=%.1f%% walk=%.1f%% reach=%.1f%% comps=%d (total %dms)" % [
		map_seed, _map.shape_count, int(rep["loops"]), int(rep["open_loops"]), int(rep["segments"]), _map.build_ms,
		float(rep["free_ratio"]) * 100.0, float(rep["walk_area"]) * 100.0,
		float(rep["reach_ratio"]) * 100.0, int(rep["components"]),
		int(Time.get_ticks_usec() - t0) / 1000
	])


func _reseed(roll_map: bool) -> void:
	if _map == null or roll_map:
		if roll_map:
			_rng.seed = int(Time.get_ticks_msec())
			map_seed = _rng.randi_range(1, 999999)
		_gen_map()

	pop.reset()
	aura.nutrient = Balance.START_NUTRIENT
	aura.picked = 0
	_acc = 0.0
	_blk_cd = 0.0
	_fuse_cd = 0.0

	_rng.seed = map_seed
	var start := _pick_start()
	player_unit.teleport(start)
	print("[START] player=(%.0f,%.0f) solid=%s" % [start.x, start.y, str(_map.solid_point(start))])
	if cam != null:
		cam.position = player_unit.position
		cam.reset_smoothing()
	_spawn_wave()


# 开局站在左肺门：支气管刚插进左叶的那个口子，出门就是肺泡区
func _pick_start() -> Vector2:
	var mid_x: float = _map.size.x * 0.5
	var p: Vector2 = _map.nearest_free(Vector2(mid_x - 430.0, _map.size.y * 0.310), 520.0)
	if p.x < 0.0:
		p = _pick_near_center()
	return p


func _pick_near_center() -> Vector2:
	var best: Vector2 = _map.size * 0.5
	var best_d := 1.0e9
	for i in range(30):
		var p: Vector2 = _map.random_free_point(_rng, Balance.PLAYER_R + 6.0)
		var d: float = p.distance_to(_map.size * 0.5)
		if d < best_d:
			best_d = d
			best = p
	return best


# 三团病毒：左叶、右叶、第三团不限 —— 全身感染才符合玩法设定
func _spawn_wave() -> void:
	_spawn_pts.clear()
	var mid_x: float = _map.size.x * 0.5
	var wants: Array = [[0.0, mid_x], [mid_x, _map.size.x], [0.0, _map.size.x]]
	for w in wants:
		var cands: Array[Vector2] = []
		for attempt in range(70):
			var cand: Vector2 = _map.random_free_point(_rng, 60.0)
			if cand.x < float(w[0]) or cand.x > float(w[1]):
				continue
			var ok := true
			for p in _spawn_pts:
				if p.distance_to(cand) < 620.0:
					ok = false
					break
			# 找开阔处播种，不然一大半粒子直接落进肉壁被丢掉
			if ok and _map.clearance(cand) >= 66.0:
				cands.append(cand)
		if cands.is_empty():
			for attempt in range(70):
				var cand2: Vector2 = _map.random_free_point(_rng, 60.0)
				if cand2.x >= float(w[0]) and cand2.x <= float(w[1]):
					cands.append(cand2)
		var pick: Vector2 = cands[int(_rng.randi_range(0, cands.size() - 1))] if not cands.is_empty() else _map.size * 0.5
		_spawn_pts.append(pick)

	pop.spawn_virus(Virus.KIND_BLOB, _spawn_pts[0], 150.0, 0.0, 1380, _rng.randf() * TAU)
	pop.spawn_virus(Virus.KIND_BAND, _spawn_pts[1], 290.0, 46.0, 430, _rng.randf() * TAU)
	pop.spawn_virus(Virus.KIND_CHAIN, _spawn_pts[2], 36.0, 0.0, 52, _rng.randf() * TAU)


# ============================================================ 输入

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey:
		var k := e as InputEventKey
		if not k.pressed or k.echo:
			return
		if k.keycode == KEY_SPACE:
			place_fuse_at(get_global_mouse_position())
		elif k.keycode == KEY_F:
			if view != null:
				view.set_decor_on(not view.decor_on)
				print("[DECOR] on=%s" % str(view.decor_on))
		elif k.keycode == KEY_R:
			_reseed(true)
		return

	if not (e is InputEventMouseButton):
		return
	var mb := e as InputEventMouseButton
	if not mb.pressed:
		return
	var pos := get_global_mouse_position()
	if mb.button_index == MOUSE_BUTTON_LEFT:
		fire_at(pos)
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		if _blk_cd <= 0.0:
			if place_block_at(pos):
				_blk_cd = Balance.BLOCK_COOLDOWN


# ============================================================ 手段（供输入与自动验收共用）

func fire_at(target: Vector2) -> int:
	var d: Vector2 = target - player_unit.position
	if d.length() < 1.0:
		d = Vector2.RIGHT
	return jet.fire(player_unit.position, d)


func place_block_at(target: Vector2) -> bool:
	if aura.nutrient < Balance.BLOCK_COST:
		return false
	var d: Vector2 = target - player_unit.position
	if d.length() < 1.0:
		d = Vector2.RIGHT
	if not pop.place_block(player_unit.position, d):
		return false
	aura.nutrient -= Balance.BLOCK_COST
	return true


func place_fuse_at(target: Vector2) -> bool:
	if _fuse_cd > 0.0 or aura.nutrient < Balance.FUSE_COST:
		return false
	var d: Vector2 = target - player_unit.position
	if d.length() < 1.0:
		d = Vector2.RIGHT
	var spot: Vector2 = player_unit.position + d.normalized() * Balance.FUSE_OFFSET
	# 引信不能丢在肉壁里，往流明吸一下
	if _map.solid_point(spot):
		spot = _map.nearest_free(spot, 80.0)
		if spot.x < 0.0:
			return false
	if not pop.add_fuse(spot):
		return false
	aura.nutrient -= Balance.FUSE_COST
	_fuse_cd = Balance.FUSE_COOLDOWN
	return true


# ============================================================ 主循环

func _process(delta: float) -> void:
	var mv := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		mv.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		mv.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		mv.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		mv.y += 1.0
	player_unit.move_input(mv, delta)

	if cam != null:
		cam.position = player_unit.position
	if hud != null and hud.mini != null:
		hud.mini.player = player_unit.position
		if cam != null:
			var vs: Vector2 = get_viewport_rect().size / cam.zoom
			hud.mini.view_rect = Rect2(cam.get_screen_center_position() - vs * 0.5, vs)
		hud.mini.queue_redraw()

	if _blk_cd > 0.0:
		_blk_cd = maxf(0.0, _blk_cd - delta)
	if _fuse_cd > 0.0:
		_fuse_cd = maxf(0.0, _fuse_cd - delta)

	_acc += delta
	if _acc > 0.25:
		_acc = 0.25
	var guard := 0
	while _acc >= STEP and guard < MAX_CATCHUP:
		_acc -= STEP
		guard += 1
		var t0 := Time.get_ticks_usec()
		pop.tick(STEP)
		jet.tick(STEP)
		aura.tick(STEP, player_unit.position)
		_tick_us = Time.get_ticks_usec() - t0

	_update_hud()


func _update_hud() -> void:
	if hud == null:
		return
	var d := {
		"jet_ratio": jet.ready_ratio(),
		"live": pop.live_count(), "blob": pop.live_by_kind(Virus.KIND_BLOB),
		"band": pop.live_by_kind(Virus.KIND_BAND), "chain": pop.live_by_kind(Virus.KIND_CHAIN),
		"corpse": pop.corpse_count(), "tick_ms": float(_tick_us) / 1000.0,
		"nutrient": aura.nutrient, "picked": aura.picked, "hit": jet.last_hit(),
		"blocks": pop.block_count(), "fuses": pop.fuse_count(),
		"cd_block": _blk_cd, "cd_fuse": _fuse_cd,
		"map_seed": map_seed,
	}
	if _map != null:
		d["free_ratio"] = _map.free_ratio
		d["segs"] = _map.seg_a.size()
		d["loops"] = _map.loops.size()
		d["map_size"] = _map.size
	hud.refresh(d)
