extends SceneTree

# A Screen Space PhysXParticleFluid3D is lit by the scene like any surface: an
# opaque red MPM puddle under a sun straight above, with a box shading its left
# half, then in the dark (sun off, no ambient light), then lit by one omni light
# on its right. It used to be shaded by its own fixed sun term and a constant
# ambient floor, so it ignored shadows and glowed in the dark.
# MPM, so no CUDA needed; needs a window:
#   godot --path . --script res://test/gpu/fluid_screen_space_lighting_test.gd

var _pass := true
var _cam: Camera3D
var _sun: DirectionalLight3D
var _env: Environment


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXParticleFluid3D", "set_render_mode"):
		print("[ss_lighting] SKIP: this engine build has no fluid render modes yet")
		quit(0)
		return
	create_timer(120.0).timeout.connect(func() -> void:
		print("[ss_lighting] FAIL: timed out")
		quit(1))
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.3, 0.3, 0.3)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(1, 1, 1)
	_env.ambient_light_energy = 0.3
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	we.environment = _env
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
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-90, 0, 0) # straight down
	_sun.shadow_enabled = true
	get_root().add_child(_sun)
	# Shades x < 0 of the puddle.
	var blocker := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 0.05, 3.0)
	blocker.mesh = bm
	blocker.position = Vector3(-1.0, 1.5, 0)
	get_root().add_child(blocker)
	_cam = Camera3D.new()
	get_root().add_child(_cam)
	_cam.look_at_from_position(Vector3(0, 1.4, 1.6), Vector3(0, 0, 0))
	var f: Node3D = ClassDB.instantiate("PhysXParticleFluid3D")
	f.set("solver", 2)
	f.set("render_mode", 2) # Screen Space
	f.set("particle_size", 0.04)
	f.set("spawn_on_ready", false)
	f.set("spawn_region_size", Vector3(0.8, 0.4, 0.8))
	f.set("mpm_domain_size", Vector3(4, 0.6, 4)) # implicit floor: the ground
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.8, 0.05, 0.05) # opaque: the fluid shows its own (lit) colour
	f.set("material_override", m)
	f.position = Vector3(0, 0.3, 0)
	get_root().add_child(f)
	f.call_deferred("spawn")
	_run.call_deferred()


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("  [%s] %-50s %s" % ["ok" if ok else "FAIL", label, detail])
	_pass = _pass and ok


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _at(img: Image, p: Vector3) -> Color:
	var uv := _cam.unproject_position(p) / get_root().get_visible_rect().size
	return img.get_pixelv(Vector2i(uv * Vector2(img.get_size())))


func _run() -> void:
	await _frames(150) # the puddle settles

	var img := get_root().get_texture().get_image()
	var shaded := _at(img, Vector3(-0.2, 0.02, 0))
	var lit := _at(img, Vector3(0.2, 0.02, 0))
	print("1) sun straight above, the left half in a box's shadow")
	_check("the fluid is red there", lit.r > lit.g + 0.2, "%s" % lit)
	_check("its shaded half is darker than its sunlit half", shaded.r < lit.r * 0.6, "%s vs %s" % [shaded, lit])

	print("2) in the dark: sun off, no ambient light")
	_sun.visible = false
	_env.ambient_light_energy = 0.0
	await _frames(6)
	img = get_root().get_texture().get_image()
	var dark := _at(img, Vector3(0.2, 0.02, 0))
	_check("the fluid goes dark (doesn't glow)", dark.r < 0.06, "%s" % dark)

	print("3) one omni light on its right")
	var omni := OmniLight3D.new()
	omni.position = Vector3(0.35, 0.25, 0)
	omni.omni_range = 0.6
	omni.light_energy = 3.0
	get_root().add_child(omni)
	await _frames(6)
	img = get_root().get_texture().get_image()
	var near := _at(img, Vector3(0.25, 0.02, 0))
	var far := _at(img, Vector3(-0.25, 0.02, 0))
	_check("lit near the light, dark away from it", near.r > 0.15 and far.r < near.r * 0.4, "%s vs %s" % [near, far])
	img.save_png("user://fluid_screen_space_lighting_test.png")

	print("[ss_lighting] %s" % ("PASS" if _pass else "FAIL"))
	quit(0 if _pass else 1)
