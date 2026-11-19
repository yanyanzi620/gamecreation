extends RefCounted
class_name OrganMap
# ============================================================
# 器官地图 —— 生成结果 + 运行时查询
# ============================================================
# 生成侧思路（重要）：
#   不直接摆墙，而是先摆「流明」（可通行区域）的并集 —— 圆和胶囊。
#   取这个并集的边界，就是墙。所以「挖圆形」和「摆平行墙」是同一套算法，
#   差别只在用哪些形状去拼流明。肾小管就是「沿骨架扫掠的胶囊」，同一套代码。
#
# 运行时三件套：
#   · loops   闭合轮廓（世界坐标），给渲染 / 未来美术用
#   · 墙段    扁平数组 + 粗格分桶，给玩家与病毒做「能否穿过」判定
#   · 掩码    10 像素一格的「实心/流明」+ 到墙的距离场，给点查询与出生采样
#
# 为什么用距离场：判断「玩家身体能不能通过」不能只看中心点，
# 需要知道这一点离墙有多远。距离场一次算好，之后连通性体检、出生点采样都是 O(1)。
# ============================================================

const CELL := 30.0        # 墙段分桶用的粗格（与病毒种群同格）
const PIX := 8.0          # 掩码 / 距离场的分辨率
const SIMPLIFY_EPS := 2.0 # 轮廓简化容差（像素）
const CONTOUR_STEP := 20.0 # 轮廓采样步长（比 CELL 细，边缘更圆）
const SHAPE_CELL := 64.0   # 形状索引粗格（加速 sdf 查询）

var size := Vector2(1600.0, 1000.0)

var loops: Array = []              # Array[PackedVector2Array]  可通行区的轮廓（肉壁）
var clip_loops: Array = []         # 器官外轮廓（胸膜线），纯视觉：让人一眼看出这是肺
var _clip_closed: Array = []
var open_loop_count := 0           # 未闭合轮廓数（>0 说明地图被场地边界切开了）
var seg_a := PackedVector2Array()
var seg_b := PackedVector2Array()

var decor: Array = []              # 纯视觉装饰：[中心, 半径]，不参与碰撞
var build_ms := 0
var free_ratio := 0.0
var shape_count := 0

# 器官外形：流明会被裁进这些形状的并集里。
# 不给就是整块矩形场地；给了就是「肺 / 肾 / 心」本来的那个轮廓。
var clip_shapes: Array = []
var organ_bounds := Rect2()        # 器官（可通行区）包围盒，相机限位用

var _shapes: Array = []            # [kind, a, b, r]，kind 0 = 圆，1 = 胶囊
var _in := PackedByteArray()       # 1 = 在器官外形内
var _buckets := {}                 # 粗格索引 -> Array[int]
var _sidx := {}                    # 形状索引：粗格 -> Array[int]
var _sw := 0
var _sh := 0
var _loop_closed: Array = []       # 与 loops 一一对应：该轮廓是否闭合
var _bw := 0
var _bh := 0
var _solid := PackedByteArray()    # 1 = 实心组织
var _dist := PackedFloat32Array()  # 到实心组织的距离（像素）
var _mw := 0
var _mh := 0
var _walk_main := PackedByteArray()   # 1 = 属于主连通块（玩家出生 / 病毒播种只认这里）
var _walk_th := -1.0

# ------------------------------------------------------------ 形状

func add_circle(c: Vector2, r: float) -> void:
	_shapes.append([0, c, c, r])


# 器官外形（裁剪用）：只管轮廓，不会自己变成流明
func add_clip_circle(c: Vector2, r: float) -> void:
	clip_shapes.append([0, c, c, r])


func add_clip_capsule(a: Vector2, b: Vector2, r: float) -> void:
	clip_shapes.append([1, a, b, r])


func add_capsule(a: Vector2, b: Vector2, r: float) -> void:
	_shapes.append([1, a, b, r])


# 有符号距离：负 = 流明内部。只在生成期用（顶点采样 / 采点），不在每帧用。
# 走形状索引：只算附近那几个形状，轮廓采样从「O(形状数)」变成「O(1)」。
func sdf(p: Vector2) -> float:
	if _sidx.is_empty():
		return _sdf_full(p)
	var best := 1.0e9
	var key := _sidx_key(p)
	if _sidx.has(key):
		for si in _sidx[key]:
			var sh = _shapes[si]
			var d := 0.0
			if sh[0] == 0:
				d = p.distance_to(sh[1]) - float(sh[3])
			else:
				d = _pt_seg_dist(p, sh[1], sh[2]) - float(sh[3])
			if d < best:
				best = d
	return best


