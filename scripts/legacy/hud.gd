extends CanvasLayer
# F1 / TAB 切换；全 ASCII，避免默认字体缺中文字符

var main: Node
var label: Label
var show_hud := true

func _ready() -> void:
    label = Label.new()
    label.position = Vector2(24, 14)
    label.add_theme_font_size_override("font_size", 17)
    label.add_theme_color_override("font_color", Color(0.85, 0.92, 0.96))
    add_child(label)

func setup(m: Node) -> void:
    main = m

func toggle() -> void:
    show_hud = not show_hud

func _process(_delta: float) -> void:
    if main == null:
        return
    label.visible = show_hud
    if not show_hud:
        return

    var gs: Node = GameState
    var rows := PackedStringArray()
    var state_text := "PAUSED" if main.paused else "LIVE"
    rows.append("FPS %d    TICK %d    SCALE %.2fx    SEED %d    %s" % [
        Engine.get_frames_per_second(), main.ticks, main.time_scale, main.seed_value, state_text])
    rows.append("")
    rows.append("G %5.1f%%     O2 %5.1f / %5.1f     TOX %5.1f" % [gs.g, gs.o2, gs.o2_max, gs.tox])
    rows.append("C %5.1f / %5.1f    ENZ %3.1f / %3.1f    FIELD R %6.1f" % [
        gs.c, gs.c_max, gs.enz, gs.enz_max, main.spread.main_radius()])
    rows.append("")
    for id in gs.organs:
        var o: Dictionary = gs.organs[id]
        rows.append("%-7s  I %5.1f   P %5.1f   D %5.1f" % [o["label"], o["i"], o["p"], o["d"]])
    rows.append("")
    rows.append("SCALE  unit d=90   purify r=250   alveolus d=190   grid 100/500u   arena 2400x1500")
    rows.append("")
    rows.append("WASD move   LMB / SPACE purify   [ ] speed   P pause   N step   R reseed   TAB hud")
    label.text = "\n".join(rows)
