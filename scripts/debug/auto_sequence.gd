extends Node
# ============================================================
# 自动验收 / 压测 / 截图 —— 只在命令行带参数时运行，绝不参与正常游戏
#
#   -- --shot        四张实拍（射流 / 尸体 / 阻隔带挡弹道 / 引信），约 27s 后自动退出
#   -- --aim         瞄准预览三连拍（阻隔带可放 / 阻隔带放不下 / 引信），并验证落位接口
#   -- --overview    全图俯瞰，核对器官轮廓与肺泡尺寸
#   -- --stress      只跑病毒模拟 3600 帧，量「几万颗时单帧还撑不撑得住」
#   -- --walk        贴墙滑行自测：新逻辑 vs 旧「只走一个轴」的 A/B 对比
#   -- --stress      只跑病毒模拟 3600 帧，量「几万颗时单帧还撑不撑得住」
#   -- --walk        贴墙滑行自测：新逻辑 vs 旧「只走一个轴」的 A/B 对比
#
# 额外开关：
#   --seed=NNN       固定地图种子（默认 Balance.DEFAULT_SEED）
#   --decor-off      关掉腔室内装饰层，出纯灰盒对比图
#
# 为什么要单独成文件：验收流程里有大量 await 与临时摆位，混在主循环里会让
# main.gd 变成「玩法 + 测试」的混合物。这里只读 host 的公开状态，不改玩法逻辑。
# ============================================================

const Virus = preload("res://scripts/world/virus_population.gd")

var host = null


func setup(h) -> void:
	host = h


func wants_run() -> bool:
	var a := OS.get_cmdline_user_args()
	return a.has("--shot") or a.has("--aim") or a.has("--overview") or a.has("--stress") or a.has("--walk") or a.has("--econ") or a.has("--wall") or a.has("--perf")


func run() -> void:
	var a := OS.get_cmdline_user_args()
	if a.has("--econ"):
		_econ()
	elif a.has("--wall"):
		_wallcheck()
	elif a.has("--aim"):
		await _aim()
	elif a.has("--overview"):
		await _overview()
	elif a.has("--stress"):
		_stress()
	elif a.has("--perf"):
		await _perf()
	elif a.has("--walk"):
		_walk()
	else:
		await _shot()


# ============================================================ 瞄准预览三连拍
# 拖拽瞄准是纯输入层的东西，命令行里没法真的拖鼠标；这里直接驱动预览层，
# 目的是用画面确认「预览看到的」和「落下去的」是同一份几何。
func _aim() -> void:
	await get_tree().create_timer(0.60).timeout
	var origin: Vector2 = host.player_unit.position
	var aim := Vector2.RIGHT
	var open_reach := 0.0
	for k in range(24):
		var ang := TAU * float(k) / 24.0
		var d := Vector2(cos(ang), sin(ang))
		var r := 0.0
		while r < 520.0 and not host._map.solid_point(origin + d * (r + 20.0)):
			r += 20.0
		if r > open_reach:
			open_reach = r
			aim = d

	# ① 阻隔带：能放（青色）—— 两端被肉壁裁短的话会看到两道黄色横杠
	var good: Vector2 = origin + aim * minf(open_reach - 40.0, 300.0)
	host.preview.set_block(origin, good, true, Balance.BLOCK_RANGE_MAX)
	await get_tree().create_timer(0.20).timeout
	_save("res://aim_block.png")

	# ② 阻隔带：养分不够（红色）—— 拖拽照旧、只是不能落位，给玩家的即时反馈
	host.preview.set_block(origin, good, false, Balance.BLOCK_RANGE_MAX)
	await get_tree().create_timer(0.20).timeout
	_save("res://aim_block_low.png")

	# ③ 引信：可放（青色双圈：内圈清场 / 外圈只吸跳跃链）
	var fuse_spot: Vector2 = origin + aim * minf(open_reach - 30.0, Balance.FUSE_RANGE_MAX)
	host.preview.set_fuse(origin, fuse_spot, true, Balance.FUSE_RANGE_MAX)
	await get_tree().create_timer(0.20).timeout
	_save("res://aim_fuse.png")
	host.preview.clear()

	# 落位接口真跑一遍（养分给够，否则第二条会被余额挡掉，测不到几何）
	host.aura.nutrient = 120
	var ok_block: bool = host.place_block_at(good)
	var ok_fuse: bool = host.place_fuse_at(fuse_spot)
	var span: Array = host.pop.block_span(0)
	var blen := float(span[2]) if span.size() >= 3 else -1.0
	print("[AIM] block=%s len=%.0f (满长 %.0f) | fuse=%s | nut=%d blocks=%d fuses=%d" % [
		str(ok_block), blen, Balance.BLOCK_LEN,
		str(ok_fuse), host.aura.nutrient, host.pop.block_count(), host.pop.fuse_count()
	])
	await get_tree().create_timer(0.90).timeout
	_save("res://aim_placed.png")
	get_tree().quit()



