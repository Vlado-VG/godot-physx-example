class_name BombLook
extends RefCounted

# The red bomb the demos fire (playground, tank, destructible rigs): one shared material. The first time a material
# like it is drawn in a run, the renderer builds its shader pipeline, and that frame hitches -- on the first shot,
# mid-game. prewarm() draws it once, as a 1 cm sphere in front of the camera for two frames, while the scene loads.

static var _material: StandardMaterial3D


static func material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.albedo_color = Color(0.95, 0.3, 0.1)
		_material.emission_enabled = true
		_material.emission = Color(0.6, 0.15, 0.0)
	return _material


static func mesh(radius: float) -> SphereMesh:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.material = material()
	return sm


# Call from _ready(): waits a frame for the scene's camera, then shows the bomb to it for two frames.
static func prewarm(p_node: Node) -> void:
	await p_node.get_tree().process_frame
	var cam := p_node.get_viewport().get_camera_3d()
	if cam == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh(0.005)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cam.add_child(mi)
	mi.position = Vector3(0, 0, -1)
	await p_node.get_tree().process_frame
	await p_node.get_tree().process_frame
	mi.queue_free()
