extends Node3D

# PhysXFlow3D.light_scattering: a green light low in a swirling sea of ground fog,
# ringed by pillars and a leaning slab. The light glows through the fog around
# it, and the pillars, the slab and the walker cast dark shafts through that glow
# (PhysXFlow3D.scattering_receive_shadows). The fog is one thin, cold box emitter
# over the whole floor (it feeds gently and stays down), wheeled round the light
# by smoke-free stirrers; a capsule on a hub turning against that swirl wades
# through it, cutting across the flow. A dim blue moon keeps the rest of the fog
# dark.
#
#   L        light scattering on / off
#   K        the glow's shadows on / off (scattering_receive_shadows)
#   G        the green light on / off
#   WASD + right mouse   fly the camera

@onready var _flow: Node = $PhysXFlow3D
@onready var _label: Label = $HUD/Label
@onready var _light: Light3D = $GreenLight


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_L:
			_flow.set("light_scattering", not _flow.get("light_scattering"))
		KEY_K:
			_flow.set("scattering_receive_shadows", 0 if _flow.get("scattering_receive_shadows") != 0 else 3)
		KEY_G:
			_light.visible = not _light.visible
		_:
			return
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var on := ["off", "on"]
	# Where the frame goes: CPU process/physics (ms) and GPU render time (the
	# light scattering pass is part of the render), plus Flow's own step and how
	# many sparse blocks the gas is using -- the main driver of its GPU cost.
	var vp_rid := get_viewport().get_viewport_rid()
	var stats: Dictionary = _flow.get_stats()
	_label.text = "Light scattering: %s [L]   shadows: %s [K]   green light: %s [G]\nWASD + right mouse: fly   FPS %d\nprocess %.2f ms   physics %.2f ms   render cpu %.2f ms   gpu %.2f ms\nflow step %.2f ms   active blocks %d / %d" % [
		on[int(_flow.get("light_scattering"))], on[int(_flow.get("scattering_receive_shadows") != 0)], on[int(_light.visible)],
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		RenderingServer.viewport_get_measured_render_time_cpu(vp_rid) + RenderingServer.get_frame_setup_time_cpu(),
		RenderingServer.viewport_get_measured_render_time_gpu(vp_rid),
		stats.get("step_ms", 0.0), stats.get("active_blocks", 0), _flow.get("max_blocks")]
