extends Control
# ============================================================
# 整肺简图（小地图）
# ============================================================
# 场地（4300×1260）远超一屏，没有简图玩家不知道「对面那叶还剩多少」。
# 这里画六样东西，从上到下：
#   1. 顶栏数字：全场病毒数 / 尸体数 / 阻隔带条数 / 引信枚数
#   2. 器官缩略图（左叶 / 右叶 / 中间气管，一眼分清）
#   3. 病毒热力点（黄绿）与尸体疤（灰）—— 直接看感染铺到哪了
#   4. 阻隔带（青色线段）/ 引信（橙色圈）—— 自己布下的战术资产
#   5. 当前视口框（浅青）与单元光点（蓝白 + 呼吸环）
#   6. 底栏双叶负载条：左叶 / 右叶各剩多少病毒，谁是重点
# 纯 UI，不参与碰撞；数据每 0.1 秒从 virus_population 采一次，不逐帧扫描。
# ============================================================

const HEAD_H := 26.0
const FOOT_H := 30.0

var map = null                       # OrganMap
var pop = null                       # VirusPopulation
var tex: Texture2D = null
var player := Vector2.ZERO
var view_rect := Rect2()

var _snap: Dictionary = {}
var _accum := 0.0
var _pulse := 0.0
var _left := 0
var _right := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func _process(delta: float) -> void:
	_pulse += delta
	_accum += delta
	if _accum >= 0.10:                       # 10Hz 采样足够看出扩散趋势，别逐帧扫 7800 个槽
		_accum = 0.0
		_refresh()
	queue_redraw()


func _refresh() -> void:
	if pop == null:
		return
	_snap = pop.minimap_snapshot(700)
	_left = int(_snap.get("left", 0))
	_right = int(_snap.get("right", 0))


