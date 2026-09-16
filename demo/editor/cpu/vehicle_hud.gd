extends CanvasLayer

# Forza-Horizon-style telemetry readout -- plain numbers, monospace, no
# gauges. Everything is read off vehicle_car.gd's telemetry dict, which the
# car fills from the PhysX vehicle2 state each physics tick.
#
#   SPEED / RPM / GEAR / THROTTLE / BRAKE / STEERING / CLUTCH / HANDBRAKE
#   FUEL (0.0 - 1.0, one decimal) / ENGINE on-off / DRIVE mode
#   PITCH / ROLL / G-force lat+long, and a per-wheel contact+slip grid.

@onready var _car: RigidBody3D = get_node("../DogeCar")
@onready var _panel: Label = $Telemetry
@onready var _speed_label: Label = $Speed


func _process(_delta: float) -> void:
	var t: Dictionary = _car.telemetry
	var wheel_lines := _wheel_grid(t["wheels"])
	_panel.text = "\n".join(PackedStringArray([
		"SPEED      %6.1f km/h" % t["speed_kmh"],
		"RPM        %6.0f" % t["rpm"] if t["gearbox"] else "WHEEL RPM  %6.0f" % t["wheel_rpm"],
		"GEAR       %6s" % t["gear_label"],
		"THROTTLE   %6.2f" % t["throttle"],
		"BRAKE      %6.2f" % t["brake"],
		"STEERING   %6.2f" % t["steer"],
		"CLUTCH     %6.2f" % t["clutch"],
		"HANDBRAKE  %6.2f" % t["handbrake"],
		"",
		"ENGINE     %6s" % ("ON" if t["engine_on"] else "OFF"),
		"FUEL       %6.1f" % t["fuel"],
		"DRIVE      %6s" % _drive_label(t),
		"",
		"PITCH      %6.1f deg" % t["pitch"],
		"ROLL       %6.1f deg" % t["roll"],
		"G LAT      %6.2f g" % t["g_lat"],
		"G LONG     %6.2f g" % t["g_long"],
		"",
		wheel_lines[0],
		wheel_lines[1],
		wheel_lines[2],
	]))
	_speed_label.text = "%d" % int(round(t["speed_kmh"]))


func _drive_label(t: Dictionary) -> String:
	if not t["gearbox"]:
		return "DIRECT"
	return "GEARBOX-MAN" if t["manual_gear"] else "GEARBOX-AUTO"


## 2x2 wheel grid: contact marker, wheel rpm and longitudinal slip per wheel.
## Order matches the car: 0 RF, 1 LF, 2 RR, 3 LR -> display FL FR / RL RR.
func _wheel_grid(wheels: Array) -> Array:
	if wheels.size() < 4:
		return ["WHEELS     (waiting for telemetry)", "", ""]
	var order := [1, 0, 3, 2]
	var cells: Array[String] = []
	for idx in order:
		var w: Dictionary = wheels[idx]
		cells.append("%s c%5.0f s%5.2f" % [
				"FL" if idx == 1 else ("FR" if idx == 0 else ("RL" if idx == 3 else "RR")),
				w["rpm"], w["slip"]])
	return [
		"WHEELS     %s   %s" % [cells[0], cells[1]],
		"           %s   %s" % [cells[2], cells[3]],
		"(c = wheel rpm, s = longitudinal slip, contact shown by nonzero rpm)",
	]
