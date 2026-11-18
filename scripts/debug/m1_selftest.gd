extends Node
# M1 自测（任务卡 M1-T1 v1.2 §8）：headless 直驱 step()，不经酶系统
#   & <godot_console> --headless --path E:\gamecreation res://scenes/debug/m1_selftest.tscn
#   退出码 0 = 全 PASS

const STEP := 1.0 / 60.0
const PRADIUS := 250.0
const RATE := 45.0
const FAR := Vector2(-9999.0, -9999.0)

var spread: Node
var block: Node
var fails := 0
var total := 0


func _ready() -> void:
	RNG.reset(12345)                     # 同 seed 连跑两次必须逐字节一致
	spread = load("res://scripts/world/spread_system.gd").new()
	block = load("res://scripts/units/tools/block_system.gd").new()
	spread._ensure_cfg()
	block._ensure_cfg()
	spread.clear()                       # 去掉 greybox_demo 的演示带
	spread.attach_blocks(block)

	_a1()
	_a2()
	_a3()
	_a4()
	_a5()
	_a6()
	_a7()
	_a8()
	_a9()
	_det()

	print("--------------------------------------------------------------")
	if fails == 0:
		print("M1 SELFTEST: %d/%d PASS" % [total, total])
	else:
		print("M1 SELFTEST: %d/%d PASS, %d FAIL" % [total - fails, total, fails])
	block.free()
	spread.free()
	get_tree().quit(0 if fails == 0 else 1)


# ============================================================ 断言脚手架

func _check(id: String, title: String, passed: bool, expected: float, actual: float, tol: float, note: String) -> void:
	total += 1
	if not passed:
		fails += 1
	print("%-3s | %-12s | %-4s | expect=%9.3f actual=%9.3f tol=%6.3f | %s" % [
		id, title, "PASS" if passed else "FAIL", expected, actual, tol, note])


func _info(id: String, title: String, note: String) -> void:
	print("%-3s | %-12s | INFO | %s" % [id, title, note])


func _only_band() -> Dictionary:
	for f in spread.fields:
		if f["kind"] == "band":
			return f
	return {}


func _spawn_only_band(pos: Vector2, dir: Vector2) -> Dictionary:
	spread.spawn_band(pos, dir)
	return spread.fields[spread.fields.size() - 1]


func _has_block(uid: int) -> bool:
	for w in block.active_blocks():
		if int(w["uid"]) == uid:
			return true
	return false


func _spawn_only_sphere(pos: Vector2, r: float, grow: float) -> Dictionary:
	spread.spawn(pos, r, grow)
	return spread.fields[spread.fields.size() - 1]


# ============================================================ A1 阻断带硬度

func _a1() -> void:
	spread.clear()
	var origin := Vector2(700.0, 500.0)
	var bdir := Vector2(-1.0, 0.0)
	var f = _spawn_only_band(origin, bdir)
	# 墙在带的前方 150，normal 与带的前进方向相反 → 判定 side<0 = hard
	var wc: Vector2 = origin + bdir * 150.0
	block.place_at(wc, bdir.orthogonal(), 260.0, bdir)

	var nrm := bdir
	var s0: float = (f["head"] - wc).dot(nrm)
	var max_adv := 0.0
	var min_gap := 1.0e9
	var contact := -1
	var escape := -1
	for i in 600:
		spread.step(STEP, FAR, false, PRADIUS, RATE)
		var s: float = (f["head"] - wc).dot(nrm)
		max_adv = maxf(max_adv, s - s0)
		min_gap = minf(min_gap, absf(s))
		if contact < 0 and float(f["stuck"]) > 0.0:
			contact = i + 1
		elif contact > 0 and escape < 0 and absf(s) > 1.5:
			escape = i + 1

	var ok: bool = absf(max_adv - 149.0) <= 1.0 and min_gap >= 0.9
	_check("A1", "阻断带硬度", ok, 149.0, max_adv, 1.0,
		"最小法向间距 %.3f（≥1.0 = 未穿墙）；顶墙 tick=%d 解死锁 tick=%s" % [
			min_gap, contact, str(escape) if escape > 0 else "无"])


# ============================================================ A2 阻断带软度

func _a2() -> void:
	spread.clear()
	var c := Vector2(900.0, 700.0)
	var f = _spawn_only_band(c, Vector2(0.0, 1.0))
	var fid: int = int(f["id"])
	# 墙正好穿过场心（side≈0 → 边界判 soft），带沿墙线共线滑行，全程"在墙内"
	block.place_at(c, Vector2(0.0, 1.0), 260.0, Vector2(1.0, 0.0))
	block.tick(2.0)                      # 先让墙起效（否则前 2 秒完全不减速）
	f["next_turn_at"] = 1.0e9            # 测试隔离：只验乘数，转向由 A6 覆盖

	var mode: String = block.active_blocks()[0]["per_field"][fid]
	for i in 600:
		spread.step(STEP, FAR, false, PRADIUS, RATE)
	var adv: float = (f["head"] - c).dot(Vector2(0.0, 1.0))
	var ok: bool = mode == "soft" and absf(adv - 120.0) <= 1.0
	_check("A2", "阻断带软度", ok, 120.0, adv, 1.0,
		"判定=%s；末帧乘数 %.2f，600 tick 全程头端段与墙相交" % [mode, float(f["mult"])])


