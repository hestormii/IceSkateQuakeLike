class_name Player extends CharacterBody3D

enum State { SKATE, WALL_RUN, GRAPPLE }

const MIN_STRAFE_INTO_WALL := 0.5
const WALL_RUN_EXIT_RATIO := 0.5
const FLAT_SURFACE_NORMAL_Y := 0.7
const MIN_LAUNCH_ALONG := 0.3

signal update_pos(player_pos)

@export var can_move : bool = true
@export var has_gravity : bool = true
@export var can_jump : bool = true
@export var can_brake : bool = true
@export var can_wall_run : bool = true
@export var can_hook : bool = true

@export_group("Skating")
@export var top_speed : float = 15.0
@export var push_acceleration : float = 15.0
@export var ice_friction : float = 2.5
@export var brake_deceleration : float = 25.0
@export var overspeed_drag : float = 6.0
@export_range(0.0, 1.0) var air_control : float = 0.4
@export var jump_velocity : float = 4.5

@export_group("Wall Run")
@export var wall_run_min_speed : float = 6.0
@export var wall_stick_speed : float = 2.0
@export var wall_jump_push : float = 6.0
@export var wall_jump_lift : float = 5.0
@export var wall_run_cooldown : float = 0.3

@export_group("Grapple")
@export_flags_3d_physics var hook_mask : int = 5
@export var hook_range : float = 40.0
@export var hook_pull_speed : float = 30.0
@export var hook_pull_acceleration : float = 120.0
@export var hook_arrive_distance : float = 1.5
@export var hook_max_time : float = 2.0
@export var hook_cooldown : float = 0.6
@export_range(0.0, 1.0) var hook_momentum_keep : float = 0.8
@export var hook_min_launch_speed : float = 10.0
@export var hook_damage : float = 25.0
@export var hook_bounce_speed : float = 10.0
@export var hook_bounce_lift : float = 6.0

@export_group("Gravity Flip")
@export var flip_time : float = 0.35
@export var inverted_air_limit : float = 2.0

@export_group("Look")
@export var look_speed : float = 0.002

@export_group("Input Actions")
@export var input_left : String = "left"
@export var input_right : String = "right"
@export var input_forward : String = "forward"
@export var input_back : String = "backward"
@export var input_jump : String = "jump"
@export var input_brake : String = "brake"
@export var input_hook : String = "hook"

var state : State = State.SKATE
var wall_normal : Vector3 = Vector3.ZERO
var wall_cooldown_left : float = 0.0
var hook_point : Vector3 = Vector3.ZERO
var hook_normal : Vector3 = Vector3.UP
var hook_local : Vector3 = Vector3.ZERO
var hook_enemy : Enemy = null
var hook_on_enemy : bool = false
var hook_time_left : float = 0.0
var hook_cooldown_left : float = 0.0
var flip_blend : float = 0.0
var flip_air_time : float = 0.0
var head_upright_y : float = 0.0
var head_inverted_y : float = 0.0
var mouse_captured : bool = false
var look_rotation : Vector2

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var body_shape: CollisionShape3D = $Collider
@onready var point: Marker3D = $Point
@onready var speed_label: Label = $Ui/speed
@onready var top_speed_label: Label = $Ui/max_speed
@onready var state_label: Label = $Ui/min_speed
@onready var vision: RayCast3D = $Head/Camera3D/vision
@onready var color_rect: ColorRect = $Ui/ColorRect
@onready var player_pos: Timer = $PlayerPos

func _ready() -> void:
	check_input_mappings()
	look_rotation.y = rotation.y
	look_rotation.x = head.rotation.x
	head_upright_y = head.position.y
	head_inverted_y = 2.0 * body_shape.position.y - head.position.y
	point.top_level = true
	point.scale = Vector3.ONE * 0.3
	point.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		capture_mouse()
	if Input.is_key_pressed(KEY_ESCAPE):
		release_mouse()

	if mouse_captured and event is InputEventMouseMotion:
		rotate_look(event.relative)


