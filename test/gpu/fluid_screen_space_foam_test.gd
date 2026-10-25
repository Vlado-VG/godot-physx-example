extends SceneTree

# Screen Space PhysXParticleFluid3D draws its foam: two identical splashes (a
# fast PBD stream into a floor), one with foam on, side by side, seen from
# above, with a rough material (no bright highlights), over a dark floor. The
# foamed one shows white foam over its pool, the other next to none. (In Screen Space the
# foam spheres are hidden and the effect draws the foam: this catches it not
# drawing.)
# Needs a window and a CUDA device (PBD) -- skips otherwise:
#   godot --path . --script res://test/gpu/fluid_screen_space_foam_test.gd

const FRAMES := 150

var _t := 0
var _foamy: PhysXParticleFluid3D
var _plain: PhysXParticleFluid3D


func _splash(x: float, foam: bool) -> PhysXParticleFluid3D:
	var f := PhysXParticleFluid3D.new()
	f.solver = PhysXParticleFluid3D.SOLVER_PBD
	f.spawn_on_ready = false
	f.particle_count = 12000
	f.particle_size = 0.06
	f.emitting = true
	f.emission_rate = 12000.0
	f.emission_radius = 0.1
	f.emission_velocity = Vector3(0, -7, 0)
	f.position = Vector3(x, 3.5, 0)
	f.foam_enabled = foam
	f.foam_particle_count = 6000
	f.foam_lifetime = 1.0
	f.foam_threshold = 200.0
	f.set("render_mode", 2) # RENDER_MODE_SCREEN_SPACE; set() so this parses on builds without render modes
	# Rough, so the sun highlight is a dim sheen: near-white then means foam.
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.6, 0.9)
	m.roughness = 1.0
	f.material_override = m
	get_root().add_child(f)
	return f


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXParticleFluid3D", "set_render_mode"):
		print("[ss_foam] SKIP: this engine build has no fluid render modes yet")
		quit(0)
		return
	var fb := StaticBody3D.new()
	var fc := CollisionShape3D.new()
	var fs := BoxShape3D.new()
	fs.size = Vector3(16, 1, 8)
	fc.shape = fs
	fb.add_child(fc)
	fb.position = Vector3(0, -0.5, 0)
	get_root().add_child(fb)
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(16, 8)
	floor_mesh.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.1, 0.1, 0.1) # dark, so the (lit) white foam stands out
	floor_mesh.material_override = fm
	get_root().add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	get_root().add_child(sun)
	var cam := Camera3D.new()
	get_root().add_child(cam)
	# From above, so the foam counted is foam over the liquid (spray in open air
	# showed even when the liquid covered the foam under it).
	cam.look_at_from_position(Vector3(0, 7.0, 0.01), Vector3(0, 0, 0))
	_foamy = _splash(-2.5, true)
	_plain = _splash(2.5, false)
	process_frame.connect(_frame)


# Foam-coloured pixels (bright and grey-white: lit foam, not the blue liquid or
# the dark floor) in each half of the frame.
func _white(img: Image, left: bool) -> int:
	var n := 0
	var w := img.get_width()
	for y in range(0, img.get_height(), 2):
		for x in range(0 if left else w / 2, w / 2 if left else w, 2):
			var c := img.get_pixel(x, y)
			if minf(c.r, minf(c.g, c.b)) > 0.45 and maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) < 0.2:
				n += 1
	return n


func _frame() -> void:
	_t += 1
	if _t == 10 and _plain.get_live_particle_count() == 0:
		print("[ss_foam] no live particles (no CUDA device) -> SKIP")
		quit(0)
		return
	if _t == FRAMES:
		var img := get_root().get_texture().get_image()
		var foamy := _white(img, true)
		var plain := _white(img, false)
		var ok := _foamy.get_live_foam_count() > 100 and foamy > plain * 5 + 100
		print("[ss_foam] foam particles %d; foam-white pixels: foam on %d, foam off %d" % [_foamy.get_live_foam_count(), foamy, plain])
		img.save_png("user://fluid_screen_space_foam_test.png")
		print("[ss_foam] ", "PASS" if ok else "FAIL")
		quit(0 if ok else 1)
