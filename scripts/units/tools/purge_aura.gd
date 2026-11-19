extends Node2D
# 净化场（近身接触清除）+ 养分自动拾取（巨噬细胞回收）
#
# 分工：
#   净化场 = 被动、贴身、持续、量小 —— 站在病毒里也不会被瞬间淹没
#   拾取   = 射流打死的尸体躺够 1 秒后，在 PICKUP_RADIUS 内自动变成光点飞回来
#            （不用走过去，远处清出来的收益也算数）
#
# 养分是硬资源：阻隔带要花 30 才放得出来。

const PURGE_RADIUS := Balance.PURGE_RADIUS
const PURGE_PER_SEC := Balance.PURGE_PER_SEC
const PICKUP_RADIUS := Balance.PICKUP_RADIUS
const PICKUP_PER_SEC := Balance.PICKUP_PER_SEC
const MOTE_SPEED := Balance.MOTE_SPEED
const MOTE_MAX := Balance.MOTE_MAX

var nutrient := 0
var last_purge := 0
var picked := 0      # 累计拾取的尸体数（验收用）

var _acc_purge := 0.0
var _acc_pick := 0.0
var _pop = null
var _center := Vector2.ZERO
var _flash := 0.0
var _motes: Array = []


func bind(pop) -> void:
	_pop = pop


func tick(dt: float, center: Vector2) -> void:
	_center = center
	if _pop == null:
		return

	# 1) 近身消融
	_acc_purge += dt * PURGE_PER_SEC
	var n := int(_acc_purge)
	if n > 0:
		_acc_purge -= float(n)
		last_purge = _pop.purge_circle(center, PURGE_RADIUS, n)
		if last_purge > 0:
			_flash = 0.12

	# 2) 自动拾取：把范围内的老尸体变成光点
	#    关键：先算「还能带几个」，再决定吃几个 ——
	#    否则尸体已经被从池里删掉、光点却因为满员没生成，养分就被吞掉了
	_acc_pick += dt * PICKUP_PER_SEC
	if _acc_pick > float(MOTE_MAX):
		_acc_pick = float(MOTE_MAX)   # 不攒超过一次能带走的量
	var m := int(_acc_pick)
	var room := MOTE_MAX - _motes.size()
	if room > 0 and m > 0:
		if m > room:
			m = room
		var spots: Array = _pop.take_corpse_near(center, PICKUP_RADIUS, m)
		_acc_pick -= float(spots.size())
		picked += spots.size()
		for s in spots:
			_motes.append(s)

	# 3) 光点飞向单元，到了入账
	var keep: Array = []
	for mote in _motes:
		var p: Vector2 = mote
		var d := center - p
		var l := d.length()
		if l < 16.0:
			nutrient += Balance.NUTRIENT_PER_CORPSE
			continue
		keep.append(p + d / l * MOTE_SPEED * dt)
	_motes = keep

	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt)
	queue_redraw()


func _draw() -> void:
	var a := 1.0 if _flash > 0.0 else 0.0
	draw_circle(_center, PURGE_RADIUS, Color(0.30, 0.80, 0.95, 0.05 + 0.06 * a))
	draw_arc(_center, PURGE_RADIUS, 0.0, TAU, 64, Color(0.42, 0.88, 1.0, 0.35 + 0.35 * a), 2.0)
	# 拾取范围：白色细环（养分是白色，别再用金色，否则和病毒撞色）
	draw_arc(_center, PICKUP_RADIUS, 0.0, TAU, 96, Color(1.0, 1.0, 1.0, 0.10), 1.0)
	for mote in _motes:
		var p: Vector2 = mote
		draw_circle(p, 3.2, Color(1.0, 1.0, 1.0, 0.95))
		draw_circle(p, 6.0, Color(1.0, 1.0, 1.0, 0.12))
