extends Node2D
# ============================================================
# 主场景 —— 体内免疫战斗（正式玩法，替换 M1-T1 灰盒）
#
# 组成
#   OrganMap 器官地图：流明（可通行）由形状并集生成，边界即肉壁
#   OrganView 把地图画出来（纯代码占位，美术接口留好）
#   Virus    病毒种群：三形态粒子（圆盘 / 带状 / 跳跃链）
#   Jet      射流：左键，扇形清除
#   Aura     净化场（贴身自动消融）+ 养分自动拾取
#   玩家     中枢意识接管的一个免疫单元（本版先只做一个）
#
# 操作
#   WASD  移动（肉壁和阻隔带都挡人，撞上沿墙滑动）
#   左键  射流
#   右键  阻隔带（消耗养分，先闪烁后生效）
#   空格  引信（小圈杀盘/带/链，大圈只吸跳跃链）
#   R     换一张肺（新种子）+ 重新播种
#
# 地图种子可以用命令行固定：-- --seed=12345，方便复现同一张图。
# 所有平衡数值来自 scripts/core/balance.gd。
# ============================================================

const STEP := 1.0 / 60.0
const START_NUTRIENT := 60
const DEFAULT_SEED := 20261119

const KIND_BLOB := 0
const KIND_BAND := 1
const KIND_CHAIN := 2

var pop
var cam: Camera2D
var mini: Control
var view: Node2D
var jet
var aura

var player := Vector2(800.0, 500.0)
var map_seed := DEFAULT_SEED

var _map = null
var _rng := RandomNumberGenerator.new()
var _spawn_pts: Array[Vector2] = []

var _acc := 0.0
var _blk_cd := 0.0
var _fuse_cd := 0.0
var _tick_us := 0
var _shot := false

var _hud: Label
var _hud2: Label
var _hud3: Label
var _hint: Label
var _bar: ColorRect


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.06, 0.08, 0.10))
	# 窗口失焦 / 空闲时不要被降频（否则会「画面冻住，动一下鼠标才继续」）
	OS.low_processor_usage_mode = false
	Engine.max_fps = 0
	_shot = (OS.get_cmdline_user_args().has("--shot")
		or OS.get_cmdline_user_args().has("--overview")
		or OS.get_cmdline_user_args().has("--walk")
		or OS.get_cmdline_user_args().has("--stress"))
	map_seed = _parse_seed()

	_build()
	_build_hud()
	_reseed(false)

	if _shot:
		_shot_sequence()


func _parse_seed() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			return int(a.substr(7))
	return DEFAULT_SEED


func _build() -> void:
	# 器官视图压在病毒(z=-1)下面
	view = load("res://scripts/world/organ_view.gd").new()
	view.name = "OrganView"
	view.z_index = -2
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

	# 相机：地图比屏幕大得多，镜头跟着免疫单元走
	cam = Camera2D.new()
	cam.name = "Cam"
	# 一屏刚好装下一整叶（约 90%）：看得见自己要守的那半区，看不见对面 —— 逼着走气管
	cam.zoom = Vector2(Balance.CAM_ZOOM, Balance.CAM_ZOOM)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 9.0
	add_child(cam)
	cam.make_current()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	_hud = Label.new()
	_hud.position = Vector2(18.0, 12.0)
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_color", Color(0.86, 0.93, 0.89))
	layer.add_child(_hud)

	_bar = ColorRect.new()
	_bar.position = Vector2(18.0, 96.0)
	_bar.size = Vector2(240.0, 8.0)
	_bar.color = Color(0.35, 0.92, 0.62)
	layer.add_child(_bar)

	_hud2 = Label.new()
	_hud2.position = Vector2(18.0, 112.0)
	_hud2.add_theme_font_size_override("font_size", 14)
	_hud2.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	layer.add_child(_hud2)

	_hud3 = Label.new()
	_hud3.position = Vector2(18.0, 134.0)
	_hud3.add_theme_font_size_override("font_size", 13)
	_hud3.add_theme_color_override("font_color", Color(0.62, 0.74, 0.86))
	layer.add_child(_hud3)

	# 整肺简图（右上角）
	var vp := get_viewport().get_visible_rect().size
	mini = load("res://scripts/ui/minimap.gd").new()
	mini.size = Vector2(360.0, 190.0)
	mini.position = Vector2(vp.x - 376.0, 16.0)
	mini.pop = pop
	layer.add_child(mini)

	_hint = Label.new()
	_hint.position = Vector2(18.0, 156.0)
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.60, 0.68, 0.64))
	_hint.text = "WASD 移动（镜头跟随） · 左键 = 射流 · 右键 = 阻隔带(30) · 空格 = 引信(40) · R = 换一张肺"
	layer.add_child(_hint)


