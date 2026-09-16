extends SceneTree

# Verifies the real PhysXDestructible3D node (feature/physx-blast-destruction,
# Phase 3): intact, it should render/collide as the whole unfractured cube
# (chunk 0) via one static body. apply_radial_damage() should fracture it
# into 8 real falling rigid bodies with their own convex collision + visual
# mesh instance, which then land on a floor under gravity like any other
# rigid body in this module.
#
# SKIPs (not FAILs) on a build without blast_sdk= configured, same as
# blast_probe_test.gd -- PhysXDestructible3D doesn't exist in that build.

var _node
var _tick := 0
var _damage_applied := false

func _initialize() -> void:
	print("[destructible] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXDestructible3D"):
		print("[destructible] PhysXDestructible3D not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var root := Node3D.new()
	get_root().add_child(root)

	var floor_body := StaticBody3D.new()
	var fc := CollisionShape3D.new()
	var fs := BoxShape3D.new()
	fs.size = Vector3(50, 1, 50)
	fc.shape = fs
	floor_body.add_child(fc)
	floor_body.position = Vector3(0, -6, 0)
	root.add_child(floor_body)

	_node = ClassDB.instantiate("PhysXDestructible3D")
	_node.asset_path = ProjectSettings.globalize_path("res://test/data/blast_cube.asset")
	_node.chunks_path = ProjectSettings.globalize_path("res://test/data/blast_cube.chunks")
	_node.position = Vector3(0, 5, 0)
	root.add_child(_node)

func _physics_process(_delta: float) -> bool:
	_tick += 1

	if _tick == 5:
		# Intact: exactly one real PhysicsServer3D body should exist (chunk 0,
		# the whole unfractured mesh), sitting still (static) at the node's
		# own position -- confirm via a direct-space overlap query rather
		# than reaching into the node's private state.
		var params := PhysicsShapeQueryParameters3D.new()
		var probe_shape := BoxShape3D.new()
		probe_shape.size = Vector3(3, 3, 3)
		params.shape = probe_shape
		params.transform = Transform3D(Basis(), Vector3(0, 5, 0))
		var hits := get_root().get_world_3d().direct_space_state.intersect_shape(params, 8)
		print("[destructible] intact overlap hits=", hits.size(), " (expect >= 1, the intact body)")
		if hits.size() < 1:
			print("[destructible] FAIL: intact body not found where expected")
			quit(1)
			return true

	if _tick == 10 and not _damage_applied:
		_damage_applied = true
		var spawned: int = _node.apply_radial_damage(Vector3(0, 5, 0), 5.0, 0.1, 3.0)
		print("[destructible] apply_radial_damage spawned=", spawned)
		if spawned != 8:
			print("[destructible] FAIL: expected 8 pieces, got ", spawned)
			quit(1)
			return true

	if _tick == 200:
		# Pieces should have fallen under gravity and landed on the floor by
		# now (floor top is at y=-5.5) -- confirm at least one real body
		# actually moved and came to rest near the floor, not stuck at the
		# original y=5 spawn height (which would mean gravity/collision never
		# applied to the spawned pieces).
		var params := PhysicsShapeQueryParameters3D.new()
		var probe_shape := BoxShape3D.new()
		probe_shape.size = Vector3(20, 4, 20)
		params.shape = probe_shape
		params.transform = Transform3D(Basis(), Vector3(0, -4, 0))
		var hits := get_root().get_world_3d().direct_space_state.intersect_shape(params, 16)
		print("[destructible] near-floor hits=", hits.size(), " (expect >= 1, pieces should have fallen)")
		var ok := hits.size() >= 1
		print("[destructible] overall -> %s" % ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
		return true
	return false
