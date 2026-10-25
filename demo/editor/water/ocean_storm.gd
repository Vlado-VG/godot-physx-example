extends Node3D

# Open-ocean storm: a boat on deep water whose sea state changes during play.
#
#   W / S  throttle   A / D  steer   mouse  look   wheel  camera distance
#   1 / 2 / 3  ease toward calm / breezy / storm
#   4      automatic storm cycle on / off
#   H      wake hull outline: box / pointed skiff
#   Esc    release the mouse (click to capture again)
#
# What it shows:
# - set_sea_state(): wind, direction, wave height and fetch change every frame
#   without a rebuild -- the waves keep their phase and grow, calm or turn, and
#   the boat's wake and foam carry on through it.
# - recenter(): the simulated ripple square follows the boat (re-centred when
#   the boat is RECENTER_DISTANCE from its centre) with no frame of missing
#   water, and the ocean's waves stay put in the world while it moves.
#   That makes this an endless ocean: the FFT waves are periodic and fixed to
#   the world, so they have no edge; only the small square where the boat
#   splashes is bounded, and it travels with the boat, while render_extent
#   draws the sea out to the horizon. Drive as far as you like. (The one limit
#   is float precision hundreds of km from the origin, as in any Godot scene.)
#   A custom water material must sample the ocean at world X/Z for this --
#   see water_surface.gdshader's cuv_o -- or its waves slide on every recenter.
# - PhysXWaterWake3D.hull_profile: a tapered hull's foam follows its sides.

const RECENTER_DISTANCE := 10.0
const EASE_RATE := 0.08 # storm intensity change per second
const CYCLE_SECONDS := 120.0 # calm -> storm -> calm in auto mode

# Sea state at intensity 0 (calm) and 1 (storm).
const WIND_CALM := 5.0
const WIND_STORM := 26.0
const AMP_CALM := 0.25
const AMP_STORM := 2.0
const DIR_CALM := Vector2(-1.0, 0.3)
const DIR_TURN := 0.6 # the wind backs this much (radians) as the storm builds

# The pointed skiff's half-beam from bow to stern (fractions of the full half-beam).
const SKIFF_PROFILE := [0.12, 0.5, 0.82, 0.97, 1.0, 1.0, 0.96, 0.88]

@onready var _water: PhysXWaterSurface3D = $Water
@onready var _boat: RigidBody3D = $Boat
@onready var _wake: PhysXWaterWake3D = $Boat/Wake
@onready var _sun: DirectionalLight3D = $Sun
@onready var _env: Environment = ($WorldEnvironment as WorldEnvironment).environment
@onready var _hud: Label = $HUD/Label

var _intensity := 0.0
var _target := 0.0
var _auto := false
var _auto_time := 0.0
var _recenters := 0
var _profiled := true
var _sky: ProceduralSkyMaterial
var _sky_top_calm: Color
var _sky_horizon_calm: Color
var _fog_color_calm: Color
var _sun_energy_calm := 1.0


func _ready() -> void:
	_sky = _env.sky.sky_material as ProceduralSkyMaterial
	_sky_top_calm = _sky.sky_top_color
	_sky_horizon_calm = _sky.sky_horizon_color
	_fog_color_calm = _env.fog_light_color
	_sun_energy_calm = _sun.light_energy
	_wake.hull_profile = PackedFloat32Array(SKIFF_PROFILE)
	($Boat/ChaseCamera as Camera3D).make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply(true)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_1:
			_target = 0.0
			_auto = false
		KEY_2:
			_target = 0.5
			_auto = false
		KEY_3:
			_target = 1.0
			_auto = false
		KEY_4:
			_auto = not _auto
			_auto_time = asin(clampf(_intensity * 2.0 - 1.0, -1.0, 1.0)) / TAU * CYCLE_SECONDS + CYCLE_SECONDS * 0.25
		KEY_H:
			_profiled = not _profiled
			_wake.hull_profile = PackedFloat32Array(SKIFF_PROFILE) if _profiled else PackedFloat32Array()
		_:
			return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _auto:
		_auto_time += delta
		_target = 0.5 - 0.5 * cos(_auto_time / CYCLE_SECONDS * TAU)
	var before := _intensity
	_intensity = move_toward(_intensity, _target, EASE_RATE * delta)
	if _intensity != before:
		_apply(false)

	# The ripple square follows the boat.
	var bp := _boat.global_position
	var center := _water.global_position
	if Vector2(bp.x - center.x, bp.z - center.z).length() > RECENTER_DISTANCE:
		_water.recenter(bp)
		_recenters += 1

	_hud.text = "Sea: %s  (intensity %.2f%s)\nwind %.1f m/s, waves x%.2f   ripple square re-centred %d times\nendless ocean: %.0f m from the origin -- the ripple square follows the boat, the waves have no edge\nwake hull: %s   [1/2/3] calm/breezy/storm  [4] auto cycle  [H] hull outline  [WASD] drive" % [
		_sea_name(), _intensity, ", auto" if _auto else "", _water.wind_speed, _water.wave_amplitude, _recenters,
		Vector2(bp.x, bp.z).length(), "pointed skiff" if _profiled else "box"]


func _apply(_initial: bool) -> void:
	var k := _intensity
	var dir := DIR_CALM.normalized().rotated(DIR_TURN * k)
	_water.set_sea_state(lerpf(WIND_CALM, WIND_STORM, k), dir, lerpf(AMP_CALM, AMP_STORM, k), 0.0)
	# The weather around it.
	_sun.light_energy = lerpf(_sun_energy_calm, _sun_energy_calm * 0.25, k)
	_sky.sky_top_color = _sky_top_calm.lerp(Color(0.18, 0.2, 0.24), k)
	_sky.sky_horizon_color = _sky_horizon_calm.lerp(Color(0.32, 0.35, 0.38), k)
	_env.fog_light_color = _fog_color_calm.lerp(Color(0.36, 0.39, 0.42), k)
	_env.fog_density = lerpf(0.002, 0.012, k)


func _sea_name() -> String:
	if _intensity < 0.2:
		return "calm"
	if _intensity < 0.65:
		return "breezy"
	return "storm"
