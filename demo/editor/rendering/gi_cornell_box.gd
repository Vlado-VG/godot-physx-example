extends Node3D

# PXTGI, the module's global illumination (PXTGI3D, experimental), in the Cornell box: a closed white room, red left wall, blue right wall, two
# white spheres and one light under the ceiling. With no ambient light, everything but the direct light is bounce
# light. Everything is a node in the scene. GI runs in the running scene only (not in the editor).
#
#   G        GI: PXTGI / Godot's SDFGI (decent settings) / none
#   B        debug view: off / world only / world hits / world position
#   M        multi-bounce (the radiance cache: off-screen hits carry bounce light) on / off
#   WASD, Space / Ctrl, Shift, hold right mouse: fly

@onready var _env: Environment = $WorldEnvironment.environment
@onready var _gi: Node3D = $GI
@onready var _label: Label = $HUD/Label

var _gi_mode := 0 # 0 PXTGI, 1 SDFGI, 2 none


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _set_gi(mode: int) -> void:
	_gi_mode = mode
	_gi.visible = mode == 0
	_env.sdfgi_enabled = mode == 1
	if mode == 1:
		_env.sdfgi_cascades = 4
		_env.sdfgi_min_cell_size = 0.1
		_env.sdfgi_use_occlusion = true
		_env.sdfgi_bounce_feedback = 0.5
		RenderingServer.environment_set_sdfgi_ray_count(RenderingServer.ENV_SDFGI_RAY_COUNT_64)
		RenderingServer.environment_set_sdfgi_frames_to_converge(RenderingServer.ENV_SDFGI_CONVERGE_IN_30_FRAMES)
		RenderingServer.environment_set_sdfgi_frames_to_update_light(RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_4_FRAMES)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_G:
			_set_gi((_gi_mode + 1) % 3)
		KEY_M:
			_gi.set("multi_bounce", not _gi.get("multi_bounce"))
		KEY_B:
			var views: Array[int] = [0, 3, 4, 5]
			_gi.set("debug", views[(views.find(int(_gi.get("debug"))) + 1) % views.size()])
		_:
			return
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var gi_names: Array[String] = ["PXTGI", "Godot SDFGI (decent)", "none"]
	var debug_names := {0: "off", 3: "world only", 4: "world hits", 5: "world position"}
	var dbg: String = debug_names.get(int(_gi.get("debug")), "?") if _gi_mode == 0 else "-"
	var vp := get_viewport().get_viewport_rid()
	_label.text = "GI: %s [G]   debug: %s [B]   multi-bounce: %s [M]\nWASD + right mouse: fly   Shift: fast\nFPS %d   %s" % [
		gi_names[_gi_mode], dbg, "on" if _gi.get("multi_bounce") else "off", Engine.get_frames_per_second(), RenderTime.gpu(vp)]