# ============================================================ 俯瞰
func _overview() -> void:
	host.cam.zoom = Vector2(1700.0 / host._map.size.x, 1000.0 / host._map.size.y)
	host.cam.position = host._map.size * 0.5
	host.cam.reset_smoothing()
	await get_tree().create_timer(0.80).timeout
	_save("res://overview.png")
	get_tree().quit()


# ============================================================ 贴墙命中自测
# 在「离肉壁 ≤2px」的位置人造一颗病毒，从 300px 外用射流打它。
# 这是回归项：只要射程按「墙前 12px 死区」算，这里就会掉到很低甚至 0。
func _wallcheck() -> void:
	var organ = host.pop.organ
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261120
	var spots := PackedVector2Array()
	var tries := 0
	while spots.size() < 12 and tries < 40000:
		tries += 1
		var p := Vector2(rng.randf_range(220.0, Balance.ARENA_W - 220.0),
			rng.randf_range(220.0, Balance.ARENA_H - 220.0))
		if organ.solid_point(p):
			continue
		var mind := 999.0
		for k in range(8):
			var dd := Vector2.RIGHT.rotated(float(k) * TAU / 8.0)
			var dist := 1.0
			while dist <= 40.0:
				if organ.solid_point(p + dd * dist):
					break
				dist += 1.0
			mind = minf(mind, dist)
		if mind <= 2.0:
			spots.append(p)
	var tried := 0
	var killed := 0
	var no_lane := 0
	for p in spots:
		# 找一个「站得下人、且到目标视线通畅」的发射点，模拟玩家正对着它开火
		var ok := false
		var origin := Vector2.ZERO
		var dir := Vector2.RIGHT
		for k in range(16):
			var a := float(k) * TAU / 16.0
			var o: Vector2 = p + Vector2.RIGHT.rotated(a) * 300.0
			if o.x < 80.0 or o.x > Balance.ARENA_W - 80.0 or o.y < 80.0 or o.y > Balance.ARENA_H - 80.0:
				continue
			if organ.solid_point(o):
				continue
			if not organ.line_free(o.x, o.y, p.x, p.y):
				continue
			origin = o
			dir = (p - o).normalized()
			ok = true
			break
		if not ok:
			no_lane += 1
			continue
		var idx: int = host.pop._spawn(p.x, p.y, 8.0, 0, 0, 0.0, 900001, 0.0, 0.0)
		if idx < 0:
			no_lane += 1
			continue
		tried += 1
		host.pop.clear_fan(origin, dir, Balance.JET_LENGTH, deg_to_rad(Balance.JET_HALF_ANGLE_DEG))
		if host.pop._ptype[idx] == 1:
			killed += 1
		else:
			print("[WALL] miss at %s (wall dist probe passed, origin %s)" % [p, origin])
	var pct := 100.0 * float(killed) / maxf(1.0, float(tried))
	print("[WALL] spots=%d tried=%d killed=%d no_lane=%d -> %.0f%% (目标 100%%)" % [
		spots.size(), tried, killed, no_lane, pct])
	get_tree().quit()


# ============================================================ 经济实测
# 站着朝一个方向持续开火 20 秒，看「收入（养分/秒）」和「掉落（尸体/秒）」到底多少。
# 用来给 balance.gd 的 *_COST 定标，不参与正式玩法。
func _econ() -> void:
	var seconds := 20.0
	var frame := 1.0 / 60.0
	var sub := frame / 4.0
	# 把单元挪到第一处感染源上：这里病毒最密，量出来的收支才接近实战
	if host._spawn_pts.size() > 0:
		host.player_unit.position = host._spawn_pts[0] as Vector2
	var aim_a := 0.0
	var t := 0.0
	var hits := 0
	var nut0: int = host.aura.nutrient
	var last_print := 0.0
	while t < seconds:
		# 每 0.6 秒换一个朝向（八向轮转）：不假设敌人从哪边来，只量「本地有多密」
		aim_a = floor(t / 0.6) * (TAU / 8.0)
		var aim_dir := Vector2.RIGHT.rotated(aim_a)
		var hit: int = host.jet.fire(host.player_unit.position, aim_dir)
		if hit > 0:
			hits += hit
		for i in range(4):
			host.pop.tick(sub)
			host.jet.tick(sub)
			host.aura.tick(sub, host.player_unit.position)
		t += frame
		if t - last_print >= 2.0:
			last_print = t
			print("[ECON] t=%.0fs live=%d corpse=%d nut=%d picked=%d hits=%d" % [
				t, host.pop.live_count(), host.pop.corpse_count(),
				host.aura.nutrient, host.aura.picked, hits])
	var sec_used := seconds
	print("[ECON] RESULT %.0fs  kills=%d (%.1f/s)  corpse_now=%d  nutrient=%d (+%d, %.1f/s)  picked=%d (%.1f/s)" % [
		sec_used, hits, float(hits) / sec_used, host.pop.corpse_count(),
		host.aura.nutrient, host.aura.nutrient - nut0,
		float(host.aura.nutrient - nut0) / sec_used,
		host.aura.picked, float(host.aura.picked) / sec_used])
	get_tree().quit()


