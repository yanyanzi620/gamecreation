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
# 肺泡放大 + 数量减少：单个腔室更大，地形不那么破碎，也不那么崎岖
const ALV_R_MIN := 110.0
const ALV_R_MAX := 136.0
const ALV_JITTER_POS := 20.0
const ALV_JITTER_R := 0.06
const HUB_R := 158.0             # 少量大叶泡：能展开走位的「主战厅」，不是全都一样大
const MIN_SEPTUM := 62.0        # 隔膜必须比门宽，肉壁才连得成网（肺泡变大，隔膜同步加厚）
const NEIGHBOR_RANGE := 1.18    # 以节距为单位，认定「相邻」的距离

# ---- 连接管（玩家可走）----
# 门宽随机：细门只够玩家侧身挤过，粗门能让病毒整股涌进去 —— 同一张图里有宽有窄才有机动感。
# 下限按玩家碰撞半径卡死（0.72 * PLAYER_R(30) = 21.6），再小玩家就永远过不去。
const DUCT_R_MIN := 34.0        # 门宽 68：一个大肺泡配一条像样的通道，不再是细缝
const DUCT_R_MAX := 56.0        # 门宽 112：主通道，扩散会顺着它走
const EXTRA_LINK_CHANCE := 0.38 # 生成树之外再开这么多旁门，形成环路
const MAX_DOOR_GAP := 184.0     # 两腔室之间最远还能开门的空隙。
                                # 按新节距 334、邻接上限 1.18 倍反推，最坏间隙约 174；
                                # 留 10 单位余量，避免大半径/主战厅种子把生成树边砍掉形成孤岛。

# ---- 孔隙（只有病毒能过）----
const PORE_R_MIN := 12.0
const PORE_R_MAX := 20.0
const PORE_RANGE := 20.0
const PORE_CHANCE := 0.45

# ---- 支气管主干 ----
const TRUNK_R := 96.0           # 气管半径（192 宽）
const BRANCH_R := 64.0          # 肺门分支半径（128 宽）
const BRANCH_COUNT := 3         # 每侧分支数，合计 6 个肺门

# ---- 器官轮廓（按 6200×2300 设计，运行时按实际尺寸缩放）----
# 不再用一排水平胶囊拼肺叶：胶囊交界处会形成台阶和硬凹角。
# 这里给左叶一圈控制点，Catmull-Rom 采样成连续多边形，右叶镜像；
# 内侧肺门有凹口，外缘从上段宽阔逐渐收到下段，通道仍由 _airway 接到这个轮廓上。
const SIL_BASE := Vector2(6200.0, 2300.0)
const SIL_FLIP_Y := false          # true = 换回解剖学上「肺尖窄、肺底宽」
const SIL_LEFT := [
	[2490.0, 210.0], [2100.0, 175.0], [1500.0, 180.0], [900.0, 220.0],
	[610.0, 330.0], [500.0, 570.0], [450.0, 900.0], [430.0, 1240.0],
	[470.0, 1510.0], [570.0, 1760.0], [740.0, 1970.0], [990.0, 2140.0],
	[1240.0, 2190.0], [1480.0, 2110.0], [1690.0, 1930.0], [1870.0, 1690.0],
	[2070.0, 1430.0], [2260.0, 1150.0], [2280.0, 980.0], [2150.0, 855.0],
	[2200.0, 720.0], [2400.0, 520.0], [2560.0, 330.0],
]

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
	var cy := SIL_BASE.y * 0.5
	var ctrl: Array[Vector2] = []
	for n in SIL_LEFT:
		var y := float(n[1])
		if SIL_FLIP_Y:
			y = cy * 2.0 - y
		ctrl.append(Vector2(float(n[0]) * kx, y * ky))
	var left := _smooth_closed(ctrl, 5)
	var right := PackedVector2Array()
	for p in left:
		right.append(Vector2(size.x - p.x, p.y))
	m.add_clip_polygon(left)
	m.add_clip_polygon(right)
	# 中间只有左右两叶之间的体腔，不放任何轮廓