func _draw() -> void:
	if tex == null or map == null:
		return
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0.025, 0.035, 0.050, 0.90), true)

	var font := ThemeDB.fallback_font
	var mrect := Rect2(6.0, HEAD_H, size.x - 12.0, size.y - HEAD_H - FOOT_H)
	var sc: float = minf(mrect.size.x / map.size.x, mrect.size.y / map.size.y)
	var dst := Rect2(Vector2.ZERO, map.size * sc)
	dst.position = mrect.position + (mrect.size - dst.size) * 0.5
	var off := dst.position

	# ---- 缩略图（压暗一点，让上面的热点更醒目）
	draw_texture_rect(tex, dst, false, Color(0.62, 0.64, 0.72, 1.0))
	draw_rect(dst, Color(0.32, 0.22, 0.26, 0.9), false, 1.0)

	# ---- 尸体疤（灰点）
	var corpse: PackedVector2Array = _snap.get("corpse", PackedVector2Array())
	for p in corpse:
		draw_rect(Rect2(off + p * sc - Vector2(0.8, 0.8), Vector2(1.6, 1.6)),
			Color(0.62, 0.62, 0.66, 0.55))

	# ---- 病毒热力点（黄绿）
	var live: PackedVector2Array = _snap.get("live", PackedVector2Array())
	for p2 in live:
		draw_rect(Rect2(off + p2 * sc - Vector2(1.0, 1.0), Vector2(2.0, 2.0)),
			Color(0.74, 0.90, 0.34, 0.92))

	# ---- 阻隔带（青线；闪烁中的用虚线感表示）
	var blocks: Array = _snap.get("blocks", [])
	for b in blocks:
		var a: Vector2 = off + (b[0] as Vector2) * sc
		var bb: Vector2 = off + (b[1] as Vector2) * sc
		var on: bool = int(b[2]) == 1
		draw_line(a, bb, Color(0.30, 0.86, 1.0, 0.95 if on else 0.45), 2.0 if on else 1.0)

	# ---- 引信（橙圈）
	var fuses: PackedVector2Array = _snap.get("fuses", PackedVector2Array())
	for f in fuses:
		draw_arc(off + f * sc, 3.4, 0.0, TAU, 12, Color(1.0, 0.62, 0.24, 0.95), 1.4)

	# ---- 当前视口
	if view_rect.size.x > 1.0:
		var vr := Rect2(off + view_rect.position * sc, view_rect.size * sc)
		draw_rect(vr, Color(0.66, 0.90, 1.0, 0.50), false, 1.0)
		# 四个角加粗，缩小后也能一眼看到框
		var cl := minf(6.0, minf(vr.size.x, vr.size.y) * 0.25)
		var cc := Color(0.72, 0.94, 1.0, 0.95)
		draw_line(vr.position, vr.position + Vector2(cl, 0.0), cc, 1.6)
		draw_line(vr.position, vr.position + Vector2(0.0, cl), cc, 1.6)
		draw_line(Vector2(vr.end.x, vr.position.y), Vector2(vr.end.x - cl, vr.position.y), cc, 1.6)
		draw_line(Vector2(vr.end.x, vr.position.y), Vector2(vr.end.x, vr.position.y + cl), cc, 1.6)

	# ---- 玩家（蓝白光点 + 呼吸环）
	var pp := off + player * sc
	var breath := 0.5 + 0.5 * absf(sin(_pulse * 2.6))
	draw_arc(pp, 4.2 + breath * 2.4, 0.0, TAU, 16, Color(0.55, 0.82, 1.0, 0.30 + 0.45 * breath), 1.2)
	draw_circle(pp, 2.6, Color(0.86, 0.95, 1.0))

	# ---- 左 / 右叶标签（跟着器官走，不写死坐标）
	var mlab := off + Vector2(map.size.x * 0.27, map.size.y * 0.62) * sc
	var rlab := off + Vector2(map.size.x * 0.73, map.size.y * 0.62) * sc
	draw_string(font, mlab - Vector2(6.0, -4.0), "左", HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
		Color(0.70, 0.78, 0.86, 0.85))
	draw_string(font, rlab - Vector2(6.0, -4.0), "右", HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
		Color(0.70, 0.78, 0.86, 0.85))

	# ---- 顶栏
	var n_live: int = 0 if pop == null else pop.live_count()
	var n_corpse: int = 0 if pop == null else pop.corpse_count()
	var n_blk: int = 0 if pop == null else pop.block_count()
	var n_fuse: int = 0 if pop == null else pop.fuse_count()
	var head := "病毒 %d   尸体 %d   带 %d   引信 %d" % [n_live, n_corpse, n_blk, n_fuse]
	draw_string(font, Vector2(8.0, 17.0), head, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(0.82, 0.88, 0.94, 0.92))

	# ---- 底栏：两叶负载条（条长按 SOFT_CAP 换算，超过就画满）
	var base_y := size.y - FOOT_H + 4.0
	_draw_load(font, Vector2(8.0, base_y), "左", _left, Color(0.74, 0.90, 0.34), size.x - 16.0)
	_draw_load(font, Vector2(8.0, base_y + 13.0), "右", _right, Color(0.74, 0.90, 0.34), size.x - 16.0)

	draw_rect(r, Color(0.34, 0.52, 0.58, 0.70), false, 1.0)


# 单叶负载条：标签 + 数字 + 条
func _draw_load(font: Font, pos: Vector2, tag: String, val: int, col: Color, width: float) -> void:
	var soft_cap := 900.0                     # 现在单叶 900 颗就算「压满」，只用于显示比例
	var label := "%s %d" % [tag, val]
	draw_string(font, pos + Vector2(0.0, 9.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
		Color(0.78, 0.84, 0.90, 0.90))
	var bx := pos.x + 54.0
	var bw := width - 60.0
	draw_rect(Rect2(bx, pos.y + 2.0, bw, 6.0), Color(0.10, 0.13, 0.16, 0.9), true)
	var fill := clampf(float(val) / soft_cap, 0.0, 1.0)
	if fill > 0.0:
		draw_rect(Rect2(bx, pos.y + 2.0, bw * fill, 6.0), col, true)
	draw_rect(Rect2(bx, pos.y + 2.0, bw, 6.0), Color(0.30, 0.36, 0.40, 0.8), false, 1.0)