# ============================================================ 地图

func _gen_map() -> void:
	var t0 := Time.get_ticks_usec()
	var gen := LungGen.new()
	_map = gen.build(map_seed, pop.arena_size())
	pop.bind_organ(_map)
	view.set_map(_map)
	if mini != null:
		mini.map = _map
		mini.pop = pop
		mini.tex = view.map_texture()
	if cam != null:
		# 限位到「器官本身」的范围，别让镜头跑到体腔外的空地上
		var ob: Rect2 = _map.organ_bounds
		cam.limit_left = int(maxf(0.0, ob.position.x - 60.0))
		cam.limit_top = int(maxf(0.0, ob.position.y - 60.0))
		cam.limit_right = int(minf(_map.size.x, ob.end.x + 60.0))
		cam.limit_bottom = int(minf(_map.size.y, ob.end.y + 60.0))
		cam.position = player
		cam.reset_smoothing()
	# 可达率用「真实碰撞口径」：玩家碰撞按 0.72R 算，这里阈值同步
	# 阈值与真实碰撞一致：blocked_body 用的是 0.72R 的偏移线
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
	aura.nutrient = START_NUTRIENT
	aura.picked = 0
	_acc = 0.0
	_blk_cd = 0.0
	_fuse_cd = 0.0

	_rng.seed = map_seed
	player = _pick_start()
	print("[START] player=(%.0f,%.0f) solid=%s" % [player.x, player.y, str(_map.solid_point(player))])
	if cam != null:
		cam.position = player
		cam.reset_smoothing()
	_spawn_wave()


# 开局站在左肺门：支气管刚插进左叶的那个口子，出门就是肺泡区
func _pick_start() -> Vector2:
	var mid_x: float = _map.size.x * 0.5
	# 左肺门：主支气管刚插进左叶的位置（和 LungGen 的 hilar 对齐）
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


# 三种形态各找一块开阔流明播种，彼此至少隔开 380 像素
func _spawn_wave() -> void:
	_spawn_pts.clear()
	for attempt in range(80):
		if _spawn_pts.size() >= 3:
			break
		var cand: Vector2 = _map.random_free_point(_rng, 52.0)
		var ok := true
		for p in _spawn_pts:
			if p.distance_to(cand) < 760.0:
				ok = false
				break
		if ok:
			_spawn_pts.append(cand)

	while _spawn_pts.size() < 3:
		var fallback: Vector2 = _map.size * 0.5 + Vector2(float(_spawn_pts.size()) * 120.0, 0.0)
		_spawn_pts.append(fallback)

	# 场地面积从 4.0M 涨到 5.4M，播种量按面积再补一次
	# 面积 5.4M -> 9.6M，播种量按面积同比补
	pop.spawn_virus(KIND_BLOB, _spawn_pts[0], 160.0, 0.0, 1380, _rng.randf() * TAU)
	pop.spawn_virus(KIND_BAND, _spawn_pts[1], 290.0, 46.0, 430, _rng.randf() * TAU)
	pop.spawn_virus(KIND_CHAIN, _spawn_pts[2], 36.0, 0.0, 52, _rng.randf() * TAU)


