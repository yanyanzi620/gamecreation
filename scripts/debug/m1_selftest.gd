extends Node
# M1-T1 自测：无 UI、无玩家节点，直接 new 出 SpreadSystem + BlockSystem，
# 按固定 STEP 手动推进，打印 A1–A6 后退出（全 PASS → 0，否则 1）。
#
# 刻意不经过 main.gd 的酶扣减：酶 3 段只够 6 秒，撑不满 A2 的 10 秒。

const STEP := 1.0 / 60.0
const SEED := 12345
const PRADIUS := 250.0
const RATE := 45.0
const ORIGIN := Vector2(800.0, 500.0)
const PERF_US_LIMIT := 200.0

var _res: Array = []


func _ready() -> void:
	print("M1-SELFTEST seed=%d" % SEED)

	var r1: Array = _suite()
	var l1: Array = _lines(r1)
	var r2: Array = _suite()
	var l2: Array = _lines(r2)
	var identical: bool = l1 == l2

	for l in l1:
		print(l)

	var perf_us := _perf()
	var perf_ok: bool = perf_us <= PERF_US_LIMIT
	print("[%s] PERF 4band_2block      avg=%6.1fus tol=%.1fus" % [
		"PASS" if perf_ok else "FAIL", perf_us, PERF_US_LIMIT])
	print("[%s] DETERMINISM run2_identical=%s" % [
		"PASS" if identical else "FAIL", "yes" if identical else "no"])

	var passed := 0
	for c in r1:
		if c["ok"]:
			passed += 1
	print("M1-SELFTEST: %d/%d PASS" % [passed, r1.size()])

	get_tree().quit(0 if (passed == r1.size() and perf_ok and identical) else 1)


# ============================================================ 断言装配

func _suite() -> Array:
	_res = []
	_case_a1()
	_case_a2()
	_case_a3()
	_case_a4()
	_case_a5()
	_case_a6()
	return _res


func _record(id: String, name: String, expected: float, actual: float, tol: float) -> void:
	_res.append({
		"id": id,
		"name": name,
		"expected": expected,
		"actual": actual,
		"tol": tol,
		"ok": absf(actual - expected) <= tol,
	})


func _lines(r: Array) -> Array:
	var out := []
	for c in r:
		out.append("[%s] %-4s %-22s expected=%7.3f actual=%7.3f tol=%.3f" % [
			"PASS" if c["ok"] else "FAIL", c["id"], c["name"], c["expected"], c["actual"], c["tol"]])
	return out


# ============================================================ 用例

func _case_a1() -> void:
	# 放一条带，不净化不阻断，跑 600 tick
	var pr: Array = _mk()
	var sp: Node = pr[0]
	sp.spawn_band(ORIGIN, Vector2.RIGHT)
	for i in 600:
		sp.step(STEP, Vector2.ZERO, false, PRADIUS, RATE)
	var b: Dictionary = sp.bands()[0]
	var head: Vector2 = b["head"]
	var p0: Vector2 = b["path"][0]
	_record("A1", "band_advance_600t", 300.0, head.distance_to(p0), 0.5)
	_drop(pr)


func _case_a2() -> void:
	# 玩家站在 head 处按住净化 600 tick → 净位移 ≈ 0
	var pr: Array = _mk()
	var sp: Node = pr[0]
	sp.spawn_band(ORIGIN, Vector2.RIGHT)
	var eng := 0
	for i in 600:
		var b: Dictionary = sp.bands()[0]
		var head: Vector2 = b["head"]
		if sp.step(STEP, head, true, PRADIUS, RATE) > 0:
			eng += 1
	var b2: Dictionary = sp.bands()[0]
	_record("A2", "purify_equilibrium", 0.0, _advance(b2), 3.0)
	if eng != 600:
		var last: Dictionary = _res[_res.size() - 1]
		last["ok"] = false
	print("[INFO] A2 engaged_ticks=%d/600" % eng)
	_drop(pr)


func _case_a3() -> void:
	# t=0 在 head 当前位置横切放 1 条，再跑 720 tick
	var pr: Array = _mk()
	var sp: Node = pr[0]
	var bs: Node = pr[1]
	sp.spawn_band(ORIGIN, Vector2.RIGHT)
	bs.attach_spread(sp)
	sp.attach_blocks(bs)
	var b: Dictionary = sp.bands()[0]
	var dir: Vector2 = b["dir"]
	var perp: Vector2 = dir.orthogonal().normalized()
	var half: float = bs.default_length() * 0.5
	var uid: int = bs.place(ORIGIN + perp * half, ORIGIN - perp * half)
	var adv_at_2s := 0.0
	for i in 720:
		sp.step(STEP, Vector2.ZERO, false, PRADIUS, RATE)
		if i == 119:
			adv_at_2s = _advance(b)
	var total: float = _advance(b)
	print("[INFO] A3 uid=%d phase[0,2)=%.3f phase[2,12)=%.3f" % [uid, adv_at_2s, total - adv_at_2s])
	_record("A3", "block_timing", 180.0, total, 3.0)
	_drop(pr)


