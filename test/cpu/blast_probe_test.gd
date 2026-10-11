extends SceneTree

# Verifies the Blast runtime path (feature/physx-blast-destruction) on this
# engine: the pre-authored Blast asset (a cube Voronoi-fractured into 8
# chunks, authored offline by the module's throwaway blast_test_gen tool --
# see test/data/blast_cube.asset/.chunks) is loaded through
# PhysXDestructible3D (its native asset_path/chunks_path format), radial
# damage covering the whole thing splits it into 8 real rigid bodies -- one
# per leaf chunk, each with a real convex collision shape cooked from that
# chunk's render-mesh points via the normal PhysicsServer3D path -- all
# placed at the node's pose.
#
# (Upstream's godot-physx-example drives the same asset through a
# GodotPhysXBlastProbe harness class that doesn't exist in this engine;
# this project's destructible node is the equivalent.)

var _destructible: PhysXDestructible3D
var _tick := 0

func _initialize() -> void:
	print("[blast_probe] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXDestructible3D"):
		print("[blast_probe] PhysXDestructible3D not registered (build without blast) -> FAIL")
		quit(1)
		return

	var root := Node3D.new()
	get_root().add_child(root)

	var floor_body := StaticBody3D.new()
	var fc := CollisionShape3D.new()
	var fs := BoxShape3D.new()
	fs.size = Vector3(50, 1, 50)
	fc.shape = fs
	floor_body.add_child(fc)
	floor_body.position = Vector3(0, -5, 0)
	root.add_child(floor_body)

	var destructible := PhysXDestructible3D.new()
	destructible.asset_path = ProjectSettings.globalize_path("res://test/data/blast_cube.asset")
	destructible.chunks_path = ProjectSettings.globalize_path("res://test/data/blast_cube.chunks")
	destructible.position = Vector3(0, 5, 0)
	root.add_child(destructible)
	_destructible = destructible

func _physics_process(_d: float) -> bool:
	_tick += 1
	if _tick < 2:
		return false
	if not _destructible.is_loaded():
		print("[blast_probe] load() failed -> FAIL")
		quit(1)
		return false

	# Overkill damage covering the whole 2x2x2 cube from its center -- see
	# the module's Blast planning notes for why damage=1.0 (exact 100% of
	# the bonds' initial health) was insufficient in the standalone prototype
	# despite reporting health=0.0; 5.0 reliably crosses whatever the real
	# break threshold is. PhysXDestructible3D converts the world damage point
	# to local space internally -- the node sits at (0, 5, 0), so world
	# (0, 5, 0) is the same center-of-cube point upstream's probe hit with
	# local Vector3.ZERO.
	var spawned: int = _destructible.apply_radial_damage(Vector3(0, 5, 0), 5.0, 0.1, 3.0)
	var body_count: int = _destructible.get_piece_count()
	print("[blast_probe] apply_radial_damage spawned=", spawned, " body_count=", body_count)

	var ok: bool = spawned == 8 and body_count == 8
	if ok:
		# Confirm the spawned pieces are real, live PhysicsServer3D bodies
		# with a sane transform (the node's pose -- redot places every new
		# piece body there, the visual mesh carries the chunk offset) -- not
		# just RIDs that happen to exist.
		for i in body_count:
			var xform: Transform3D = _destructible.get_piece_transform(i)
			if xform.origin.distance_to(Vector3(0, 5, 0)) > 0.01:
				print("[blast_probe] body %d has unexpected transform %s -> FAIL" % [i, xform])
				ok = false

	print("[blast_probe] overall -> %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
	return false
