extends SceneTree

# Verifies PhysXDestructible3D distributes mass across split pieces
# proportional to each one's actual volume (feature/physx-blast-destruction)
# -- checked how Unreal's own Blast integration handles this
# (BlastMeshComponent.cpp: IdealChunkMass = RootChunkMass * ThisChunkVolume /
# TotalVolume) since every piece used to get PhysicsServer3D's flat default
# mass (1.0) regardless of size.
#
# No direct API exposes a piece's body RID to script, but
# PhysicsDirectSpaceState3D.intersect_shape() results carry "rid" -- a real
# overlap query is enough to get each spawned piece's actual body RID, then
# PhysicsServer3D.body_get_param(rid, BODY_PARAM_MASS) reads back what
# _chunk_mass() actually assigned it. Two things verified: masses are NOT
# all identical (proves real per-piece distribution happened, not just the
# same flat default every piece used to get), and they sum close to the
# configured total mass (conservation, same as Unreal's own approach).
#
# SKIPs (not FAILs) on a build without blast_sdk= configured.

var _node
var _tick := 0

func _initialize() -> void:
	print("[destructible_mass] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXDestructible3D"):
		print("[destructible_mass] PhysXDestructible3D not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var root := Node3D.new()
	get_root().add_child(root)

	_node = ClassDB.instantiate("PhysXDestructible3D")
	_node.asset_path = ProjectSettings.globalize_path("res://test/data/blast_cube.asset")
	_node.chunks_path = ProjectSettings.globalize_path("res://test/data/blast_cube.chunks")
	_node.mass = 8.0
	_node.position = Vector3(0, 5, 0)
	root.add_child(_node)

func _physics_process(_delta: float) -> bool:
	_tick += 1

	if _tick == 10:
		var spawned: int = _node.apply_radial_damage(Vector3(0, 5, 0), 5.0, 0.1, 3.0)
		print("[destructible_mass] apply_radial_damage spawned=", spawned)
		if spawned != 8:
			print("[destructible_mass] FAIL: expected 8 pieces, got ", spawned)
			quit(1)
			return true

	if _tick == 15:
		var params := PhysicsShapeQueryParameters3D.new()
		var probe_shape := BoxShape3D.new()
		probe_shape.size = Vector3(6, 6, 6)
		params.shape = probe_shape
		params.transform = Transform3D(Basis(), Vector3(0, 5, 0))
		var hits := get_root().get_world_3d().direct_space_state.intersect_shape(params, 16)

		var masses: Array[float] = []
		var seen := {}
		for h in hits:
			var rid: RID = h.get("rid")
			if seen.has(rid):
				continue
			seen[rid] = true
			var m: float = PhysicsServer3D.body_get_param(rid, PhysicsServer3D.BODY_PARAM_MASS)
			masses.append(m)

		print("[destructible_mass] piece masses = ", masses)
		if masses.size() != 8:
			print("[destructible_mass] FAIL: expected 8 distinct piece bodies, got ", masses.size())
			quit(1)
			return true

		var total := 0.0
		var min_m: float = masses[0]
		var max_m: float = masses[0]
		for m in masses:
			total += m
			min_m = minf(min_m, m)
			max_m = maxf(max_m, m)

		# Not all the same -- real per-piece distribution, not a flat default.
		var distributed := (max_m - min_m) > 0.01
		# Sums close to the configured total mass (8.0), allowing some slack
		# for the minimum-mass floor on any unusually small slice.
		var conserved := absf(total - 8.0) < 1.0
		print("[destructible_mass] min=", min_m, " max=", max_m, " total=", total,
			" distributed=", distributed, " conserved=", conserved)

		var ok := distributed and conserved
		print("[destructible_mass] overall -> %s" % ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
		return true
	return false
