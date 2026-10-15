extends SceneTree

# PhysXFlow3D.scattering_receive_shadows: a shadow-casting OmniLight3D in a fog layer, with
# a wall on one side of it. Seen from above, the light's glow in the fog (each
# capture minus one with scattering off, so Flow's own lighting drops out) is
# about the same on both sides with shadows off; with them on, the fog behind the
# wall (which the wall hides from the light) loses nearly all of it.
# Needs a window (headless has no RenderingDevice):
#   godot --path . --script res://test/flow/flow_scatter_shadow_test.gd

const LIGHT_POS := Vector3(0, 0.6, 0)
const SIDE := 2.4 # meters from the light, either side

var _flow: Node3D
var _cam: Camera3D
var _tick := 0
var _pass := true
var _results := {}


func _initialize() -> void:
	create_timer(40.0).timeout.connect(func() -> void:
		print("[flow_shadow] FAIL: timed out")
		quit(1))
	if not ClassDB.class_exists("PhysXFlow3D"):
		print("[flow_shadow] SKIP: this build has no Flow support (flow_sdk=)")
		quit(0)
		return
	if not ClassDB.class_has_method("PhysXFlow3D", "set_scattering_receive_shadows"):
		print("[flow_shadow] PhysXFlow3D has no scattering_receive_shadows -> FAIL")
		quit(1)
		return
	var root := Node3D.new()
	get_root().add_child(root)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0, 0, 0)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.02, 0.02, 0.02)
	root.add_child(env)
	# Flow's own lighting (the first DirectionalLight3D) kept dim, so the fog's
	# brightness is mostly the omni light's scattering.
	var sun := DirectionalLight3D.new()
	sun.light_energy = 0.05
	root.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, Vector3(0, -1, -0.01))

	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0, 0, 0)
	floor.material_override = fmat
	root.add_child(floor)

	_flow = ClassDB.instantiate("PhysXFlow3D")
	_flow.set("floor_enabled", true)
	_flow.set("buoyancy", 0.0)
	_flow.set("smoke_fade", 0.02)
	_flow.set("smoke_density", 1.5)
	_flow.set("smoke_color", Color(0.8, 0.8, 0.8))
	_flow.set("emission_strength", 0.0)
	_flow.set("light_scattering", true)
	_flow.set("scattering_shadow_steps", 0) # only scene shadows here, not the gas's own
	root.add_child(_flow)
	var e: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	e.set("shape", 1)
	e.set("size", Vector3(8, 0.5, 3))
	e.set("temperature", 0.0)
	e.set("smoke", 1.0)
	e.set("couple_rate", 2.0)
	e.position = Vector3(0, 0.25, 0)
	root.add_child(e)
	e.set("flow", e.get_path_to(_flow))

	var light := OmniLight3D.new()
	light.light_color = Color(1, 1, 1)
	light.light_energy = 2.0
	light.omni_range = 6.0
	light.shadow_enabled = true
	light.position = LIGHT_POS
	root.add_child(light)

	# The wall, between the light and the +X side.
	var wall := MeshInstance3D.new()
	var wm := BoxMesh.new()
	wm.size = Vector3(0.2, 2.0, 4.0)
	wall.mesh = wm
	wall.position = Vector3(0.8, 1.0, 0)
	root.add_child(wall)

	_cam = Camera3D.new()
	root.add_child(_cam)
	_cam.look_at_from_position(Vector3(0, 9, 0.01), Vector3.ZERO)
	_cam.current = true


func _patch(img: Image, world: Vector3) -> float:
	var at := _cam.unproject_position(world) * (float(img.get_width()) / get_root().get_visible_rect().size.x)
	var sum := 0.0
	var n := 0
	for y in range(int(at.y) - 8, int(at.y) + 8):
		for x in range(int(at.x) - 8, int(at.x) + 8):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				sum += img.get_pixel(x, y).get_luminance()
				n += 1
	return sum / maxf(n, 1)


func _check(label: String, ok: bool, detail: String) -> void:
	print("  [%s] %-50s %s" % ["ok" if ok else "FAIL", label, detail])
	if not ok:
		_pass = false


func _process(_d: float) -> bool:
	if _flow == null:
		return true
	_tick += 1
	# [tick to capture, light_scattering, receive omni + spot shadows]
	for cap in [[180, false, false], [210, true, false], [240, true, true]]:
		if _tick == cap[0] - 12:
			_flow.set("light_scattering", cap[1])
			_flow.set("scattering_receive_shadows", 3 if cap[2] else 0)
		if _tick == cap[0]:
			var img := get_root().get_texture().get_image()
			img.save_png("res://excluded/shots/flow_shadow_%s_%s.png" % ["scatter" if cap[1] else "none", "shadows" if cap[2] else "noshadows"])
			_results[cap[0]] = [_patch(img, Vector3(-SIDE, 0.3, 0)), _patch(img, Vector3(SIDE, 0.3, 0))]
	if _tick == 241:
		var base: Array = _results[180]
		var off: Array = _results[210]
		var on: Array = _results[240]
		var glow_off := [off[0] - base[0], off[1] - base[1]]
		var glow_on := [on[0] - base[0], on[1] - base[1]]
		print("[flow_shadow] the light's glow, open side / behind the wall: shadows off %.3f / %.3f, on %.3f / %.3f" % [glow_off[0], glow_off[1], glow_on[0], glow_on[1]])
		_check("the light glows in the fog", glow_off[0] > 0.03, "")
		_check("without shadows the two sides glow alike", absf(glow_off[0] - glow_off[1]) < 0.25 * glow_off[0], "")
		_check("with shadows the wall blocks most of it", glow_on[1] < glow_on[0] * 0.3, "%.0f%% of the open side" % (100.0 * glow_on[1] / maxf(glow_on[0], 0.0001)))
		_check("and the open side keeps it", glow_on[0] > glow_off[0] * 0.8, "")
		print("[flow_shadow] ", "PASS" if _pass else "FAIL")
		quit(0 if _pass else 1)
		return true
	return false
