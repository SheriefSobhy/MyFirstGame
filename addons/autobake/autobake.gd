@tool
extends EditorPlugin
## Bakes the lightmap for main.tscn without clicking anything.
## It does NOTHING unless the editor is started with the --autobake user arg:
##   Godot_v4.7.2-stable_win64_console.exe --editor --path . -- --autobake
## (tools/rebake.bat runs exactly that, then bakes the navmeshes with
## tools/bake_navmesh.gd.) It opens main.tscn, presses the editor's own
## "Bake Lightmaps" button (LightmapGI can't be baked from script in 4.7),
## answers the save dialog with res://main.lmbake, saves the scene and quits.

const LIGHTMAP_FILE := "res://main.lmbake"


func _enter_tree() -> void:
	if "--autobake" in OS.get_cmdline_user_args():
		_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	await _frames(30)
	EditorInterface.open_scene_from_path("res://main.tscn")
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
		_answer_file_dialog(EditorInterface.get_base_control())
		await _frames(120)
		print("AUTOBAKE: light_data ", lm.light_data.resource_path if lm.light_data else "NOT BAKED")
	EditorInterface.save_scene()
	await _frames(30)
	print("AUTOBAKE: done")
	get_tree().quit()


func _find_button(n: Node, text: String) -> Button:
	if n is Button and n.text == text:
		return n
	for c in n.get_children():
		var r := _find_button(c, text)
		if r:
			return r
	return null


func _answer_file_dialog(n: Node) -> void:
	if n is FileDialog and n.visible:
		n.hide()
		n.file_selected.emit(LIGHTMAP_FILE)
		return
	for c in n.get_children():
		_answer_file_dialog(c)