# 闭合 Catmull-Rom：控制点只决定大形，采样点负责把外缘变连续。
# 每段 5 个采样足够平滑，又不会让胸膜距离查询变得昂贵。
func _smooth_closed(ctrl: Array[Vector2], steps: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := ctrl.size()
	for i in range(n):
		var p0 := ctrl[(i - 1 + n) % n]
		var p1 := ctrl[i]
		var p2 := ctrl[(i + 1) % n]
		var p3 := ctrl[(i + 2) % n]
		for k in range(steps):
			var t := float(k) / float(steps)
			var t2 := t * t
			var t3 := t2 * t
			out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t +
				(2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
				(-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	return out


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

	# 每叶两个「主战厅」：肺门附近一个、深部一个。
	# 大空间用来走位和清群，小肺泡与窄门仍然负责节奏和绕行，不再是一张均匀蜂窝。
	var hub_targets := [
		rect.position + Vector2(rect.size.x * 0.58, rect.size.y * 0.30),
		rect.position + Vector2(rect.size.x * 0.48, rect.size.y * 0.73),
	]
	for target in hub_targets:
		var hi := _nearest_point(cx, target)
		if hi >= 0:
			cr[hi] = minf(HUB_R, m.clip_inside_dist(cx[hi]) * 0.90)

	if cx.size() < 4:
		return

	# 位置松弛：任何一对肺泡之间都要留出隔膜
	for _it in range(7):
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
		_alv_detail(m, rng, cx[i], cr[i])

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
		if cx[int(e3[0])].distance_to(cx[int(e3[1])]) - cr[int(e3[0])] - cr[int(e3[1])] > MAX_DOOR_GAP:
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


# 单个肺泡的腔室内装饰（纯视觉）。注意：全部画在圆内，不碰墙、不参与碰撞。
#   间隔小突：从壁往腔内伸的一小段（真实肺泡的肺泡间隔上就有这种突起）
#   毛细血管弧：贴着腔壁走的一圈线，给平坦的腔室一点「体内」的感觉
#   上皮斑点：腔内散布的小点，压住死平的色块
func _alv_detail(m: OrganMap, rng: RandomNumberGenerator, c: Vector2, r: float) -> void:
	var k: float = r / 126.0                     # 跟着肺泡尺寸缩放，大肺泡的装饰也大
	# 沿壁短弧：让腔壁看起来是「有厚度的间隔」，而不是一根发亮的等高线
	var rims := int(rng.randi_range(3, 6))
	for s in range(rims):
		var a0 := rng.randf() * TAU
		var span := rng.randf_range(0.22, 0.55)
		var pts0 := PackedVector2Array()
		for i in range(7):
			var t0 := float(i) / 6.0
			var aa0 := a0 + span * t0
			pts0.append(c + Vector2(cos(aa0), sin(aa0)) * (r * 0.94))
		m.detail.append([pts0, 0])

	# 间隔小突：从壁上往腔内伸的一段（起点落在 r + 8，压到墙线上去，看起来是「从墙上长出来」）。
	# 数量少、伸得长、带弧度 —— 短而直的线看起来像划痕，长而弯的才像肉。
	var spurs := int(rng.randi_range(2, 4))
	for s in range(spurs):
		var a1 := rng.randf() * TAU
		var deep := rng.randf_range(0.30, 0.55) * r    # 伸进去多深
		var bend := rng.randf_range(-0.26, 0.26)
		var pts := PackedVector2Array()
		for i in range(7):
			var t := float(i) / 6.0
			var aa := a1 + bend * t * t
			pts.append(c + Vector2(cos(aa), sin(aa)) * ((r + 8.0) - (deep + 8.0) * t))
		m.detail.append([pts, 0])

	# 隔膜弦线：跨过腔室的一道浅弧（真实肺里肺泡之间本来就有薄间隔横在其中），
	# 作用是把大片空腔切成"有结构"的几块，压掉死平感
	var chords := int(rng.randi_range(1, 2))
	for s in range(chords):
		var c0 := rng.randf() * TAU
		var cspan := rng.randf_range(0.9, 1.9)
		var lift := rng.randf_range(0.55, 0.85)
		var pts3 := PackedVector2Array()
		for i in range(9):
			var t3 := float(i) / 8.0
			var aa3 := c0 + cspan * t3
			# 从壁上的 A 点，经腔内，再到壁上的 B 点：半径按抛物线收进去
			var rr3 := r * (1.0 - lift * sin(t3 * PI) * 0.55)
			pts3.append(c + Vector2(cos(aa3), sin(aa3)) * rr3)
		m.detail.append([pts3, 2])

	var caps := int(rng.randi_range(2, 4))
	for s in range(caps):
		var a2 := rng.randf() * TAU
		var span2 := rng.randf_range(0.5, 1.4)
		var rr := r * rng.randf_range(0.55, 0.82)
		var pts2 := PackedVector2Array()
		for i in range(12):
			var t2 := float(i) / 11.0
			var aa2 := a2 + span2 * t2
			# 加点径向抖动，别让它们像同心圆
			var wob := r * 0.03 * sin(t2 * 6.0)
			pts2.append(c + Vector2(cos(aa2), sin(aa2)) * (rr + wob))
		m.detail.append([pts2, 1])

	var specks := int(rng.randi_range(5, 11))
	for s in range(specks):
		var ang := rng.randf() * TAU
		var rr2 := r * sqrt(rng.randf()) * 0.88
		var p := c + Vector2(cos(ang), sin(ang)) * rr2
		var dir := Vector2(cos(ang + 1.4), sin(ang + 1.4)) * rng.randf_range(1.6, 3.4) * k
		m.detail.append([PackedVector2Array([p, p + dir]), 2])


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
	# 连到主战厅的门至少是一条主路：大厅不能只能靠侧身小门进出。
	if maxf(cr[i], cr[j]) >= HUB_R * 0.90:
		dr = maxf(dr, minf(50.0, minf(cr[i], cr[j]) * 0.42))
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
			var route_end := t1
			# 第二条分支：从肺门再往里走一段，多一个入口
			var t2b := _nearest_alv(hilar + Vector2(side * 150.0 * kx, size.y * 0.14))
			if t2b != Vector2.INF and t2b.distance_to(t1) > 120.0:
				m.add_capsule(t1, t2b, BRANCH_R * 0.85)
				m.add_clip_capsule(t1, t2b, BRANCH_R + 40.0)
				route_end = t2b
			# 第三条较窄的深部支路：给玩家跨区绕行路线，也给病毒一条捷径。
			var t3 := _nearest_alv(hilar + Vector2(side * 220.0 * kx, size.y * 0.34))
			if t3 != Vector2.INF and t3.distance_to(route_end) > 180.0:
				m.add_capsule(route_end, t3, BRANCH_R * 0.68)
				m.add_clip_capsule(route_end, t3, BRANCH_R + 24.0)


func _nearest_point(points: Array[Vector2], probe: Vector2) -> int:
	var best := -1
	var bd := 1.0e20
	for i in range(points.size()):
		var d := points[i].distance_squared_to(probe)
		if d < bd:
			bd = d
			best = i
	return best


func _nearest_alv(probe: Vector2) -> Vector2:
	var best := Vector2.INF
	var bd := 1.0e9
	for a in _alv:
		var d: float = float(a[0].distance_to(probe))
		if d < bd:
			bd = d
			best = a[0]
	return best
