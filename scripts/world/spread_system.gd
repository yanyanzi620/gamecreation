extends Node2D
# M1 扩散系统（任务卡 M1-T1 v1.2）
#
# 契约：
#   §3   step(dt, player_pos, purifying, purify_radius, rate) -> int（返回咬合数）
#   §5.1 spawn / spawn_band / bands / clear / main_radius / gradient_at
#
# C1：阻断带（面前筑墙）+ 带状对 soft/hard 的响应。带状此时仍是直线推进
#     （随机折线与解死锁在 C2，球状 48 射线绕射在 C3）。
#
# 禁止项自查（对应新卡 §9）：
#   1 不碰 O₂/Tox/缺血债/隔离     2 逻辑层不引用节点路径
#   3 只用 RNG.spread             4 数值只在 data/*.json
#   5 没有吸附/推挤               6 双态只判一次，不重算
#   7 净化不吃带子               8 不在 _draw/_process 里推进
#   9 不生成新病毒

const MAX_PATH_POINTS := 200
const SEG_EPS := 1e-4         # 共线/端点相交的浮点容差
const ALIVE_EPS := 1e-9
const HEAD_D := 14.0
const WOB := 0.12

const COL_SPHERE_FILL := Color(0.58, 0.88, 0.26, 0.20)
const COL_SPHERE_EDGE := Color(0.74, 1.0, 0.42, 0.85)
const COL_BAND := Color(0.58, 0.88, 0.26, 0.16)
const COL_BAND_EDGE := Color(0.74, 1.0, 0.42, 0.55)
const COL_HEAD := Color(1.0, 0.36, 0.34, 1.0)
const COL_HEAD_SLOW := Color(0.85, 0.85, 0.85, 1.0)

var fields: Array = []
var block_system = null
var _auto_blocks := true      # 进树时自建阻断带节点（main.gd 不许改）

var _next_field_id := 1
var _tick := 0
var _player_pos := Vector2.ZERO

var _cfg_ready := false
var _mismatch := 1.5
var _band: Dictionary = {}
var _sphere: Dictionary = {}
var _blocks_cfg: Dictionary = {}
var _force_turn: Dictionary = {}
var _demo := false


func _ready() -> void:
	_ensure_cfg()
	# 主场景不能改（卡 §10.1），所以阻断带由本系统自举：自建一个私有子节点
	# 并通过 §5.3 的 BlockProvider 契约接上；测试/未来 M5-T2 可用 attach_blocks 注入自己的实例
	if block_system == null and _auto_blocks:
		block_system = load("res://scripts/units/tools/block_system.gd").new()
		block_system.name = "Blocks"
		add_child(block_system)
		attach_blocks(block_system)


func _unhandled_input(event: InputEvent) -> void:
	if not _demo or block_system == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_B:
				# 灰盒演示：朝鼠标方向放一道阻断带（M5-T2 接管正式输入前用）
				var aim := get_global_mouse_position() - _player_pos
				if aim.length_squared() < 1.0:
					aim = Vector2.RIGHT
				block_system.place(_player_pos, aim)
			KEY_V:
				block_system.clear()


# ============================================================ 配置（直读 data/*.json）

func _ensure_cfg() -> void:
	if _cfg_ready:
		return
	_cfg_ready = true
	_read_json("res://data/pathogens.json")
	_read_json("res://data/blocks.json")


