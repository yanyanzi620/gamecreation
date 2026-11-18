extends Node2D
# M1 扩散系统：球状（灰盒回归分支，逻辑一字未改）+ 带状（M1-T1）
#
# 铁律：
#   · 推进只发生在 step() 内（固定 tick），_process 不碰逻辑；
#   · tick 内不调随机，抖动只用出生时取的 sd；
#   · 数值全部来自 data/pathogens.json 与 data/blocks.json。
#
# 带状 tick 顺序严格按任务卡 §4.1：scale → 相交判定 → 推进 → 折线加点 → 净化回退。

const MAX_PATH_POINTS := 200      # 任务卡 §13 风险表：顶点 > 200 必须合并共线点
const SEG_EPS := 0.5              # 线段退化为点的判定阈值（单位）

# —— 视觉常量（灰盒，非平衡数值）——
const VIS_HEAD_D := 14.0          # 头端 ⌀14
const VIS_WOBBLE_AMP := 0.07
const VIS_WOBBLE_FREQ := 0.045
const COL_BAND_FILL := Color(0.58, 0.88, 0.26, 0.22)
const COL_BAND_EDGE := Color(0.74, 1.0, 0.42, 0.85)
const COL_BAND_HEAD := Color(0.80, 1.0, 0.50, 0.9)
const COL_BAND_HEAD_BLOCKED := Color(0.55, 0.6, 0.35)
const COL_SPHERE_FILL := Color(0.58, 0.88, 0.26, 0.20)
const COL_SPHERE_EDGE := Color(0.74, 1.0, 0.42, 0.85)
const COL_SPHERE_HEAD := Color(0.80, 1.0, 0.50, 0.9)

var fields: Array = []            # 球 / 带混合，用 kind 区分
var block_system: Node = null     # BlockProvider（M5），未 attach 时 scale 恒 1.0

var _tick := 0
var _cfg_ready := false
var _band_cfg_data: Dictionary = {}
var _block_cfg_data: Dictionary = {}
var _mismatch_penalty := 1.5
var _demo_enabled := false


func _ready() -> void:
	_ensure_cfg()
	_demo_enabled = bool(_band_cfg_data.get("greybox_demo", false))
	if _demo_enabled:
		_ensure_block_system()


func _ensure_cfg() -> void:
	if _cfg_ready:
		return
	_cfg_ready = true
	var p = Config.get_value("pathogens", {})
	if typeof(p) == TYPE_DICTIONARY:
		var b = p.get("band", {})
		if typeof(b) == TYPE_DICTIONARY:
			_band_cfg_data = b
		var pen = p.get("mismatch_efficiency_penalty", 1.5)
		if typeof(pen) == TYPE_FLOAT or typeof(pen) == TYPE_INT:
			_mismatch_penalty = maxf(1.0, float(pen))
	_block_cfg_data = _load_json_section("res://data/blocks.json", "block_band")


