extends Node2D
# M5 战斗道具：阻断带（任务卡 M1-T1 附带部分）
#
# 契约：
#   §5.2 place(a,b) -> int / active_blocks() -> Array / count() -> int
#   §5.3 BlockProvider.active_blocks()（SpreadSystem 在 tick 中只读调用）
#
# 刻意不碰：O₂ / Tox / 缺血债 / 隔离（阻断带拦病毒，不拦血）。
# 数值全部来自 data/blocks.json，本文件零魔法数值（除视觉常量）。

const VIS_DASH_LEN := 12.0
const VIS_DASH_GAP := 8.0
const VIS_WIDTH_ARMING := 3.0
const VIS_WIDTH_ARMED := 4.0
const VIS_CAP_LEN := 12.0
const LIFE_EPS := 1e-4            # 浮点累加容差：30.0 秒除以 1/60 会剩 ~3e-15
const COL_ARMING := Color(0.95, 0.85, 0.35, 0.55)
const COL_ARMED := Color(0.95, 0.85, 0.35, 1.0)

var _blocks: Array = []
var _uid := 0
var _clock := 0.0
var _spread = null
var _cfg: Dictionary = {}
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


func _v(key: String, fallback):
	return _cfg.get(key, fallback)


func default_length() -> float:
	_ensure_cfg()
	return clampf(float(_v("default_length", 120.0)),
		float(_v("min_length", 60.0)), float(_v("max_length", 300.0)))


# ============================================================ 对外 API

func count() -> int:
	return _blocks.size()


func active_blocks() -> Array:
	var out := []
	for b in _blocks:
		out.append({"a": b["a"], "b": b["b"], "arming": b["arming"], "life": b["life"]})
	return out


func clear() -> void:
	_blocks.clear()
	_redraw()


func attach_spread(sp) -> void:
	# 放置时做正交吸附需要知道「最近的带状场」；只读 spread.bands()
	_spread = sp


func place(a: Vector2, b: Vector2) -> int:
	_ensure_cfg()
	var maxc := int(_v("max_concurrent", 2))
	if _blocks.size() >= maxc:
		print("[BLOCK] reject: limit %d" % maxc)
		return -1

	var band = _nearest_band((a + b) * 0.5)
	if band == null:
		print("[BLOCK] reject: no band")
		return -1

	var raw := b - a
	if raw.length() < 1.0:
		print("[BLOCK] reject: zero length")
		return -1
	var raw_dir := raw.normalized()

	var bdir: Vector2 = band["dir"]
	var perp: Vector2 = bdir.orthogonal().normalized()

	# 2) 正交吸附：画的方向离垂线超过公差就判「没切到」
	var tol := deg_to_rad(float(_v("snap_tolerance_deg", 25.0)))
	if absf(raw_dir.dot(perp)) < cos(tol):
		print("[BLOCK] reject: not orthogonal")
		return -1

	# 3) 放置点离中心线太远 → 没切到
	var center := (a + b) * 0.5
	var pth: PackedVector2Array = band["path"]
	var off := absf((center - pth[0]).dot(perp))
	if off > float(band["width"]) * 0.5 + float(_v("hit_margin", 40.0)):
		print("[BLOCK] reject: not on band")
		return -1

	var length := clampf(raw.length(), float(_v("min_length", 60.0)), float(_v("max_length", 300.0)))
	var sgn := 1.0 if raw_dir.dot(perp) >= 0.0 else -1.0
	var u := perp * sgn * length
	var a2 := center - u * 0.5
	var b2 := center + u * 0.5

	var arm := float(_v("arm_seconds", 2.0))
	var life := float(_v("life_seconds", 30.0))
	_uid += 1
	_blocks.append({
		"uid": _uid,
		"a": a2,
		"b": b2,
		"arming": arm,
		"life": life,
		"layer_index": _blocks.size(),
	})
	EventBus.band_placed.emit(_uid, a2, b2, _clock + life)
	_redraw()
	return _uid


# ============================================================ tick（由 SpreadSystem.step 转发）

func tick(dt: float) -> void:
	_ensure_cfg()
	_clock += dt
	var alive := []
	for b in _blocks:
		b["arming"] = maxf(0.0, float(b["arming"]) - dt)
		b["life"] = float(b["life"]) - dt
		if float(b["life"]) > LIFE_EPS:
			alive.append(b)
	if alive.size() != _blocks.size():
		_blocks = alive
	_redraw()


# ============================================================ 内部

func _nearest_band(center: Vector2):
	if _spread == null or not _spread.has_method("bands"):
		return null
	var best = null
	var best_d := INF
	for band in _spread.bands():
		var pth: PackedVector2Array = band["path"]
		var bdir: Vector2 = band["dir"]
		var perp: Vector2 = bdir.orthogonal().normalized()
		var d: float = absf((center - pth[0]).dot(perp))
		if d < best_d:
			best_d = d
			best = band
	return best


func _redraw() -> void:
	if is_inside_tree():
		queue_redraw()


# ============================================================ 绘制（只读状态）

func _draw() -> void:
	for b in _blocks:
		var a: Vector2 = b["a"]
		var bb: Vector2 = b["b"]
		var arm := float(b["arming"])
		if arm > 0.0:
			# 起效中：虚线 + 1Hz 闪烁
			var ph := fmod(maxf(0.0, float(_v("arm_seconds", 2.0)) - arm), 1.0)
			var pulse := 0.35 + 0.65 * (0.5 + 0.5 * sin(ph * TAU))
			var col := COL_ARMING
			col.a = COL_ARMING.a * pulse
			_draw_dashed(a, bb, col)
		else:
			draw_line(a, bb, COL_ARMED, VIS_WIDTH_ARMED)
			var u := (bb - a).normalized()
			var nrm := u.orthogonal().normalized()
			draw_line(a - nrm * VIS_CAP_LEN, a + nrm * VIS_CAP_LEN, COL_ARMED, VIS_WIDTH_ARMED)
			draw_line(bb - nrm * VIS_CAP_LEN, bb + nrm * VIS_CAP_LEN, COL_ARMED, VIS_WIDTH_ARMED)


func _draw_dashed(a: Vector2, b: Vector2, col: Color) -> void:
	var d := b - a
	var total := d.length()
	if total < 0.01:
		return
	var u := d / total
	var pos := 0.0
	while pos < total:
		var seg := minf(VIS_DASH_LEN, total - pos)
		draw_line(a + u * pos, a + u * (pos + seg), col, VIS_WIDTH_ARMING)
		pos += VIS_DASH_LEN + VIS_DASH_GAP
