extends SceneTree

# Transparent geometry sorts against a Screen Space PhysXParticleFluid3D: a
# falling stream of opaque red liquid with a transparent green ball (like the
# debris vortex ball) just in front of it at one height and one just behind it
# at another. Where the stream crosses them, the ball in front shows green and
# the one behind leaves the frame as it was -- without MSAA and with 4x MSAA
# (the liquid then has to be drawn into the multisampled targets). The fluid
# used to draw over all transparent geometry, so the ball in front was hidden. MPM, so no CUDA needed; needs a window:
#   godot --path . --script res://test/gpu/fluid_transparent_sort_test.gd

const FRONT_Y := 1.4
const BEHIND_Y := 0.8

var _pass := true
var _cam: Camera3D
var _balls: Array[MeshInstance3D] = []


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXParticleFluid3D", "set_render_mode"):
		print("[transparent_sort] SKIP: this engine build has no fluid render modes yet")
		quit(0)
		return
	create_timer(120.0).timeout.connect(func() -> void:
		print("[transparent_sort] FAIL: timed out")
		quit(1))
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
	_cam = Camera3D.new()
	get_root().add_child(_cam)
	_cam.look_at_from_position(Vector3(0, 1.1, 3.0), Vector3(0, 1.1, 0))
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
	f.set("mpm_domain_size", Vector3(4, 4.4, 4)) # implicit floor at the ground
	var lm := StandardMaterial3D.new()
	lm.albedo_color = Color(0.8, 0.05, 0.05)
	f.set("material_override", lm)
	f.position = Vector3(0, 2.2, 0)
	get_root().add_child(f)
	_balls.append(_ball(Vector3(0, FRONT_Y, 0.5)))
	_balls.append(_ball(Vector3(0, BEHIND_Y, -0.5)))
	_run.call_deferred()


func _ball(p: Vector3) -> MeshInstance3D:
	var s := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.2
	sm.height = 0.4
	s.mesh = sm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.1, 0.9, 0.1, 0.85)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	s.material_override = m
	s.position = p
	s.visible = false
	get_root().add_child(s)
	return s


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("  [%s] %-52s %s" % ["ok" if ok else "FAIL", label, detail])
	_pass = _pass and ok


func _frames(n: int) -> void:
	for i in n:
		await process_frame


# The frame where the stream (x = 0, z = 0) is at height y.
func _at(img: Image, y: float) -> Color:
	var uv := _cam.unproject_position(Vector3(0, y, 0)) / get_root().get_visible_rect().size
	return img.get_pixelv(Vector2i(uv * Vector2(img.get_size())))


func _diff(a: Color, b: Color) -> float:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)


func _case(label: String) -> void:
	for b in _balls:
		b.visible = false
	await _frames(4)
	var img := get_root().get_texture().get_image()
	var front0 := _at(img, FRONT_Y)
	var behind0 := _at(img, BEHIND_Y)
	for b in _balls:
		b.visible = true
	await _frames(4)
	img = get_root().get_texture().get_image()
	var front1 := _at(img, FRONT_Y)
	var behind1 := _at(img, BEHIND_Y)
	print(label)
	_check("a transparent ball in front shows over the liquid", front1.g - front1.r > 0.3, "%s -> %s" % [front0, front1])
	# The stream itself flickers a little frame to frame; the ball showing
	# would turn it green.
	_check("a transparent ball behind is hidden by it", behind1.g - behind0.g < 0.15, "%s -> %s" % [behind0, behind1])


func _run() -> void:
	await _frames(140) # the stream reaches the ground and settles into a column
	await _case("1) no MSAA")
	get_root().msaa_3d = Viewport.MSAA_4X
	await _frames(10)
	await _case("2) 4x MSAA")
	print("[transparent_sort] %s" % ("PASS" if _pass else "FAIL"))
	quit(0 if _pass else 1)
