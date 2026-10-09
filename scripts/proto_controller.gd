extends CharacterBody3D

enum State { SKATE, WALL_RUN }

const MIN_STRAFE_INTO_WALL := 0.5
const WALL_RUN_EXIT_RATIO := 0.5

@export var can_move : bool = true
@export var has_gravity : bool = true
@export var can_jump : bool = true
@export var can_brake : bool = true
@export var can_wall_run : bool = true

@export_group("Skating")
@export var top_speed : float = 15.0
@export var push_acceleration : float = 15.0
@export var ice_friction : float = 2.5
@export var brake_deceleration : float = 25.0
@export_range(0.0, 1.0) var air_control : float = 0.4
@export var jump_velocity : float = 4.5

@export_group("Wall Run")
@export var wall_run_min_speed : float = 6.0
@export var wall_stick_speed : float = 2.0
@export var wall_jump_push : float = 6.0
@export var wall_jump_lift : float = 5.0
@export var wall_run_cooldown : float = 0.3

@export_group("Look")
@export var look_speed : float = 0.002

@export_group("Input Actions")
@export var input_left : String = "left"
@export var input_right : String = "right"
@export var input_forward : String = "forward"
@export var input_back : String = "backward"
@export var input_jump : String = "jump"
@export var input_brake : String = "brake"

var state : State = State.SKATE
var wall_normal : Vector3 = Vector3.ZERO
var wall_cooldown_left : float = 0.0
var mouse_captured : bool = false
var look_rotation : Vector2
var hooked := false

@onready var head: Node3D = $Head
@onready var speed_label: Label = $speed
@onready var top_speed_label: Label = $max_speed
@onready var state_label: Label = $min_speed
@onready var ray_cast_3d: RayCast3D = $Head/Camera3D/RayCast3D
@onready var point: Marker3D = $Point


func _ready() -> void:
	check_input_mappings()
	look_rotation.y = rotation.y
	look_rotation.x = head.rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		capture_mouse()
	if Input.is_key_pressed(KEY_ESCAPE):
		release_mouse()

	if mouse_captured and event is InputEventMouseMotion:
		rotate_look(event.relative)


func _physics_process(delta: float) -> void:
	wall_cooldown_left = maxf(wall_cooldown_left - delta, 0.0)

	var input_dir := Vector2.ZERO
	if can_move:
		input_dir = Input.get_vector(input_left, input_right, input_forward, input_back)

	if state == State.SKATE:
		skate(delta, input_dir)
	else:
		wall_run()

	move_and_slide()

	if state == State.SKATE:
		try_start_wall_run(input_dir)
	else:
		update_wall_run()


func _process(_delta: float) -> void:
	speed_label.text = "Speed: %.1f" % Vector2(velocity.x, velocity.z).length()
	top_speed_label.text = "Top speed: %.1f" % top_speed
	state_label.text = "State: %s" % State.keys()[state]
	if Input.is_action_just_pressed("hook"):
		hook()


func skate(delta: float, input_dir: Vector2) -> void:
	var grounded := is_on_floor()

	if has_gravity and not grounded:
		velocity += get_gravity() * delta

	if can_jump and grounded and Input.is_action_just_pressed(input_jump):
		velocity.y = jump_velocity

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var wish_dir := global_basis * Vector3(input_dir.x, 0.0, input_dir.y)

	if can_brake and grounded and Input.is_action_pressed(input_brake):
		horizontal = horizontal.move_toward(Vector3.ZERO, brake_deceleration * delta)
	elif wish_dir != Vector3.ZERO:
		var control := 1.0 if grounded else air_control
		var speed_cap := maxf(top_speed, horizontal.length())
		horizontal += wish_dir * push_acceleration * control * delta
		horizontal = horizontal.limit_length(speed_cap)
	elif grounded:
		horizontal = horizontal.move_toward(Vector3.ZERO, ice_friction * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z


func try_start_wall_run(input_dir: Vector2) -> void:
	if not can_wall_run or wall_cooldown_left > 0.0:
		return
	if is_on_floor() or not is_on_wall() or input_dir.x == 0.0:
		return

	var normal := flat_wall_normal()
	var strafe_dir := global_basis.x * signf(input_dir.x)
	if strafe_dir.dot(-normal) < MIN_STRAFE_INTO_WALL:
		return

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var along := wall_tangent(normal, horizontal)
	if horizontal.dot(along) < wall_run_min_speed:
		return

	state = State.WALL_RUN
	wall_normal = normal
	velocity.y = 0.0


func wall_run() -> void:
	if can_jump and Input.is_action_just_pressed(input_jump):
		wall_jump()
		return

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var along := wall_tangent(wall_normal, horizontal)
	var speed_along := horizontal.dot(along)
	if speed_along < wall_run_min_speed * WALL_RUN_EXIT_RATIO:
		state = State.SKATE
		return

	velocity = along * speed_along - wall_normal * wall_stick_speed


func update_wall_run() -> void:
	if not is_on_wall() or is_on_floor():
		state = State.SKATE
		return
	wall_normal = flat_wall_normal()


func wall_jump() -> void:
	velocity += wall_normal * wall_jump_push
	velocity.y = wall_jump_lift
	wall_cooldown_left = wall_run_cooldown
	state = State.SKATE


func flat_wall_normal() -> Vector3:
	var normal := get_wall_normal()
	return Vector3(normal.x, 0.0, normal.z).normalized()


func wall_tangent(normal: Vector3, heading: Vector3) -> Vector3:
	var along := Vector3.UP.cross(normal).normalized()
	if along.dot(heading) < 0.0:
		along = -along
	return along


func rotate_look(rot_input : Vector2) -> void:
	look_rotation.x -= rot_input.y * look_speed
	look_rotation.x = clamp(look_rotation.x, deg_to_rad(-85), deg_to_rad(85))
	look_rotation.y -= rot_input.x * look_speed
	transform.basis = Basis()
	rotate_y(look_rotation.y)
	head.transform.basis = Basis()
	head.rotate_x(look_rotation.x)


func capture_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	mouse_captured = true


func release_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	mouse_captured = false


func check_input_mappings() -> void:
	if can_move:
		for action in [input_left, input_right, input_forward, input_back]:
			if not InputMap.has_action(action):
				push_error("Movement disabled. No InputAction found: " + action)
				can_move = false
				break
	if can_jump and not InputMap.has_action(input_jump):
		push_error("Jumping disabled. No InputAction found for input_jump: " + input_jump)
		can_jump = false
	if can_brake and not InputMap.has_action(input_brake):
		push_error("Braking disabled. No InputAction found for input_brake: " + input_brake)
		can_brake = false

func hook():
	ray_cast_3d.enabled = true
	var collider = ray_cast_3d.get_collider()
	var collider_point = ray_cast_3d.get_collision_point()
	if ray_cast_3d.is_colliding():
		print(collider)
		point.global_position = collider_point
		hooked = true
		while hooked:
			position = position.move_toward(collider_point, 1.0)