func _sdf_full(p: Vector2) -> float:
	var best := 1.0e9
	for sh in _shapes:
		var d := 0.0
		if sh[0] == 0:
			d = p.distance_to(sh[1]) - float(sh[3])
		else:
			d = _pt_seg_dist(p, sh[1], sh[2]) - float(sh[3])
		if d < best:
			best = d
	return best


func _sidx_key(p: Vector2) -> int:
	var i := int(clampf(p.x / SHAPE_CELL, 0.0, float(_sw - 1)))
	var j := int(clampf(p.y / SHAPE_CELL, 0.0, float(_sh - 1)))
	return j * _sw + i


func _build_shape_index() -> void:
	_sw = maxi(1, int(ceil(size.x / SHAPE_CELL)))
	_sh = maxi(1, int(ceil(size.y / SHAPE_CELL)))
	_sidx.clear()
	for si in range(_shapes.size()):
		var sh = _shapes[si]
		var r := float(sh[3])
		var box := Rect2(sh[1], Vector2.ZERO).expand(sh[2]).grow(r + SHAPE_CELL)
		var i0 := clampi(int(box.position.x / SHAPE_CELL), 0, _sw - 1)
		var i1 := clampi(int((box.position.x + box.size.x) / SHAPE_CELL), 0, _sw - 1)
		var j0 := clampi(int(box.position.y / SHAPE_CELL), 0, _sh - 1)
		var j1 := clampi(int((box.position.y + box.size.y) / SHAPE_CELL), 0, _sh - 1)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var key := j * _sw + i
				if not _sidx.has(key):
					_sidx[key] = []
				_sidx[key].append(si)


func _pt_seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# ------------------------------------------------------------ 构建

func build() -> void:
	var t0 := Time.get_ticks_msec()
	shape_count = _shapes.size()
	_rasterize()
	_compute_bounds()
	_distance_field()
	_build_shape_index()
	_build_contours()
	_build_buckets()
	build_ms = Time.get_ticks_msec() - t0


# 直接按形状往掩码里刷（比逐格算 sdf 快一个数量级）
func _rasterize() -> void:
	_mw = int(ceil(size.x / PIX))
	_mh = int(ceil(size.y / PIX))
	_solid.resize(_mw * _mh)
	_solid.fill(1)
	for s in _shapes:
		var r := float(s[3])
		var aabb := Rect2(s[1], Vector2.ZERO).expand(s[2]).grow(r)
		var i0 := clampi(int(aabb.position.x / PIX), 0, _mw - 1)
		var i1 := clampi(int((aabb.position.x + aabb.size.x) / PIX), 0, _mw - 1)
		var j0 := clampi(int(aabb.position.y / PIX), 0, _mh - 1)
		var j1 := clampi(int((aabb.position.y + aabb.size.y) / PIX), 0, _mh - 1)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var p := Vector2((float(i) + 0.5) * PIX, (float(j) + 0.5) * PIX)
				var inside := false
				if s[0] == 0:
					inside = p.distance_squared_to(s[1]) <= r * r
				else:
					inside = _pt_seg_dist(p, s[1], s[2]) <= r
				if inside and _solid[j * _mw + i] == 1:
					_solid[j * _mw + i] = 0

	# 器官外层裁剪：不在器官轮廓里的格子一律算实心（胸壁 / 体腔）
	if not clip_shapes.is_empty():
		_rasterize_clip()
		for k in range(_solid.size()):
			if _solid[k] == 0 and _in[k] == 0:
				_solid[k] = 1

	var free := 0
	for k in range(_solid.size()):
		if _solid[k] == 0:
			free += 1
	free_ratio = float(free) / float(_solid.size())