func _load_json_section(path: String, key: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("SpreadSystem: missing " + path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SpreadSystem: bad JSON " + path)
		return {}
	var sec = parsed.get(key, {})
	return sec if typeof(sec) == TYPE_DICTIONARY else {}


# ============================================================ 对外 API

func clear() -> void:
	fields.clear()
	if block_system != null and block_system.has_method("clear"):
		block_system.clear()
	if _demo_enabled and is_inside_tree():
		_spawn_demo()          # 灰盒演示带：R 重开时跟着回来
	_redraw()


func attach_blocks(bs) -> void:
	block_system = bs
	if bs != null and bs.has_method("attach_spread"):
		bs.attach_spread(self)


# 保留兼容：原返回 void，改返回值为字段索引不影响调用方
func spawn(pos: Vector2, r: float, grow: float) -> int:
	_ensure_cfg()
	fields.append({
		"kind": "sphere",
		"pos": pos,
		"r": r,
		"grow": grow,
		"sd": RNG.spread.randi() % 1000,
	})
	_redraw()
	return fields.size() - 1


func spawn_band(origin: Vector2, dir: Vector2, width := 12.0, speed := 30.0) -> int:
	_ensure_cfg()
	var w := float(width) if float(width) > 0.0 else float(_band_cfg_data.get("width", 12.0))
	var sp := float(speed) if float(speed) > 0.0 else float(_band_cfg_data.get("grow_units_per_sec", 30.0))
	var d := dir.normalized()
	if d == Vector2.ZERO:
		d = Vector2.RIGHT
	var pts := PackedVector2Array()
	pts.append(origin)
	fields.append({
		"kind": "band",
		"path": pts,
		"head": origin,
		"dir": d,
		"width": w,
		"speed": sp,
		"scale": 1.0,
		"last_scale": 1.0,
		"consumed": 0.0,                       # 累计被净化回退掉的长度
		"adv": 0.0,                            # 累计推进长度（净长度 = adv - consumed）
		"point_spacing": float(_band_cfg_data.get("point_spacing", 40.0)),
		"sd": RNG.spread.randi() % 1000,
		"born_tick": _tick,
	})
	var idx := fields.size() - 1
	# 灰盒只有肺在感染；M1-T2 起 organ_id 作为参数传入
	EventBus.infection_spawned.emit("lung", "band", origin, w)
	_redraw()
	return idx


# 只读：调试与自测用。返回的是内部字典引用，调用方不得写入。
func bands() -> Array:
	var out := []
	for f in fields:
		if f.get("kind", "sphere") == "band":
			out.append(f)
	return out


func main_radius() -> float:
	# 语义已改为「等效感染半径」= 球状 ∑r + 带状 ∑净长度
	var total := 0.0
	for f in fields:
		if f.get("kind", "sphere") == "band":
			total += _band_net_length(f)
		else:
			total += float(f["r"])
	return total


# ============================================================ tick

func step(dt: float, player_pos: Vector2, purifying: bool, pradius: float, rate: float) -> int:
	_ensure_cfg()
	_tick += 1
	# 任务卡 §6：由 step 内部转发给 BlockSystem，省掉改 main.gd
	if block_system != null:
		block_system.tick(dt)

	var engaged := 0
	for f in fields:
		if f.get("kind", "sphere") == "band":
			if _step_band(f, dt, player_pos, purifying, pradius, rate):
				engaged += 1
		else:
			if _step_sphere(f, dt, player_pos, purifying, pradius, rate):
				engaged += 1
	_redraw()
	return engaged


func _step_sphere(f: Dictionary, dt: float, player_pos: Vector2, purifying: bool, pradius: float, rate: float) -> bool:
	# 原灰盒分支，逻辑与数值一字未改（保证 A6 回归）
	var pos: Vector2 = f["pos"]
	var r: float = f["r"]
	var dist: float = player_pos.distance_to(pos)
	if purifying and dist < pradius + r:
		var edge_gap: float = maxf(0.0, dist - r)
		var eff: float = clampf(1.0 - edge_gap / pradius, 0.25, 1.0)
		f["r"] = maxf(8.0, r - rate * eff * dt)
		return true
	f["r"] = minf(1200.0, r + float(f["grow"]) * dt)
	return false


func _step_band(f: Dictionary, dt: float, player_pos: Vector2, purifying: bool, pradius: float, rate: float) -> bool:
	var dir: Vector2 = f["dir"]
	var w := float(f["width"])
	var pth: PackedVector2Array = f["path"]
	var head: Vector2 = f["head"]

	# 1) 每 tick 重算阻断乘数
	var sc := 1.0
	if block_system != null:
		sc = _block_multiplier(pth[0], head, dir, w)
	f["scale"] = sc
	f["last_scale"] = sc

	# 3) 推进（注意：先判定后推进，避免"隔空遥控"）
	var advance := float(f["speed"]) * sc * dt
	head = head + dir * advance
	f["head"] = head
	f["adv"] = float(f["adv"]) + advance

	# 4) 折线加点，限制顶点数
	var pth2: PackedVector2Array = pth
	if pth2[pth2.size() - 1].distance_to(head) > float(f["point_spacing"]):
		pth2.append(head)
		if pth2.size() > MAX_PATH_POINTS:
			pth2 = _compact_path(pth2)
		f["path"] = pth2

	# 5) 净化回退：效率 1/1.5，正好与 30 单位/秒势均力敌
	var engaged := false
	if purifying and player_pos.distance_to(head) < pradius + w * 0.5:
		engaged = true
		var amt := (rate / _mismatch_penalty) * dt
		var nh: Vector2 = head - dir * amt
		var along: float = (nh - pth2[0]).dot(dir)
		if along < 0.0:
			nh = pth2[0]
			amt = maxf(0.0, (head - pth2[0]).dot(dir))
		f["head"] = nh
		f["consumed"] = float(f["consumed"]) + amt
	return engaged


func _compact_path(pth: PackedVector2Array) -> PackedVector2Array:
	# 带是直线，隔点保留即可（M1-T2 出现弯折后改为共线角判定）
	var out := PackedVector2Array()
	out.append(pth[0])
	var i := 2
	while i < pth.size() - 1:
		out.append(pth[i])
		i += 2
	out.append(pth[pth.size() - 1])
	return out


func _band_net_length(f: Dictionary) -> float:
	# 方向定死且不弯折，净长度 = 出生点到头端的直线距离
	var pth: PackedVector2Array = f["path"]
	return maxf(0.0, (f["head"] - pth[0]).dot(f["dir"]))


# ============================================================ 阻断判定

func _block_multiplier(p0: Vector2, head: Vector2, dir: Vector2, width: float) -> float:
	# 与「已推进出的带体」相交才生效：放在头端前方不会立刻减速，
	# 病毒必须先走到那里（预判，不隔空遥控）。命中层数按 §3 表累乘。
	var blocks: Array = block_system.active_blocks()
	var sc := 1.0
	var hits := 0
	var first := float(_block_cfg_data.get("speed_multiplier_first", 0.4))
	var layers = _block_cfg_data.get("layer_multipliers", [1.0, 0.5, 0.25])
	if typeof(layers) != TYPE_ARRAY or layers.size() == 0:
		layers = [1.0]
	for b in blocks:
		if float(b["arming"]) > 0.0:
			continue
		if _segment_hits(p0, head, b["a"], b["b"]):
			var m := first
			var li: int = hits if hits < layers.size() else layers.size() - 1
			m *= float(layers[li])
			sc *= m
			hits += 1
	return sc


func _segment_hits(p0: Vector2, p1: Vector2, a: Vector2, b: Vector2) -> bool:
	if p0.distance_to(p1) < SEG_EPS:
		return Geometry2D.get_closest_point_to_segment(p0, a, b).distance_to(p0) < SEG_EPS
	return Geometry2D.segment_intersects_segment(p0, p1, a, b) != null


# ============================================================ 灰盒演示

func _ensure_block_system() -> void:
	if block_system != null:
		return
	var bs = load("res://scripts/units/tools/block_system.gd").new()
	bs.name = "Blocks"
	bs.z_index = 2
	add_child(bs)
	attach_blocks(bs)


func _spawn_demo() -> void:
	# 灰盒演示：一条横穿场地下缘的带，避开左上角 HUD 文字区
	spawn_band(Vector2(120.0, 860.0), Vector2.RIGHT)


func _unhandled_input(event: InputEvent) -> void:
	if not (_demo_enabled and is_inside_tree()):
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if block_system == null:
		return
	match event.keycode:
		KEY_B:
			_demo_place_block()
		KEY_V:
			block_system.clear()


func _demo_place_block() -> void:
	var list: Array = bands()
	if list.is_empty():
		return
	var f: Dictionary = list[0]
	var bdir: Vector2 = f["dir"]
	var perp: Vector2 = bdir.orthogonal().normalized()
	var half := float(block_system.default_length()) * 0.5
	var h: Vector2 = f["head"]
	var uid: int = block_system.place(h + perp * half, h - perp * half)
	if uid >= 0:
		print("[BLOCK] placed uid=%d by hotkey" % uid)


# ============================================================ 绘制（只读状态）

func _redraw() -> void:
	if is_inside_tree():
		queue_redraw()


func _draw() -> void:
	for f in fields:
		if f.get("kind", "sphere") == "band":
			_draw_band(f)
		else:
			_draw_sphere(f)


func _draw_sphere(f: Dictionary) -> void:
	var pts := PackedVector2Array()
	var n := 72
	var r: float = f["r"]
	var sd: int = f["sd"]
	for i in n:
		var a := TAU * float(i) / float(n)
		var wob := 1.0 + 0.035 * sin(a * 5.0 + float(sd) * 0.37) + 0.018 * sin(a * 9.0 + 1.1)
		pts.append(f["pos"] + Vector2(cos(a), sin(a)) * r * wob)
	draw_colored_polygon(pts, COL_SPHERE_FILL)
	var closed := PackedVector2Array()
	for p in pts:
		closed.append(p)
	closed.append(pts[0])
	draw_polyline(closed, COL_SPHERE_EDGE, 3.0)
	draw_circle(f["pos"], VIS_HEAD_D, COL_SPHERE_HEAD)


func _draw_band(f: Dictionary) -> void:
	var pth: PackedVector2Array = f["path"]
	var head: Vector2 = f["head"]
	var dir: Vector2 = f["dir"]
	var w := float(f["width"])
	var sd := float(f["sd"])
	var nrm: Vector2 = dir.orthogonal().normalized()

	var spine := PackedVector2Array()
	for p in pth:
		spine.append(p)
	if pth[pth.size() - 1].distance_to(head) > 0.01:
		spine.append(head)

	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var trav := 0.0
	for i in spine.size():
		if i > 0:
			trav += spine[i - 1].distance_to(spine[i])
		var wob := VIS_WOBBLE_AMP * sin(trav * VIS_WOBBLE_FREQ + sd * 0.37)
		var hw := w * 0.5 * (1.0 + wob)
		left.append(spine[i] + nrm * hw)
		right.append(spine[i] - nrm * hw)

	if left.size() >= 2:
		var poly := PackedVector2Array()
		for p in left:
			poly.append(p)
		var k := right.size() - 1
		while k >= 0:
			poly.append(right[k])
			k -= 1
		draw_colored_polygon(poly, COL_BAND_FILL)

		var outline := PackedVector2Array()
		for p in left:
			outline.append(p)
		k = right.size() - 1
		while k >= 0:
			outline.append(right[k])
			k -= 1
		outline.append(left[0])
		draw_polyline(outline, COL_BAND_EDGE, 3.0)

	var blocked := float(f["last_scale"]) < 1.0
	var hcol := COL_BAND_HEAD_BLOCKED if blocked else COL_BAND_HEAD
	draw_circle(head, VIS_HEAD_D * 0.5, hcol)
