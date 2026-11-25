extends StaticBody3D
## The red barrel prop (props/barrel_red.tscn): shoot it (or blow it up with
## a grenade or another barrel) and it explodes, hurting enemies and the
## player nearby and setting off other barrels in range a moment later.
## main.gd brings every barrel back at the start of each wave (respawn).
## Damage and range are in economy.gd (BARREL_*).

const Economy := preload("res://economy.gd")
const Blast := preload("res://effects/blast.gd")
const SPARKS_SCENE := preload("res://effects/impact_sparks.tscn")
const GROUP := "explosive_barrels"
const RESPAWN_CLEARANCE := 0.9   # m: doesn't come back on top of someone

var hp := Economy.BARREL_HP
var exploded := false
var _fuse := false               # set off by a blast: goes up after a short delay

@onready var _model: Node3D = $Model
@onready var _shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	add_to_group(GROUP)


## Bullets, grenades and other barrels. The arguments match enemy.gd's.
func take_damage(amount: int, hit_position := Vector3.ZERO, hit_normal := Vector3.UP, _headshot := false) -> void:
	if exploded or _fuse:
		return
	if hit_position != Vector3.ZERO:
		var sparks := SPARKS_SCENE.instantiate()
		get_tree().current_scene.add_child(sparks)
		sparks.setup(hit_position, hit_normal)
	hp -= amount
	if hp <= 0:
		explode()


## Set off by a nearby explosion: blows up a moment later (chain reaction).
func ignite() -> void:
	if exploded or _fuse:
		return
	_fuse = true
	var delay := randf_range(Economy.BARREL_CHAIN_DELAY.x, Economy.BARREL_CHAIN_DELAY.y)
	get_tree().create_timer(delay, false).timeout.connect(explode)


func explode() -> void:
	if exploded:
		return
	exploded = true
	_fuse = false
	_model.visible = false
	_shape.set_deferred("disabled", true)
	var player := get_tree().get_first_node_in_group("player") as Node3D
	Blast.detonate(self, global_position + Vector3.UP * 0.5, Economy.BARREL_RADIUS, Economy.BARREL_DAMAGE,
			player, Economy.BARREL_PLAYER_RADIUS, Economy.BARREL_PLAYER_DAMAGE)


## Back in one piece (start of a wave), unless someone is standing on its spot.
func respawn() -> void:
	if not exploded:
		return
	for body: Node3D in get_tree().get_nodes_in_group("enemies") + get_tree().get_nodes_in_group("player"):
		var d := Vector2(body.global_position.x - global_position.x, body.global_position.z - global_position.z)
		if d.length() < RESPAWN_CLEARANCE:
			return  # try again next wave
	exploded = false
	hp = Economy.BARREL_HP
	_model.visible = true
	_shape.disabled = false