func _read_json(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("SpreadSystem: missing " + path)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SpreadSystem: bad JSON " + path)
		return
	if path.ends_with("pathogens.json"):
		var bs = parsed.get("band", {})
		_band = bs if typeof(bs) == TYPE_DICTIONARY else {}
		var sph = parsed.get("sphere", {})
		_sphere = sph if typeof(sph) == TYPE_DICTIONARY else {}
		_mismatch = float(parsed.get("mismatch_efficiency_penalty", 1.5))
		_demo = bool(_band.get("greybox_demo", false))
		if _demo and fields.is_empty():
			# 灰盒演示：一条可正面拦的带子（F5 手动验收用）
			spawn_band(Vector2(200.0, 900.0), Vector2(1.0, -0.08))
	else:
		_blocks_cfg = parsed
		var fb = parsed.get("band", {})
		_force_turn = fb if typeof(fb) == TYPE_DICTIONARY else {}


# ============================================================ 对外接口

func attach_blocks(bs) -> void:
	block_system = bs
	if bs != null and bs.has_method("attach_spread"):
		bs.attach_spread(self)


func virus_fields() -> Array:
	# BlockSystem 做一次性双态判定时读（只读引用）
	return fields


func spawn(pos: Vector2, r: float, grow: float) -> int:
	_ensure_cfg()
	_next_field_id += 1
	fields.append({
		"id": _next_field_id,
		"kind": "sphere",
		"pos": pos,
		"r": r,
		"grow": grow,
		"sd": RNG.spread.randi() % 1000,
	})
	_redraw()
	return _next_field_id


# width / speed 传 <0 表示取 data/pathogens.json（禁止项 5：数值不许写死在 .gd）
func spawn_band(pos: Vector2, dir: Vector2, width := -1.0, speed := -1.0) -> int:
	_ensure_cfg()
	_next_field_id += 1
	var d := dir.normalized()
	if d == Vector2.ZERO:
		d = Vector2.RIGHT
	var pth := PackedVector2Array()
	pth.append(pos)
	var w := float(width) if float(width) > 0.0 else float(_band.get("width", 12.0))
	var sp := float(speed) if float(speed) > 0.0 else float(_band.get("grow_units_per_sec", 30.0))
	fields.append({
		"id": _next_field_id,
		"kind": "band",
		"path": pth,
		"head": pos,
		"dir": d,
		"width": w,
		"speed": sp,
		"travel": 0.0,
		"next_turn_at": float(_band.get("turn_interval", 90.0)),
		"stuck": 0.0,
		"mult": 1.0,
		"consumed": 0.0,
		"peak": 0.0,
		"net": 0.0,
		"turns": 0,
		"sd": RNG.spread.randi() % 1000,
	})
	_redraw()
	return _next_field_id


func bands() -> Array:
	var out := []
	for f in fields:
		if f["kind"] == "band":
			out.append({
				"id": f["id"],
				"path": f["path"],
				"head": f["head"],
				"dir": f["dir"],
				"width": f["width"],
			})
	return out


func clear() -> void:
	fields.clear()
	if block_system != null:
		block_system.clear()
	_redraw()


func main_radius() -> float:
	var total := 0.0
	for f in fields:
		if f["kind"] == "sphere":
			total += float(f["r"])
		else:
			total += float(f["net"])
	return total


func gradient_at(pos: Vector2) -> float:
	var best := 0.0
	for f in fields:
		var r := 0.0
		var d := 0.0
		if f["kind"] == "sphere":
			r = float(f["r"])
			d = pos.distance_to(f["pos"])
		else:
			r = float(f["width"])
			d = pos.distance_to(f["head"])
		if r <= 0.0 or d >= r:
			return 1.0
		best = maxf(best, 1.0 - d / r)
	return best


# ============================================================ tick

func step(dt: float, player_pos: Vector2, purifying: bool, pradius: float, rate: float) -> int:
	_ensure_cfg()
	_tick += 1
	_player_pos = player_pos

	# §6 顺序：0 墙 → 1 球 → 2 带 → 3 汇总
	var walls: Array = []
	if block_system != null:
		block_system.tick(dt)
		walls = block_system.active_blocks()

	var engaged := 0
	for f in fields:
		if f["kind"] == "sphere":
			if _step_sphere(f, dt, player_pos, purifying, pradius, rate):
				engaged += 1
	for f in fields:
		if f["kind"] != "band":
			continue
		if _step_band(f, dt, walls, player_pos, purifying, pradius, rate):
			engaged += 1

	var alive := []
	for f in fields:
		if f["kind"] == "band" or float(f["r"]) > ALIVE_EPS:
			alive.append(f)
	fields = alive
	_redraw()
	return engaged


# ------------------------------------------------------------ 球状（C1：单半径；C3 换 48 射线）

func _step_sphere(f: Dictionary, dt: float, player_pos: Vector2, purifying: bool, pradius: float, rate: float) -> bool:
	var r := float(f["r"]) + float(f["grow"]) * dt
	f["r"] = r
	if r <= 0.0:
		return false
	var pos: Vector2 = f["pos"]
	if not purifying:
		return false
	var d := pos.distance_to(player_pos)
	if d >= pradius + r:
		return false
	var eff := clampf(1.0 - d / (pradius + r), 0.0, 1.0)
	var cut := rate * eff
	if d >= r:
		# 只压边界：净化不能靠穿场实现
		f["r"] = maxf(0.0, r - cut * dt)
	else:
		var delta := clampf(cut - r / dt, 0.0, r / dt)
		f["r"] = maxf(0.0, r - delta * dt)
	return true


# ------------------------------------------------------------ 带状

func _step_band(f: Dictionary, dt: float, walls: Array, player_pos: Vector2, purifying: bool, pradius: float, rate: float) -> bool:
	var dir: Vector2 = f["dir"]
	var width := float(f["width"])
	var head: Vector2 = f["head"]

	# 1 速度乘数：仅对本场 mode=soft 且与头端段相交的墙，按层数依次乘 0.4 / 0.5 / 0.25
	var mult := 1.0
	var layer := 0
	for wall in walls:
		if _field_mode(wall, f["id"]) == "soft" and _seg_hits(head, head - dir * width, wall["a"], wall["b"]):
			mult *= _layer_mult(layer)
			layer += 1
	f["mult"] = mult

	# 2 期望位移（travel 只做转向节拍，不参与 I 值）
	var delta: Vector2 = dir * float(f["speed"]) * mult * dt
	f["travel"] = float(f["travel"]) + delta.length()

	# 3 硬墙校验：不允许越墙，停在墙前 hard_stop_margin
	var nh := _hard_block(head, delta, walls, f["id"])
	var blocked := nh.distance_squared_to(head + delta) > ALIVE_EPS
	f["head"] = nh
	f["stuck"] = (float(f["stuck"]) + dt) if blocked else 0.0
	head = nh

	# 4 转向节拍：累计推进够 90 就抖一次（随机只出现在这一步和下一步）
	if float(f["travel"]) >= float(f["next_turn_at"]):
		_turn(f, false)
		f["next_turn_at"] = float(f["next_turn_at"]) + float(_band.get("turn_interval", 90.0))

	# 5 解死锁：顶墙太久就强行拐 60~90° 走开，避免病毒被墙+边界夹死
	if float(f["stuck"]) >= float(_force_turn.get("stuck_timeout", 1.5)):
		_turn(f, true)
		f["stuck"] = 0.0

	# 6 净化回退：head -= dir*(rate/1.5)*dt，不得退过 path[0]
	var engaged := false
	if purifying and head.distance_to(player_pos) <= pradius + width:
		engaged = true
		var nh2 := head - dir * float(rate) / _mismatch * dt
		var base: Vector2 = (f["path"] as PackedVector2Array)[0]
		if (nh2 - base).dot(dir) >= 0.0:
			f["head"] = nh2
			head = nh2

	# 7 折线维护（顶点间距 ≥ point_spacing，个数封顶）
	var pth: PackedVector2Array = f["path"]
	if head.distance_to(pth[pth.size() - 1]) > float(_band.get("point_spacing", 40.0)):
		pth.append(head)
		if pth.size() > MAX_PATH_POINTS:
			pth = _compact(pth)
		f["path"] = pth

	var ln := _band_len(f)
	f["peak"] = maxf(float(f["peak"]), ln)
	f["net"] = ln
	f["consumed"] = float(f["peak"]) - ln
	return engaged


# 转向：force=false 走"每 90 单位抖 ±25°，绝对值 ≤40°"；force=true 走"60~90° 解死锁"
func _turn(f: Dictionary, force: bool) -> void:
	var deg := 0.0
	if force:
		var lo := float(_force_turn.get("force_turn_min_deg", 60.0))
		var hi := float(_force_turn.get("force_turn_max_deg", 90.0))
		deg = RNG.spread.randf_range(lo, hi)
		if RNG.spread.randf() < 0.5:
			deg = -deg
	else:
		var jit := float(_band.get("turn_jitter_deg", 25.0))
		var mx := float(_band.get("max_turn_deg", 40.0))
		deg = clampf(RNG.spread.randf_range(-jit, jit), -mx, mx)
	var cur: Vector2 = f["dir"]
	f["dir"] = cur.rotated(deg_to_rad(deg))
	f["turns"] = int(f["turns"]) + 1
	var pth: PackedVector2Array = f["path"]
	pth.append(f["head"])
	f["path"] = pth


func _field_mode(wall: Dictionary, fid: int) -> String:
	var pf: Dictionary = wall["per_field"]
	if pf.has(fid):
		return pf[fid]
	return "arming"                       # 未判定 = 完全无效


func _layer_mult(layer: int) -> float:
	var arr: Array = _blocks_cfg.get("layer_multipliers", [])
	if arr.is_empty():
		return float(_blocks_cfg.get("soft_speed_multiplier", 0.4))
	return float(arr[mini(layer, arr.size() - 1)])


# 挡住就停墙前 margin；返回新 head（没挡就是 head+delta）
func _hard_block(head: Vector2, delta: Vector2, walls: Array, fid: int) -> Vector2:
	var target := head + delta
	if delta.length_squared() <= ALIVE_EPS:
		return target
	var margin := float(_blocks_cfg.get("hard_stop_margin", 1.0))
	var best_t := 1.0
	var found := false
	for wall in walls:
		if _field_mode(wall, fid) != "hard":
			continue
		var nrm: Vector2 = wall["normal"]
		var c: Vector2 = wall["center"]
		var s0: float = (head - c).dot(nrm)
		var s1: float = (target - c).dot(nrm)
		if s0 > 0.0:
			continue                       # 已从端点绕到墙的另一侧，这道墙拦不住它
		if s1 - s0 <= ALIVE_EPS:
			continue                       # 没朝墙走
		var t := (-margin - s0) / (s1 - s0)
		if t < 0.0:
			t = 0.0
		if t > best_t:
			continue
		var p: Vector2 = head + delta * t
		var seg: Vector2 = wall["b"] - wall["a"]
		var wa: Vector2 = wall["a"]
		var u: float = (p - wa).dot(seg) / maxf(ALIVE_EPS, seg.length_squared())
		if u < 0.0 or u > 1.0:
			continue                       # 从两端绕过去
		best_t = t
		found = true
	if not found:
		return target
	return head + delta * best_t


func _band_len(f: Dictionary) -> float:
	var pth: PackedVector2Array = f["path"]
	var total := 0.0
	for i in range(1, pth.size()):
		total += pth[i - 1].distance_to(pth[i])
	if pth.size() > 0:
		total += pth[pth.size() - 1].distance_to(f["head"])
	return total


func _compact(pth: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pth.size():
		if i == 0 or i == pth.size() - 1:
			out.append(pth[i])
			continue
		var prev := out[out.size() - 1]
		var a := (pth[i] - prev).normalized()
		var b := (pth[i + 1] - pth[i]).normalized()
		if a.dot(b) < 0.999:               # 只保留折点
			out.append(pth[i])
	return out


# ============================================================ 几何

func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)


# 线段相交（含共线重叠：带子贴墙滑行时也要算"在墙里"）
func _seg_hits(p0: Vector2, p1: Vector2, a: Vector2, b: Vector2) -> bool:
	var d1 := _cross(a, b, p0)
	var d2 := _cross(a, b, p1)
	var d3 := _cross(p0, p1, a)
	var d4 := _cross(p0, p1, b)
	if ((d1 > 0.0 and d2 < 0.0) or (d1 < 0.0 and d2 > 0.0)) and ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0)):
		return true
	if absf(d1) <= SEG_EPS and _on_seg(a, b, p0):
		return true
	if absf(d2) <= SEG_EPS and _on_seg(a, b, p1):
		return true
	if absf(d3) <= SEG_EPS and _on_seg(p0, p1, a):
		return true
	if absf(d4) <= SEG_EPS and _on_seg(p0, p1, b):
		return true
	return false


