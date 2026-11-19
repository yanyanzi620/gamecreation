extends SceneTree
# 地形探针：用「高对比配色」把掩码单独烘一张图，排除渲染层的干扰
# 跑法：<godot_console> --headless --path E:\gamecreation --script res://scripts/debug/map_probe.gd

func _init() -> void:
	var m: OrganMap = LungGen.new().build(20261119, Vector2(Balance.ARENA_W, Balance.ARENA_H))
	print("free_ratio=%.1f%% shapes=%d loops=%d" % [m.free_ratio * 100.0, m.shape_count, m.loops.size()])

	var ms: Vector2i = m.mask_size()
	var img := Image.create(ms.x, ms.y, false, Image.FORMAT_RGBA8)
	for j in range(ms.y):
		for i in range(ms.x):
			# 流明 = 亮青，肉壁 = 深红（一眼就能分清）
			img.set_pixel(i, j, Color(0.0, 0.85, 0.95) if not m.solid_cell(i, j) else Color(0.55, 0.05, 0.10))
	img.save_png(ProjectSettings.globalize_path("res://probe_mask.png"))
	print("saved res://probe_mask.png  size=%s" % str(ms))
	quit()
