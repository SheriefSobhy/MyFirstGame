@tool
extends EditorPlugin
## Bakes the lightmaps (the yard, main.tscn, and the Training Arena,
## maps/training.tscn) without clicking anything.
## It does NOTHING unless the editor is started with the --autobake user arg:
##   Godot_v4.7.2-stable_win64_console.exe --editor --path . -- --autobake
## (tools/rebake.bat runs exactly that, then bakes the navmeshes with
## tools/bake_navmesh.gd.) `--autobake=training` (or `=yard`) bakes just one.
## For each scene it opens it, presses the editor's own "Bake Lightmaps"
## button (LightmapGI can't be baked from script in 4.7), answers the save
## dialog with the scene's .lmbake path, saves the scene; then it quits.

const BAKES := [
	{"id": "yard", "scene": "res://main.tscn", "file": "res://main.lmbake"},
	{"id": "town", "scene": "res://maps/town.tscn", "file": "res://maps/town.lmbake"},
	{"id": "warehouse", "scene": "res://maps/warehouse.tscn", "file": "res://maps/warehouse.lmbake"},
	{"id": "training", "scene": "res://maps/training.tscn", "file": "res://maps/training.lmbake"},
]


func _enter_tree() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--autobake" or arg.begins_with("--autobake="):
			_run.call_deferred(arg.trim_prefix("--autobake").trim_prefix("="))
			return


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run(only: String) -> void:
	await _frames(30)
	for b: Dictionary in BAKES:
		if only == "" or only == b.id:
			await _bake(b.scene, b.file)
	print("AUTOBAKE: done")
	get_tree().quit()


func _bake(scene_path: String, lightmap_file: String) -> void:
	EditorInterface.open_scene_from_path(scene_path)
	await _frames(30)
	var scene := EditorInterface.get_edited_scene_root()

	# The navmeshes are baked by tools/bake_navmesh.gd (rebake.bat runs it
	# after this), which also removes unreachable islands.

	var lm: LightmapGI = scene.get_node("LightmapGI")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(lm)
	EditorInterface.edit_node(lm)
	await _frames(10)
	var btn := _find_button(EditorInterface.get_base_control(), "Bake Lightmaps")
	if btn == null:
		print("AUTOBAKE: 'Bake Lightmaps' button not found")
	else:
		btn.pressed.emit()
		await _frames(30)
		# First bake of a scene asks where to save the lightmap file.
		_answer_file_dialog(EditorInterface.get_base_control(), lightmap_file)
		await _frames(120)
		print("AUTOBAKE: %s light_data %s" % [scene_path, lm.light_data.resource_path if lm.light_data else "NOT BAKED"])
	EditorInterface.save_scene()
	await _frames(30)


func _find_button(n: Node, text: String) -> Button:
	if n is Button and n.text == text:
		return n
	for c in n.get_children():
		var r := _find_button(c, text)
		if r:
			return r
	return null


func _answer_file_dialog(n: Node, path: String) -> void:
	if n is FileDialog and n.visible:
		n.hide()
		n.file_selected.emit(path)
		return
	for c in n.get_children():
		_answer_file_dialog(c, path)
