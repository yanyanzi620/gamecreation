extends Node2D
# M5 战斗道具：阻断带（任务卡 M1-T1 v1.2 的 C1 交付）
#
# 契约：
#   §5.2 place(from, facing) -> int / active_blocks() -> Array / count() / tick(dt)
#   §5.3 BlockProvider.active_blocks()（SpreadSystem 只读调用）
#
# 设计要点：
#   · 墙是"玩家面前的横墙"，不是吸附到病毒的带子
#   · 起效那一 tick 做一次性双态判定（soft/hard），结果写进 per_field，之后绝不重算
#   · 拦病毒不拦血：不碰 O₂ / Tox / 缺血债 / 隔离
#
# 数值全部来自 data/blocks.json，本文件零平衡数值（除视觉常量与浮点容差）。

const LIFE_EPS := 1e-4        # 浮点累加容差：30.0 秒除以 1/60 会剩 ~3e-15
const SIDE_EPS := 1e-3        # side≈0（墙正好穿过场心）→ 按 soft 处理（§4.1.1 边界表）
const ALIVE_EPS := 1e-9

const VIS_DASH := 12.0
const VIS_GAP := 8.0
const VIS_W_ARMING := 3.0
const VIS_W_ARMED := 4.0
const VIS_CAP := 12.0
const COL_ARMING := Color(0.95, 0.85, 0.35, 0.55)
const COL_ARMED := Color(0.95, 0.85, 0.35, 1.0)

var _blocks: Array = []
var _uid := 0
var _clock := 0.0
var _spread = null
var _cfg: Dictionary = {}
var _arena := Vector2(2400.0, 1500.0)
var _cfg_ready := false


# ============================================================ 配置

func _ensure_cfg() -> void:
	if _cfg_ready:
		return
	_cfg_ready = true
	var path := "res://data/blocks.json"
	if not FileAccess.file_exists(path):
		push_warning("BlockSystem: missing " + path)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("BlockSystem: bad JSON " + path)
		return
	var sec = parsed.get("block_band", {})
	_cfg = sec if typeof(sec) == TYPE_DICTIONARY else {}
	var ar = parsed.get("arena", {})
	if typeof(ar) == TYPE_DICTIONARY:
		_arena = Vector2(float(ar.get("width", 2400.0)), float(ar.get("height", 1500.0)))


func _v(key: String, fallback):
	return _cfg.get(key, fallback)


# ============================================================ 放置

func attach_spread(sp) -> void:
	_spread = sp


# 纯公式（不落库、不夹紧）：A4 与 UI 预览都读这里，保证几何口径唯一
func wall_geometry(from: Vector2, facing: Vector2) -> Dictionary:
	_ensure_cfg()
	var fdir := facing.normalized()
	if fdir == Vector2.ZERO:
		fdir = Vector2.RIGHT
	var center: Vector2 = from + fdir * float(_v("place_distance", 120.0))
	var dw_dir := Vector2(-fdir.y, fdir.x).normalized()
	var half := float(_v("length", 260.0)) * 0.5
	return {
		"center": center,
		"a": center - dw_dir * half,
		"b": center + dw_dir * half,
		"normal": -fdir,
	}


func place(from: Vector2, facing: Vector2) -> int:
	_ensure_cfg()
	if _blocks.size() >= int(_v("max_concurrent", 2)):
		print("[BLOCK] reject: limit %d" % int(_v("max_concurrent", 2)))
		return -1
	var geo := wall_geometry(from, facing)
	var seg := _clamp_segment(geo["a"], geo["b"])
	var a: Vector2 = seg[0]
	var b: Vector2 = seg[1]
	# 平移夹紧后带心跟着走，center 与端点保持同一几何
	return _add(a, b, (a + b) * 0.5, geo["normal"])


# 场景/自测注入入口：直接给终点几何，不做竞技场夹紧。
# 正式流程只走 place(from, facing)。
func place_at(center: Vector2, wall_dir: Vector2, wall_len: float, normal: Vector2) -> int:
	_ensure_cfg()
	if _blocks.size() >= int(_v("max_concurrent", 2)):
		print("[BLOCK] reject: limit %d" % int(_v("max_concurrent", 2)))
		return -1
	var dw_dir := wall_dir.normalized()
	var half := float(wall_len) * 0.5
	return _add(center - dw_dir * half, center + dw_dir * half, center, normal.normalized())


