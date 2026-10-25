extends SceneTree

# PhysXSkinnedCloth3D follows the skeleton's FINAL pose and the world's gravity.
#   U22 / 0016: a SkeletonModifier3D bends bone 1 by 90 deg about Z; a strip
#   skinned to bone 1 and fully pinned (max distance 0) must follow the bent
#   bone (strip along -X at y ~1), not the unbent rest pose (up to y 2).
#   0017: with the space's gravity turned sideways (+Z, out of the strip's
#   plane: its pinned top edge is a hinge along X), a strip pinned only along
#   its top edge must swing toward +Z, not hang straight down.
#   Game time: with Engine.time_scale 0 the cloth holds still even when gravity
#   flips (it steps by the scaled process delta, not the wall clock).
# Needs a window (the cloth solver is a compute shader):
#   godot --path . --script res://test/gpu/skinned_cloth_pose_gravity_test.gd

class Bend extends SkeletonModifier3D:
	func _process_modification_with_delta(_delta: float) -> void:
		get_skeleton().set_bone_pose_rotation(1, Quaternion(Vector3(0, 0, 1), PI * 0.5))


var _bent: Node3D
var _hang: Node3D
var _t := 0
var _ok := true
var _frozen_at := PackedVector3Array()
var _frames := 0


func _check(cond: bool, msg: String) -> void:
	print("[cloth_pose] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


# A two-bone skeleton (bone 1 one metre up from bone 0) with a 0.2 x 1 m strip
# skinned to bone 1, standing from y 1 to y 2. Returns the cloth node.
func _rig(x: float, bend: bool, pinned_rows: int) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(x, 0, 0)
	get_root().add_child(root)
	var sk := Skeleton3D.new()
	sk.add_bone("root")
	sk.add_bone("tip")
	sk.set_bone_parent(1, 0)
	sk.set_bone_rest(1, Transform3D(Basis(), Vector3(0, 1, 0)))
	sk.reset_bone_poses()
	root.add_child(sk)
	if bend:
		sk.add_child(Bend.new())

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
			bones.append_array([0, 0, 0, 0]) # skin bind 0 (= skeleton bone 1)
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

	var cloth: Node3D = ClassDB.instantiate("PhysXSkinnedCloth3D")
	var dist := PackedFloat32Array()
	for r in ROWS:
		for c in 2:
			dist.append(0.0 if r >= ROWS - pinned_rows else 2.0)
	cloth.set("max_distances", dist)
	sk.add_child(cloth)
	cloth.set("mesh_instance_path", cloth.get_path_to(mi))
	return cloth


# Particle positions in the strip mesh's local space (= the skeleton's).
func _positions(cloth: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var sk := cloth.get_parent()
	for n in sk.get_children(true):
		if n is MeshInstance3D and n.name != "Strip":
			var mat: ShaderMaterial = (n as MeshInstance3D).get_surface_override_material(0)
			var tex: Texture2DRD = mat.get_shader_parameter("cloth_positions") if mat else null
			if tex == null:
				continue
			var f := RenderingServer.get_rendering_device().texture_get_data(tex.texture_rd_rid, 0).to_float32_array()
			for i in int(cloth.call("get_particle_count")):
				out.append(Vector3(f[i * 4], f[i * 4 + 1], f[i * 4 + 2]))
	return out


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXSkinnedCloth3D"):
		print("[cloth_pose] SKIP: no PhysXSkinnedCloth3D")
		quit(0)
		return
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.look_at_from_position(Vector3(2, 1.5, 6), Vector3(2, 1.2, 0))
	_bent = _rig(0, true, 9) # every row pinned
	_hang = _rig(4, false, 1) # only the top row pinned
	physics_frame.connect(_tick)


func _tick() -> void:
	_t += 1
	if _t == 10:
		# Gravity sideways for the hanging strip (the whole world's: both rigs share the space).
		var space := get_root().get_world_3d().space
		PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3(0, 0, 1))
	if _t == 180:
		var p := _positions(_bent)
		_check(p.size() > 0, "the bent strip has %d particles to read" % p.size())
		var top := -INF
		var min_x := INF
		for v in p:
			top = maxf(top, v.y)
			min_x = minf(min_x, v.x)
		_check(top < 1.4 and min_x < -0.8, "0016: the pinned strip follows the bend (highest y %.2f, want ~1.1-1.2; lowest x %.2f, want ~-1.0)" % [top, min_x])
		var h := _positions(_hang)
		var tip := Vector3()
		var low_y := INF
		for v in h:
			if v.y < low_y:
				low_y = v.y
				tip = v
		var max_z := -INF
		for v in h:
			max_z = maxf(max_z, v.z)
		_check(max_z > 0.15, "0017: under sideways gravity the free strip swings toward +Z (furthest z %.2f, want > 0.15: stays ~0 when gravity is ignored)" % max_z)
		if _hang.has_method("get_effective_gravity"):
			var g: Vector3 = _hang.call("get_effective_gravity")
			_check(g.distance_to(Vector3(0, 0, 9.8)) < 0.01, "0017: get_effective_gravity() = %s (want (0, 0, 9.8))" % g)
		# Freeze game time, then flip gravity: nothing may move (compared from a few
		# frames in, after any game time from before the freeze has been simulated).
		PhysicsServer3D.area_set_param(get_root().get_world_3d().space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3(0, 0, -1))
		Engine.time_scale = 0.0
		process_frame.connect(_frozen_frame)


func _frozen_frame() -> void:
	_frames += 1
	if _frames == 5:
		_frozen_at = _positions(_hang)
	if _frames < 45:
		return
	process_frame.disconnect(_frozen_frame)
	Engine.time_scale = 1.0
	var now := _positions(_hang)
	var moved := 0.0
	for i in mini(now.size(), _frozen_at.size()):
		moved = maxf(moved, now[i].distance_to(_frozen_at[i]))
	_check(now.size() > 0 and moved < 0.005, "time_scale 0: the cloth holds still for 40 frames after gravity flips (moved %.3f m)" % moved)
	print("[cloth_pose] ", "PASS" if _ok else "FAIL")
	quit(0 if _ok else 1)