# 器官轮廓刷成 _in 掩码（1 = 在器官内）
func _rasterize_clip() -> void:
	_in.resize(_mw * _mh)
	_in.fill(0)
	for s in clip_shapes:
		var r2 := float(s[3])
		var aabb2 := Rect2(s[1], Vector2.ZERO).expand(s[2]).grow(r2)
		var a0 := clampi(int(aabb2.position.x / PIX), 0, _mw - 1)
		var a1 := clampi(int((aabb2.position.x + aabb2.size.x) / PIX), 0, _mw - 1)
		var b0 := clampi(int(aabb2.position.y / PIX), 0, _mh - 1)
		var b1 := clampi(int((aabb2.position.y + aabb2.size.y) / PIX), 0, _mh - 1)
		for j in range(b0, b1 + 1):
			for i in range(a0, a1 + 1):
				var p2 := Vector2((float(i) + 0.5) * PIX, (float(j) + 0.5) * PIX)
				var ins := false
				if s[0] == 0:
					ins = p2.distance_squared_to(s[1]) <= r2 * r2
				else:
					ins = _pt_seg_dist(p2, s[1], s[2]) <= r2
				if ins:
					_in[j * _mw + i] = 1


# 到器官外边界的距离（0 = 在轮廓上，>0 = 在外），用于「不要把肺泡摆到体外」
func clip_sdf(p: Vector2) -> float:
	if clip_shapes.is_empty():
		return -1.0
	var best := 1.0e9
	for s in clip_shapes:
		var d := 0.0
		if s[0] == 0:
			d = maxf(0.0, p.distance_to(s[1]) - float(s[3]))
		else:
			d = maxf(0.0, _pt_seg_dist(p, s[1], s[2]) - float(s[3]))
		best = minf(best, d)
	return best


# 该格是否在器官轮廓内（build 之后可用）
# 从器官内部某点到「器官边界」的距离（不在器官内返回 -1）。
# 用于生成器：贴边的肺泡按这个距离缩径，于是肺泡能一直铺到胸膜，边缘不是锯齿。
func clip_inside_dist(p: Vector2) -> float:
	if clip_shapes.is_empty():
		return 1.0e9
	var best := -1.0e9
	for s in clip_shapes:
		var kind: int = int(s[0])
		var d := 0.0
		if kind == 0:
			d = (p as Vector2).distance_to(s[1] as Vector2)
		else:
			d = _dist_point_seg(p, s[1] as Vector2, s[2] as Vector2)
		var inside: float = float(s[3]) - d
		if inside > best:
			best = inside
	return best


func _dist_point_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func in_organ_cell(i: int, j: int) -> bool:
	if _in.is_empty():
		return true
	if i < 0 or j < 0 or i >= _mw or j >= _mh:
		return false
	return _in[j * _mw + i] == 1


# 可通行区的包围盒（相机限位 / 小地图用）
func _compute_bounds() -> void:
	var mn := Vector2(1.0e9, 1.0e9)
	var mx := Vector2(-1.0e9, -1.0e9)
	for j in range(_mh):
		for i in range(_mw):
			if _solid[j * _mw + i] != 0:
				continue
			var p := Vector2(float(i) * PIX, float(j) * PIX)
			mn.x = minf(mn.x, p.x)
			mn.y = minf(mn.y, p.y)
			mx.x = maxf(mx.x, p.x + PIX)
			mx.y = maxf(mx.y, p.y + PIX)
	if mn.x > mx.x:
		organ_bounds = Rect2(Vector2.ZERO, size)
	else:
		organ_bounds = Rect2(mn, mx - mn)


# 两遍倒角距离变换：每个格子到最近实心格的距离（像素）
func _distance_field() -> void:
	_dist.resize(_mw * _mh)
	var inf := 1.0e6
	for j in range(_mh):
		for i in range(_mw):
			_dist[j * _mw + i] = 0.0 if _solid[j * _mw + i] == 1 else inf
	var d1 := PIX
	var d2 := PIX * 1.41421356
	for j in range(_mh):
		for i in range(_mw):
			var idx := j * _mw + i
			var v := _dist[idx]
			if i > 0:
				v = minf(v, _dist[idx - 1] + d1)
			if j > 0:
				v = minf(v, _dist[idx - _mw] + d1)
			if i > 0 and j > 0:
				v = minf(v, _dist[idx - _mw - 1] + d2)
			if i + 1 < _mw and j > 0:
				v = minf(v, _dist[idx - _mw + 1] + d2)
			_dist[idx] = v
	for j in range(_mh - 1, -1, -1):
		for i in range(_mw - 1, -1, -1):
			var idx2 := j * _mw + i
			var v2 := _dist[idx2]
			if i + 1 < _mw:
				v2 = minf(v2, _dist[idx2 + 1] + d1)
			if j + 1 < _mh:
				v2 = minf(v2, _dist[idx2 + _mw] + d1)
			if i + 1 < _mw and j + 1 < _mh:
				v2 = minf(v2, _dist[idx2 + _mw + 1] + d2)
			if i > 0 and j + 1 < _mh:
				v2 = minf(v2, _dist[idx2 + _mw - 1] + d2)
			_dist[idx2] = v2


