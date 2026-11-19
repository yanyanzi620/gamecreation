extends RefCounted
class_name LungGen
# ============================================================
# 肺地图生成器（固定骨架 + 抖动 + 左右两叶）
# ============================================================
# 结构（自上而下三层，越往下越「细」）：
#
#   0) 整体分区 —— 左叶 / 右叶 / 中间纵隔带
#      两块叶子的肺泡泡沫彼此不通，只靠中间那条「支气管主干」连起来。
#      于是整张地图天然有左右两个大战场 + 一条中间走廊（堵点）。
#
#   1) 肺泡泡沫（主力战场）—— 六边形密排圆腔，直径 ~140（玩家 44，约占肺泡面积 10%）
#      隔膜 ~46，用「随机生成树」连门：保证连通、有分叉有环路，
#      又不会像矩形网格那样连成一排排横贯全图的直走廊。
#
#   2) 支气管主干（跨叶通道 / 病毒捷径）
#      中间纵隔里一条纵向主干（半径 60），从上到下贯穿，两侧各有 3 条分支
#      打进左右叶，形成 6 个「肺门」开口。这是两叶之间唯一的玩家通道。
#
#   3) 肺泡间孔隙（病毒专用）—— 细缝 7~10，只有病毒挤得过去。
#
# 玩法含义：病毒有三条玩家走不了/绕不过的路（支气管、孔隙、跨叶主干），
#          所以「堵」比「追」重要；左右分叶让「先保哪一叶」变成真的决策。
#
# 改「块头」只看 PARAM 段，不用动算法。
# ============================================================

# ---- 肺泡泡沫 ----
# 配比口径：肺泡直径 2R ≈ 140，玩家直径 44 -> 面积占比 ≈ (22/70)^2 ≈ 10%
#           隔膜 MIN_SEPTUM ≈ 46（看得见的一层肉壁，不是实心大块）
const ALV_R_MIN := 66.0
const ALV_R_MAX := 74.0
const ALV_JITTER_POS := 14.0
const ALV_JITTER_R := 0.03
const MIN_SEPTUM := 46.0        # 隔膜必须比门宽，肉壁才连得成网
const NEIGHBOR_RANGE := 1.12    # 以格距为单位，认定「相邻」的距离

# ---- 连接管（玩家可走）----
const DUCT_R_MIN := 20.0        # 门宽 40~44：要窄于隔膜，才凿不穿墙
const DUCT_R_MAX := 22.0
const EXTRA_LINK_CHANCE := 0.22 # 生成树之外再开这么多旁门，形成环路

# ---- 孔隙（只有病毒能过）----
const PORE_R_MIN := 7.0
const PORE_R_MAX := 10.0
const PORE_RANGE := 12.0        # 两肺泡边缘间距小于这个值才可能开孔
const PORE_CHANCE := 0.45

# ---- 整体分区 ----
const LOBE_MARGIN := 46.0       # 叶边缘到场地边的距离（外面是胸膜/胸壁）
const MID_BAND := 156.0         # 中间纵隔带宽：两根支气管主干都住在这条带里
const TRUNK_R := 60.0           # 支气管主干半径（120 宽，玩家和病毒都能过）
const BRANCH_R := 42.0          # 肺门分支半径（84 宽）
const BRANCH_COUNT := 3         # 每侧分支数，形成 6 个肺门


func build(seed_value: int, size: Vector2) -> OrganMap:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var m := OrganMap.new()
	m.size = size

	# ---------------------------------------------------------- 0) 左右两叶
	# 中间留出 MID_BAND 宽的纵隔带，两叶互不相通
	var half := MID_BAND * 0.5
	var mid_x := size.x * 0.5
	var lobe_h := size.y - LOBE_MARGIN * 2.0
	_lobe(m, rng, Rect2(LOBE_MARGIN, LOBE_MARGIN, mid_x - half - LOBE_MARGIN, lobe_h))
	_lobe(m, rng, Rect2(mid_x + half, LOBE_MARGIN, size.x - LOBE_MARGIN - (mid_x + half), lobe_h))

	# ---------------------------------------------------------- 1) 支气管主干
	_airway(m, rng, size)

	m.build()

	# ---------------------------------------------------------- 2) 肉壁纹理：小肺泡
	# 纯视觉：不算流明、不参与碰撞，只让「红区」看起来像肺实质而不是石头
	# 注意：必须在 build() 之后，因为要用到掩码和距离场
	var target := clampi(int(size.x * size.y / 13000.0), 120, 460)
	var tries := 0
	while m.decor.size() < target and tries < target * 14:
		tries += 1
		var p := Vector2(rng.randf_range(30.0, size.x - 30.0), rng.randf_range(30.0, size.y - 30.0))
		if not m.solid_point(p):
			continue
		if m.clearance(p) < 12.0:
			continue
		var rr := rng.randf_range(11.0, 20.0)
		m.decor.append([p, rr])

	return m


