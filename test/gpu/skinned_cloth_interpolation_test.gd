extends SceneTree

# PhysXSkinnedCloth3D captures the skeleton where it is DRAWN: with physics
# interpolation on, a character moved on physics ticks is drawn smoothly in
# between. The cloth captured the tick transform, which jumps once per tick and
# sits still on the frames between, so at a high frame rate the cloth was
# yanked once per tick against the smooth body (kezsonaj 0001).
# A rig walks along +X at 1.4 m/s, moved on 60 Hz physics ticks, drawn
# interpolated, rendering uncapped (several frames per tick). A strip pinned
# along its top row hangs from it; its free bottom corner, as drawn, must move
# as smoothly as the body: the per-frame second difference of its drawn
# position stays close to the body's (it jerked once per tick before). The
# skeleton's pose never changes (only the node it hangs from moves), so the
# cloth must also follow the body without a skeleton update: its pinned top
# corner stays on the body as drawn, every frame (it was left behind where the
# pose was last captured, and stepped every other frame).
# Needs a window (the cloth solver is a compute shader):
#   godot --path . --script res://test/gpu/skinned_cloth_interpolation_test.gd


# Runs after the cloth (process priority 100) each frame, reading it as drawn.
class Probe extends Node:
	var test

	func _process(_delta: float) -> void:
		test._frame()


const SPEED := 1.4

var _root: Node3D
var _cloth: Node3D
var _t := 0
var _frames := 0
var _cloth_hist := PackedVector3Array()
var _body_hist := PackedVector3Array()
var _cloth_jerk := 0.0
var _body_jerk := 0.0
var _samples := 0
var _pin_off := 0.0
var _ok := true


func _check(cond: bool, msg: String) -> void:
	print("[cloth_interp] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXSkinnedCloth3D"):
		print("[cloth_interp] SKIP: no PhysXSkinnedCloth3D")
		quit(0)
		return
	physics_interpolation = true
	Engine.physics_ticks_per_second = 60
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.look_at_from_position(Vector3(4, 1.5, 8), Vector3(4, 1.5, 0))

	_root = Node3D.new()
	get_root().add_child(_root)
	var sk := Skeleton3D.new()
	sk.add_bone("root")
	sk.add_bone("tip")
	sk.set_bone_parent(1, 0)
	sk.set_bone_rest(1, Transform3D(Basis(), Vector3(0, 1, 0)))
	sk.reset_bone_poses()
	_root.add_child(sk)

	const ROWS := 9
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var idx := PackedInt32Array()
	for r in ROWS:
		for c in 2:
			verts.append(Vector3(c * 0.2, 1.0 + float(r) / (ROWS - 1), 0))
			normals.append(Vector3(0, 0, 1))
			uvs.append(Vector2(c, float(r) / (ROWS - 1)))
			bones.append_array([0, 0, 0, 0])
			weights.append_array([1.0, 0.0, 0.0, 0.0])
	for r in ROWS - 1:
		var a := r * 2
		idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, StandardMaterial3D.new())
	var skin := Skin.new()
	skin.add_bind(1, Transform3D(Basis(), Vector3(0, -1, 0)))
	var mi := MeshInstance3D.new()
	mi.name = "Strip"
	mi.mesh = mesh
	mi.skin = skin
	sk.add_child(mi)
	mi.skeleton = mi.get_path_to(sk)

	_cloth = ClassDB.instantiate("PhysXSkinnedCloth3D")
	var dist := PackedFloat32Array()
	for r in ROWS:
		for c in 2:
			dist.append(0.0 if r == ROWS - 1 else 2.0)
	_cloth.set("max_distances", dist)
	sk.add_child(_cloth)
	_cloth.set("mesh_instance_path", _cloth.get_path_to(mi))

	var probe := Probe.new()
	probe.test = self
	probe.process_priority = 1000
	get_root().add_child(probe)
	physics_frame.connect(_tick)


func _tick() -> void:
	_t += 1
	# Walks after the cloth has settled (moved on ticks: drawn interpolated).
	if _t > 60:
		_root.position.x += SPEED / Engine.physics_ticks_per_second
	if _t == 300:
		var fps := float(_frames) / 3.0
		_check(fps > 150.0, "rendering %.0f fps over 60 Hz physics (want several frames per tick)" % fps)
		var cj := sqrt(_cloth_jerk / maxi(_samples, 1)) * 1000.0
		var bj := sqrt(_body_jerk / maxi(_samples, 1)) * 1000.0
		_check(_pin_off < 0.01, "the pinned corner stays on the body as drawn (furthest off %.4f m)" % _pin_off)
		_check(_samples > 100 and cj < bj + 1.0, "the hanging corner moves as smoothly as the body it hangs from: %.2f mm/frame^2 vs the body's %.2f (%d frames; 12 mm/frame^2 on the tick transform)" % [cj, bj, _samples])
		print("[cloth_interp] ", "PASS" if _ok else "FAIL")
		quit(0 if _ok else 1)


# The free bottom corner and the body, as drawn this frame.
func _frame() -> void:
	if _t <= 120:
		return
	_frames += 1
	var ri: MeshInstance3D = null
	for n in _cloth.get_parent().get_children(true):
		if n is MeshInstance3D and n.name != "Strip":
			ri = n
	var mat: ShaderMaterial = ri.get_surface_override_material(0) if ri else null
	var tex: Texture2DRD = mat.get_shader_parameter("cloth_positions") if mat else null
	if tex == null:
		return
	var f := RenderingServer.get_rendering_device().texture_get_data(tex.texture_rd_rid, 0).to_float32_array()
	var corner := ri.get_global_transform_interpolated() * Vector3(f[0], f[1], f[2])
	var body := _root.get_global_transform_interpolated().origin
	var pin := ri.get_global_transform_interpolated() * Vector3(f[68], f[69], f[70])
	_pin_off = maxf(_pin_off, pin.distance_to(body + Vector3(0.2, 2, 0)))
	_cloth_hist.append(corner)
	_body_hist.append(body)
	var n := _cloth_hist.size()
	if n >= 3:
		var c2 := _cloth_hist[n - 1] - 2.0 * _cloth_hist[n - 2] + _cloth_hist[n - 3]
		var b2 := _body_hist[n - 1] - 2.0 * _body_hist[n - 2] + _body_hist[n - 3]
		_cloth_jerk += c2.length_squared()
		_body_jerk += b2.length_squared()
		_samples += 1
