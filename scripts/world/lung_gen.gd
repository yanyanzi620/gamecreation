extends RefCounted
class_name LungGen
# ============================================================
# 肺地图生成器（器官轮廓 + 固定骨架 + 抖动）
# ============================================================
# 四层，从外到内：
#
#   0) 器官轮廓（整张地图的形状就是一对肺，不是矩形）
#      用「大肉块圆」沿脊柱拼出上窄下宽的两叶，再加中间一条纵隔连接带。
#      流明会被裁进这个轮廓里，轮廓外全是胸壁 —— 所以地图本身就是肺的形状。
#
#   1) 肺泡泡沫（主力战场）
#      每叶内部六边形密排圆腔，直径 ~140（玩家 44，面积占比约 10%），
#      隔膜 ~46，用「随机生成树」连门：连通、有分叉、有环路，不出现直走廊。
#      肺泡必须整个落在轮廓内（退让 0.8r），给肺表面留一圈完整胸膜壁。
#
#   2) 支气管主干（跨叶通道 / 病毒捷径）
#      纵隔里一条纵向主干（上粗下细、带摆动），两侧各 3 条分支。
#      每条分支都直接连到该侧最近的那个肺泡 —— 这样主干和两叶一定连得通。
#
#   3) 肺泡间孔隙（病毒专用）—— 细缝 7~10，只有病毒挤得过去。
#
# 玩法含义：病毒有三条玩家走不了/绕不过的路（支气管、孔隙、跨叶主干），
#          所以「堵」比「追」重要；左右分叶让「先保哪一叶」变成真的决策。
#
# 改「块头」只看 PARAM 段；轮廓数据在 SIL 段。
# ============================================================

# ---- 肺泡泡沫 ----
# 配比口径：肺泡直径 2R ≈ 140，玩家直径 44 -> 面积占比 ≈ (22/70)^2 ≈ 10%
const ALV_R_MIN := 70.0
const ALV_R_MAX := 80.0
const ALV_JITTER_POS := 11.0
const ALV_JITTER_R := 0.03
const MIN_SEPTUM := 46.0        # 隔膜必须比门宽，肉壁才连得成网
const NEIGHBOR_RANGE := 1.16    # 以节距为单位，认定「相邻」的距离

# ---- 连接管（玩家可走）----
# 门宽随机：细门只够玩家侧身挤过，粗门能让病毒整股涌进去 —— 同一张图里有宽有窄才有机动感。
# 下限按玩家碰撞半径卡死（0.72 * PLAYER_R(30) = 21.6），再小玩家就永远过不去。
const DUCT_R_MIN := 20.0        # 门宽 40：刚才容得下玩家（0.72 * 26 = 18.7）
const DUCT_R_MAX := 34.0        # 门宽 68：大通道，扩散会顺着它走，但不会宽到把整排骨腔糊成一条
const EXTRA_LINK_CHANCE := 0.22 # 生成树之外再开这么多旁门，形成环路

# ---- 孔隙（只有病毒能过）----
const PORE_R_MIN := 8.0
const PORE_R_MAX := 13.0
const PORE_RANGE := 16.0
const PORE_CHANCE := 0.45

# ---- 支气管主干 ----
const TRUNK_R := 88.0           # 气管半径（176 宽）
const BRANCH_R := 52.0          # 肺门分支半径（104 宽）
const BRANCH_COUNT := 3         # 每侧分支数，合计 6 个肺门

