extends RigidBody3D
# Sample-point buoyancy: floats by pushing up at a handful of points on the
# hull, proportional to how far each point is submerged below the water
# surface -- the same technique the caustic-volume reference's duck demo
# uses, and most arcade boat physics. Works on any backend (Jolt/
# GodotPhysics/PhysX) since it only calls RigidBody3D.apply_force() -- no
# physics-engine-specific API at all.
#
# Phase 2: water_surface_path (optional) points at a real PhysXWaterSurface3D
# -- when set, each sample point's water height comes from
# PhysXWaterSurface3D.sample_height() (real ripple+ocean wave data) instead
# of the flat water_level constant, and this body registers itself as a
# ripple-disturbing sphere proxy each tick so it actually pushes the water,
# not just receives a height back. Leaving water_surface_path unset keeps the
# original flat-water behavior byte-for-byte -- strictly additive, nothing
# that only sets water_level breaks.

@export var water_level := 0.0 # world-space Y of the water surface -- fallback when water_surface_path is unset
@export var water_surface_path: NodePath # optional; a PhysXWaterSurface3D for real wave data
@export var sample_points: Array[Vector3] = [
	Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(1, 0, 1),
] # local-space offsets, roughly at the hull's waterline corners
@export var buoyancy_strength := 10.0 # upward force per meter submerged, per sample point
@export var water_drag := 2.0 # damps each sample point's own velocity while submerged -- without this the hull bobs forever
@export var hull_radius := 1.0 # approximate footprint radius, used only to register as a ripple-disturbing sphere proxy when water_surface_path is set

var _water: Node # PhysXWaterSurface3D -- untyped since this script must load even in a build without the water module

func _ready() -> void:
	if water_surface_path.is_empty():
		return
	_water = get_node_or_null(water_surface_path)

func _exit_tree() -> void:
	if _water != null and is_instance_valid(_water):
		_water.clear_sphere(get_instance_id())

func _physics_process(_delta: float) -> void:
	if _water != null:
		_water.submit_sphere(get_instance_id(), global_position, hull_radius, 1.0)

	for local_pt in sample_points:
		var world_pt := to_global(local_pt)
		var level: float = _water.sample_height(world_pt) if _water != null else water_level
		var submersion: float = level - world_pt.y
		if submersion <= 0.0:
			continue
		var offset := world_pt - global_position
		var point_vel := linear_velocity + angular_velocity.cross(offset)
		var force := Vector3.UP * buoyancy_strength * submersion
		force -= point_vel * water_drag
		apply_force(force, offset)
