extends RefCounted
class_name LungGen
# ============================================================
# 肺地图生成器（固定骨架 + 抖动）
# ============================================================
# 三层结构，各管一件事：
#
#   1) 肺泡泡沫（主体）—— 六边形密排的圆腔，直径 ~92，隔膜 ~40
#      用「随机生成树」把它们连起来：保证全连通、有分叉有环路，
#      而且不会像矩形网格那样连成一排排横贯全图的直走廊。
#
#   2) 支气管树（骨架 / 装饰 / 病毒专用捷径）
#      手写的一棵树，半径 12~22，比玩家窄 -> 玩家钻不进去，病毒能过。
#
#   3) 肺泡间孔隙（病毒专用）—— 细缝 6~9，只有病毒挤得过去。
#
# 玩法含义：病毒有三条玩家走不了的路（支气管、孔隙），所以「堵」比「追」重要。
# 改「块头」只看 PARAM 段，不用动算法。
# ============================================================

# 支气管树骨架：[parent, x, y, r]，parent = -1 是根
const NODES := [
	[-1, 70.0, 505.0, 22.0],    # 肺门：从左侧进入
	[0, 300.0, 500.0, 18.0],
	[1, 545.0, 300.0, 15.0],
	[1, 560.0, 700.0, 15.0],
	[2, 790.0, 165.0, 13.0],
	[2, 805.0, 405.0, 13.0],
	[3, 805.0, 600.0, 13.0],
	[3, 790.0, 845.0, 13.0],
	[4, 1085.0, 110.0, 12.0],
	[5, 1175.0, 300.0, 12.0],
	[5, 1150.0, 500.0, 12.0],
	[6, 1150.0, 690.0, 12.0],
	[7, 1120.0, 860.0, 12.0],
	[7, 1010.0, 945.0, 12.0],
]

# ---- 肺泡泡沫 ----
# 配比口径：肺泡直径 2R ≈ 92（玩家 44 宽，在里面有充裕空间）
#           隔膜厚 MIN_SEPTUM ≈ 40（看得见的一层肉壁，不是实心大块）
const FOAM_STEP := 160.0        # 六边形格的中心距
const FOAM_MARGIN := 80.0
const ALV_R_MIN := 54.0
const ALV_R_MAX := 58.0
const ALV_JITTER_POS := 12.0
const ALV_JITTER_R := 0.03
const MIN_SEPTUM := 44.0        # 隔膜必须比门宽，肉壁才连得成网
const NEIGHBOR_RANGE := 1.10    # 以 FOAM_STEP 为单位，认定「相邻」的距离

# ---- 连接管（玩家可走）----
const DUCT_R_MIN := 19.0        # 门宽 38~42：要窄于隔膜，才凿不穿墙
const DUCT_R_MAX := 21.0
const EXTRA_LINK_CHANCE := 0.22 # 生成树之外再开这么多旁门，形成环路

# ---- 孔隙（只有病毒能过）----
const PORE_R_MIN := 6.0
const PORE_R_MAX := 9.0
const PORE_RANGE := 10.0        # 两肺泡边缘间距小于这个值才可能开孔
const PORE_CHANCE := 0.50


