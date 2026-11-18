extends Node
# 数据驱动：所有数值从 data/*.json 读，加内容不改代码

var data: Dictionary = {}

func _ready() -> void:
    load_all()

func load_all() -> void:
    for key in ["organs", "pathogens", "units", "economy", "injectors"]:
        var path := "res://data/%s.json" % key
        if not FileAccess.file_exists(path):
            push_warning("missing data file: " + path)
            data[key] = {}
            continue
        var txt := FileAccess.get_file_as_string(path)
        var parsed = JSON.parse_string(txt)
        data[key] = parsed if parsed != null else {}
        if parsed == null:
            push_error("JSON parse failed: " + path)

func get_value(key: String, fallback = null):
    return data.get(key, fallback)
