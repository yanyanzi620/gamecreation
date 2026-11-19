extends Control
# ============================================================
# 整肺简图（小地图）
# ============================================================
# 3040×1320 的场地远超屏幕，没有简图玩家会迷路。
# 这里画三样东西：
#   1. 器官掩码缩略图（左叶 / 右叶 / 中间支气管，一眼能分清）
#   2. 当前视口框（相机看的是哪一块）
#   3. 玩家光点
# 纯 UI，不参与碰撞；organ_view.map_texture() 提供缩略图源。
# ============================================================

var map = null
var tex: Texture2D = null
var player := Vector2.ZERO
var view_rect := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if tex == null or map == null:
		return
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0.03, 0.04, 0.06, 0.88), true)

	# 等比缩放，居中放
	var sc: float = minf(size.x / map.size.x, size.y / map.size.y)
	var dst := Rect2(Vector2.ZERO, map.size * sc)
	dst.position = (size - dst.size) * 0.5
	draw_texture_rect(tex, dst, false)

	# 当前视口
	if view_rect.size.x > 1.0:
		var vr := Rect2(dst.position + view_rect.position * sc, view_rect.size * sc)
		draw_rect(vr, Color(0.65, 0.88, 1.0, 0.45), false, 1.0)

	# 玩家
	draw_circle(dst.position + player * sc, 3.2, Color(0.45, 0.78, 1.0))

	draw_rect(r, Color(0.40, 0.52, 0.58, 0.75), false, 1.0)