# ---- 器官轮廓（按 3040×1320 写死，运行时按实际尺寸缩放）----
# 每个节点 = [x, y, r]：一个"肉块圆"。左叶沿脊柱上小下大；右叶镜像。
const SIL_BASE := Vector2(6200.0, 2300.0)
# 叶形是「上宽下窄」（按需求方口径）。真解剖学是肺尖窄、肺底宽 —— 想换回真实解剖把这里改 true 即可，
# SIL_SHAPES 的 y 会整体上下镜像，肺泡撒点跟着走，不用改别的。
const SIL_FLIP_Y := false
# 叶形：肺尖很窄 -> 往下逐渐变宽 -> 最宽处在 60% 高度 -> 向肺底收成圆角。
# 用一串半径递增/递减的圆拼，而不是一个大圆（大圆会变成一个球，看不出是肺）。
# 叶形不再用「一串圆」拼（圆一多就变成球，看不出是肺）。
# 下面是一串圆形 + 胶囊，按真实肺的比例摆：肺尖窄 -> 上段细长 -> 中段变宽 -> 肺底最宽并收成圆角。
# 格式：圆 = [0, x, y, 0, 0, r]；胶囊 = [1, ax, ay, bx, by, r]；右叶自动镜像。
const SIL_SHAPES := [
	# 上宽下窄的叶形：每一「排」是一条水平胶囊，宽度自上而下逐级收窄，
	# 圆顶靠最上面一排的圆角收出来，底部收成小叶尖 —— 不是一根柱子，也不是一个球。
	[1, 650.0, 380.0, 2550.0, 380.0, 200.0],     # 肺尖（宽 2300，最上、最宽）
	[1, 670.0, 650.0, 2530.0, 650.0, 250.0],     # 上段（2360）
	[1, 780.0, 950.0, 2420.0, 950.0, 300.0],     # 上中段（2240）
	[1, 900.0, 1250.0, 2300.0, 1250.0, 300.0],   # 中段（2000）
	[1, 1040.0, 1550.0, 2160.0, 1550.0, 260.0],  # 下段（1640）
	[1, 1200.0, 1800.0, 2000.0, 1800.0, 220.0],  # 下段（1240）
	[1, 1360.0, 2000.0, 1840.0, 2000.0, 180.0],  # 肺底（840）
	[1, 1480.0, 2130.0, 1720.0, 2130.0, 140.0],  # 肺底尖（520，收圆角）
]
# 气管 / 主支气管不在这里：它们自带轮廓（见 _airway），否则纵隔会被填成一根柱子

var _alv: Array = []   # 本局所有肺泡 [中心, 半径]，给支气管分支找落点用


func build(seed_value: int, size: Vector2) -> OrganMap:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var m := OrganMap.new()
	m.size = size
	_alv.clear()

	# ---------------------------------------------------------- 0) 器官轮廓
	_silhouette(m, size)

	# ---------------------------------------------------------- 0.5) 两叶的肺泡
	# 两叶的格子范围（叶形本身由轮廓决定，这里只是撒点的范围）
	_lobe(m, rng, Rect2(470.0, 240.0, 2160.0, 1960.0))
	_lobe(m, rng, Rect2(size.x - 2630.0, 240.0, 2160.0, 1960.0))

	# ---------------------------------------------------------- 1) 支气管主干
	_airway(m, rng, size)

	m.build()

	# ---------------------------------------------------------- 2) 肉壁纹理：小肺泡
	# 纯视觉：不算流明、不参与碰撞，只让「红区」看起来像肺实质而不是石头
	var target := clampi(int(size.x * size.y / 9000.0), 120, 620)
	var tries := 0
	while m.decor.size() < target and tries < target * 16:
		tries += 1
		var p := Vector2(rng.randf_range(30.0, size.x - 30.0), rng.randf_range(30.0, size.y - 30.0))
		if m.clip_sdf(p) > 0.0:
			continue            # 体腔里不画肺纹理
		if not m.solid_point(p):
			continue
		if m.clearance(p) < 12.0:
			continue
		var rr := rng.randf_range(14.0, 26.0)
		m.decor.append([p, rr])

	return m


# ============================================================ 器官轮廓
func _silhouette(m: OrganMap, size: Vector2) -> void:
	var kx: float = size.x / SIL_BASE.x
	var ky: float = size.y / SIL_BASE.y
	var kr: float = (kx + ky) * 0.5
	var cy := SIL_BASE.y * 0.5

	for n in SIL_SHAPES:
		var r := float(n[5]) * kr
		var sy2 := float(n[2])
		var sy4 := float(n[4])
		if SIL_FLIP_Y:
			sy2 = cy * 2.0 - sy2
			sy4 = cy * 2.0 - sy4
		if int(n[0]) == 0:
			var p := Vector2(float(n[1]) * kx, sy2 * ky)
			r = minf(r, minf(p.y - 44.0, size.y - p.y - 44.0))   # 不许顶到场地上下边
			m.add_clip_circle(p, r)
			m.add_clip_circle(Vector2(size.x - p.x, p.y), r)      # 右叶镜像
		else:
			var a := Vector2(float(n[1]) * kx, sy2 * ky)
			var b := Vector2(float(n[3]) * kx, sy4 * ky)
			# 胶囊两端都要留边距，否则肺底会被场地边切平、轮廓出现开口
			var room := 1.0e9
			for p2 in [a, b]:
				room = minf(room, minf(minf(p2.y - 44.0, size.y - p2.y - 44.0),
					minf(p2.x - 44.0, size.x - p2.x - 44.0)))
			r = minf(r, room)
			m.add_clip_capsule(a, b, r)
			m.add_clip_capsule(Vector2(size.x - a.x, a.y), Vector2(size.x - b.x, b.y), r)

	# 中间只有左右两叶之间的体腔，不放任何轮廓