# ============================================================ A3 起效延迟

func _a3() -> void:
	spread.clear()
	var origin := Vector2(1000.0, 400.0)
	var f = _spawn_only_band(origin, Vector2(-1.0, 0.0))
	# 带已经越过墙 → side>0 → soft；重点是"2 秒前完全无效果"
	block.place_at(Vector2(880.0, 400.0), Vector2(0.0, 1.0), 260.0, Vector2(1.0, 0.0))

	var judged := -1.0
	var adv_119 := -1.0
	for i in 600:
		spread.step(STEP, FAR, false, PRADIUS, RATE)
		if i + 1 == 119:
			adv_119 = (f["head"] - origin).dot(Vector2(-1.0, 0.0))
		if judged < 0 and block.active_blocks()[0]["mode"] != "arming":
			judged = float(i + 1) * STEP

	var full_speed: float = 119.0 * STEP * 30.0
	var ok: bool = absf(judged - 2.0) <= STEP + 1e-6 and absf(adv_119 - full_speed) <= 0.5
	_check("A3", "起效延迟", ok, 2.0, judged, 0.017,
		"判定前 119 tick 已推进 %.3f（全速 %.3f，未被减速 = 完全无效果）" % [adv_119, full_speed])


# ============================================================ A4 垂直于朝向

func _a4() -> void:
	spread.clear()
	# 几何口径用未夹紧公式（玩家在 (0,0) 时墙端会越界，夹紧会平移整段）
	var geo: Dictionary = block.wall_geometry(Vector2.ZERO, Vector2.RIGHT)
	var ga: Vector2 = geo["a"]
	var gb: Vector2 = geo["b"]
	var gc: Vector2 = geo["center"]
	var center_err: float = gc.distance_to(Vector2(120.0, 0.0))
	var wlen: float = ga.distance_to(gb)
	var perp: float = absf((gb - ga).normalized().dot(Vector2.RIGHT))
	var ok: bool = center_err <= 0.5 and absf(wlen - 260.0) <= 0.5 and perp <= 0.02
	_check("A4", "垂直于朝向", ok, 120.0, center_err, 0.5,
		"带心误差 / 墙长 %.3f（±0.5）/ 与 facing 夹角余弦 %.4f" % [wlen, perp])

	var uid: int = block.place(Vector2.ZERO, Vector2.RIGHT)
	var clamped: Array = block.active_blocks()
	if uid > 0 and clamped.size() > 0:
		var ca: Vector2 = clamped[0]["a"]
		var cb: Vector2 = clamped[0]["b"]
		var cc: Vector2 = clamped[0]["center"]
		_info("A4", "夹紧后", "a=(%.1f,%.1f) b=(%.1f,%.1f) center=(%.1f,%.1f)（整段平移进竞技场）" % [
			ca.x, ca.y, cb.x, cb.y, cc.x, cc.y])
	block.clear()


# ============================================================ A5 上限与寿命

func _a5() -> void:
	spread.clear()
	_spawn_only_band(Vector2(600.0, 600.0), Vector2(1.0, 0.0))
	var c1: int = block.place(Vector2(600.0, 300.0), Vector2.RIGHT)
	block.place(Vector2(600.0, 900.0), Vector2.RIGHT)
	var c3: int = block.place(Vector2(600.0, 1200.0), Vector2.RIGHT)

	var gone := -1.0
	for i in 1810:
		spread.step(STEP, FAR, false, PRADIUS, RATE)
		if gone < 0 and not _has_block(c1):
			gone = float(i + 1) * STEP

	var ok: bool = c3 == -1 and gone > 0.0 and absf(gone - 30.0) <= STEP + 1e-6
	_check("A5", "上限与寿命", ok, 30.0, gone, 0.017,
		"第 3 条返回 %d；前两条 t=0 同时放置，同 tick 到期消失" % c3)


# ============================================================ A6 带状折线

