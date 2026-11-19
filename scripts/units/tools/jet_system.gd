extends Node2D
# 射流：左键点一次 = 一发扇形清除（固定长度 / 固定角度 / 冷却）
# 单次扳机：按住不放不会连发；只有冷却归零后新的按下才生效。

const LENGTH := 320.0
const HALF_ANGLE_DEG := 16.0
const COOLDOWN := 0.50
const VIS_SEC := 0.30
const ARC_STEPS := 18

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

	var pts := PackedVector2Array()
	pts.append(_from)
	for k in range(ARC_STEPS + 1):
		var ang := -half + (2.0 * half) * float(k) / float(ARC_STEPS)
		pts.append(_from + _dir.rotated(ang) * LENGTH)
	draw_colored_polygon(pts, Color(0.42, 0.94, 1.0, 0.20 * a))

	var e0 := _from + _dir.rotated(-half) * LENGTH
	var e1 := _from + _dir.rotated(half) * LENGTH
	draw_line(_from, e0, Color(0.55, 1.0, 1.0, 0.55 * a), 2.0)
	draw_line(_from, e1, Color(0.55, 1.0, 1.0, 0.55 * a), 2.0)
	var base := _dir.angle()
	draw_arc(_from, LENGTH, base - half, base + half, ARC_STEPS,
		Color(0.55, 1.0, 1.0, 0.45 * a), 2.0)