# 行进方块（marching squares）：在顶点网格上采 sdf，取 0 等值线
func _build_contours() -> void:
	var w := int(ceil(size.x / CONTOUR_STEP))
	var h := int(ceil(size.y / CONTOUR_STEP))
	var vx := w + 1
	var vy := h + 1
	var vals := PackedFloat32Array()
	vals.resize(vx * vy)
	for j in range(vy):
		for i in range(vx):
			vals[j * vx + i] = sdf(Vector2(float(i) * CONTOUR_STEP, float(j) * CONTOUR_STEP))

	var segs: Array = []
	for j in range(h):
		for i in range(w):
			var a := vals[j * vx + i]
			var b := vals[j * vx + i + 1]
			var c := vals[(j + 1) * vx + i + 1]
			var d := vals[(j + 1) * vx + i]
			var x0 := float(i) * CONTOUR_STEP
			var y0 := float(j) * CONTOUR_STEP

			var pts: Array = []
			if (a < 0.0) != (b < 0.0):
				pts.append([0, Vector2(x0 + CONTOUR_STEP * (a / (a - b)), y0)])
			if (b < 0.0) != (c < 0.0):
				pts.append([1, Vector2(x0 + CONTOUR_STEP, y0 + CONTOUR_STEP * (b / (b - c)))])
			if (d < 0.0) != (c < 0.0):
				pts.append([2, Vector2(x0 + CONTOUR_STEP * (d / (d - c)), y0 + CONTOUR_STEP)])
			if (a < 0.0) != (d < 0.0):
				pts.append([3, Vector2(x0, y0 + CONTOUR_STEP * (a / (a - d)))])

			if pts.size() == 2:
				segs.append([pts[0][1], pts[1][1]])
			elif pts.size() == 4:
				var center_inside := ((a + b + c + d) * 0.25) < 0.0
				if center_inside:
					segs.append([pts[0][1], pts[1][1]])
					segs.append([pts[2][1], pts[3][1]])
				else:
					segs.append([pts[0][1], pts[3][1]])
					segs.append([pts[1][1], pts[2][1]])

	loops = []
	_loop_closed = []
	open_loop_count = 0
	for item in _split_pinches(_stitch(segs)):
		var lp: PackedVector2Array = item[0]
		loops.append(lp)
		_loop_closed.append(item[1])
		if not item[1]:
			open_loop_count += 1


# 器官外轮廓（胸膜线）：对 clip_inside_dist 取 0 等值线，和肉壁轮廓同一套行进方块。
# 只用于渲染 —— 让「这是一片肺叶」的形状成立，而不是一团毛边。
func build_clip_contours() -> void:
	clip_loops = []
	_clip_closed = []
	if clip_shapes.is_empty():
		return
	var step := 32.0
	var w := int(ceil(size.x / step))
	var h := int(ceil(size.y / step))
	var vx := w + 1
	var vy := h + 1
	var vals := PackedFloat32Array()
	vals.resize(vx * vy)
	for j in range(vy):
		for i in range(vx):
			vals[j * vx + i] = -clip_inside_dist(Vector2(float(i) * step, float(j) * step))

	var segs: Array = []
	for j in range(h):
		for i in range(w):
			var a := vals[j * vx + i]
			var b := vals[j * vx + i + 1]
			var c := vals[(j + 1) * vx + i + 1]
			var d := vals[(j + 1) * vx + i]
			var x0 := float(i) * step
			var y0 := float(j) * step
			var pts: Array = []
			if (a < 0.0) != (b < 0.0):
				pts.append([0, Vector2(x0 + step * (a / (a - b)), y0)])
			if (b < 0.0) != (c < 0.0):
				pts.append([1, Vector2(x0 + step, y0 + step * (b / (b - c)))])
			if (d < 0.0) != (c < 0.0):
				pts.append([2, Vector2(x0 + step * (d / (d - c)), y0 + step)])
			if (a < 0.0) != (d < 0.0):
				pts.append([3, Vector2(x0, y0 + step * (a / (a - d)))])
			if pts.size() == 2:
				segs.append([pts[0][1], pts[1][1]])
			elif pts.size() == 4:
				var center_inside := ((a + b + c + d) * 0.25) < 0.0
				if center_inside:
					segs.append([pts[0][1], pts[1][1]])
					segs.append([pts[2][1], pts[3][1]])
				else:
					segs.append([pts[0][1], pts[3][1]])
					segs.append([pts[1][1], pts[2][1]])

	for item in _split_pinches(_stitch(segs)):
		var lp: PackedVector2Array = item[0]
		if lp.size() < 3:
			continue
		clip_loops.append(lp)
		_clip_closed.append(item[1])