func _physics_process(delta: float) -> void:
	wall_cooldown_left = maxf(wall_cooldown_left - delta, 0.0)
	hook_cooldown_left = maxf(hook_cooldown_left - delta, 0.0)

	var input_dir := Vector2.ZERO
	if can_move:
		input_dir = Input.get_vector(input_left, input_right, input_forward, input_back)

	if can_hook and Input.is_action_just_pressed("hook"):
		if state == State.GRAPPLE:
			end_grapple()
		else:
			try_hook()

	match state:
		State.SKATE:
			skate(delta, input_dir)
		State.WALL_RUN:
			wall_run()
		State.GRAPPLE:
			grapple(delta)

	move_and_slide()

	match state:
		State.SKATE:
			try_start_wall_run(input_dir)
		State.WALL_RUN:
			update_wall_run()

	update_gravity_flip(delta)


func _process(delta: float) -> void:
	var target_blend := 0.0 if up_direction.y > 0.0 else 1.0
	if flip_blend != target_blend:
		flip_blend = move_toward(flip_blend, target_blend, delta / flip_time)
		apply_look()

	var gravity_note := "" if up_direction.y > 0.0 else " (inverted)"
	speed_label.text = "Speed: %.1f" % velocity.slide(up_direction).length()
	top_speed_label.text = "Top speed: %.1f" % top_speed
	state_label.text = "State: %s%s" % [State.keys()[state], gravity_note]



func skate(delta: float, input_dir: Vector2) -> void:
	var grounded := is_on_floor()

	if has_gravity and not grounded:
		velocity += gravity_vector() * delta

	if can_jump and grounded and Input.is_action_just_pressed(input_jump):
		velocity = velocity.slide(up_direction) + up_direction * jump_velocity

	var horizontal := velocity.slide(up_direction)
	var vertical := velocity - horizontal
	var wish_dir := right_vector() * input_dir.x + global_basis.z * input_dir.y

	if can_brake and grounded and Input.is_action_pressed(input_brake):
		horizontal = horizontal.move_toward(Vector3.ZERO, brake_deceleration * delta)
	elif wish_dir != Vector3.ZERO:
		var control := 1.0 if grounded else air_control
		var speed_cap := maxf(top_speed, horizontal.length())
		if grounded:
			speed_cap = maxf(top_speed, speed_cap - overspeed_drag * delta)
		horizontal += wish_dir * push_acceleration * control * delta
		horizontal = horizontal.limit_length(speed_cap)
	elif grounded:
		horizontal = horizontal.move_toward(Vector3.ZERO, ice_friction * delta)

	velocity = horizontal + vertical


func try_start_wall_run(input_dir: Vector2) -> void:
	if not can_wall_run or wall_cooldown_left > 0.0:
		return
	if is_on_floor() or not is_on_wall() or input_dir.x == 0.0:
		return

	var normal := flat_wall_normal()
	var strafe_dir := right_vector() * signf(input_dir.x)
	if strafe_dir.dot(-normal) < MIN_STRAFE_INTO_WALL:
		return

	var horizontal := velocity.slide(up_direction)
	var along := wall_tangent(normal, horizontal)
	if horizontal.dot(along) < wall_run_min_speed:
		return

	state = State.WALL_RUN
	wall_normal = normal
	velocity = horizontal


func wall_run() -> void:
	if can_jump and Input.is_action_just_pressed(input_jump):
		wall_jump()
		return

	var horizontal := velocity.slide(up_direction)
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
	velocity = velocity.slide(up_direction) + wall_normal * wall_jump_push + up_direction * wall_jump_lift
	wall_cooldown_left = wall_run_cooldown
	state = State.SKATE


