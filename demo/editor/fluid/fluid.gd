extends Node3D

# Editor + runtime showcase for PhysXParticleFluid3D. Everything is a real scene
# node: select the fluid to see its inspector and drag its spawn-region gizmo
# handles in the viewport. Press Play and it fills the tank.
#
#   SPACE  drop a ball    M  render mode    R  reset    ESC

@onready var _fluid: PhysXParticleFluid3D = $PhysXParticleFluid3D
@onready var _hud: Label = $HUD/Label
var _balls: Array[RigidBody3D] = []
const MODES := ["Particles", "Isosurface", "Screen Space"]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_drop_ball()
			KEY_M:
				# Particles -> Isosurface -> Screen Space, live. (String access: this
				# engine build has no render_mode yet; the key comes alive with it.)
				if _fluid.get("render_mode") != null:
					_fluid.set("render_mode", (int(_fluid.get("render_mode")) + 1) % MODES.size())
			KEY_R:
				for b in _balls:
					if is_instance_valid(b):
						b.queue_free()
				_balls.clear()
				_fluid.clear()
			KEY_ESCAPE:
				get_tree().quit()

func _drop_ball() -> void:
	var rb := RigidBody3D.new()
	rb.mass = 3.0
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.14
	cs.shape = sh
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.14
	sm.height = 0.28
	mi.mesh = sm
	rb.add_child(mi)
	rb.position = _fluid.global_position + Vector3(randf_range(-0.3, 0.3), 1.2, randf_range(-0.3, 0.3))
	add_child(rb)
	_balls.append(rb)

func _process(_dt: float) -> void:
	var mode_v = _fluid.get("render_mode") # null until the engine build has render modes
	_hud.text = "PhysXParticleFluid3D showcase   SPACE ball   M render mode   R reset   ESC\nparticles: %d   render: %s   FPS: %d" % [
		_fluid.get_live_particle_count(), MODES[int(mode_v)] if mode_v != null else "-", Engine.get_frames_per_second()]