func build(seed_value: int, size: Vector2) -> OrganMap:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var m := OrganMap.new()
	m.size = size

	# ---------------------------------------------------------- 1) 支气管树
	var pos: Array[Vector2] = []
	var rad: Array[float] = []
	for n in NODES:
		var is_root: bool = n[0] < 0
		var base := Vector2(float(n[1]), float(n[2]))
		var jp := Vector2(rng.randf_range(-10.0, 10.0), rng.randf_range(-10.0, 10.0))
		pos.append(base if is_root else base + jp)
		rad.append(float(n[3]) * rng.randf_range(0.92, 1.08))

	m.add_circle(pos[0], rad[0])
	for i in range(1, NODES.size()):
		var parent: int = int(NODES[i][0])
		m.add_capsule(pos[parent], pos[i], rad[i])

	# ---------------------------------------------------------- 2) 肺泡：六边形密排
	var cx: Array[Vector2] = []
	var cr: Array[float] = []
	var row_dy := FOAM_STEP * 0.8660254
	var cols := int((size.x - FOAM_MARGIN * 2.0) / FOAM_STEP)
	var rows := int((size.y - FOAM_MARGIN * 2.0) / row_dy)
	for j in range(rows):
		for i in range(cols):
			var x := FOAM_MARGIN + FOAM_STEP * 0.5 + float(i) * FOAM_STEP
			if j % 2 == 1:
				x += FOAM_STEP * 0.5
			var y := FOAM_MARGIN + row_dy * 0.5 + float(j) * row_dy
			var p := Vector2(
				x + rng.randf_range(-ALV_JITTER_POS, ALV_JITTER_POS),
				y + rng.randf_range(-ALV_JITTER_POS, ALV_JITTER_POS))
			p.x = clampf(p.x, 38.0, size.x - 38.0)
			p.y = clampf(p.y, 38.0, size.y - 38.0)
			var r := rng.randf_range(ALV_R_MIN, ALV_R_MAX) * rng.randf_range(1.0 - ALV_JITTER_R, 1.0 + ALV_JITTER_R)
			cx.append(p)
			cr.append(r)

	# 位置松弛：任何一对肺泡之间都要留出隔膜，否则 jitter 会把它们并成一个大腔
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
	for i in range(cx.size()):
		cx[i].x = clampf(cx[i].x, 38.0, size.x - 38.0)
		cx[i].y = clampf(cx[i].y, 38.0, size.y - 38.0)

	# 邻接表：只认紧挨着的六邻居，避免跨格连出长廊
	var adj: Array = []
	for i in range(cx.size()):
		adj.append([])
	var near := FOAM_STEP * NEIGHBOR_RANGE
	for i in range(cx.size()):
		for j in range(i + 1, cx.size()):
			if cx[i].distance_to(cx[j]) <= near:
				adj[i].append(j)
				adj[j].append(i)

	# 落单的肺泡（四周都被挤开）不要，否则会变成玩家永远进不去的死泡
	var keep: Array[int] = []
	for i in range(cx.size()):
		if not adj[i].is_empty():
			keep.append(i)

	# ---------------------------------------------------------- 3) 放肺泡本体
	for i in keep:
		m.add_circle(cx[i], cr[i])

	# ---------------------------------------------------------- 4) 随机生成树：连通但不直廊
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

	# 兜底：万一还有没接上的（松弛把图拆碎了），就近拉一条过去
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

	# 旁门：在树上加环路，让玩家可以绕后 / 被包夹
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
		_door(m, cx, cr, int(e3[0]), int(e3[1]), rng)

	# ---------------------------------------------------------- 5) 孔隙（病毒专用）
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

	m.build()

	# ---------------------------------------------------------- 6) 肉壁纹理：小肺泡
	# 纯视觉：不算流明、不参与碰撞，只让「红区」看起来像肺实质而不是石头
	# 注意：必须在 build() 之后，因为要用到掩码和距离场
	var tries := 0
	while m.decor.size() < 260 and tries < 4000:
		tries += 1
		var p := Vector2(rng.randf_range(40.0, size.x - 40.0), rng.randf_range(40.0, size.y - 40.0))
		if not m.solid_point(p):
			continue
		if m.clearance(p) < 10.0:
			continue
		var rr := rng.randf_range(9.0, 17.0)
		m.decor.append([p, rr])

	return m


# 两个肺泡之间的「门」：只铺在隔膜那一段，不从圆心铺到圆心
func _door(m: OrganMap, cx: Array[Vector2], cr: Array[float], i: int, j: int,
		rng: RandomNumberGenerator) -> void:
	var dir := (cx[j] - cx[i]).normalized()
	var pa: Vector2 = cx[i] + dir * (cr[i] - 12.0)
	var pb: Vector2 = cx[j] - dir * (cr[j] - 12.0)
	m.add_capsule(pa, pb, rng.randf_range(DUCT_R_MIN, DUCT_R_MAX))