func try_hook() -> void:
	if hook_cooldown_left > 0.0:
		return

	var from := camera.global_position
	var to := from - camera.global_basis.z * hook_range
	var query := PhysicsRayQueryParameters3D.create(from, to, hook_mask, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return

	hook_point = hit.position
	hook_normal = hit.normal
	hook_enemy = hit.collider as Enemy
	hook_on_enemy = hook_enemy != null
	if hook_on_enemy:
		hook_local = hook_enemy.to_local(hook_point)

	hook_time_left = hook_max_time
	point.visible = true
	state = State.GRAPPLE


func grapple(delta: float) -> void:
	hook_time_left -= delta
	if hook_time_left <= 0.0 or (can_jump and Input.is_action_just_pressed(input_jump)):
		end_grapple()
		return

	if hook_on_enemy:
		if not is_instance_valid(hook_enemy):
			end_grapple()
			return
		hook_point = hook_enemy.to_global(hook_local)
	point.global_position = hook_point

	var to_anchor := hook_point - body_shape.global_position
	var distance := to_anchor.length()
	if distance <= hook_arrive_distance:
		arrive_at_anchor(to_anchor / distance)
		return

	var pull_dir := to_anchor / distance
	velocity = velocity.move_toward(pull_dir * hook_pull_speed, hook_pull_acceleration * delta)


func arrive_at_anchor(pull_dir: Vector3) -> void:
	var speed := maxf(velocity.length() * hook_momentum_keep, hook_min_launch_speed)
	if hook_on_enemy:
		strike_enemy(pull_dir, speed)
	else:
		launch_from_surface(speed)
	end_grapple()


func strike_enemy(pull_dir: Vector3, speed: float) -> void:
	if hook_enemy.is_executable():
		hook_enemy.execute()
		velocity = pull_dir * speed
		return

	hook_enemy.take_damage(hook_damage)
	var away := (body_shape.global_position - hook_enemy.global_position).slide(up_direction)
	if away.length() < 0.01:
		away = -pull_dir.slide(up_direction)
	velocity = away.normalized() * hook_bounce_speed + up_direction * hook_bounce_lift


func launch_from_surface(speed: float) -> void:
	velocity = launch_direction(hook_normal) * speed
	if absf(hook_normal.y) >= FLAT_SURFACE_NORMAL_Y:
		flip_gravity_to(Vector3(0.0, signf(hook_normal.y), 0.0))


func launch_direction(normal: Vector3) -> Vector3:
	var candidates: Array[Vector3] = [-camera.global_basis.z, -global_basis.z, Vector3.UP]
	for candidate in candidates:
		var along := candidate.slide(normal)
		if along.length() > MIN_LAUNCH_ALONG:
			return along.normalized()
	return Vector3.UP


func end_grapple() -> void:
	state = State.SKATE
	hook_cooldown_left = hook_cooldown
	hook_on_enemy = false
	hook_enemy = null
	point.visible = false


func flip_gravity_to(new_up: Vector3) -> void:
	up_direction = new_up
	flip_air_time = 0.0


func update_gravity_flip(delta: float) -> void:
	if up_direction.y > 0.0 or state == State.GRAPPLE:
		return
	if is_on_floor():
		flip_air_time = 0.0
		return
	flip_air_time += delta
	if flip_air_time > inverted_air_limit:
		flip_gravity_to(Vector3.UP)


func gravity_vector() -> Vector3:
	return -up_direction * get_gravity().length()


func right_vector() -> Vector3:
	return global_basis.x * signf(up_direction.y)


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
	look_rotation.x = clampf(look_rotation.x, deg_to_rad(-85), deg_to_rad(85))
	look_rotation.y -= rot_input.x * look_speed * signf(up_direction.y)
	apply_look()


func apply_look() -> void:
	var eased := smoothstep(0.0, 1.0, flip_blend)
	transform.basis = Basis(Vector3.UP, look_rotation.y)
	head.transform.basis = Basis(Vector3.BACK, PI * eased) * Basis(Vector3.RIGHT, look_rotation.x)
	head.position.y = lerpf(head_upright_y, head_inverted_y, eased)


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
	if can_hook and not InputMap.has_action(input_hook):
		push_error("Grapple disabled. No InputAction found for input_hook: " + input_hook)
		can_hook = false


func _on_player_pos_timeout() -> void:
	update_pos.emit(global_position)