func _on_seg(a: Vector2, b: Vector2, p: Vector2) -> bool:
	return (
		p.x >= minf(a.x, b.x) - SEG_EPS and p.x <= maxf(a.x, b.x) + SEG_EPS
		and p.y >= minf(a.y, b.y) - SEG_EPS and p.y <= maxf(a.y, b.y) + SEG_EPS
	)


func _wob(k: int, sd: int) -> float:
	return sin(float(k) * 1.7 + float(sd) * 0.17)


# ============================================================ 绘制（只读状态）

func _redraw() -> void:
	if is_inside_tree():
		queue_redraw()


func _draw() -> void:
	for f in fields:
		if f["kind"] == "sphere":
			_draw_sphere(f)
		else:
			_draw_band(f)


func _draw_sphere(f: Dictionary) -> void:
	var pos: Vector2 = f["pos"]
	var r := float(f["r"])
	if r <= 0.0:
		return
	var pts := PackedVector2Array()
	var n := 40
	for k in n:
		var a := TAU * float(k) / float(n)
		var rr := r * (1.0 + WOB * 0.6 * _wob(k, int(f["sd"])))
		pts.append(pos + Vector2(cos(a), sin(a)) * rr)
	draw_colored_polygon(pts, COL_SPHERE_FILL)
	pts.append(pts[0])
	draw_polyline(pts, COL_SPHERE_EDGE, 2.0)


