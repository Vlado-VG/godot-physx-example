extends SceneTree

# PhysXFlow3D.light_scattering: an OmniLight3D sitting in low smoke must make the
# smoke glow in its color. Same scene, same frame setup, captured with the option
# off and then on: around the light the image gets clearly greener, while a patch
# of empty sky stays the same (the light lights the floor in both shots, so the
# difference is the glow in the gas). Needs a window (headless has no
# RenderingDevice):
#   godot --path . --script res://test/flow/flow_scatter_test.gd

const LIGHT_POS := Vector3(0, 0.6, 0)

var _flow: Node3D
var _cam: Camera3D
var _tick := 0
var _off: Image
var _pass := true


func _initialize() -> void:
	create_timer(40.0).timeout.connect(func() -> void:
		print("[flow_scatter] FAIL: timed out")
		quit(1))
	if not ClassDB.class_exists("PhysXFlow3D"):
		print("[flow_scatter] SKIP: this build has no Flow support (flow_sdk=)")
		quit(0)
		return
	if not ClassDB.class_has_method("PhysXFlow3D", "set_light_scattering"):
		print("[flow_scatter] PhysXFlow3D has no light_scattering -> FAIL")
		quit(1)
		return
	var root := Node3D.new()
	get_root().add_child(root)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.02, 0.02, 0.03)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.05, 0.05, 0.06)
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 0.15
	root.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, Vector3(-0.3, -1, -0.2))

	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor.mesh = pm
	root.add_child(floor)

	_flow = ClassDB.instantiate("PhysXFlow3D")
	_flow.set("floor_enabled", true)
	_flow.set("buoyancy", 0.0)
	_flow.set("smoke_fade", 0.05)
	_flow.set("smoke_color", Color(0.7, 0.7, 0.75))
	root.add_child(_flow)
	var e: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	e.set("shape", 1) # box
	e.set("size", Vector3(3, 0.4, 3))
	e.set("velocity", Vector3(0, -0.2, 0))
	e.set("temperature", 0.0)
	e.set("smoke", 1.0)
	e.position = Vector3(0, 0.4, 0)
	root.add_child(e)
	e.set("flow", e.get_path_to(_flow))

	var light := OmniLight3D.new()
	light.light_color = Color(0.2, 1.0, 0.4)
	light.light_energy = 1.0
	light.omni_range = 5.0
	light.position = LIGHT_POS
	root.add_child(light)

	_cam = Camera3D.new()
	root.add_child(_cam)
	_cam.look_at_from_position(Vector3(0, 2.5, 6), Vector3(0, 0.4, 0))
	_cam.current = true


# Mean color of a square patch (half-size px) around a screen point.
func _patch(img: Image, center: Vector2, half: int) -> Color:
	var sum := Color(0, 0, 0, 0)
	var n := 0
	for y in range(int(center.y) - half, int(center.y) + half):
		for x in range(int(center.x) - half, int(center.x) + half):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				sum += img.get_pixel(x, y)
				n += 1
	return sum / maxf(n, 1)


func _check(label: String, ok: bool, detail: String) -> void:
	print("  [%s] %-46s %s" % ["ok" if ok else "FAIL", label, detail])
	if not ok:
		_pass = false


func _process(_d: float) -> bool:
	if _flow == null:
		return true
	_tick += 1
	if _tick == 150:
		_off = get_root().get_texture().get_image()
		_off.save_png("res://excluded/shots/flow_scatter_off.png")
		_flow.set("light_scattering", true)
	if _tick == 170:
		var on := get_root().get_texture().get_image()
		on.save_png("res://excluded/shots/flow_scatter_on.png")
		# unproject_position works in the viewport's own size, which can differ from the captured image.
		var at := _cam.unproject_position(LIGHT_POS) * (float(on.get_width()) / get_root().get_visible_rect().size.x)
		var sky := Vector2(on.get_width() * 0.5, on.get_height() * 0.05)
		var off_glow := _patch(_off, at, 12)
		var on_glow := _patch(on, at, 12)
		var off_sky := _patch(_off, sky, 10)
		var on_sky := _patch(on, sky, 10)
		print("[flow_scatter] stats %s" % _flow.get_stats())
		print("[flow_scatter] light at screen %s (image %dx%d)" % [at, on.get_width(), on.get_height()])
		print("[flow_scatter] around the light: off %s  on %s | sky: off %s  on %s" % [off_glow, on_glow, off_sky, on_sky])
		_check("Flow running", _flow.get_stats().running, str(_flow.get_stats().error))
		_check("the smoke around the light glows green", on_glow.g > off_glow.g + 0.05 and on_glow.g - off_glow.g > (on_glow.r - off_glow.r) * 2.0, "green +%.3f, red +%.3f" % [on_glow.g - off_glow.g, on_glow.r - off_glow.r])
		_check("empty sky is untouched", absf(on_sky.g - off_sky.g) < 0.01, "green %+.4f" % (on_sky.g - off_sky.g))
		print("[flow_scatter] ", "PASS" if _pass else "FAIL")
		quit(0 if _pass else 1)
		return true
	return false