func clip_loop_is_closed(i: int) -> bool:
	return i >= 0 and i < _clip_closed.size() and bool(_clip_closed[i])


# 行进方块在鞍点处会让两条子轮廓在一个点上相触，
# 拼出来的环就会「自相切」——Godot 的三角化不认这种多边形（填不出来）。
# 这里把自切环在对触点处拆成两个简单环。
func _split_pinches(src: Array) -> Array:
	var out: Array = []
	for item in src:
		_split_one(item[0], item[1], 0, out)
	return out


# 行进方块在鞍点会让一条轮廓「自相切」，Godot 三角化不认这种多边形。
# 在对触点处把它拆成两个简单环；拆分出来的两条继承原来的闭合性。
func _split_one(arr: PackedVector2Array, closed: bool, depth: int, out: Array) -> void:
	if arr.size() < 4 or depth > 8:
		return
	var seen := {}
	for i in range(arr.size()):
		var k := _key(arr[i])
		if seen.has(k):
			var j: int = seen[k]
			var a := arr.slice(j, i)
			var b := PackedVector2Array()
			for t in range(i, arr.size()):
				b.append(arr[t])
			for t in range(0, j):
				b.append(arr[t])
			_split_one(a, closed, depth + 1, out)
			_split_one(b, closed, depth + 1, out)
			return
		seen[k] = i
	out.append([arr, closed])


# 把零散线段拼成折线。返回值：Array[ [PackedVector2Array, bool 是否闭合] ]
# 闭合标记很重要：不闭合的折线一旦被当成环，就会多出一条「首尾连线」的假墙。
func _stitch(segs: Array) -> Array:
	var pts := {}
	var adj := {}
	for sg in segs:
		var ka := _key(sg[0])
		var kb := _key(sg[1])
		if ka == kb:
			continue
		pts[ka] = sg[0]
		pts[kb] = sg[1]
		if not adj.has(ka):
			adj[ka] = []
		if not adj.has(kb):
			adj[kb] = []
		adj[ka].append(kb)
		adj[kb].append(ka)

	var visited := {}
	var out: Array = []
	for start in adj.keys():
		if visited.has(start):
			continue
		var loop := PackedVector2Array()
		var prev = null
		var cur = start
		var closed := false
		while true:
			loop.append(pts[cur])
			visited[cur] = true
			var nxt = null
			for n in adj[cur]:
				if n != prev and not visited.has(n):
					nxt = n
					break
			if nxt == null:
				closed = cur != start and adj[cur].has(start) and loop.size() >= 4
				break
			prev = cur
			cur = nxt
			if cur == start:
				closed = true
				break
		if loop.size() >= 6:
			var simp := _rdp(loop, SIMPLIFY_EPS)
			if simp.size() >= 4:
				out.append([simp, closed])
	return out


func _key(p: Vector2) -> Vector2:
	return Vector2(roundf(p.x * 100.0) * 0.01, roundf(p.y * 100.0) * 0.01)


