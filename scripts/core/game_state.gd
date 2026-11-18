extends Node
# 全局状态：五条资源 + 器官三态。所有系统只读这里的字段，写通过 set_*

signal changed

var g := 30.0
var o2 := 90.0
var o2_max := 90.0
var tox := 10.0
var c := 100.0
var c_max := 100.0
var enz := 3.0
var enz_max := 3.0
var defeated := false
var organs: Dictionary = {}

func reset() -> void:
    g = 30.0
    o2 = 90.0
    o2_max = 90.0
    tox = 10.0
    c = 100.0
    c_max = 100.0
    enz = 3.0
    defeated = false
    organs = {
        "lung": {"label": "LUNG", "i": 12.0, "p": 0.0, "d": 0.0, "w": 2.0},
        "kidney": {"label": "KIDNEY", "i": 18.0, "p": 0.0, "d": 0.0, "w": 2.0},
        "heart": {"label": "HEART", "i": 6.0, "p": 0.0, "d": 0.0, "w": 3.0},
    }
    _recompute()

func set_i(organ: String, v: float) -> void:
    if organs.has(organ):
        var o: Dictionary = organs[organ]
        o["i"] = clampf(v, 0.0, 100.0)

func recompute(dt: float) -> void:
    var lung_i: float = organs["lung"]["i"]
    var heart_d: float = organs["heart"]["d"]
    o2_max = maxf(20.0, 90.0 - lung_i * 0.6 - heart_d * 0.3)
    o2 = minf(o2_max, o2 + dt * 3.0)

    var necro := necrotic_count()
    var pump := g * 0.05 + float(necro) * 3.0
    var kidney_i: float = organs["kidney"]["i"]
    var decay := 2.0 * (1.0 - kidney_i / 100.0 * 0.8)
    tox = clampf(tox + (pump - decay) * dt, 0.0, 100.0)

    c_max = maxf(30.0, 100.0 - tox / 2.0 - heart_d * 0.3)
    c = minf(c_max, c + dt * 0.1)
    if c <= 0.0:
        defeated = true
    _recompute()

func necrotic_count() -> int:
    var n := 0
    for id in organs:
        var o: Dictionary = organs[id]
        if o["d"] >= 100.0:
            n += 1
    return n

func _recompute() -> void:
    var total := 0.0
    var wsum := 0.0
    for id in organs:
        var o: Dictionary = organs[id]
        if o["d"] >= 100.0:
            continue
        var w: float = o["w"]
        if o["i"] > 60.0:
            w *= 2.0
        total += o["i"] * w
        wsum += w
    g = total / wsum if wsum > 0.0 else 0.0
    changed.emit()
