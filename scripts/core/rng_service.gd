extends Node
# 种子化随机：三条独立流，保证可复现

var seed_value := 12345
var spread := RandomNumberGenerator.new()
var drop := RandomNumberGenerator.new()
var events := RandomNumberGenerator.new()

func _ready() -> void:
    reset(seed_value)

func reset(s: int) -> void:
    seed_value = s
    spread.seed = s
    drop.seed = s * 7919 + 1
    events.seed = s * 104729 + 3
