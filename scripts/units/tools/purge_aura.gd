extends Node2D
# 净化场（近身接触清除）+ 巨噬细胞回收（尸体换养分）
#
# 和射流分工：
#   射流  = 主动、定向、有冷却、打得远（清一条通道）
#   净化场 = 被动、贴身、持续、量小（站在病毒里也不会被立刻淹没）
#
# 回收只吃「躺了 1 秒以上」的尸体，这样射流划过的地方还能先看到疤。

const RADIUS := 108.0
const PURGE_PER_SEC := 55.0
const HARVEST_PER_SEC := 26.0
const HARVEST_RADIUS := 118.0

var nutrient := 0
var last_purge := 0
var last_harvest := 0

var _acc_purge := 0.0
var _acc_harv := 0.0
var _pop = null
var _center := Vector2.ZERO
var _flash := 0.0


func bind(pop) -> void:
	_pop = pop


func tick(dt: float, center: Vector2) -> void:
	_center = center
	if _pop == null:
		return

	_acc_purge += dt * PURGE_PER_SEC
	var n := int(_acc_purge)
	if n > 0:
		_acc_purge -= float(n)
		last_purge = _pop.purge_circle(center, RADIUS, n)
		if last_purge > 0:
			_flash = 0.12

	_acc_harv += dt * HARVEST_PER_SEC
	var m := int(_acc_harv)
	if m > 0:
		_acc_harv -= float(m)
		last_harvest = _pop.harvest_circle(center, HARVEST_RADIUS, m)
		nutrient += last_harvest

	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt)
		queue_redraw()


func _draw() -> void:
	var a := 1.0 if _flash > 0.0 else 0.0
	draw_circle(_center, RADIUS, Color(0.30, 0.80, 0.95, 0.05 + 0.06 * a))
	draw_arc(_center, RADIUS, 0.0, TAU, 64, Color(0.42, 0.88, 1.0, 0.35 + 0.35 * a), 2.0)
	draw_arc(_center, HARVEST_RADIUS, 0.0, TAU, 64, Color(0.62, 0.55, 0.95, 0.18), 1.0)