# ============================================================ 实跑帧率
# 和 --stress 的分工：stress 只量「模拟一帧要几毫秒」；
# perf 走正常主循环 + 真实渲染，自动转圈开火，量的是玩家真正看到的帧率。
var _perf_on := false
var _perf_t := 0.0
var _perf_all := 0.0
var _perf_frames := 0
var _perf_wf := 0
var _perf_worst := 0.0


func _perf() -> void:
	await get_tree().create_timer(0.60).timeout
	if host._spawn_pts.size() > 0:
		host.player_unit.position = host._spawn_pts[0]
	# 额外播种：直接把战场推进高压区，不必等一分钟自然扩散
	for p in host._spawn_pts:
		for k in range(3):
			host.pop.seed_blob(p, 50.0, 260)
	_perf_on = true
	await get_tree().create_timer(40.0).timeout
	_perf_on = false
	print("[PERF] RESULT avg=%.1ffps worst=%.1fms live=%d" % [
		float(_perf_frames) / maxf(_perf_all, 0.001), _perf_worst * 1000.0, host.pop.live_count()])
	get_tree().quit()


func _process(delta: float) -> void:
	if not _perf_on:
		return
	_perf_t += delta
	_perf_all += delta
	_perf_frames += 1
	_perf_wf += 1
	_perf_worst = maxf(_perf_worst, delta)
	var aim := Vector2.RIGHT.rotated(floor(_perf_all / 0.6) * (TAU / 8.0))
	host.jet.fire(host.player_unit.position, aim)
	if _perf_t >= 2.0:
		print("[PERF] t=%.0fs fps=%.1f worst=%.1fms live=%d corpse=%d" % [
			_perf_all, float(_perf_wf) / _perf_t, _perf_worst * 1000.0,
			host.pop.live_count(), host.pop.corpse_count()])
		_perf_t = 0.0
		_perf_wf = 0
		_perf_worst = 0.0


# ============================================================ 压测
func _stress() -> void:
	var frames := 3600
	host.pop.prof_enabled = true
	var sum := 0.0
	var worst := 0.0
	for k in range(frames):
		var t0 := Time.get_ticks_usec()
		host.pop.tick(1.0 / 60.0)
		var used := float(Time.get_ticks_usec() - t0) / 1000.0
		sum += used
		worst = maxf(worst, used)
		if k % 60 == 59:
			print("[STRESS] t=%ds live=%d corpse=%d slot=%d avg=%.2fms worst=%.2fms | sweep=%.2f upload=%.2f rep=%.2f(n=%d scan=%d)" % [
				(k + 1) / 60, host.pop.live_count(), host.pop.corpse_count(), host.pop.slot_count(),
				sum / 60.0, worst,
				float(host.pop.prof_sweep_us) / 1000.0, float(host.pop.prof_upload_us) / 1000.0,
				float(host.pop.prof_rep_us) / 1000.0, host.pop.prof_rep_n, host.pop.prof_scan_n])
			host.pop.prof_sweep_us = 0
			host.pop.prof_upload_us = 0
			host.pop.prof_rep_us = 0
			host.pop.prof_rep_n = 0
			host.pop.prof_scan_n = 0
			sum = 0.0
			worst = 0.0
		if k % 600 == 599:
			# 每 10 秒全池审计一次：证明「调度没有把病毒弄丢 / 弄停」
			print("[AUDIT] %s" % [host.pop.audit()])
			print("[SCHED] %s" % [host.pop.debug_sched()])
	get_tree().quit()


