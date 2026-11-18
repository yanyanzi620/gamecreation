extends Node
# 全局信号总线：模块之间只通过这里通信

signal global_changed(g, o2, tox, c, enz)
signal organ_changed(organ_id: String, i: float, p: float, d: float)

signal infection_spawned(organ_id: String, shape: String, pos: Vector2, strength: float)
signal band_placed(uid: int, a: Vector2, b: Vector2, expire_at: float)
signal tool_used(kind: String, pos: Vector2, radius: float)

signal unit_dispatched(unit_id: int, from_organ: String, to_organ: String, eta: float)
signal unit_taken_over(unit_id: int)
signal isolation_changed(organ_id: String, active: bool, debt: float)
signal necrosis(organ_id: String)

signal phase_changed(phase: int)
signal run_victory()
signal run_defeat(reason: String)