# ============================================================ 输入

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey:
		var k := e as InputEventKey
		if not k.pressed or k.echo:
			return
		if k.keycode == KEY_SPACE:
			_place_fuse(get_global_mouse_position())
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
		_fire(pos)
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		if _blk_cd <= 0.0:
			if _place_block(pos):
				_blk_cd = Balance.BLOCK_COOLDOWN


# ============================================================ 手段

func _fire(target: Vector2) -> int:
	var d := target - player
	if d.length() < 1.0:
		d = Vector2.RIGHT
	return jet.fire(player, d)


func _place_block(target: Vector2) -> bool:
	if aura.nutrient < Balance.BLOCK_COST:
		return false
	var d := target - player
	if d.length() < 1.0:
		d = Vector2.RIGHT
	if not pop.place_block(player, d):
		return false
	aura.nutrient -= Balance.BLOCK_COST
	return true


func _place_fuse(target: Vector2) -> bool:
	if _fuse_cd > 0.0 or aura.nutrient < Balance.FUSE_COST:
		return false
	var d := target - player
	if d.length() < 1.0:
		d = Vector2.RIGHT
	var spot: Vector2 = player + d.normalized() * Balance.FUSE_OFFSET
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


# ============================================================ 移动

# 撞墙就贴着墙走：把「想走的方向」往两侧掰，逐档试探，
# 第一个走得通的当作这一帧的实际位移 —— 于是斜墙、凹角、肺泡内壁都顺滑。
const SLIDE_DEG := [0.0, 16.0, -16.0, 34.0, -34.0, 52.0, -52.0, 70.0, -70.0, 88.0, -88.0]

func _move_step(dir: Vector2, delta: float) -> void:
	if dir.length() < 0.001:
		return
	var base := dir.normalized()
	var speed := Balance.PLAYER_SPEED * delta
	for k in SLIDE_DEG:
		var d := base.rotated(deg_to_rad(k))
		var s := d * speed
		if not pop.path_blocked(player, player + s):
			player += s
			_clamp_player()
			return
		# 半步再试一次：贴墙且目标是窄口时，避免整帧位移全部作废
		if not pop.path_blocked(player, player + s * 0.5):
			player += s * 0.5
			_clamp_player()
			return
	_clamp_player()


func _clamp_player() -> void:
	var m := Balance.PLAYER_R + 6.0
	player.x = clampf(player.x, m, _map.size.x - m)
	player.y = clampf(player.y, m, _map.size.y - m)


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
	_move_step(mv, delta)

	if cam != null:
		cam.position = player
	if mini != null:
		mini.player = player
		if cam != null:
			var vs: Vector2 = get_viewport_rect().size / cam.zoom
			mini.view_rect = Rect2(cam.get_screen_center_position() - vs * 0.5, vs)
		mini.queue_redraw()

	if _blk_cd > 0.0:
		_blk_cd = maxf(0.0, _blk_cd - delta)
	if _fuse_cd > 0.0:
		_fuse_cd = maxf(0.0, _fuse_cd - delta)

	_acc += delta
	if _acc > 0.25:
		_acc = 0.25      # 失焦/卡顿回来后不要疯狂追帧
	var guard := 0
	while _acc >= STEP and guard < 8:
		_acc -= STEP
		guard += 1
		var t0 := Time.get_ticks_usec()
		pop.tick(STEP)
		jet.tick(STEP)
		aura.tick(STEP, player)
		_tick_us = Time.get_ticks_usec() - t0

	_update_hud()
	queue_redraw()


