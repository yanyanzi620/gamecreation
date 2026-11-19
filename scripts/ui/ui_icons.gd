extends RefCounted
# ============================================================
# UI 图标加载器 —— key -> Texture2D
#
# 素材真身在 assets/ui/icons/，映射表是同目录的 manifest.json。
# 美术换图（同名覆盖 / 换文件名 / 换 png）都不需要改这里：
#   1. 同名覆盖 -> 连 manifest 都不用动
#   2. 换文件名或格式 -> 改 manifest.json 的那一行
# 只有「加一个全新指标」时才需要动 FALLBACK 这张表。
# ============================================================

const DIR := "res://assets/ui/icons/"
const MANIFEST := "res://assets/ui/icons/manifest.json"

# 兜底表：manifest.json 读不到（比如导出时没带上 json）就用这份
const FALLBACK := {
	"nutrient": "nutrient.svg",
	"virus": "virus.svg",
	"blob": "virus_blob.svg",
	"band": "virus_band.svg",
	"chain": "virus_chain.svg",
	"corpse": "corpse.svg",
	"perf": "perf.svg",
	"jet": "skill_jet.svg",
	"block": "skill_block.svg",
	"fuse": "skill_fuse.svg",
	"lobe": "lobe.svg",
}


static func load_set() -> Dictionary:
	var files := FALLBACK.duplicate()
	var overridden := _read_manifest()
	for k in overridden.keys():
		files[k] = overridden[k]
	var out := {}
	for k in files.keys():
		var path := DIR + String(files[k])
		out[k] = load(path) if ResourceLoader.exists(path) else null
	return out


static func _read_manifest() -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(MANIFEST):
		return out
	var txt := FileAccess.get_file_as_string(MANIFEST)
	if txt.is_empty():
		return out
	var data = JSON.parse_string(txt)
	if not (data is Dictionary):
		return out
	var icons = data.get("icons", null)
	if not (icons is Dictionary):
		return out
	for k in icons.keys():
		if icons[k] is String:
			out[String(k)] = String(icons[k])
	return out
