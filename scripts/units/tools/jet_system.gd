extends Node2D
# 射流：左键点一次 = 一发扇形清除（固定长度 / 固定角度 / 冷却）
# 单次扳机：按住不放不会连发；只有冷却归零后新的按下才生效。

const LENGTH := Balance.JET_LENGTH
const HALF_ANGLE_DEG := Balance.JET_HALF_ANGLE_DEG
const COOLDOWN := Balance.JET_COOLDOWN
const VIS_SEC := Balance.JET_VIS_SEC
const ARC_STEPS := Balance.JET_ARC_STEPS
const RAY_COUNT := Balance.JET_RAYS

var cooldown_left := 0.0
var _flash := 0.0
var _from := Vector2.ZERO
var _dir := Vector2.RIGHT
var _pop = null
var _last_hit := 0


func bind(pop) -> void:
	_pop = pop


func ready_ratio() -> float:
	return clampf(1.0 - cooldown_left / COOLDOWN, 0.0, 1.0)


func last_hit() -> int:
	return _last_hit


func fire(from: Vector2, dir: Vector2) -> int:
	if cooldown_left > 0.0 or _pop == null:
		return -1
	var d := dir.normalized()
	if d == Vector2.ZERO:
		d = Vector2.RIGHT
	cooldown_left = COOLDOWN
	_from = from
	_dir = d
	_flash = VIS_SEC
	_last_hit = _pop.clear_fan(_from, _dir, LENGTH, deg_to_rad(HALF_ANGLE_DEG))
	if OS.get_cmdline_user_args().has("--shot"):
		var clipped := 0
		var max_reach := 0.0
		for q in _pop.fan_shape:
			var dq: float = q.distance_to(_from)
			max_reach = maxf(max_reach, dq)
			if dq < LENGTH - 1.0:
				clipped += 1
		print("[JET] rays=%d clipped=%d max_reach=%.0f/%.0f hit=%d" % [
			_pop.fan_shape.size(), clipped, max_reach, LENGTH, _last_hit])
	queue_redraw()
	return _last_hit


func tick(dt: float) -> void:
	if cooldown_left > 0.0:
		cooldown_left = maxf(0.0, cooldown_left - dt)
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt)
		queue_redraw()


func _draw() -> void:
	if _flash <= 0.0:
		return
	var a := _flash / VIS_SEC
	var half := deg_to_rad(HALF_ANGLE_DEG)

	# 外缘用 pop 里那份「每条射线打到墙为止」的结果：打不穿墙，扇形就缺一块
	var arc := PackedVector2Array()
	if _pop != null and _pop.fan_shape.size() >= 3:
		arc = _pop.fan_shape
	else:
		for k in range(RAY_COUNT):
			var ang := -half + (2.0 * half) * float(k) / float(maxi(1, RAY_COUNT - 1))
			arc.append(_from + _dir.rotated(ang) * LENGTH)

	var pts := PackedVector2Array()
	pts.append(_from)
	for p in arc:
		pts.append(p)
	draw_colored_polygon(pts, Color(0.42, 0.94, 1.0, 0.20 * a))

	# 外缘折线（被墙削掉的地方会明显断在墙上）
	var edge := arc.duplicate()
	draw_polyline(edge, Color(0.55, 1.0, 1.0, 0.55 * a), 2.0)
	draw_line(_from, arc[0], Color(0.55, 1.0, 1.0, 0.35 * a), 1.5)
	draw_line(_from, arc[arc.size() - 1], Color(0.55, 1.0, 1.0, 0.35 * a), 1.5)
