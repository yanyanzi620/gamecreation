extends CanvasLayer
# ============================================================
# HUD —— 组装层：一个图标面板 + 一张小地图
#
# 只做「显示」，不持有任何玩法状态：每帧由 main 传一份字典进来。
# 具体怎么画在 hud_panel.gd（图标 + 数字，不写文字标签）；
# 图标素材在 assets/ui/icons/，映射表是那边的 manifest.json。
#
# 想加新指标：main 往字典里塞一个键 -> hud_panel 里加一个 chip。
# 别回头去读 pop/aura 的内部字段（双人分屏时这一层要能整个换掉）。
# ============================================================

const PanelScript := preload("res://scripts/ui/hud_panel.gd")
const IconLoader := preload("res://scripts/ui/ui_icons.gd")

var mini: Control
var panel: Control

var _icons: Dictionary = {}


func build(vp: Vector2, minimap_script) -> void:
	_icons = IconLoader.load_set()

	panel = PanelScript.new()
	panel.name = "Panel"
	panel.position = Vector2.ZERO
	panel.size = vp
	add_child(panel)
	panel.set_icons(_icons)

	mini = minimap_script.new()
	mini.name = "Mini"
	mini.size = Vector2(360.0, 190.0)
	mini.position = Vector2(vp.x - 376.0, 16.0)
	mini.icons = _icons
	mini.font = ThemeDB.fallback_font
	add_child(mini)


# 一帧一次的纯显示刷新。字典里所有键都是「已经算好的值」，HUD 不自己推导。
func refresh(d: Dictionary) -> void:
	if panel != null:
		panel.set_data(d)
