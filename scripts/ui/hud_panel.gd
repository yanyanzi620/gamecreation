extends Control
# ============================================================
# HUD 绘制层 —— 只画，不算
#
# 口径：**状态量一律用图标 + 数字表达，不写文字标签**。
#   左上：养分 / 病毒总量 / 尸体 / 帧耗时（下面一行细分三种病毒形态）
#   左下：三个技能按钮（射流 / 阻隔带 / 引信），带冷却扇形、花费、在场数量
#
# 图标来自 assets/ui/icons/（见 assets/ui/README.md），本文件不认识文件名，
# 只认 key（"nutrient" / "jet" / ...）—— 美术换图不需要改这里。
# ============================================================

const PANEL_X := 14.0
const PANEL_Y := 14.0
const PAD := 12.0
const GAP1 := 22.0
const GAP2 := 16.0
const ICON1 := 30.0
const ICON2 := 22.0
const FS1 := 20
const FS2 := 15

const SKILL_R := 30.0
const SKILL_GAP := 22.0
const SKILL_BX := 18.0
const SKILL_BY := 18.0

var icons: Dictionary = {}
var font: Font = null
var data: Dictionary = {}

var _pulse := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func set_icons(t: Dictionary) -> void:
	icons = t
	queue_redraw()


func set_data(d: Dictionary) -> void:
	data = d


func _process(delta: float) -> void:
	_pulse += delta
	queue_redraw()      # 冷却扇形要连续变化，这个小面板每帧重绘代价可以忽略


func _draw() -> void:
	if font == null:
		font = ThemeDB.fallback_font
	if data.is_empty():
		return
	_draw_stats()
	_draw_skills()


# ------------------------------------------------------------ 左上状态区

func _draw_stats() -> void:
	var items1 := [
		["nutrient", _s(data.get("nutrient", 0)), Color(1.0, 1.0, 1.0, 0.96)],
		["virus", _s(data.get("live", 0)), Color(0.62, 0.92, 0.66, 0.96)],
		["corpse", _s(data.get("corpse", 0)), Color(0.82, 0.86, 0.90, 0.92)],
		["perf", "%.1f" % float(data.get("tick_ms", 0.0)), Color(0.70, 0.80, 0.88, 0.86)],
	]
	var items2 := [
		["blob", _s(data.get("blob", 0)), Color(0.62, 0.92, 0.66, 0.92)],
		["band", _s(data.get("band", 0)), Color(0.97, 0.78, 0.40, 0.92)],
		["chain", _s(data.get("chain", 0)), Color(0.90, 0.55, 0.86, 0.92)],
	]
	var w1 := _row_w(items1, ICON1, FS1, GAP1)
	var w2 := _row_w(items2, ICON2, FS2, GAP2)
	var pw: float = maxf(w1, w2) + PAD * 2.0
	var ph := PAD * 2.0 + ICON1 + 10.0 + ICON2
	var bg := Rect2(PANEL_X, PANEL_Y, pw, ph)
	draw_rect(bg, Color(0.030, 0.045, 0.065, 0.78), true)
	draw_rect(bg, Color(0.24, 0.44, 0.52, 0.55), false, 1.0)
	# 左侧一条竖向色标，把「资源 / 敌方」分区一眼分开
	draw_rect(Rect2(bg.position.x, bg.position.y, 2.0, bg.size.y), Color(0.36, 0.86, 0.94, 0.75), true)

	var x := PANEL_X + PAD
	var y := PANEL_Y + PAD
	for it in items1:
		x = _chip(Vector2(x, y), String(it[0]), String(it[1]), ICON1, FS1, it[2], GAP1)
	x = PANEL_X + PAD + 4.0
	y += ICON1 + 10.0
	for it2 in items2:
		x = _chip(Vector2(x, y), String(it2[0]), String(it2[1]), ICON2, FS2, it2[2], GAP2)


