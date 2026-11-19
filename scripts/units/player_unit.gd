extends Node2D
# ============================================================
# 免疫单元 —— 被「中枢意识」接管的那一颗
#
# 现在场上只有一颗，但这一层是为「多单元」准备的：
#   · 位置与绘制在单元自己身上（不再是 main 里一个裸 Vector2）
#   · 移动规则（贴墙滑行）在 Move，和器官地图/病毒遮挡无关的部分不耦合
#   · taken_over = false 时代表「未被接管的单元」：将来由本地数值自动演化，
#     main 只需要切换「哪一颗受控」，调度（血管、瞬移、失联）都挂在这一层之上
#
# 依赖：OrganMap（地形判定）+ VirusPopulation（肉壁/阻隔带对移动的遮挡）
# ============================================================

# 撞墙就贴着墙走：把「想走的方向」往两侧掰，逐档试探，
# 第一个走得通的当作这一帧的实际位移 —— 于是斜墙、凹角、肺泡内壁都顺滑。
const SLIDE_DEG := [0.0, 16.0, -16.0, 34.0, -34.0, 52.0, -52.0, 70.0, -70.0, 88.0, -88.0]

var r: float = Balance.PLAYER_R
var speed: float = Balance.PLAYER_SPEED
var taken_over := true

var organ = null        # OrganMap
var virus = null        # VirusPopulation


func bind(o, v) -> void:
	organ = o
	virus = v


func teleport(p: Vector2) -> void:
	position = p
	_clamp()


# dir 是原始输入方向（可以没归一化，也可以为零）
func move_input(dir: Vector2, delta: float) -> void:
	if dir.length() < 0.001 or organ == null:
		return
	var base := dir.normalized()
	var step := speed * delta
	for k in SLIDE_DEG:
		var d := base.rotated(deg_to_rad(k))
		var s := d * step
		if not virus.path_blocked(position, position + s):
			position += s
			_clamp()
			return
		# 半步再试一次：贴墙且目标是窄口时，避免整帧位移全部作废
		if not virus.path_blocked(position, position + s * 0.5):
			position += s * 0.5
			_clamp()
			return
	_clamp()


func _clamp() -> void:
	var m: float = r + 6.0
	position.x = clampf(position.x, m, organ.size.x - m)
	position.y = clampf(position.y, m, organ.size.y - m)


func _draw() -> void:
	# 接管态：冷蓝 + 朝向短线（阻隔带和引信都按正前方放，得看得出「正前方」在哪）
	var body := Color(0.34, 0.64, 1.0, 0.92)
	if not taken_over:
		body = Color(0.42, 0.46, 0.52, 0.75)   # 失联/未接管：灰掉（多单元时用）
	draw_circle(Vector2.ZERO, r * 1.6, Color(0.20, 0.45, 0.95, 0.16))
	draw_circle(Vector2.ZERO, r, body)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(0.76, 0.89, 1.0), 2.0)
	draw_line(Vector2.ZERO, Vector2(0.0, -r - 10.0), Color(0.80, 0.92, 1.0, 0.5), 2.0)

