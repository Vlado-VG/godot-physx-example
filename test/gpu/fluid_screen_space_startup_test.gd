extends SceneTree

# A Screen Space PhysXParticleFluid3D starting up draws nothing but itself: in
# a bright scene, over its first frames, no frame swaps most of the screen at
# once (the shading quad used to show Godot's placeholder texture -- a
# checkerboard over everything -- before its textures were hooked up) and
# nothing paints near-black (the depth-only pass used to write black under the
# liquid, which showed through wherever the liquid wasn't fully opaque).
# MPM, so no CUDA needed; needs a window:
#   godot --path . --script res://test/gpu/fluid_screen_space_startup_test.gd

const FRAMES := 40

var _t := 0
var _prev: Image
var _flash := 0
var _black_max := 0


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXParticleFluid3D", "set_render_mode"):
		print("[ss_startup] SKIP: this engine build has no fluid render modes yet")
		quit(0)
		return
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.7, 0.75, 0.8)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.6
	we.environment = env
	get_root().add_child(we)
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 1, 20)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	get_root().add_child(floor_body)
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor_mesh.mesh = pm
	get_root().add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	get_root().add_child(sun)
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.1, 2.6), Vector3(0, 0.8, 0))
	var f: Node3D = ClassDB.instantiate("PhysXParticleFluid3D")
	f.set("solver", 2)
	f.set("render_mode", 2) # Screen Space
	f.set("particle_size", 0.03)
	f.set("particle_count", 20000)
	f.set("spawn_on_ready", false)
	f.set("emitting", true)
	f.set("emission_rate", 6000.0)
	f.set("emission_radius", 0.08)
	f.set("emission_velocity", Vector3(0, -2, 0))
	f.set("mpm_domain_size", Vector3(4, 4.4, 4))
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.2, 0.7, 0.3, 0.5)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	f.set("material_override", m)
	f.position = Vector3(0, 2.2, 0)
	get_root().add_child(f)
	process_frame.connect(_frame)


func _frame() -> void:
	_t += 1
	var img := get_root().get_texture().get_image()
	img.resize(320, 180, Image.INTERPOLATE_NEAREST)
	var black := 0
	var changed := 0
	for y in range(0, 180, 2):
		for x in range(0, 320, 2):
			var c := img.get_pixel(x, y)
			if c.v < 0.04:
				black += 1
			if _prev:
				var p := _prev.get_pixel(x, y)
				if absf(c.r - p.r) + absf(c.g - p.g) + absf(c.b - p.b) > 0.15:
					changed += 1
	# Frame 2 is the first drawn one (frame 1 is still black): count from 3.
	if _t >= 3:
		_black_max = maxi(_black_max, black)
		if changed > 160 * 90 / 2:
			_flash += 1
			print("[ss_startup] frame %d: %d of %d samples changed at once" % [_t, changed, 160 * 90])
	_prev = img
	if _t == FRAMES:
		var ok := _flash == 0 and _black_max < 10
		print("[ss_startup] frames that swapped most of the screen: %d; most near-black samples in a frame: %d" % [_flash, _black_max])
		print("[ss_startup] ", "PASS" if ok else "FAIL")
		quit(0 if ok else 1)