func _row_w(items: Array, icon_s: float, fs: int, gap: float) -> float:
	var w := 0.0
	for i in range(items.size()):
		w += icon_s + 7.0 + font.get_string_size(String(items[i][1]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if i < items.size() - 1:
			w += gap
	return w


# 一个「图标 + 数字」单元；返回下一个单元的起始 x
func _chip(pos: Vector2, key: String, text: String, icon_s: float, fs: int, col: Color, gap: float) -> float:
	_draw_icon(key, pos, icon_s, col)
	var tx := pos.x + icon_s + 7.0
	draw_string(font, Vector2(tx, pos.y + icon_s * 0.5 + float(fs) * 0.36), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	return tx + font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + gap


func _draw_icon(key: String, pos: Vector2, s: float, col: Color) -> void:
	var t: Texture2D = icons.get(key, null)
	if t != null:
		draw_texture_rect(t, Rect2(pos, Vector2(s, s)), false, col)
	else:
		# 素材缺失时的占位：一个色点，保证还能读数值
		draw_circle(pos + Vector2(s * 0.5, s * 0.5), s * 0.34, Color(col.r, col.g, col.b, 0.35))


# ------------------------------------------------------------ 左下技能栏

func _draw_skills() -> void:
	var nutrient: int = int(data.get("nutrient", 0))
	var r := SKILL_R
	var by := size.y - SKILL_BY - r * 2.0      # 顶边留 SKILL_BY，圆直径 2r，整颗圆都在屏内
	var step := r * 2.0 + SKILL_GAP
	var aim := int(data.get("aim", 0))

	# 技能栏底板：地图底色太花，不垫一层深底图标会看不清
	var bg := Rect2(SKILL_BX - 10.0, by - 10.0, step * 2.0 + r * 2.0 + 20.0, r * 2.0 + 20.0)
	draw_rect(bg, Color(0.030, 0.045, 0.065, 0.74), true)
	draw_rect(bg, Color(0.24, 0.44, 0.52, 0.50), false, 1.0)

	# 射流不要「在场数量」（它没有实体，右上角空着更干净）
	_skill(Vector2(SKILL_BX, by), "jet", float(data.get("jet_ratio", 1.0)),
		0, 0, 0, true, false)

	_skill(Vector2(SKILL_BX + step, by), "block", 1.0,
		Balance.BLOCK_COST, int(data.get("blocks", 0)), 0,
		nutrient >= Balance.BLOCK_COST, aim == 1)

	_skill(Vector2(SKILL_BX + step * 2.0, by), "fuse", float(data.get("fuse_ratio", 1.0)),
		Balance.FUSE_COST, int(data.get("fuses", 0)), Balance.FUSE_MAX,
		nutrient >= Balance.FUSE_COST, aim == 2)


func _skill(pos: Vector2, key: String, ratio: float, cost: int, count: int, max_count: int,
		affordable: bool, aiming: bool) -> void:
	var r := SKILL_R
	var c: Vector2 = pos + Vector2(r, r)
	draw_circle(c, r, Color(0.045, 0.065, 0.090, 0.86))
	draw_circle(c, r - 1.0, Color(0.10, 0.15, 0.19, 0.72))

	var tint := Color(1.0, 1.0, 1.0, 1.0) if affordable else Color(1.0, 0.55, 0.50, 0.85)
	_draw_icon(key, c - Vector2(18.0, 18.0), 36.0, tint)

	# 冷却扇形：从 12 点顺时针扫过「还没好」的那一段
	if ratio < 0.999:
		var steps := 26
		var a0 := -PI * 0.5
		var a1 := a0 + TAU * clampf(1.0 - ratio, 0.0, 1.0)
		var pts := PackedVector2Array()
		pts.append(c)
		for i in range(steps + 1):
			var a := a0 + (a1 - a0) * float(i) / float(steps)
			pts.append(c + Vector2(cos(a), sin(a)) * (r - 1.0))
		draw_colored_polygon(pts, Color(0.01, 0.02, 0.035, 0.74))

	var ring := Color(0.36, 0.86, 0.94, 0.55) if affordable else Color(1.0, 0.42, 0.38, 0.75)
	if ratio < 0.999:
		ring = Color(0.45, 0.55, 0.62, 0.75)
	draw_arc(c, r, 0.0, TAU, 40, ring, 2.0)
	if aiming:
		# 瞄准态：外圈呼吸，告诉你「正拿着这个技能」
		var br := 0.45 + 0.55 * absf(sin(_pulse * 5.0))
		draw_arc(c, r + 5.0, 0.0, TAU, 44, Color(0.62, 0.98, 1.0, 0.45 + 0.45 * br), 2.0)

	# 花费：画在圆内右下（0 表示不要钱，不画）
	if cost > 0:
		draw_string(font, c + Vector2(8.0, 24.0), _s(cost), HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(1.0, 0.94, 0.80, 0.92) if affordable else Color(1.0, 0.55, 0.50, 0.92))

	# 在场数量 / 上限：右上角小徽章
	if count > 0:
		var badge_c: Vector2 = c + Vector2(r - 6.0, -(r - 6.0))
		draw_circle(badge_c, 9.5, Color(0.03, 0.05, 0.07, 0.95))
		draw_arc(badge_c, 9.5, 0.0, TAU, 18, Color(0.36, 0.86, 0.94, 0.75), 1.2)
		var txt := _s(count)
		if max_count > 0:
			txt += "/" + _s(max_count)
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(font, badge_c + Vector2(-tw * 0.5, 4.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			Color(0.88, 0.96, 1.0, 0.95))


# 数字统一走这里：整数不带小数点，小数留一位
func _s(v) -> String:
	if v is float:
		return "%.1f" % v
	return str(int(v))