func _update_hud() -> void:
	var ratio: float = jet.ready_ratio()
	_bar.size = Vector2(240.0 * ratio, 8.0)
	_bar.color = Color(0.35, 0.92, 0.62) if ratio >= 1.0 else Color(0.85, 0.55, 0.20)
	_hud.text = "live %d  (绿 %d / 琥珀 %d / 品红 %d)   corpse %d   tick %.2f ms   冷却 %d%%" % [
		pop.live_count(),
		pop.live_by_kind(KIND_BLOB),
		pop.live_by_kind(KIND_BAND),
		pop.live_by_kind(KIND_CHAIN),
		pop.corpse_count(), float(_tick_us) / 1000.0, int(ratio * 100.0)
	]
	_hud2.text = "养分 %d   已拾 %d   命中 %d   带 %d   引信 %d   冷却 带%.1fs / 信%.1fs" % [
		aura.nutrient, aura.picked, jet.last_hit(), pop.block_count(),
		pop.fuse_count(), _blk_cd, _fuse_cd
	]
	if _map != null:
		_hud3.text = "肺 seed %d   左叶/右叶 + 中间支气管   流明 %.1f%%   墙段 %d   轮廓 %d   面 %d×%d" % [
			map_seed, _map.free_ratio * 100.0, _map.seg_a.size(), _map.loops.size(),
			int(_map.size.x), int(_map.size.y)
		]


# ============================================================ 画面

func _aclamp() -> Vector2:
	return player


func _draw() -> void:
	# 玩家（免疫单元）；地形在 OrganView 层
	draw_circle(player, Balance.PLAYER_R * 1.6, Color(0.20, 0.45, 0.95, 0.16))
	draw_circle(player, Balance.PLAYER_R, Color(0.34, 0.64, 1.0, 0.92))
	draw_arc(player, Balance.PLAYER_R, 0.0, TAU, 32, Color(0.76, 0.89, 1.0), 2.0)
	# 朝向短线：让人看得出「正前方」是哪儿（阻隔带和引信都按正前方放）
	draw_line(player, player + Vector2(0.0, -Balance.PLAYER_R - 10.0), Color(0.80, 0.92, 1.0, 0.5), 2.0)


# ============================================================ 自动验收（-- --shot）

