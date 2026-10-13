extends SceneTree

# PhysXParticleFluid3D.get_submersion() on the MPM solver (it used to always
# return 0: it only asked the PBD fluid object, which MPM never fills). A block of
# MPM fluid settles into a walled tank on the domain floor (the MPM fluid isn't
# confined sideways by its domain, so without walls it spreads thin); a box well
# under the surface must read close to full, a box above it empty, and a box
# straddling the surface about half (so the per-particle volume is right, not just
# clamped to 1). The estimate uses each particle's seeded volume; a settled pool
# is ~15% denser (MPM is slightly compressible) and its particles sit in layers
# ~0.1 m apart, so a box straddling the surface reads somewhat over half. Needs a windowed run (headless has no compute RenderingDevice, so
# MPM skips).

const TANK := 2.0 # inner width of the tank, metres

var _fluid: PhysXParticleFluid3D
var _walls: Array[StaticBody3D] = []
var _floor_y := 0.0
var _tick := 0


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXParticleFluid3D"):
		print("[mpm_submersion] PhysXParticleFluid3D not registered -> SKIP")
		quit(0)
		return
	var root := Node3D.new()
	get_root().add_child(root)
	_fluid = PhysXParticleFluid3D.new()
	_fluid.solver = PhysXParticleFluid3D.SOLVER_MPM
	_fluid.particle_count = 60000
	_fluid.particle_size = 0.05
	_fluid.mpm_domain_size = Vector3(3, 3, 3)
	_fluid.spawn_region_size = Vector3(1.8, 1.0, 1.8)
	_fluid.position = Vector3(0, 3, 0)
	root.add_child(_fluid)
	_floor_y = _fluid.position.y - _fluid.mpm_domain_size.y * 0.5
	for side in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var wall := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.2, 3.0, TANK + 0.4) if side.x != 0.0 else Vector3(TANK + 0.4, 3.0, 0.2)
		cs.shape = box
		wall.add_child(cs)
		wall.position = Vector3(0, _floor_y + 1.5, 0) + side * (TANK * 0.5 + 0.1)
		root.add_child(wall)
		_walls.append(wall)
	# get_path() needs the nodes fully in the tree: wire the walls in on the first physics tick.
	call_deferred("_wire_walls")


func _wire_walls() -> void:
	var paths: Array[NodePath] = []
	for w in _walls:
		paths.append(w.get_path())
	_fluid.mpm_colliders = paths


# A 1 m x height x 1 m box over the tank's centre, its bottom h metres above the floor.
func _probe(h: float, height := 0.2) -> float:
	return _fluid.get_submersion(AABB(Vector3(-0.5, _floor_y + h, -0.5), Vector3(1.0, height, 1.0)))


func _surface_y() -> float:
	var pts := _fluid.get_particle_positions()
	var ys := PackedFloat32Array()
	for p in pts:
		if absf(p.x) < 0.5 and absf(p.z) < 0.5:
			ys.append(p.y)
	if ys.is_empty():
		return NAN
	ys.sort()
	return ys[int(ys.size() * 0.99)] # the top of the centre column, past a stray splash


func _physics_process(_d: float) -> bool:
	_tick += 1
	if _tick == 6 and _fluid.get_live_particle_count() == 0:
		print("[mpm_submersion] 0 live particles (no compute RenderingDevice) -> SKIP")
		quit(0)
		return true
	if _tick % 40 == 0 or _tick == 180:
		print("[mpm_submersion] tick %3d  surface %.2f m over the floor  low box %.2f  above box %.2f" % [
			_tick, _surface_y() - _floor_y, _probe(0.1), _probe(1.6)])
	if _tick == 180:
		var low := _probe(0.1)
		var above := _probe(1.6)
		var surface := _surface_y() - _floor_y
		var half := _probe(surface - 0.2, 0.4) # half under the surface, half over it
		var ok := low > 0.7 and above < 0.02 and half > 0.35 and half < 0.8
		print("[mpm_submersion]   box inside the pool %.2f (want > 0.7), above it %.2f (want ~0), across the surface %.2f (want 0.35-0.8) -> %s" % [
			low, above, half, "PASS" if ok else "FAIL"])
		quit(0 if ok else 1)
	return false
