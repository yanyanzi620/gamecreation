extends Node2D
# 灰盒主场景：只在代码里搭节点，避免手写 .tscn 出错

const STEP := 1.0 / 60.0
const ARENA := Vector2(2400.0, 1500.0)

var spread: Node
var player: Node2D
var camera: Camera2D
var hud: CanvasLayer

var paused := false
var time_scale := 1.0
var scale_steps := [0.25, 0.5, 1.0, 2.0, 4.0]
var scale_index := 2
var accum := 0.0
var ticks := 0
var seed_value := 12345
var start_pos := Vector2(760.0, 520.0)

func _ready() -> void:
    _build()
    _respawn()

func _build() -> void:
    spread = load("res://scripts/world/spread_system.gd").new()
    spread.name = "Spread"
    add_child(spread)

    player = load("res://scripts/units/player_unit.gd").new()
    player.name = "Player"
    add_child(player)

    camera = Camera2D.new()
    camera.name = "Cam"
    camera.position_smoothing_enabled = true
    camera.position_smoothing_speed = 6.0
    camera.enabled = true
    player.add_child(camera)

    hud = load("res://scripts/ui/hud.gd").new()
    hud.name = "HUD"
    add_child(hud)
    hud.setup(self)

func _respawn() -> void:
    RNG.reset(seed_value)
    GameState.reset()
    ticks = 0
    accum = 0.0
    player.position = start_pos
    spread.clear()
    # 球状扩散：起始半径 120，每秒 +3 单位
    spread.spawn(start_pos + Vector2(300.0, 120.0), 120.0, 3.0)
    GameState.set_i("lung", 12.0)
    GameState.recompute(STEP)

func _physics_process(delta: float) -> void:
    if paused:
        return
    accum += delta * time_scale
    var steps := 0
    while accum >= STEP and steps < 16:
        _simulate(STEP)
        accum -= STEP
        steps += 1

func _simulate(dt: float) -> void:
    ticks += 1
    var mv := Vector2.ZERO
    if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
        mv.y -= 1.0
    if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
        mv.y += 1.0
    if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
        mv.x -= 1.0
    if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
        mv.x += 1.0
    player.move(mv, dt, ARENA)

    var hold: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_key_pressed(KEY_SPACE)
    var active: bool = hold and GameState.enz > 0.01
    var engaged: int = spread.step(dt, player.position, active, player.PURIFY_RADIUS, player.PURIFY_RATE)

    # 酶只在真正咬住感染边界时才消耗；空放不烧资源
    if engaged > 0:
        GameState.enz = maxf(0.0, GameState.enz - 0.5 * dt)
    else:
        GameState.enz = minf(GameState.enz_max, GameState.enz + dt / 3.0)

    var r: float = spread.main_radius()
    GameState.set_i("lung", clampf(r / 10.0, 0.0, 100.0))
    GameState.recompute(dt)
    queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey) or not event.pressed or event.echo:
        return
    match event.keycode:
        KEY_BRACKETLEFT:
            scale_index = maxi(0, scale_index - 1)
            time_scale = scale_steps[scale_index]
        KEY_BRACKETRIGHT:
            scale_index = mini(scale_steps.size() - 1, scale_index + 1)
            time_scale = scale_steps[scale_index]
        KEY_P:
            paused = not paused
        KEY_N:
            if paused:
                _simulate(STEP)
        KEY_R:
            _respawn()
        KEY_TAB, KEY_F1:
            hud.toggle()

func _draw() -> void:
    draw_rect(Rect2(Vector2.ZERO, ARENA), Color(0.055, 0.068, 0.088), true)

    # 100 单位细网格 + 500 单位粗网格（给玩家尺度参照）
    var x := 0.0
    while x <= ARENA.x:
        var major_x := int(x) % 500 == 0
        draw_line(Vector2(x, 0.0), Vector2(x, ARENA.y),
            Color(0.145, 0.175, 0.215) if major_x else Color(0.088, 0.105, 0.130), 1.0)
        x += 100.0
    var y := 0.0
    while y <= ARENA.y:
        var major_y := int(y) % 500 == 0
        draw_line(Vector2(0.0, y), Vector2(ARENA.x, y),
            Color(0.145, 0.175, 0.215) if major_y else Color(0.088, 0.105, 0.130), 1.0)
        y += 100.0

    # 器官地形占位：直径 190 的“肺泡”参照圈（肺 L1 的尺度基准）
    var alveoli := [Vector2(1240.0, 880.0), Vector2(420.0, 1120.0), Vector2(1780.0, 340.0),
        Vector2(300.0, 260.0), Vector2(2020.0, 1180.0), Vector2(980.0, 220.0)]
    for a in alveoli:
        draw_arc(a, 95.0, 0.0, TAU, 44, Color(0.175, 0.215, 0.265), 2.0)
        draw_arc(a, 95.0 + 26.0, 0.0, TAU, 44, Color(0.128, 0.158, 0.196), 1.0)

    draw_rect(Rect2(Vector2.ZERO, ARENA), Color(0.42, 0.26, 0.31), false, 3.0)