func _draw_band(f: Dictionary) -> void:
	var pth: PackedVector2Array = f["path"]
	var pts := PackedVector2Array()
	pts.append_array(pth)
	pts.append(f["head"])
	if pts.size() < 2:
		return
	var w := float(f["width"]) * 0.5
	var sd := int(f["sd"])
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in pts.size():
		var t: Vector2
		if i == 0:
			t = (pts[1] - pts[0]).normalized()
		elif i == pts.size() - 1:
			t = (pts[i] - pts[i - 1]).normalized()
		else:
			t = (pts[i + 1] - pts[i - 1]).normalized()
		var nrm := Vector2(-t.y, t.x)
		var ww := w * (1.0 + WOB * _wob(i, sd))
		left.append(pts[i] + nrm * ww)
		right.append(pts[i] - nrm * ww)

	var poly := PackedVector2Array()
	poly.append_array(left)
	for i in range(right.size() - 1, -1, -1):
		poly.append(right[i])
	if poly.size() >= 3:
		draw_colored_polygon(poly, COL_BAND)
	draw_polyline(left, COL_BAND_EDGE, 2.0)
	draw_polyline(right, COL_BAND_EDGE, 2.0)

	var head: Vector2 = f["head"]
	var dir: Vector2 = f["dir"]
	var head_col := COL_HEAD if float(f["mult"]) >= 1.0 else COL_HEAD_SLOW
	draw_circle(head, HEAD_D, head_col)
	var tip := head + dir * (HEAD_D * 2.6)
	var side := dir.orthogonal() * (HEAD_D * 0.9)
	var tail := head + dir * (HEAD_D * 0.4)
	draw_line(tail, tip, COL_HEAD, 2.0)
	draw_line(tip, tail + side, COL_HEAD, 2.0)
	draw_line(tip, tail - side, COL_HEAD, 2.0)