# ============================================================ 一叶的肺泡泡沫
func _lobe(m: OrganMap, rng: RandomNumberGenerator, rect: Rect2) -> void:
	var step: float = ALV_R_MAX * 2.0 + MIN_SEPTUM
	var row_dy := step * 0.8660254
	var cols := maxi(2, int(rect.size.x / step) + 1)
	var rows := maxi(2, int(rect.size.y / row_dy) + 1)

	var cx: Array[Vector2] = []
	var cr: Array[float] = []
	for j in range(rows):
		for i in range(cols):
			var x := rect.position.x + step * 0.5 + float(i) * step
			if j % 2 == 1:
				x += step * 0.5
			var y := rect.position.y + row_dy * 0.5 + float(j) * row_dy
			var p := Vector2(
				x + rng.randf_range(-ALV_JITTER_POS, ALV_JITTER_POS),
				y + rng.randf_range(-ALV_JITTER_POS, ALV_JITTER_POS))
			var r := rng.randf_range(ALV_R_MIN, ALV_R_MAX) * rng.randf_range(1.0 - ALV_JITTER_R, 1.0 + ALV_JITTER_R)
			# 贴到胸膜的肺泡按可用距离缩径（真实肺里外周的肺泡本来就小），
			# 这样肺泡能一直铺到轮廓边缘，肺的形状是肺泡自己长出来的，不是被裁出来的
			var room := m.clip_inside_dist(p)
			if room < 0.0:
				continue
			r = minf(r, room * 0.96)
			if r < 44.0:
				continue            # 太小放不下玩家，别生成死泡
			cx.append(p)
			cr.append(r)

	if cx.size() < 4:
		return

	# 位置松弛：任何一对肺泡之间都要留出隔膜
	for _it in range(5):
		var moved := false
		for i in range(cx.size()):
			for j in range(i + 1, cx.size()):
				var need: float = cr[i] + cr[j] + MIN_SEPTUM
				var d := cx[i].distance_to(cx[j])
				if d >= need or d < 0.01:
					continue
				var push := (need - d) * 0.5
				var dir := (cx[j] - cx[i]).normalized()
				cx[i] -= dir * push
				cx[j] += dir * push
				moved = true
		if not moved:
			break

	# 邻接表：只认紧挨着的六邻居，避免跨格连出长廊
	var adj: Array = []
	for i in range(cx.size()):
		adj.append([])
	var near := step * NEIGHBOR_RANGE
	for i in range(cx.size()):
		for j in range(i + 1, cx.size()):
			if cx[i].distance_to(cx[j]) <= near:
				adj[i].append(j)
				adj[j].append(i)

	var keep: Array[int] = []
	for i in range(cx.size()):
		if not adj[i].is_empty():
			keep.append(i)
	if keep.size() < 3:
		return

	for i in keep:
		m.add_circle(cx[i], cr[i])
		_alv.append([cx[i], cr[i]])

	# 随机生成树：连通但不直廊
	var in_tree := {}
	var tree_edges: Array = []
	var start_node: int = keep[int(rng.randi_range(0, keep.size() - 1))]
	in_tree[start_node] = true
	var frontier: Array = []
	for nb in adj[start_node]:
		frontier.append([start_node, nb])
	while not frontier.is_empty():
		var k := int(rng.randi_range(0, frontier.size() - 1))
		var e: Array = frontier[k]
		frontier.remove_at(k)
		var nb2: int = e[1]
		if in_tree.has(nb2):
			continue
		in_tree[nb2] = true
		tree_edges.append([e[0], nb2])
		for n2 in adj[nb2]:
			if not in_tree.has(n2):
				frontier.append([nb2, n2])

	# 兜底：没接上的就近拉一条
	for i in keep:
		if in_tree.has(i):
			continue
		var best := -1
		var bd := 1.0e9
		for j in keep:
			if not in_tree.has(j):
				continue
			var d2: float = cx[i].distance_to(cx[j])
			if d2 < bd:
				bd = d2
				best = j
		if best >= 0:
			in_tree[i] = true
			tree_edges.append([best, i])

	# 旁门：在树上加环路
	var linked := {}
	for e2 in tree_edges:
		linked["%d:%d" % [mini(int(e2[0]), int(e2[1])), maxi(int(e2[0]), int(e2[1]))]] = true
	var extra: Array = []
	for i in keep:
		for j in adj[i]:
			if j < i:
				continue
			if linked.has("%d:%d" % [i, j]):
				continue
			if rng.randf() < EXTRA_LINK_CHANCE:
				linked["%d:%d" % [i, j]] = true
				extra.append([i, j])

	for e3 in tree_edges + extra:
		if cx[int(e3[0])].distance_to(cx[int(e3[1])]) - cr[int(e3[0])] - cr[int(e3[1])] > 110.0:
			continue                     # 隔着肉壁太远，连过去会变成细长面条
		_door(m, cx, cr, int(e3[0]), int(e3[1]), rng)

	# 孔隙（病毒专用）
	for i in keep:
		for j in adj[i]:
			if j < i:
				continue
			if linked.has("%d:%d" % [i, j]):
				continue
			var gap: float = cx[i].distance_to(cx[j]) - cr[i] - cr[j]
			if gap > PORE_RANGE:
				continue
			if rng.randf() > PORE_CHANCE:
				continue
			m.add_capsule(cx[i], cx[j], rng.randf_range(PORE_R_MIN, PORE_R_MAX))