func _rdp(pts: PackedVector2Array, eps: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var keep := PackedByteArray()
	keep.resize(n)
	keep.fill(0)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: Array = [[0, n - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var i0: int = seg[0]
		var i1: int = seg[1]
		var best := -1.0
		var bi := -1
		for k in range(i0 + 1, i1):
			var d := _pt_seg_dist(pts[k], pts[i0], pts[i1])
			if d > best:
				best = d
				bi = k
		if bi >= 0 and best > eps:
			keep[bi] = 1
			stack.append([i0, bi])
			stack.append([bi, i1])
	var out := PackedVector2Array()
	for i in range(n):
		if keep[i] == 1:
			out.append(pts[i])
	return out


func _build_buckets() -> void:
	_bw = int(ceil(size.x / CELL))
	_bh = int(ceil(size.y / CELL))
	seg_a = PackedVector2Array()
	seg_b = PackedVector2Array()
	_buckets.clear()
	for li in range(loops.size()):
		var loop: PackedVector2Array = loops[li]
		var n: int = loop.size()
		var closed: bool = _loop_closed[li] if li < _loop_closed.size() else false
		var pairs: int = n if closed else n - 1
		for i in range(pairs):
			var a: Vector2 = loop[i]
			var b: Vector2 = loop[(i + 1) % n]
			if a.distance_squared_to(b) < 4.0:
				continue
			var idx: int = seg_a.size()
			seg_a.append(a)
			seg_b.append(b)
			var r := Rect2(a, Vector2.ZERO).expand(b).grow(CELL * 0.5)
			var i0 := clampi(int(r.position.x / CELL), 0, _bw - 1)
			var i1 := clampi(int((r.position.x + r.size.x) / CELL), 0, _bw - 1)
			var j0 := clampi(int(r.position.y / CELL), 0, _bh - 1)
			var j1 := clampi(int((r.position.y + r.size.y) / CELL), 0, _bh - 1)
			for j in range(j0, j1 + 1):
				for ii in range(i0, i1 + 1):
					var key := j * _bw + ii
					if not _buckets.has(key):
						_buckets[key] = []
					_buckets[key].append(idx)


# ------------------------------------------------------------ 运行时查询

# 线段 a->b 是否穿墙
func blocked(a: Vector2, b: Vector2) -> bool:
	var r := Rect2(a, Vector2.ZERO).expand(b)
	var i0 := clampi(int(r.position.x / CELL), 0, _bw - 1)
	var i1 := clampi(int((r.position.x + r.size.x) / CELL), 0, _bw - 1)
	var j0 := clampi(int(r.position.y / CELL), 0, _bh - 1)
	var j1 := clampi(int((r.position.y + r.size.y) / CELL), 0, _bh - 1)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var key := j * _bw + i
			if not _buckets.has(key):
				continue
			for idx in _buckets[key]:
				if _seg_hit(a, b, seg_a[idx], seg_b[idx]):
					return true
	return false


# 带「身体半径」的穿越判定：中心线 + 两侧偏移线
func blocked_body(a: Vector2, b: Vector2, half: float) -> bool:
	if blocked(a, b):
		return true
	var d := b - a
	if d.length_squared() < 0.0001:
		return false
	var n := Vector2(-d.y, d.x).normalized() * half
	return blocked(a + n, b + n) or blocked(a - n, b - n)


func _seg_hit(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var rx := b.x - a.x
	var ry := b.y - a.y
	var sx := d.x - c.x
	var sy := d.y - c.y
	var den := rx * sy - ry * sx
	if absf(den) < 0.00001:
		return false
	var qx := c.x - a.x
	var qy := c.y - a.y
	var t := (qx * sy - qy * sx) / den
	var u := (qx * ry - qy * rx) / den
	return t >= 0.0 and t <= 1.0 and u >= 0.0 and u <= 1.0


func _cell_of(p: Vector2) -> int:
	var i := int(clampf(p.x / PIX, 0.0, float(_mw - 1)))
	var j := int(clampf(p.y / PIX, 0.0, float(_mh - 1)))
	return j * _mw + i


func solid_point(p: Vector2) -> bool:
	return _solid[_cell_of(p)] == 1


# 逐点采样版的「线段是否撞墙」：只查栅格，不碰轮廓段，给病毒繁殖这种每帧上千次的调用用。
# 采样步长取 PIX*3 ≈ 24 单位，比隔膜最薄处（MIN_SEPTUM 46）细，不会穿墙。
func line_free(x0: float, y0: float, x1: float, y1: float) -> bool:
	var dx := x1 - x0
	var dy := y1 - y0
	var steps := int(sqrt(dx * dx + dy * dy) / 24.0)
	if steps < 1:
		steps = 1
	for k in range(1, steps + 1):
		var t := float(k) / float(steps)
		var i := int((x0 + dx * t) / PIX)
		var j := int((y0 + dy * t) / PIX)
		if i < 0 or j < 0 or i >= _mw or j >= _mh:
			return false
		if _solid[j * _mw + i] == 1:
			return false
	return true


# 单个点是否实心（不做 Vector2 装箱，循环里更省）
func solid_xy(x: float, y: float) -> bool:
	var i := int(x / PIX)
	var j := int(y / PIX)
	if i < 0 or j < 0 or i >= _mw or j >= _mh:
		return true
	return _solid[j * _mw + i] == 1


# 给渲染层用：第 i 条轮廓是否闭合（不闭合的画的时候不要首尾相连）
func loop_is_closed(i: int) -> bool:
	if i < 0 or i >= _loop_closed.size():
		return false
	return _loop_closed[i]


# 给渲染层烘焙贴图用
func mask_size() -> Vector2i:
	return Vector2i(_mw, _mh)


func solid_cell(i: int, j: int) -> bool:
	if i < 0 or j < 0 or i >= _mw or j >= _mh:
		return true
	return _solid[j * _mw + i] == 1


# 到最近墙的距离（像素）；实心格为 0
func clearance(p: Vector2) -> float:
	return _dist[_cell_of(p)]


func is_lumen(p: Vector2) -> bool:
	return sdf(p) < 0.0


# 往最近的可通行点吸附（跳跃链落进组织时用）
func nearest_free(p: Vector2, max_r: float) -> Vector2:
	if not solid_point(p):
		return p
	var step := PIX
	var rings := int(max_r / step)
	for r in range(1, rings + 1):
		var rr := float(r) * step
		var count := maxi(8, int(TAU * rr / step))
		for k in range(count):
			var ang := TAU * float(k) / float(count)
			var q := p + Vector2(cos(ang), sin(ang)) * rr
			if q.x < 4.0 or q.y < 4.0 or q.x > size.x - 4.0 or q.y > size.y - 4.0:
				continue
			if not solid_point(q):
				return q
	return Vector2(-1.0, -1.0)


# 采样一个「够开阔」的流明点（出生点 / 病毒播种用）
func random_free_point(rng: RandomNumberGenerator, min_clear: float) -> Vector2:
	# 先确保主连通块算过（阈值取和调用方同量级）
	if _walk_main.is_empty():
		walk_report(min_clear)
	for _k in range(600):
		var p := Vector2(rng.randf_range(60.0, size.x - 60.0), rng.randf_range(60.0, size.y - 60.0))
		if clearance(p) >= min_clear and is_main_walkable(p):
			return p
	return size * 0.5


# 这个点是否落在「主连通块」里（防出生点被塞进死腔）
func is_main_walkable(p: Vector2) -> bool:
	if _walk_main.is_empty():
		return true
	return _walk_main[_cell_of(p)] == 1


# ------------------------------------------------------------ 体检
func walk_report(player_r: float) -> Dictionary:
	var w := _mw
	var h := _mh
	var walk := PackedByteArray()
	walk.resize(w * h)
	var walkable := 0
	for k in range(w * h):
		if _solid[k] == 0 and _dist[k] >= player_r:
			walk[k] = 1
			walkable += 1

	var seen := PackedByteArray()
	seen.resize(w * h)
	var main_labels := PackedInt32Array()
	main_labels.resize(w * h)
	main_labels.fill(-1)
	var best := 0
	var best_id := -1
	var comps := 0
	var q: Array = []
	for start in range(w * h):
		if walk[start] == 0 or seen[start] == 1:
			continue
		comps += 1
		var cid := comps - 1
		q.clear()
		q.append(start)
		seen[start] = 1
		var size_c := 0
		while not q.is_empty():
			var idx: int = q.pop_back()
			size_c += 1
			main_labels[idx] = cid
			var x: int = idx % w
			var y: int = idx / w
			for dd in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var nx: int = x + int(dd[0])
				var ny: int = y + int(dd[1])
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var ni: int = ny * w + nx
				if walk[ni] == 1 and seen[ni] == 0:
					seen[ni] = 1
					q.append(ni)
		if size_c > best:
			best = size_c
			best_id = cid
	_walk_main.resize(w * h)
	_walk_main.fill(0)
	_walk_th = player_r
	for k in range(w * h):
		if main_labels[k] == best_id:
			_walk_main[k] = 1
	var stray := 0.0
	if w * h > 0:
		stray = float(walkable - best) / float(w * h)
	return {
		"stray_area": stray,
		"free_ratio": free_ratio,
		"walk_area": float(walkable) / float(w * h),
		"reach_ratio": (float(best) / float(walkable)) if walkable > 0 else 0.0,
		"components": comps,
		"segments": seg_a.size(),
		"loops": loops.size(),
		"open_loops": open_loop_count,
		"shape_build_ms": build_ms,
	}
