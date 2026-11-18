extends Node2D
# 免疫单元：直径 90 单位（屏高 9%）

const SPEED := 320.0
const RADIUS := 45.0
const PURIFY_RADIUS := 250.0
const PURIFY_RATE := 45.0

var facing := Vector2.RIGHT

func move(dir: Vector2, dt: float, arena: Vector2) -> void:
    if dir.length() > 0.1:
        facing = dir.normalized()
        position += facing * SPEED * dt
    position.x = clampf(position.x, 0.0, arena.x)
    position.y = clampf(position.y, 0.0, arena.y)
    queue_redraw()

func _draw() -> void:
    draw_arc(Vector2.ZERO, PURIFY_RADIUS, 0.0, TAU, 64, Color(0.31, 0.82, 0.77, 0.32), 2.0)
    draw_circle(Vector2.ZERO, RADIUS, Color(0.22, 0.53, 0.61))
    draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 40, Color(0.78, 0.95, 0.97), 3.0)
    draw_circle(Vector2(-8.0, -8.0), 11.0, Color(0.82, 0.96, 1.0))
    draw_line(Vector2.ZERO, facing * (RADIUS + 14.0), Color(0.60, 0.90, 0.95), 3.0)
