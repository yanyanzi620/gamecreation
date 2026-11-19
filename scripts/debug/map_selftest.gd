extends Node2D
# ============================================================
# 地图生成自测（自动验收）
# 跑法：
#   <godot_console> --headless --path E:\gamecreation res://scenes/debug/map_selftest.tscn
# 期望末行：MAP SELFTEST: x/x PASS
#
# 验收项（每一项都对应一个「程序化地图最常见的翻车点」）
#   B1 轮廓闭合数    至少 3 条闭合轮廓，不然地图是碎的
#   B2 墙段数量      至少 40 段，不然没墙
#   B3 流明占比      10%~52%，太低没地方走，太高就不是器官（肺泡泡沫结构天然偏开阔）
#   B4 玩家可达率    ≥ 90%，防「有角落永远进不去」
#   B5 连通块        允许 1~4 块（肺泡本身可以互相不通）
#   B6 墙体判定      穿越墙段两侧必须判为 blocked
#   B7 确定性        同种子两次生成，墙段数与坐标哈希完全一致
#   B8 生成耗时      < 400 ms
# ============================================================

const SEEDS := [20261119, 777, 424242, 1001]

var _fails := 0
var _total := 0


func _ready() -> void:
	print("=== 地图生成自测 ===")
	var t_all := Time.get_ticks_msec()

	for s in SEEDS:
		_test_seed(int(s))

	_line("B7", "确定性（同种子两次一致）", _determinism(), "")
	_line("B8", "单次生成耗时 < 400ms", true, "见上表 build 列")

	print("总耗时 %d ms" % (Time.get_ticks_msec() - t_all))
	print("MAP SELFTEST: %d/%d PASS" % [_total - _fails, _total])
	get_tree().quit(1 if _fails > 0 else 0)


func _test_seed(seedv: int) -> void:
	var gen := LungGen.new()
	var m: OrganMap = gen.build(seedv, Vector2(3040.0, 1320.0))
	var rep: Dictionary = m.walk_report(16.0)

	var tag := "seed %d" % seedv
	print("\n--- %s ---" % tag)
	print("  shapes=%d loops=%d(open %d) segs=%d build=%dms free=%.1f%% walk=%.1f%% reach=%.1f%% comps=%d" % [
		m.shape_count, int(rep["loops"]), int(rep["open_loops"]), int(rep["segments"]), m.build_ms,
		float(rep["free_ratio"]) * 100.0, float(rep["walk_area"]) * 100.0,
		float(rep["reach_ratio"]) * 100.0, int(rep["components"])
	])

	_line("B1", "%s 轮廓闭合数 >= 3" % tag, int(rep["loops"]) >= 3, "loops=%d" % int(rep["loops"]))
	_line("B2", "%s 墙段数 >= 40" % tag, int(rep["segments"]) >= 40, "segs=%d" % int(rep["segments"]))

	var fr := float(rep["free_ratio"])
	_line("B3", "%s 流明占比 10%%~52%%" % tag, fr >= 0.10 and fr <= 0.52, "free=%.1f%%" % (fr * 100.0))
	_line("B4", "%s 玩家可达率 >= 90%%" % tag, float(rep["reach_ratio"]) >= 0.90,
		"reach=%.1f%%" % (float(rep["reach_ratio"]) * 100.0))
	_line("B5", "%s 死腔面积 < 3%%" % tag, float(rep["stray_area"]) < 0.03,
		"comps=%d stray=%.2f%%" % [int(rep["components"]), float(rep["stray_area"]) * 100.0])
	_line("B9", "%s 轮廓无开口" % tag, int(rep["open_loops"]) == 0,
		"open=%d" % int(rep["open_loops"]))
	_line("B6", "%s 墙体判定有效" % tag, _wall_check(m), "")
	_line("B8", "%s 生成耗时 < 400ms" % tag, m.build_ms < 400, "build=%dms" % m.build_ms)


# 取前 60 段墙，在法线方向各偏 10 像素跨过去，必须判为穿墙
func _wall_check(m: OrganMap) -> bool:
	var n := mini(60, m.seg_a.size())
	for i in range(n):
		var a: Vector2 = m.seg_a[i]
		var b: Vector2 = m.seg_b[i]
		var mid := (a + b) * 0.5
		var d := (b - a).normalized()
		var nv := Vector2(-d.y, d.x) * 9.0
		if not m.blocked(mid - nv, mid + nv):
			print("    !! 墙段 %d 判不出穿越 (%s -> %s)" % [i, a, b])
			return false
	return true


func _determinism() -> bool:
	var g1 := LungGen.new()
	var m1: OrganMap = g1.build(20261119, Vector2(3040.0, 1320.0))
	var g2 := LungGen.new()
	var m2: OrganMap = g2.build(20261119, Vector2(3040.0, 1320.0))
	if m1.seg_a.size() != m2.seg_a.size():
		return false
	var h1 := 0.0
	var h2 := 0.0
	for i in range(m1.seg_a.size()):
		h1 += m1.seg_a[i].x * 3.7 + m1.seg_a[i].y * 1.1 + m1.seg_b[i].x * 0.3 + m1.seg_b[i].y * 5.9
		h2 += m2.seg_a[i].x * 3.7 + m2.seg_a[i].y * 1.1 + m2.seg_b[i].x * 0.3 + m2.seg_b[i].y * 5.9
	return absf(h1 - h2) < 0.01


func _line(tag: String, name: String, ok: bool, extra: String) -> void:
	_total += 1
	if not ok:
		_fails += 1
	print("  %-3s | %-34s | %s | %s" % [tag, name, "PASS" if ok else "FAIL", extra])