# 整个圆是否落在器官轮廓内（8 方向采样）
func _fits(m: OrganMap, p: Vector2, margin: float) -> bool:
	if m.clip_sdf(p) > 0.0:
		return false
	for k in range(8):
		var a := TAU * float(k) / 8.0
		if m.clip_sdf(p + Vector2(cos(a), sin(a)) * margin) > 0.0:
			return false
	return true


# 两个肺泡之间的「门」：只铺在隔膜那一段，不从圆心铺到圆心
func _door(m: OrganMap, cx: Array[Vector2], cr: Array[float], i: int, j: int,
		rng: RandomNumberGenerator) -> void:
	var dir := (cx[j] - cx[i]).normalized()
	var pa: Vector2 = cx[i] + dir * (cr[i] - 14.0)
	var pb: Vector2 = cx[j] - dir * (cr[j] - 14.0)
	# 三档随机：窄门占多数（战术口），中门次之，宽门少数（病毒会顺着宽门整股推）
	var roll := rng.randf()
	var dr := 0.0
	if roll < 0.45:
		dr = rng.randf_range(DUCT_R_MIN, DUCT_R_MIN + 6.0)
	elif roll < 0.85:
		dr = rng.randf_range(DUCT_R_MIN + 6.0, DUCT_R_MIN + 18.0)
	else:
		dr = rng.randf_range(DUCT_R_MIN + 18.0, DUCT_R_MAX)
	dr = minf(dr, minf(cr[i], cr[j]) * 0.5)       # 窄肺泡配窄门，别把整颗凿穿
	m.add_capsule(pa, pb, dr)


# ============================================================ 中间支气管主干
# 纵向主干贯穿全场，两侧各开 3 条分支，每条都连到该侧最近的肺泡
func _airway(m: OrganMap, rng: RandomNumberGenerator, size: Vector2) -> void:
	var mid_x := size.x * 0.5
	var kx: float = size.x / SIL_BASE.x

	# 1) 气管：从上方进来，短短一截就分叉（解剖上气管在肺外，所以它自带轮廓）
	var t_top := Vector2(mid_x, size.y * 0.060)
	var carina := Vector2(mid_x, size.y * 0.205)
	m.add_circle(t_top + Vector2(0.0, 30.0), 116.0)
	m.add_capsule(t_top, carina, TRUNK_R)
	m.add_clip_capsule(t_top, carina, TRUNK_R + 30.0)

	# 2) 左右主支气管：从隆突斜插进各自肺门，这一段是两叶唯一的通道
	for side in [-1.0, 1.0]:
		var hilar := Vector2(mid_x + side * 430.0 * kx, size.y * 0.310)
		m.add_capsule(carina, hilar, BRANCH_R)
		m.add_clip_capsule(carina, hilar, BRANCH_R + 26.0)

		# 3) 进入肺门后继续往里连到最近的肺泡，保证主干 <-> 两叶一定连通
		var t1 := _nearest_alv(hilar)
		if t1 != Vector2.INF:
			m.add_capsule(hilar, t1, BRANCH_R)
			m.add_clip_capsule(hilar, t1, BRANCH_R + 46.0)
			# 第二条分支：从肺门再往里走一段，多一个入口
			var t2b := _nearest_alv(hilar + Vector2(side * 150.0 * kx, size.y * 0.14))
			if t2b != Vector2.INF and t2b.distance_to(t1) > 120.0:
				m.add_capsule(t1, t2b, BRANCH_R * 0.85)
				m.add_clip_capsule(t1, t2b, BRANCH_R + 40.0)


func _nearest_alv(probe: Vector2) -> Vector2:
	var best := Vector2.INF
	var bd := 1.0e9
	for a in _alv:
		var d: float = float(a[0].distance_to(probe))
		if d < bd:
			bd = d
			best = a[0]
	return best