func _case_a4() -> void:
	# 已有 2 条时放第 3 条 → -1，count 仍 2
	var pr: Array = _mk()
	var sp: Node = pr[0]
	var bs: Node = pr[1]
	sp.spawn_band(ORIGIN, Vector2.RIGHT)
	bs.attach_spread(sp)
	sp.attach_blocks(bs)
	var perp: Vector2 = Vector2.RIGHT.orthogonal().normalized()
	var u1: int = bs.place(ORIGIN + perp * 60.0, ORIGIN - perp * 60.0)
	var u2: int = bs.place(ORIGIN + perp * 100.0, ORIGIN - perp * 100.0)
	# 第 3 条几何完全合法（长度 300 在 clamp 内），只应被数量上限拒
	var r3: int = bs.place(ORIGIN + perp * 150.0, ORIGIN - perp * 150.0)
	print("[INFO] A4 uids=%d,%d count=%d" % [u1, u2, bs.count()])
	_record("A4", "block_limit_2", -1.0, float(r3), 0.0)
	if bs.count() != 2:
		var last: Dictionary = _res[_res.size() - 1]
		last["ok"] = false
	_drop(pr)


func _case_a5() -> void:
	# 放置后跑 1800 tick，第 30 秒该条消失
	var pr: Array = _mk()
	var sp: Node = pr[0]
	var bs: Node = pr[1]
	sp.spawn_band(ORIGIN, Vector2.RIGHT)
	bs.attach_spread(sp)
	sp.attach_blocks(bs)
	var perp: Vector2 = Vector2.RIGHT.orthogonal().normalized()
	var uid: int = bs.place(ORIGIN + perp * 60.0, ORIGIN - perp * 60.0)
	var vanish := -1
	var alive_1799 := -1
	for i in 1802:
		sp.step(STEP, Vector2.ZERO, false, PRADIUS, RATE)
		if i == 1798:
			alive_1799 = bs.count()
		if vanish < 0 and bs.count() == 0:
			vanish = i + 1
	print("[INFO] A5 uid=%d alive_at_1799=%d vanished_tick=%d" % [uid, alive_1799, vanish])
	_record("A5", "block_life_1800t", 1800.0, float(vanish) if vanish >= 0 else 99999.0, 1.0)
	_drop(pr)


func _case_a6() -> void:
	# 回归：球 120 + 3×10 = 150；球旁边的阻断带对球无效
	var pr: Array = _mk()
	var sp: Node = pr[0]
	var bs: Node = pr[1]
	sp.spawn(ORIGIN, 120.0, 3.0)
	sp.spawn_band(Vector2(2000.0, 200.0), Vector2.RIGHT)
	bs.attach_spread(sp)
	sp.attach_blocks(bs)
	var b: Dictionary = sp.bands()[0]
	var dir: Vector2 = b["dir"]
	var perp: Vector2 = dir.orthogonal().normalized()
	var head: Vector2 = b["head"]
	var half: float = bs.default_length() * 0.5
	var uid: int = bs.place(head + perp * half, head - perp * half)
	for i in 600:
		sp.step(STEP, Vector2.ZERO, false, PRADIUS, RATE)
	var sf: Dictionary = sp.fields[0]
	var r: float = sf["r"]
	print("[INFO] A6 block_uid=%d sphere_r=%.3f band_len=%.3f" % [uid, r, _advance(b)])
	_record("A6", "sphere_regression", 150.0, r, 0.5)
	_drop(pr)


# ============================================================ 工具

func _mk() -> Array:
	RNG.reset(SEED)
	GameState.reset()
	var sp = load("res://scripts/world/spread_system.gd").new()
	var bs = load("res://scripts/units/tools/block_system.gd").new()
	return [sp, bs]


func _drop(pr: Array) -> void:
	for n in pr:
		if is_instance_valid(n):
			n.free()


func _advance(b: Dictionary) -> float:
	var head: Vector2 = b["head"]
	var p0: Vector2 = b["path"][0]
	var dir: Vector2 = b["dir"]
	return (head - p0).dot(dir)


func _perf() -> float:
	# 4 条带 + 2 条阻断带的单 tick 逻辑耗时
	var pr: Array = _mk()
	var sp: Node = pr[0]
	var bs: Node = pr[1]
	for i in 4:
		sp.spawn_band(Vector2(200.0, 200.0 + float(i) * 200.0), Vector2.RIGHT)
	bs.attach_spread(sp)
	sp.attach_blocks(bs)
	for i in 2:
		var b: Dictionary = sp.bands()[i]
		var dir: Vector2 = b["dir"]
		var perp: Vector2 = dir.orthogonal().normalized()
		var head: Vector2 = b["head"]
		var half: float = bs.default_length() * 0.5
		bs.place(head + perp * half, head - perp * half)

	var player := Vector2(500.0, 500.0)
	for i in 60:
		sp.step(STEP, player, false, PRADIUS, RATE)

	var n := 600
	var t0 := Time.get_ticks_usec()
	for i in n:
		sp.step(STEP, player, false, PRADIUS, RATE)
	var us := float(Time.get_ticks_usec() - t0) / float(n)
	_drop(pr)
	return us