# ============================================================ 贴墙滑行 A/B
func _walk() -> void:
	var pu = host.player_unit
	var p0: Vector2 = pu.position
	var dirn := Vector2(-1.0, -1.0).normalized()
	var moved := 0.0
	var last: Vector2 = pu.position
	for i in range(180):
		pu.move_input(dirn, 1.0 / 60.0)
		moved += pu.position.distance_to(last)
		last = pu.position

	# 旧逻辑：一次只走一个轴（贴着墙会卡住），用来对比
	var old_p: Vector2 = p0
	var old_path := 0.0
	var prev: Vector2 = old_p
	var step: Vector2 = dirn * Balance.PLAYER_SPEED * (1.0 / 60.0)
	for i in range(180):
		prev = old_p
		if not host.pop.path_blocked(old_p, old_p + step):
			old_p += step
		elif absf(step.x) >= absf(step.y):
			if not host.pop.path_blocked(old_p, old_p + Vector2(step.x, 0.0)):
				old_p += Vector2(step.x, 0.0)
		elif not host.pop.path_blocked(old_p, old_p + Vector2(0.0, step.y)):
			old_p += Vector2(0.0, step.y)
		old_path += old_p.distance_to(prev)
	print("[WALK] from=(%.0f,%.0f) slide_to=(%.0f,%.0f) path=%.0f | old_to=(%.0f,%.0f) path=%.0f | solid=%s" % [
		p0.x, p0.y, pu.position.x, pu.position.y, moved, old_p.x, old_p.y, old_path,
		str(host._map.solid_point(pu.position))])
	get_tree().quit()


# ============================================================ 四张实拍
func _shot() -> void:
	await get_tree().create_timer(0.60).timeout
	# 朝「最开阔的那个方向」开火：肺泡放大后正前方常常 150 就撞墙，
	# 硬写 RIGHT 会让验收永远 hit=0（那不是玩法坏了，是相机位置坏了）。
	var aim := Vector2.RIGHT
	var open_reach := 0.0
	var origin: Vector2 = host.player_unit.position
	for k in range(16):
		var ang := TAU * float(k) / 16.0
		var d := Vector2(cos(ang), sin(ang))
		var r := 0.0
		while r < 440.0 and not host._map.solid_point(origin + d * (r + 24.0)):
			r += 24.0
		if r > open_reach:
			open_reach = r
			aim = d
	# 正前方补一团做验收（这团就是射流的靶）
	var demo: Vector2 = origin + aim * minf(open_reach - 70.0, 360.0)
	if open_reach < 240.0:
		# 四周都堵：先挪到附近最开阔的位置再试一次
		var spot: Vector2 = host._map.nearest_free(origin + aim * 120.0, 300.0)
		if spot.x > 0.0:
			host.player_unit.teleport(spot)
			host.cam.position = spot
			host.cam.reset_smoothing()
			origin = spot
			demo = origin + aim * 220.0
	if not host._map.solid_point(demo):
		host.pop.spawn_virus(Virus.KIND_BLOB, demo, 70.0, 0.0, 140, 0.0)
	await get_tree().create_timer(0.60).timeout

	# 第一发：路上没有阻隔带，扇形一直到肉壁为止（验证「被胸膜截断」）
	host.fire_at(demo)
	await get_tree().create_timer(0.05).timeout
	_save("res://jet_shot.png")
	await get_tree().create_timer(0.55).timeout
	host.fire_at(demo)
	await get_tree().create_timer(0.85).timeout
	_save("res://main_shot_a.png")

	# 第二发：正前方铺一条阻隔带，射流必须停在带子上（验证「带子挡射线」）
	host.place_block_at(demo)
	await get_tree().create_timer(0.60).timeout
	host.fire_at(demo)
	await get_tree().create_timer(0.05).timeout
	_save("res://jet_band.png")

	# 引信丢到正前方那团病毒里（能吸链、能清盘/带）
	var fuse_spot: Vector2 = host.player_unit.position + aim * 270.0
	if host._map.solid_point(fuse_spot):
		fuse_spot = host._map.nearest_free(fuse_spot, 60.0)
	if fuse_spot.x > 0.0:
		host.pop.add_fuse(fuse_spot)
	await get_tree().create_timer(2.20).timeout
	_save("res://main_shot_b.png")
	get_tree().quit()


func _save(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path(path))
	print("[SHOT] ", path)
	print("[STAT] seed=%d live=%d corpse=%d nut=%d picked=%d hit=%d fuse=%d chain=%d player=(%.0f,%.0f)" % [
		host.map_seed, host.pop.live_count(), host.pop.corpse_count(),
		host.aura.nutrient, host.aura.picked, host.jet.last_hit(),
		host.pop.fuse_count(), host.pop.live_by_kind(Virus.KIND_CHAIN),
		host.player_unit.position.x, host.player_unit.position.y
	])
