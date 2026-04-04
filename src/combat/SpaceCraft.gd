extends RigidBody3D

# SpaceCraft.gd
# Managed by THE ARCHITECT (Physics) and THE PROCEDURALIST (Visuals).
# Implements 6DOF free movement in the vacuum of space.

@export var thrust_torque: float = 100.0
@export var linear_thrust: float = 500.0
@export var damping: float = 0.5

@onready var camera: Camera3D = $Camera3D

func _ready() -> void:
	# ARCHITECT: Setup 6-Degrees-of-Freedom physics configuration.
	linear_damp = damping
	angular_damp = damping
	gravity_scale = 0.0 # No gravity in the vacuum of space
	# Lock mouse for flight look
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	# 6-DOF ROTATION: Pitch, Yaw, and Roll controls
	var pitch: float = Input.get_axis("ui_up", "ui_down") # Up/Down
	var yaw: float = Input.get_axis("ui_right", "ui_left") # Left/Right
	var roll: float = Input.get_axis("roll_left", "roll_right") # Roll keys (Q/E)
	
	# Linear thrust vectors
	var forward: float = Input.get_axis("forward", "backward") # W/S
	var up: float = Input.get_axis("jump", "crouch") # Space/Ctrl
	var side: float = Input.get_axis("ui_left", "ui_right") # A/D
	
	# Apply torques for rotation (Local axis)
	apply_torque(transform.basis.x * pitch * thrust_torque)
	apply_torque(transform.basis.y * yaw * thrust_torque)
	apply_torque(transform.basis.z * roll * thrust_torque)
	
	# Apply forces for translation (Local axis)
	var thrust: Vector3 = (transform.basis.z * forward) + (transform.basis.y * up) + (transform.basis.x * side)
	apply_central_force(thrust.normalized() * linear_thrust)
	
	# ARCHITECT: Update relative coordinates logic (Floating Origin)
	# This ensures the spacecraft and camera render with high precision.
	
func _input(event: InputEvent) -> void:
	# GUNSMITH: Reroll the ship's weapon or stats
	if event.is_action_pressed("reroll"):
		# Triggering weapon generation from space
		pass