# ============================================================ 一叶的肺泡泡沫
# 每一叶独立做：六边形密排 -> 夹在叶内 -> 位置松弛 -> 邻接表 -> 随机生成树 -> 门 -> 孔隙
func _lobe(m: OrganMap, rng: RandomNumberGenerator, rect: Rect2) -> void:
	# 按叶子的实际尺寸均分开，保证铺满（不留右下角空地）
	var step: float = ALV_R_MAX * 2.0 + MIN_SEPTUM
	var row_dy := step * 0.8660254
	var cols := maxi(1, int(rect.size.x / step))
	var rows := maxi(1, int(rect.size.y / row_dy))
	var dx := rect.size.x / float(cols)
	var dy := rect.size.y / float(rows)
	if cols < 2 or rows < 2:
		return

	var cx: Array[Vector2] = []
	var cr: Array[float] = []
	for j in range(rows):
		for i in range(cols):
			var x := rect.position.x + dx * (float(i) + 0.5)
			if j % 2 == 1:
				x += dx * 0.5
			var y := rect.position.y + dy * (float(j) + 0.5)
			var p := Vector2(
				x + rng.randf_range(-ALV_JITTER_POS, ALV_JITTER_POS),
				y + rng.randf_range(-ALV_JITTER_POS, ALV_JITTER_POS))
			var r := rng.randf_range(ALV_R_MIN, ALV_R_MAX) * rng.randf_range(1.0 - ALV_JITTER_R, 1.0 + ALV_JITTER_R)
			cx.append(p)
			cr.append(r)

	# 圆不能越出叶边界（叶外是胸膜，没有流明）
	for i in range(cx.size()):
		_clamp_in(cx, cr, i, rect)

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
		for i in range(cx.size()):
			_clamp_in(cx, cr, i, rect)
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

	# 落单的肺泡（四周都被挤开）不要，否则会变成玩家永远进不去的死泡
	var keep: Array[int] = []
	for i in range(cx.size()):
		if not adj[i].is_empty():
			keep.append(i)
	if keep.size() < 3:
		return

	# 肺泡本体
	for i in keep:
		m.add_circle(cx[i], cr[i])

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


# 把第 i 个圆夹进叶矩形（留 6px 缓冲，避免贴在边界上产生零厚度的薄墙）
func _clamp_in(cx: Array[Vector2], cr: Array[float], i: int, rect: Rect2) -> void:
	var pad: float = cr[i] + 6.0
	cx[i].x = clampf(cx[i].x, rect.position.x + pad, rect.end.x - pad)
	cx[i].y = clampf(cx[i].y, rect.position.y + pad, rect.end.y - pad)


# 两个肺泡之间的「门」：只铺在隔膜那一段，不从圆心铺到圆心
func _door(m: OrganMap, cx: Array[Vector2], cr: Array[float], i: int, j: int,
		rng: RandomNumberGenerator) -> void:
	var dir := (cx[j] - cx[i]).normalized()
	var pa: Vector2 = cx[i] + dir * (cr[i] - 14.0)
	var pb: Vector2 = cx[j] - dir * (cr[j] - 14.0)
	m.add_capsule(pa, pb, rng.randf_range(DUCT_R_MIN, DUCT_R_MAX))


# ============================================================ 中间支气管主干
# 纵向主干贯穿全场（两叶之间唯一的玩家通道），两侧各开 3 个肺门打进叶里
func _airway(m: OrganMap, rng: RandomNumberGenerator, size: Vector2) -> void:
	var mid_x := size.x * 0.5
	var top := 78.0
	var bot := size.y - 64.0

	# 气管入口（喇叭口）：不要顶到场地边，否则轮廓会被切开（自测 B9 会报开口）
	m.add_circle(Vector2(mid_x, top + 30.0), TRUNK_R + 26.0)

	# 主干：上粗下细、带轻微摆动 —— 一根笔直等粗的柱子看起来像墙不像气道
	var segs := 7
	var prev := Vector2(mid_x, top)
	for k in range(1, segs + 1):
		var t := float(k) / float(segs)
		var y := lerpf(top, bot * 0.94, t)
		var x := mid_x + sin(t * 3.1) * 22.0 + rng.randf_range(-6.0, 6.0)
		var r := lerpf(TRUNK_R, TRUNK_R * 0.62, t)
		m.add_capsule(prev, Vector2(x, y), r)
		prev = Vector2(x, y)

	# 肺门分支：从主干斜插进左右叶
	var reach := MID_BAND * 0.5 + ALV_R_MAX + 86.0
	for k in range(BRANCH_COUNT):
		var t := (float(k) + 0.5) / float(BRANCH_COUNT)
		var y := size.y * (0.18 + 0.64 * t)
		var dy := rng.randf_range(-18.0, 18.0)
		m.add_capsule(Vector2(mid_x, y), Vector2(mid_x - reach, y + dy), BRANCH_R)
		m.add_capsule(Vector2(mid_x, y), Vector2(mid_x + reach, y - dy), BRANCH_R)
