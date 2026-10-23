extends SceneTree

# PhysXLensFlare3D: the frame's bright light reflected back over the screen as
# ghosts through its centre. A small bright light in the upper left of a black
# view, and settings with one white ghost at scale -1 (the light mirrored
# through the centre, its own size) and no halo:
#   1. the mirrored point (lower right) brightens;
#   2. a point off the ghost's line (lower left) doesn't;
#   3. a light below the threshold doesn't flare at all;
#   4. no ghosts and no halo, or the node hidden, leaves the frame as it was;
#   5. the default look (no settings) flares too.
# Needs a window (the effect is a compositor effect):
#   godot --path . --script res://test/gpu/lens_flare_test.gd

const LIGHT_UV := Vector2(0.25, 0.3)

var _flare: Node3D
var _settings: Resource
var _light_mat: ShaderMaterial
var _light: MeshInstance3D
var _cam: Camera3D
var _t := 0
var _ok := true
var _shots := {}


func _check(cond: bool, msg: String) -> void:
	print("[lens_flare] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXLensFlare3D"):
		print("[lens_flare] SKIP: no PhysXLensFlare3D")
		quit(0)
		return
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	we.environment = env
	get_root().add_child(we)
	_cam = Camera3D.new()
	get_root().add_child(_cam)

	# A small light, as bright as a sun's disk (well past the threshold).
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nrender_mode unshaded;\nuniform float level = 8.0;\nvoid fragment() { ALBEDO = vec3(level); }\n"
	_light_mat = ShaderMaterial.new()
	_light_mat.shader = shader
	_light = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.4, 0.4)
	_light.mesh = q
	_light.material_override = _light_mat
	get_root().add_child(_light)

	_settings = ClassDB.instantiate("PhysXLensFlareSettings")
	_settings.set("ghost_colors", PackedColorArray([Color.WHITE]))
	_settings.set("ghost_scales", PackedFloat32Array([-1.0]))
	_settings.set("ghost_chroma_shift", 0.0)
	_settings.set("halo_intensity", 0.0)
	_settings.set("tint", Color.WHITE)
	_flare = ClassDB.instantiate("PhysXLensFlare3D")
	_flare.visible = false
	_flare.set("settings", _settings)
	get_root().add_child(_flare)
	process_frame.connect(_frame)


func _shot() -> Image:
	return get_root().get_texture().get_image()


func _lum(img: Image, uv: Vector2) -> float:
	var c := img.get_pixel(int(uv.x * img.get_width()), int(uv.y * img.get_height()))
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _max_diff(a: Image, b: Image) -> float:
	var d := 0.0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			d = maxf(d, maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b))))
	return d


func _frame() -> void:
	_t += 1
	# Each state gets 20 frames to settle before its shot.
	match _t:
		1:
			# Placed once the camera is in the tree.
			_light.position = _cam.project_position(LIGHT_UV * get_root().get_visible_rect().size, 5.0)
		20:
			_shots["off"] = _shot()
			_flare.visible = true
		40:
			_shots["on"] = _shot()
			_light_mat.set_shader_parameter("level", 0.5)
		60:
			_shots["dim"] = _shot()
			_flare.visible = false
		80:
			_shots["dim_off"] = _shot()
			_light_mat.set_shader_parameter("level", 8.0)
			_flare.visible = true
			_settings.set("ghost_scales", PackedFloat32Array())
		100:
			_shots["no_ghosts"] = _shot()
			_flare.set("settings", null)
		120:
			_shots["default"] = _shot()
			_flare.visible = false
		140:
			_shots["hidden"] = _shot()
			_finish()


func _finish() -> void:
	var mirrored := Vector2.ONE - LIGHT_UV
	var off_line := Vector2(LIGHT_UV.x, mirrored.y)
	var off: Image = _shots["off"]
	var on: Image = _shots["on"]
	print("[lens_flare] light %.3f  mirrored off %.3f on %.3f  off-line off %.3f on %.3f" % [
		_lum(off, LIGHT_UV), _lum(off, mirrored), _lum(on, mirrored), _lum(off, off_line), _lum(on, off_line)])
	_check(_lum(off, LIGHT_UV) > 0.9, "the light is in the frame where expected")
	_check(_lum(on, mirrored) - _lum(off, mirrored) > 0.05, "the ghost lights the mirrored point (+%.3f)" % (_lum(on, mirrored) - _lum(off, mirrored)))
	_check(absf(_lum(on, off_line) - _lum(off, off_line)) < 0.01, "off the ghost's line stays dark")
	var dim_diff := _max_diff(_shots["dim"], _shots["dim_off"])
	_check(dim_diff < 0.01, "a light below the threshold doesn't flare (max diff %.4f)" % dim_diff)
	var none_diff := _max_diff(_shots["no_ghosts"], off)
	_check(none_diff < 0.01, "no ghosts and no halo draws nothing (max diff %.4f)" % none_diff)
	_check(_max_diff(_shots["default"], off) > 0.05, "the default look flares")
	var hidden_diff := _max_diff(_shots["hidden"], off)
	_check(hidden_diff < 0.01, "hidden draws nothing (max diff %.4f)" % hidden_diff)
	print("[lens_flare] %s" % ("PASS" if _ok else "FAIL"))
	quit(0 if _ok else 1)
