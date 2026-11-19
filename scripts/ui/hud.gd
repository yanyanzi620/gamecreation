extends CanvasLayer
# ============================================================
# HUD —— 左上角状态行 + 冷却条 + 小地图 + 操作提示
#
# 只做「显示」，不持有任何玩法状态：每帧由 main 传一份字典进来。
# 想加新指标：在 refresh() 里从字典取一个键、画出来，别回头去读 pop/aura 的内部字段
# （保持 HUD 与玩法解耦，将来做双人分屏时这一层可以直接换掉）。
# ============================================================

var mini: Control
var _line1: Label
var _line2: Label
var _line3: Label
var _hint: Label
var _bar: ColorRect


func build(vp: Vector2, minimap_script) -> void:
	_line1 = _label(Vector2(18.0, 12.0), 16, Color(0.86, 0.93, 0.89))
	_bar = ColorRect.new()
	_bar.position = Vector2(18.0, 96.0)
	_bar.size = Vector2(240.0, 8.0)
	_bar.color = Color(0.35, 0.92, 0.62)
	add_child(_bar)
	_line2 = _label(Vector2(18.0, 112.0), 14, Color(0.95, 0.82, 0.45))
	_line3 = _label(Vector2(18.0, 134.0), 13, Color(0.62, 0.74, 0.86))

	# 整肺简图（右上角）
	mini = minimap_script.new()
	mini.size = Vector2(360.0, 190.0)
	mini.position = Vector2(vp.x - 376.0, 16.0)
	add_child(mini)

	_hint = _label(Vector2(18.0, 156.0), 13, Color(0.60, 0.68, 0.64))
	_hint.text = "WASD 移动（镜头跟随） · 左键 = 射流 · 右键按住拖拽 = 阻隔带(30) · 空格按住拖拽 = 引信(40) · R 换肺 · F 装饰层"


func _label(pos: Vector2, size: int, col: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	add_child(l)
	return l


# 一帧一次的纯显示刷新。字典里所有键都是「已经算好的值」，HUD 不自己推导。
func refresh(d: Dictionary) -> void:
	var ratio: float = float(d.get("jet_ratio", 1.0))
	_bar.size = Vector2(240.0 * ratio, 8.0)
	_bar.color = Color(0.35, 0.92, 0.62) if ratio >= 1.0 else Color(0.85, 0.55, 0.20)
	_line1.text = "live %d  (绿 %d / 琥珀 %d / 品红 %d)   corpse %d   tick %.2f ms   冷却 %d%%" % [
		int(d.get("live", 0)), int(d.get("blob", 0)), int(d.get("band", 0)), int(d.get("chain", 0)),
		int(d.get("corpse", 0)), float(d.get("tick_ms", 0.0)), int(ratio * 100.0)
	]
	_line2.text = "养分 %d   已拾 %d   命中 %d   带 %d   引信 %d   冷却 带%.1fs / 信%.1fs" % [
		int(d.get("nutrient", 0)), int(d.get("picked", 0)), int(d.get("hit", 0)),
		int(d.get("blocks", 0)), int(d.get("fuses", 0)),
		float(d.get("cd_block", 0.0)), float(d.get("cd_fuse", 0.0))
	]
	if d.has("map_size"):
		_line3.text = "肺 seed %d   左叶/右叶 + 中间支气管   流明 %.1f%%   墙段 %d   轮廓 %d   面 %d×%d" % [
			int(d.get("map_seed", 0)), float(d.get("free_ratio", 0.0)) * 100.0,
			int(d.get("segs", 0)), int(d.get("loops", 0)),
			int(d["map_size"].x), int(d["map_size"].y)
		]