func _a6() -> void:
	spread.clear()
	RNG.reset(12345)
	var f = _spawn_only_band(Vector2(500.0, 700.0), Vector2(1.0, 0.0))
	for i in 600:
		spread.step(STEP, FAR, false, PRADIUS, RATE)

	var pth: PackedVector2Array = f["path"]
	var max_ang := 0.0
	for i in range(1, pth.size() - 1):
		var a := (pth[i] - pth[i - 1]).normalized()
		var b := (pth[i + 1] - pth[i]).normalized()
		max_ang = maxf(max_ang, rad_to_deg(absf(a.angle_to(b))))

	var first := pth[0]
	var last := pth[pth.size() - 1]
	var chord := last - first
	var dev := 0.0
	if chord.length() > 1.0:
		chord = chord.normalized()
		for p in pth:
			dev = maxf(dev, absf((p - first).cross(chord)))

	var turns := int(f["turns"])
	var ok: bool = turns >= 3 and pth.size() >= 4 and max_ang <= 40.0 and dev >= 6.0
	_check("A6", "带状折线", ok, 8.0, dev, 2.0,
		"转向 %d 次 / 顶点 %d 个 / 最大相邻段夹角 %.1f° / 偏离首末连线 %.1f" % [
			turns, pth.size(), max_ang, dev])


# ============================================================ 双跑确定性（DoD，不占 A 位）

func _det_run() -> String:
	RNG.reset(12345)
	spread.clear()
	_spawn_only_band(Vector2(900.0, 700.0), Vector2(0.0, 1.0))
	block.place_at(Vector2(900.0, 820.0), Vector2(1.0, 0.0), 260.0, Vector2(0.0, 1.0))
	var out := ""
	for i in 120:
		spread.step(STEP, FAR, false, PRADIUS, RATE)
		if i % 20 == 0:
			var f = _only_band()
			out += "%.5f,%.5f,%.5f;" % [f["head"].x, f["head"].y, float(f["net"])]
	return out


func _det() -> void:
	var a := _det_run()
	var b := _det_run()
	print("DET | 双跑确定性   | %-4s | 120 tick 采样 %d 组，逐字节比对（%d 字符）" % [
		"PASS" if a == b else "FAIL", 6, a.length()])
	if a != b:
		fails += 1


# ============================================================ A7 球状绕射

func _a7() -> void:
	spread.clear()
	var f = _spawn_only_sphere(Vector2.ZERO, 40.0, 3.0)
	var fid: int = int(f["id"])
	# 卡内显式端点 a=(-130,60) b=(130,60)：墙在球心正上方，球判 hard
	block.place_at(Vector2(0.0, 60.0), Vector2(1.0, 0.0), 260.0, Vector2(0.0, 1.0))
	block.tick(2.0)
	var mode: String = block.active_blocks()[0]["per_field"][fid]

	for i in 600:
		spread.step(STEP, FAR, false, PRADIUS, RATE)

	var radii: PackedFloat32Array = f["radii"]
	var r90 := radii[12]                   # 90° = index 12，正对墙 → 压平
	var r45 := radii[6]                    # 45° = index 6，墙端外 → 自由鼓包
	var diff := r45 - r90
	var ok: bool = mode == "hard" and absf(r90 - 59.5) <= 3.0 and absf(r45 - 70.0) <= 3.0 and diff >= 8.0
	_check("A7", "球状绕射", ok, 59.5, r90, 3.0,
		"45°=%.2f（自由 70）两者差 %.2f（≥8 才算真绕射）；判定=%s" % [r45, diff, mode])


# ============================================================ A8 圆度回归

func _a8() -> void:
	spread.clear()
	RNG.reset(12345)
	var f = _spawn_only_sphere(Vector2.ZERO, 40.0, 3.0)
	for i in 600:
		spread.step(STEP, FAR, false, PRADIUS, RATE)

	var radii: PackedFloat32Array = f["radii"]
	var mn := 1.0e9
	var mx := -1.0e9
	var sum := 0.0
	for r in radii:
		mn = minf(mn, r)
		mx = maxf(mx, r)
		sum += r
	var mean := sum / float(radii.size())
	var span := mx - mn
	var ok: bool = span <= 1.4 and absf(mean - 70.0) <= 1.0
	_check("A8", "圆度回归", ok, 1.4, span, 0.0, "48 半径均值 %.3f（应为 70），极差 %.5f" % [mean, span])


# ============================================================ A9 性能

func _a9() -> void:
	spread.clear()
	for i in 8:
		spread.spawn(Vector2(300.0 + float(i) * 200.0, 300.0), 70.0, 3.0)
	for i in 4:
		spread.spawn_band(Vector2(200.0 + float(i) * 400.0, 1300.0), Vector2(1.0, 0.0))
	block.place_at(Vector2(600.0, 600.0), Vector2(1.0, 0.0), 260.0, Vector2(0.0, 1.0))
	block.place_at(Vector2(1400.0, 600.0), Vector2(1.0, 0.0), 260.0, Vector2(0.0, 1.0))
	block.tick(2.0)                       # 起效后再测：裁剪与松弛都要在负载里

	var t0 := Time.get_ticks_usec()
	for i in 200:
		spread.step(STEP, FAR, false, PRADIUS, RATE)
	var us := float(Time.get_ticks_usec() - t0) / 200.0
	_check("A9", "性能", us <= 300.0, 0.300, us / 1000.0, 0.0,
		"8 球 48 射线 × 2 墙 + 4 带，单 tick %.1f us（上限 300 us）" % us)
