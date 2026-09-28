extends RigidBody3D
# Sample-point buoyancy: floats by pushing up at a handful of points on the
# hull, proportional to how far each point is submerged below the water
# surface -- the same technique the caustic-volume reference's duck demo
# uses, and most arcade boat physics. Works on any backend (Jolt/
# GodotPhysics/PhysX) since it only calls RigidBody3D.apply_force() -- no
# physics-engine-specific API at all.
#
# Phase 1: flat analytic water_level (no waves yet). Once the FFT wave
# surface exists, water_level should become a real height sample at each
# point's XZ instead of one constant.

@export var water_level := 0.0 # world-space Y of the water surface
@export var sample_points: Array[Vector3] = [
	Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(1, 0, 1),
] # local-space offsets, roughly at the hull's waterline corners
@export var buoyancy_strength := 10.0 # upward force per meter submerged, per sample point
@export var water_drag := 2.0 # damps each sample point's own velocity while submerged -- without this the hull bobs forever

func _physics_process(_delta: float) -> void:
	for local_pt in sample_points:
		var world_pt := to_global(local_pt)
		var submersion := water_level - world_pt.y
		if submersion <= 0.0:
			continue
		var offset := world_pt - global_position
		var point_vel := linear_velocity + angular_velocity.cross(offset)
		var force := Vector3.UP * buoyancy_strength * submersion
		force -= point_vel * water_drag
		apply_force(force, offset)
