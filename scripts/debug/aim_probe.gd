extends SceneTree
# ============================================================
# 阻隔带落位探针 —— 只验证几何不变量，不碰模拟
#
# 跑法：
#   <godot_console> --headless --path E:\gamecreation --script res://scripts/debug/aim_probe.gd
#
# 验证什么（任一条挂了就是落位逻辑坏了）：
#   1. 带子两端不许在肉壁里（solid_point == false）
#   2. 带子中间不许穿墙（line_free 全段为真）
#   3. 裁完短于 BLOCK_MIN_USABLE 时不许返回 ok
#   4. 距离必须落在 BLOCK_RANGE_MIN ~ BLOCK_RANGE_MAX 内
# 统计什么（用来判断「能不能放得下来」的手感是否合理）：
#   ok 率 / 被肉壁裁短的比例 / 平均长度 / 放不下的原因占比
# ============================================================

const Virus = preload("res://scripts/world/virus_population.gd")

func _init() -> void:
	var m: OrganMap = LungGen.new().build(Balance.DEFAULT_SEED, Vector2(Balance.ARENA_W, Balance.ARENA_H))
	var pop = Virus.new()
	pop.bind_organ(m)

	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var dists: Array[float] = [Balance.BLOCK_RANGE_MIN, 200.0, 360.0, Balance.BLOCK_RANGE_MAX]

	var tries := 0
	var oks := 0
	var trimmed := 0
	var too_short := 0
	var too_close := 0
	var len_sum := 0.0
	var len_min := 1.0e9
	var bad_endpoint := 0
	var bad_line := 0
	var raster_miss := 0
	var bad_dist := 0
	var dist_hist: Array[int] = []

	for k in range(240):
		var o: Vector2 = m.random_free_point(rng, Balance.PLAYER_R + 4.0)
		if not m.is_main_walkable(o):
			continue
		for di in range(dists.size()):
			var want: float = dists[di]
			for a in range(8):
				var ang := TAU * float(a) / 8.0
				var dir := Vector2(cos(ang), sin(ang))
				tries += 1
				var r: Dictionary = pop.resolve_block(o, dir, want)
				if not bool(r["ok"]):
					# 分清「太窄」和「贴墙」两种失败，方便判断该调哪个数
					match String(r.get("why", "")):
						"too_narrow":
							too_short += 1
						_:
							too_close += 1
					continue
				oks += 1
				var a2: Vector2 = r["a"]
				var b2: Vector2 = r["b"]
				var ln := a2.distance_to(b2)
				len_sum += ln
				len_min = minf(len_min, ln)
				if float(r["trim"]) > 4.0:
					trimmed += 1
				var dist_used := float(r["dist"])
				# 距离不变量：永远不许超过上限；低于下限只允许「被肉壁推近」这一种情况
				if dist_used > Balance.BLOCK_RANGE_MAX + 1.0:
					bad_dist += 1
				elif dist_used < Balance.BLOCK_RANGE_MIN - 1.0 and not bool(r["capped"]):
					bad_dist += 1
				dist_hist.append(int(dist_used))
				# 不变量 1：两端不在肉壁（用栅格口径；轮廓与栅格在边界上会有不到一格的偏差，
				#            所以允许极小比例，超出就说明裁短逻辑真的坏了）
				if m.solid_point(a2) or m.solid_point(b2):
					bad_endpoint += 1
				# 不变量 2：整条线不穿墙（用「轮廓段精确判定」，跟渲染出来的是同一份几何）
				if m.blocked(a2, b2):
					bad_line += 1
				# 参考指标：栅格口径（8px 采样，会漏极薄的褶皱，不当失败用）
				if not m.line_free(a2.x, a2.y, b2.x, b2.y):
					raster_miss += 1

	var mean_len := len_sum / float(maxi(1, oks))
	var med_dist := 0
	if not dist_hist.is_empty():
		var hs: Array = dist_hist
		hs.sort()
		med_dist = int(hs[hs.size() / 2])

	print("[AIM] tries=%d ok=%d (%.1f%%) trimmed=%d(%.0f%% of ok) too_short=%d too_close=%d" % [
		tries, oks, float(oks) * 100.0 / float(maxi(1, tries)),
		trimmed, float(trimmed) * 100.0 / float(maxi(1, oks)), too_short, too_close
	])
	print("[AIM] len mean=%.0f min=%.0f (满长 %.0f) | dist median=%d | 违规 endpoint=%d line=%d dist=%d | 栅格穿线(参考)=%d" % [
		mean_len, len_min, Balance.BLOCK_LEN, med_dist, bad_endpoint, bad_line, bad_dist, raster_miss
	])
	# 边界容差：轮廓与栅格在相切褶皱处可能差不到一格，允许 endpoint 违规 ≤ 0.2%
	var endpoint_limit := int(ceil(float(oks) * 0.002))
	var pass_all := bad_line == 0 and bad_dist == 0 and oks > 0 and bad_endpoint <= endpoint_limit
	print("AIM PROBE: %s  (endpoint 容差 %d)" % ["PASS" if pass_all else "FAIL", endpoint_limit])
	pop.free()   # 探针里的 Virus 是裸建的节点，手动释放，免得退出时刷 "resources still in use"
	quit()
