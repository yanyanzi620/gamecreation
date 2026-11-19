extends Node
# ============================================================
# 音频导演 —— 事件名进，声音出
#
# 口径：**玩法层只发「事件名」，不认识文件名**。
#   主循环调 play("jet_fire")，具体放哪个 wav、多响、能不能重复播，
#   全在 assets/audio/manifest.json 里配 —— 换音效不用改代码。
#
# 三条总线：Master -> SFX / BGM（运行时自动建，不依赖项目里预设的默认总线）。
# 无头模式（--headless）自动静音：自测/CI 里不要出声、也不要刷设备告警。
# ============================================================

const DIR := "res://assets/audio/"
const MANIFEST := "res://assets/audio/manifest.json"
const VOICES := 12                          # 音效播放器池：同屏最多这么多发叠在一起

var table: Dictionary = {}                  # 事件名 -> 配置
var bank: Dictionary = {}                   # 事件名 -> Array[AudioStream]
var muted := false
var verbose := false                        # --audio 启动参数：把每次播放打到控制台（调音效时用）

var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _last_ms: Dictionary = {}
var _bgm: AudioStreamPlayer = null
var _rng := RandomNumberGenerator.new()


func setup() -> void:
	_rng.randomize()
	_ensure_buses()
	_load()
	for i in range(VOICES):
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_players.append(p)
	_bgm = AudioStreamPlayer.new()
	_bgm.bus = "BGM"
	add_child(_bgm)
	if DisplayServer.get_name() == "headless":
		muted = true
	verbose = OS.get_cmdline_user_args().has("--audio")


# 事件表：manifest 优先，读不到就按默认文件名（和 README 的表一致）
func _load() -> void:
	table = _read_manifest()
	var events: Array = table.keys()
	if not table.has("bgm"):
		table["bgm"] = {"files": ["bgm/bgm_lung.wav"], "volume_db": -16.0, "loop": true}
	for ev in events:
		bank[ev] = _load_event(table[ev])
	if not bank.has("bgm"):
		bank["bgm"] = _load_event(table["bgm"])


func _read_manifest() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST):
		return {}
	var txt := FileAccess.get_file_as_string(MANIFEST)
	if txt.is_empty():
		return {}
	var data = JSON.parse_string(txt)
	if not (data is Dictionary):
		return {}
	var ev = data.get("events", null)
	return ev if ev is Dictionary else {}


func _load_event(cfg) -> Array:
	var out: Array = []
	if not (cfg is Dictionary):
		return out
	var files = cfg.get("files", [])
	if not (files is Array):
		return out
	for f in files:
		var path := DIR + String(f)
		if not ResourceLoader.exists(path):
			continue
		var s = load(path)
		if s == null:
			continue
		if bool(cfg.get("loop", false)) and s is AudioStreamWAV:
			# 导入默认不循环：就地设 LOOP_FORWARD（只影响这一段 BGM 资源）。
			# 不 duplicate()：多出来的资源实例退出时会被报成 ObjectDB 泄漏。
			var w: AudioStreamWAV = s as AudioStreamWAV
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(round(w.get_length() * w.mix_rate))
		out.append(s)
	return out


func _ensure_buses() -> void:
	if AudioServer.get_bus_index("SFX") < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, "SFX")
		AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")
	if AudioServer.get_bus_index("BGM") < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, "BGM")
		AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")


# ------------------------------------------------------------ 播放

func play(ev: String) -> void:
	if muted:
		return
	var variants: Array = bank.get(ev, [])
	if variants.is_empty():
		return
	var cfg: Dictionary = table.get(ev, {})
	var now := Time.get_ticks_msec()
	var gap := int(cfg.get("min_gap_ms", 0))
	if now - int(_last_ms.get(ev, -999999)) < gap:
		return
	_last_ms[ev] = now

	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = variants[_rng.randi_range(0, variants.size() - 1)]
	p.volume_db = float(cfg.get("volume_db", -6.0)) + _rng.randf_range(-1.0, 1.0)
	var j := float(cfg.get("pitch_jitter", 0.0))
	p.pitch_scale = 1.0 + _rng.randf_range(-j, j)
	p.play()
	if verbose:
		print("[SFX] %s  vol=%.1f  pitch=%.2f" % [ev, p.volume_db, p.pitch_scale])


func start_bgm() -> void:
	var variants: Array = bank.get("bgm", [])
	if variants.is_empty() or _bgm == null:
		return
	var cfg: Dictionary = table.get("bgm", {})
	_bgm.stream = variants[0]
	_bgm.volume_db = float(cfg.get("volume_db", -16.0))
	if not muted:
		_bgm.play()


func stop_bgm() -> void:
	if _bgm != null:
		_bgm.stop()


# 退出时主动断引用：播放器还挂着 stream 的话，退出会报「资源仍在占用 / ObjectDB 泄漏」
func _exit_tree() -> void:
	if _bgm != null:
		_bgm.stop()
		_bgm.stream = null
	for p in _players:
		p.stop()
		p.stream = null
	bank.clear()


func toggle_mute() -> bool:
	muted = not muted
	if muted:
		if _bgm != null:
			_bgm.stop()
		for p in _players:
			p.stop()
	else:
		start_bgm()
	return muted


# 自测/调试用：这次一共加载到几段音频、覆盖几个事件
func report() -> String:
	var evs := 0
	var streams := 0
	for k in bank.keys():
		evs += 1
		streams += (bank[k] as Array).size()
	return "events=%d streams=%d muted=%s" % [evs, streams, str(muted)]
