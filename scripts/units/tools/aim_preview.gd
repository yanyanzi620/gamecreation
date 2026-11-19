extends Node2D
# ============================================================
# 瞄准预览层 —— 只回答「松开之后会落在哪」，不做任何落位判定
#
# 为什么不写进 virus_population：
#   那里是模拟 + 渲染，加进瞄准态会让「模拟」多一份临时状态；
#   预览只读几何（几何一律问 pop.resolve_block），落位仍由 pop 负责。
#
# 几何来源必须和真正落位同源：
#   阻隔带 -> pop.resolve_block()  （含肉壁裁短、距离夹取）
#   引信   -> main 算好的最终落点（含避开肉壁），这里只画
# ============================================================

const MODE_NONE := 0
const MODE_BLOCK := 1
const MODE_FUSE := 2

var pop = null

var mode := MODE_NONE
var origin := Vector2.ZERO
var target := Vector2.ZERO
var limit := 0.0
var valid := true

var _geom: Dictionary = {}


func bind(p) -> void:
	pop = p


func clear() -> void:
	if mode == MODE_NONE:
		return
	mode = MODE_NONE
	_geom = {}
	queue_redraw()


# 阻隔带：origin = 单元，target = 拖拽到的落点（已夹在距离范围内）
func set_block(o: Vector2, t: Vector2, ok: bool, max_range: float) -> void:
	mode = MODE_BLOCK
	origin = o
	target = t
	valid = ok
	limit = max_range
	_geom = pop.resolve_block(o, t - o, o.distance_to(t)) if pop != null else {}
	queue_redraw()


# 引信：spot 是 main 算好的最终落点；spot.x < 0 表示这地方放不了
func set_fuse(o: Vector2, spot: Vector2, ok: bool, max_range: float) -> void:
	mode = MODE_FUSE
	origin = o
	target = spot if spot.x >= 0.0 else o
	valid = ok
	limit = max_range
	queue_redraw()


func _draw() -> void:
	if mode == MODE_NONE:
		return
	var base := _col()
	# 距离保单环：一眼看出最远能拖到哪
	if limit > 0.0:
		draw_arc(origin, limit, 0.0, TAU, 88, Color(base.r, base.g, base.b, 0.16), 1.5)
	_dash(origin, target, Color(base.r, base.g, base.b, 0.30), 1.5, 16.0, 11.0)
	if mode == MODE_BLOCK:
		_block_viz(base)
	elif mode == MODE_FUSE:
		_fuse_viz(base)


# 颜色 = 当前能不能放：青 = 可以，橙 = 几何放不下，红 = 养分/冷却不够
func _col() -> Color:
	if not valid:
		return Color(1.0, 0.36, 0.32)
	if mode == MODE_BLOCK and not bool(_geom.get("ok", false)):
		return Color(1.0, 0.62, 0.30)
	return Color(0.62, 0.98, 1.0)


func _block_viz(base: Color) -> void:
	if not bool(_geom.get("ok", false)):
		# 这地方塞不下：落点打叉，别让玩家以为放上了
		_cross(target, 18.0, Color(1.0, 0.36, 0.32, 0.9))
		return
	var a: Vector2 = _geom["a"]
	var b: Vector2 = _geom["b"]
	draw_line(a, b, Color(base.r, base.g, base.b, 0.16), 18.0)
	draw_line(a, b, Color(base.r, base.g, base.b, 0.85), 3.0)
	draw_circle(a, 6.0, Color(base.r, base.g, base.b, 0.95))
	draw_circle(b, 6.0, Color(base.r, base.g, base.b, 0.95))
	# 被肉壁吃掉的部分：两端画一道横杠，意思是「只能封到这儿」
	if float(_geom.get("trim", 0.0)) > 4.0:
		var dir: Vector2 = (b - a).normalized()
		var nrm: Vector2 = Vector2(-dir.y, dir.x) * 12.0
		var warn := Color(1.0, 0.86, 0.35, 0.85)
		draw_line(a - nrm, a + nrm, warn, 2.0)
		draw_line(b - nrm, b + nrm, warn, 2.0)


func _fuse_viz(base: Color) -> void:
	var c: Vector2 = target
	var pulse := 0.55 + 0.45 * absf(sin(float(Time.get_ticks_msec()) * 0.006))
	# 外圈：只吸跳跃链
	draw_arc(c, Balance.FUSE_PULL, 0.0, TAU, 64, Color(0.86, 0.42, 0.95, 0.14 + 0.16 * pulse), 1.5)
	# 内圈：真正清场的范围
	draw_circle(c, Balance.FUSE_KILL, Color(base.r, base.g, base.b, 0.10))
	draw_arc(c, Balance.FUSE_KILL, 0.0, TAU, 48, Color(base.r, base.g, base.b, 0.62), 2.5)
	draw_circle(c, 5.0, Color(base.r, base.g, base.b, 0.95))
	if not valid:
		_cross(c, 14.0, Color(1.0, 0.36, 0.32, 0.9))


func _dash(a: Vector2, b: Vector2, col: Color, w: float, on: float, off: float) -> void:
	var total := a.distance_to(b)
	if total < 1.0:
		return
	var dir: Vector2 = (b - a) / total
	var t := 0.0
	while t < total:
		var e := minf(t + on, total)
		draw_line(a + dir * t, a + dir * e, col, w)
		t = e + off


func _cross(c: Vector2, r: float, col: Color) -> void:
	draw_line(c + Vector2(-r, -r) * 0.7, c + Vector2(r, r) * 0.7, col, 2.0)
	draw_line(c + Vector2(-r, r) * 0.7, c + Vector2(r, -r) * 0.7, col, 2.0)