func _shot_sequence() -> void:
	# 全图俯瞰模式：用来核对器官轮廓（-- --overview）
	if OS.get_cmdline_user_args().has("--overview"):
		cam.zoom = Vector2(1700.0 / _map.size.x, 1000.0 / _map.size.y)
		cam.position = _map.size * 0.5
		cam.reset_smoothing()
		await get_tree().create_timer(0.80).timeout
		_save("res://overview.png")
		get_tree().quit()
		return
	# 压力测试（-- --stress）：只跑模拟，量「病毒几万颗时单帧还撑不撑得住」
	if OS.get_cmdline_user_args().has("--stress"):
		var frames := 3600
		pop.prof_enabled = true
		var sum := 0.0
		var worst := 0.0
		for k in range(frames):
			var t0 := Time.get_ticks_usec()
			pop.tick(1.0 / 60.0)
			var used := float(Time.get_ticks_usec() - t0) / 1000.0
			sum += used
			worst = maxf(worst, used)
			if k % 60 == 59:
				print("[STRESS] t=%ds live=%d corpse=%d slot=%d avg=%.2fms worst=%.2fms | sweep=%.2f upload=%.2f rep=%.2f(n=%d scan=%d)" % [
					(k + 1) / 60, pop.live_count(), pop.corpse_count(), pop.slot_count(), sum / 60.0, worst,
					float(pop.prof_sweep_us) / 1000.0, float(pop.prof_upload_us) / 1000.0,
					float(pop.prof_rep_us) / 1000.0, pop.prof_rep_n, pop.prof_scan_n])
				pop.prof_sweep_us = 0
				pop.prof_upload_us = 0
				pop.prof_rep_us = 0
				pop.prof_rep_n = 0
				pop.prof_scan_n = 0
				sum = 0.0
				worst = 0.0
		get_tree().quit()
		return
	# 贴墙滑行自测（-- --walk）：新逻辑 vs 旧「只走一个轴」逻辑，同样斜推 3 秒
	if OS.get_cmdline_user_args().has("--walk"):
		var p0: Vector2 = player
		var dirn := Vector2(-1.0, -1.0).normalized()
		var moved := 0.0
		var last: Vector2 = player
		for i in range(180):
			_move_step(dirn, 1.0 / 60.0)
			moved += player.distance_to(last)
			last = player
		var old_p: Vector2 = p0
		var old_path := 0.0
		var prev: Vector2 = old_p
		var step := dirn * Balance.PLAYER_SPEED * (1.0 / 60.0)
		for i in range(180):
			prev = old_p
			if not pop.path_blocked(old_p, old_p + step):
				old_p += step
			elif absf(step.x) >= absf(step.y):
				if not pop.path_blocked(old_p, old_p + Vector2(step.x, 0.0)):
					old_p += Vector2(step.x, 0.0)
			elif not pop.path_blocked(old_p, old_p + Vector2(0.0, step.y)):
				old_p += Vector2(0.0, step.y)
			old_path += old_p.distance_to(prev)
		print("[WALK] from=(%.0f,%.0f) slide_to=(%.0f,%.0f) path=%.0f | old_to=(%.0f,%.0f) path=%.0f | solid=%s" % [
			p0.x, p0.y, player.x, player.y, moved, old_p.x, old_p.y, old_path,
			str(_map.solid_point(player))])
		get_tree().quit()
		return
	await get_tree().create_timer(0.60).timeout
	# 站到第一个病毒团旁边，保证射流够得到（否则 hit 永远是 0）
	var aim := Vector2.RIGHT
	var demo := player
	if _spawn_pts.size() >= 1:
		var target: Vector2 = _spawn_pts[0]
		var behind: Vector2 = _map.nearest_free(target + Vector2(-300.0, 80.0), 260.0)
		if behind.x > 0.0:
			player = behind
			cam.position = player
			cam.reset_smoothing()
			aim = (target - player).normalized()
	# 相机跟随之后，固定坐标的老病毒团可能已经在射程外 —— 正前方补一团做验收
	demo = player + aim * 360.0
	if not _map.solid_point(demo):
		pop.spawn_virus(KIND_BLOB, demo, 78.0, 0.0, 150, 0.0)
	await get_tree().create_timer(0.60).timeout
	# 第一发：路上没有阻隔带，扇形一直到肉壁为止（验证「被胸膜截断」）
	_fire(demo)
	await get_tree().create_timer(0.05).timeout
	_save("res://jet_shot.png")
	await get_tree().create_timer(0.55).timeout
	_fire(demo)
	await get_tree().create_timer(0.85).timeout
	_save("res://main_shot_a.png")
	# 第二发：正前方铺一条阻隔带，射流必须停在带子上（验证「带子挡射线」）
	_place_block(demo)
	await get_tree().create_timer(0.60).timeout
	_fire(demo)
	await get_tree().create_timer(0.05).timeout
	_save("res://jet_band.png")
	# 引信丢到正前方那团病毒里（能吸链、能清盘/带）
	var fuse_spot: Vector2 = player + aim * 270.0
	if _map.solid_point(fuse_spot):
		fuse_spot = _map.nearest_free(fuse_spot, 60.0)
	if fuse_spot.x > 0.0:
		pop.add_fuse(fuse_spot)
	await get_tree().create_timer(2.20).timeout
	_save("res://main_shot_b.png")
	get_tree().quit()


func _save(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path(path))
	print("[SHOT] ", path)
	print("[STAT] seed=%d live=%d corpse=%d nut=%d picked=%d hit=%d fuse=%d chain=%d player=(%.0f,%.0f)" % [
		map_seed, pop.live_count(), pop.corpse_count(), aura.nutrient, aura.picked,
		jet.last_hit(), pop.fuse_count(), pop.live_by_kind(KIND_CHAIN), player.x, player.y
	])
