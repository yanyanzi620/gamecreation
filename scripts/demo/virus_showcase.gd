extends Node2D
# 病毒三形态 + 攻击手段 的整合验证场景
#
#   绿   圆周 BLOB  ：各向同性，不规则圆盘
#   琥珀 带状 BAND  ：主轴优先 + 缓慢折线，长成条带
#   品红 跳跃链 CHAIN：单轴强推 + 定期跳跃，长成断链
#
# 攻击：
#   左键点一次 = 一发射流（固定长/角、带冷却）
#   玩家身边常驻净化场（接触消融）
#   巨噬细胞自动回收 1 秒以上的尸体 -> 养分
#
# 命令行加 `-- --shot` 会脚本化开一枪、截图后退出（自动验收用）

const KIND_BLOB := 0
const KIND_BAND := 1
const KIND_CHAIN := 2

const STEP := 1.0 / 60.0
const SPEED := 320.0
const PLAYER_R := 22.0
const BLK_CD := 0.20
const BLK_COST := 30

var player := Vector2(900.0, 450.0)
var mouse := Vector2(1120.0, 300.0)

var pop
var jet
var aura

var _acc := 0.0
var _blk_cd := 0.0
var _hud: Label
var _hud2: Label
var _bar: ColorRect
var _hint: Label
var _shot := false
var _tick_us := 0
var _sim := 0.0
var _frames := 0


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.06, 0.08, 0.10))
	# 窗口失焦 / 长时间无输入时，引擎和系统都可能给画面降频，
	# 表现就是「画面冻住、动一下鼠标才继续」。这两行是兜底。
	OS.low_processor_usage_mode = false
	Engine.max_fps = 0
	_shot = OS.get_cmdline_user_args().has("--shot")

	pop = load("res://scripts/world/virus_population.gd").new()
	pop.name = "Virus"
	add_child(pop)

	# 圆周：半径 105，260 颗（密度略低于格容，留出生长余量）
	pop.spawn_virus(KIND_BLOB, Vector2(1120.0, 300.0), 105.0, 0.0, 220, 0.0)
	# 带状：半长 185 / 半宽 40，主轴 0.18 弧度
	pop.spawn_virus(KIND_BAND, Vector2(330.0, 210.0), 200.0, 32.0, 85, 0.08)
	# 跳跃链：4 颗珠子，珠半径 22，间距 56，主轴 -0.45
	# 跳跃链：一小撮种子点，之后靠单点传播往前散成点阵
	pop.spawn_virus(KIND_CHAIN, Vector2(230.0, 770.0), 26.0, 0.0, 10, -0.35)

	jet = load("res://scripts/units/tools/jet_system.gd").new()
	jet.name = "Jet"
	add_child(jet)
	jet.bind(pop)

	aura = load("res://scripts/units/tools/purge_aura.gd").new()
	aura.name = "Aura"
	add_child(aura)
	aura.bind(pop)
	aura.nutrient = 60          # 演示用初始养分，够放两道带

	var layer := CanvasLayer.new()
	add_child(layer)

	_hud = Label.new()
	_hud.position = Vector2(18, 12)
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_color", Color(0.86, 0.93, 0.89))
	layer.add_child(_hud)

	_bar = ColorRect.new()
	_bar.position = Vector2(18, 96)
	_bar.size = Vector2(240, 8)
	_bar.color = Color(0.35, 0.92, 0.62)
	layer.add_child(_bar)

	_hud2 = Label.new()
	_hud2.position = Vector2(18, 112)
	_hud2.add_theme_font_size_override("font_size", 14)
	_hud2.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	layer.add_child(_hud2)

	_hint = Label.new()
	_hint.position = Vector2(18, 136)
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.60, 0.68, 0.64))
	_hint.text = "WASD 移动 · 左键 = 射流(0.5s) · 右键单点 = 阻隔带（30 养分） · 拾取半径 200"
	layer.add_child(_hint)

	if _shot:
		_sequence()


func _sequence() -> void:
	# 1.2s 立阻隔带 -> 2.0s 后病毒被顶住但还在射程内 -> 3.0s 两发射流打穿
	await get_tree().create_timer(1.20).timeout
	_place_block(Vector2(1120.0, 300.0))
	await get_tree().create_timer(1.80).timeout
	_fire(Vector2(1120.0, 300.0))
	await get_tree().create_timer(0.55).timeout
	_fire(Vector2(1120.0, 300.0))
	await get_tree().create_timer(0.85).timeout
	_save("res://shot_a.png")
	await get_tree().create_timer(4.20).timeout
	_save("res://shot_b.png")
	get_tree().quit()


func _save(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var p := ProjectSettings.globalize_path(path)
	img.save_png(p)
	print("[SHOT] ", p)
	print("[STAT] sim=%.2f frames=%d live=%d corpse=%d nut=%d picked=%d hit=%d" % [
		_sim, _frames, pop.live_count(), pop.corpse_count(), aura.nutrient,
		aura.picked, jet.last_hit()
	])


func _place_block(target: Vector2) -> bool:
	if aura.nutrient < BLK_COST:
		return false
	var d := target - player
	if d.length() < 1.0:
		d = Vector2.RIGHT
	aura.nutrient -= BLK_COST
	return pop.place_block(player, d)


func _fire(target: Vector2) -> int:
	var d := target - player
	if d.length() < 1.0:
		d = Vector2.RIGHT
	return jet.fire(player, d)


# 鼠标一律走事件，按下这一下就判定：
# 轮询式检测会漏掉「按下+抬起发生在同一帧」的快速点击
func _unhandled_input(e: InputEvent) -> void:
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
				_blk_cd = BLK_CD


func _process(delta: float) -> void:
	_frames += 1
	var mv := Vector2.ZERO
	if Input.is_key_pressed(KEY_A):
		mv.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		mv.x += 1.0
	if Input.is_key_pressed(KEY_W):
		mv.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		mv.y += 1.0
	if mv.length() > 0.0:
		player += mv.normalized() * SPEED * delta

	mouse = get_global_mouse_position()

	if _blk_cd > 0.0:
		_blk_cd = maxf(0.0, _blk_cd - delta)



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
		_sim += STEP
		_tick_us = Time.get_ticks_usec() - t0
	
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
	_hud2.text = "养分 %d   已拾取 %d   射流命中 %d   阻隔带 %d(耗 %d)   下道冷却 %.2fs" % [
		aura.nutrient, aura.picked, jet.last_hit(), pop.block_count(), BLK_COST, _blk_cd
	]
	queue_redraw()


func _draw() -> void:
	var sz: Vector2 = pop.arena_size()
	draw_rect(Rect2(0.0, 0.0, sz.x, sz.y), Color(0.10, 0.13, 0.16), false, 2.0)
	draw_circle(player, PLAYER_R * 1.6, Color(0.20, 0.45, 0.95, 0.16))
	draw_circle(player, PLAYER_R, Color(0.34, 0.64, 1.0, 0.92))
	draw_arc(player, PLAYER_R, 0.0, TAU, 32, Color(0.76, 0.89, 1.0), 2.0)