func _add(a: Vector2, b: Vector2, center: Vector2, normal: Vector2) -> int:
	_uid += 1
	var arm := float(_v("arm_seconds", 2.0))
	var life := float(_v("life_seconds", 30.0))
	_blocks.append({
		"uid": _uid,
		"a": a,
		"b": b,
		"center": center,
		"normal": normal,
		"arming": arm,
		"life": life,
		"mode": "arming",
		"per_field": {},
	})
	EventBus.band_placed.emit(_uid, a, b, _clock + life)
	_redraw()
	return _uid


func _clamp_segment(a: Vector2, b: Vector2) -> Array:
	var mn := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var mx := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	var sh := Vector2.ZERO
	if mn.x < 0.0:
		sh.x = -mn.x
	if mx.x + sh.x > _arena.x:
		sh.x = _arena.x - mx.x
	if mn.y < 0.0:
		sh.y = -mn.y
	if mx.y + sh.y > _arena.y:
		sh.y = _arena.y - mx.y
	return [a + sh, b + sh]


# ============================================================ 对外只读

func count() -> int:
	return _blocks.size()


func active_blocks() -> Array:
	var out := []
	for blk in _blocks:
		out.append({
			"uid": blk["uid"],
			"a": blk["a"],
			"b": blk["b"],
			"center": blk["center"],
			"normal": blk["normal"],
			"mode": blk["mode"],
			"arming": blk["arming"],
			"life": blk["life"],
			"per_field": blk["per_field"],   # 只读引用：M1 用来自查 soft/hard
		})
	return out


func clear() -> void:
	_blocks.clear()
	_redraw()


# ============================================================ tick（由 SpreadSystem.step 转发）

func tick(dt: float) -> void:
	_ensure_cfg()
	_clock += dt
	var alive := []
	for blk in _blocks:
		var arm := float(blk["arming"])
		if arm > 0.0:
			arm = maxf(0.0, arm - dt)
			blk["arming"] = arm
			if arm <= LIFE_EPS and blk["mode"] == "arming":
				_judge(blk)
				blk["mode"] = "armed"
		else:
			_judge(blk)                       # 只补判"之后出现的场"，已有结果不重算
		blk["life"] = float(blk["life"]) - dt
		if float(blk["life"]) > LIFE_EPS:
			alive.append(blk)
	_blocks = alive
	_redraw()


# §4.1.1 双态判定：一次性写入 per_field，永不重算
func _judge(blk: Dictionary) -> void:
	if _spread == null or not _spread.has_method("virus_fields"):
		return
	var pf: Dictionary = blk["per_field"]
	var nrm: Vector2 = blk["normal"]
	var c: Vector2 = blk["center"]
	for f in _spread.virus_fields():
		var fid: int = f["id"]
		if pf.has(fid):
			continue
		var front: Vector2 = f["head"] if f["kind"] == "band" else f["pos"]
		var side: float = (front - c).dot(nrm)
		# side > 0：已经在你背后 → soft；side ≤ 0：还在你面前 → hard
		# 特例：side≈0（墙正好穿过场心）按边界表判 soft
		pf[fid] = "soft" if (side > 0.0 or absf(side) <= SIDE_EPS) else "hard"


# ============================================================ 绘制（只读状态）

func _redraw() -> void:
	if is_inside_tree():
		queue_redraw()


func _draw() -> void:
	for blk in _blocks:
		var a: Vector2 = blk["a"]
		var b: Vector2 = blk["b"]
		var arm := float(blk["arming"])
		if blk["mode"] == "arming":
			var blink := float(_v("blink_hz", 4.0))
			var arm_total := maxf(ALIVE_EPS, float(_v("arm_seconds", 2.0)))
			var ph := fmod((arm_total - arm) * blink, 1.0)
			var pulse := 0.25 + 0.75 * (0.5 + 0.5 * sin(ph * TAU))
			var col := COL_ARMING
			col.a = COL_ARMING.a * pulse
			_draw_dashed(a, b, col)
		else:
			draw_line(a, b, COL_ARMED, VIS_W_ARMED)
			var u := (b - a).normalized()
			var nrm := u.orthogonal().normalized()
			draw_line(a - nrm * VIS_CAP, a + nrm * VIS_CAP, COL_ARMED, VIS_W_ARMED)
			draw_line(b - nrm * VIS_CAP, b + nrm * VIS_CAP, COL_ARMED, VIS_W_ARMED)


func _draw_dashed(a: Vector2, b: Vector2, col: Color) -> void:
	var d := b - a
	var total := d.length()
	if total < 0.01:
		return
	var u := d / total
	var pos := 0.0
	while pos < total:
		var seg := minf(VIS_DASH, total - pos)
		draw_line(a + u * pos, a + u * (pos + seg), col, VIS_W_ARMING)
		pos += VIS_DASH + VIS_GAP
