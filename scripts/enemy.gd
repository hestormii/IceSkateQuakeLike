class_name Enemy
extends CharacterBody3D

signal died

enum State {
	IDLE,
	CHASING,
}

@export var max_hp : float = 100.0
@export_range(0.0, 1.0) var execute_threshold : float = 0.3

var hp : float
var material := StandardMaterial3D.new()
var player_pos: Array = []
var state = State.IDLE
var speed: int = 5
var player: Player = null

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var navigation_agent_3d: NavigationAgent3D = $NavigationAgent3D
@onready var navigation_region_3d: NavigationRegion3D = $"../NavigationRegion3D"
@onready var update_player: Timer = $UpdatePlayer
@onready var detect: Area3D = $Detect



func _ready() -> void:
	hp = max_hp
	mesh.material_override = material
	update_tint()


func _physics_process(delta: float) -> void:
	var grounded := is_on_floor()

	if not grounded:
		velocity += gravity_vector() * delta

	match state:
		State.IDLE:
			pass
		State.CHASING:
			following()

func following():
	var next_pos = navigation_agent_3d.get_next_path_position()
	var current_pos = global_transform.origin
	var new_velocity = (next_pos - current_pos).normalized() * speed
	velocity = velocity.move_toward(new_velocity, 1)
	move_and_slide()

func target_position(target):
	navigation_agent_3d.target_position = target

func gravity_vector() -> Vector3:
	return -up_direction * get_gravity().length()

func is_executable() -> bool:
	return hp <= max_hp * execute_threshold


func take_damage(amount: float) -> void:
	hp = maxf(hp - amount, 0.0)
	if hp <= 0.0:
		die()
		return
	update_tint()


func execute() -> void:
	hp = 0.0
	die()


func die() -> void:
	died.emit()
	queue_free()


func update_tint() -> void:
	if is_executable():
		material.albedo_color = Color.RED
	else:
		material.albedo_color = Color.WHITE.lerp(Color.ORANGE, 1.0 - hp / max_hp)


func _on_detect_body_entered(body: Node3D) -> void:
	if body.is_in_group("Player"):
		player = body as Player
		player.update_pos.connect(update_player_pos)
		player_pos.append(player.global_position)
		state = State.CHASING
		update_player.start()
		target_position(player_pos.get(0))


func _on_update_player_timeout(body: Node3D) -> void:
	var pos_count = 0
	target_position(player_pos.get(pos_count + 1))

func update_player_pos():
	player_pos.append(player.update_pos)
