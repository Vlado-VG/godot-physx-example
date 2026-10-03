extends SceneTree

# Temporary trickle probe: RiverWater live count + how far downstream the
# water has traveled (max X along the course), sampled every second.

var _scene: Node3D
var _water: PhysXParticleFluid3D
var _tick := 0

func _initialize() -> void:
	_scene = load("res://demo/gpu/physx_river.tscn").instantiate()
	root.add_child(_scene)

func _physics_process(_d: float) -> bool:
	_tick += 1
	if _water == null and _scene.has_node("RiverWater"):
		_water = _scene.get_node("RiverWater")
	if _water == null or _tick < 60:
		return false
	if _tick % 60 == 0:
		var pts := _water.get_particle_positions()
		var max_x := -1e9
		var min_y := 1e9
		for p2 in pts:
			max_x = maxf(max_x, p2.x)
			min_y = minf(min_y, p2.y)
		print("[trickle] t=%4d live=%d max_x=%.1f min_y=%.1f" % [_tick, pts.size(), max_x, min_y])
	if _tick >= 1200:
		print("[trickle] done")
		quit(0)
		return true
	return false
