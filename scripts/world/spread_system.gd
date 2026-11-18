extends Node2D
# 扩散系统：灰盒版只做球状；带状/辐射/随机留给 M1 扩展

var fields: Array = []

func clear() -> void:
    fields.clear()
    queue_redraw()

func spawn(pos: Vector2, r: float, grow: float) -> void:
    fields.append({"pos": pos, "r": r, "grow": grow, "sd": RNG.spread.randi() % 1000})
    queue_redraw()

func main_radius() -> float:
    if fields.is_empty():
        return 0.0
    return fields[0]["r"]

func step(dt: float, player_pos: Vector2, purifying: bool, pradius: float, rate: float) -> int:
    var engaged := 0
    for f in fields:
        var pos: Vector2 = f["pos"]
        var r: float = f["r"]
        var dist: float = player_pos.distance_to(pos)
        if purifying and dist < pradius + r:
            var edge_gap: float = maxf(0.0, dist - r)
            var eff: float = clampf(1.0 - edge_gap / pradius, 0.25, 1.0)
            f["r"] = maxf(8.0, r - rate * eff * dt)
            engaged += 1
        else:
            f["r"] = minf(1200.0, r + float(f["grow"]) * dt)
    queue_redraw()
    return engaged

func _draw() -> void:
    for f in fields:
        var pts := PackedVector2Array()
        var n := 72
        var r: float = f["r"]
        var sd: int = f["sd"]
        for i in n:
            var a := TAU * float(i) / float(n)
            var wob := 1.0 + 0.035 * sin(a * 5.0 + float(sd) * 0.37) + 0.018 * sin(a * 9.0 + 1.1)
            pts.append(f["pos"] + Vector2(cos(a), sin(a)) * r * wob)
        draw_colored_polygon(pts, Color(0.58, 0.88, 0.26, 0.20))
        var closed := PackedVector2Array()
        for p in pts:
            closed.append(p)
        closed.append(pts[0])
        draw_polyline(closed, Color(0.74, 1.0, 0.42, 0.85), 3.0)
        draw_circle(f["pos"], 14.0, Color(0.80, 1.0, 0.50, 0.9))
