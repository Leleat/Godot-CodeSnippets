tool
extends PopupPanel


var INTERFACE : EditorInterface
var EDITOR : ScriptEditor
	
onready var item_list = $MarginContainer/VBoxContainer/ItemList
onready var filter : LineEdit = $MarginContainer/VBoxContainer/HBoxContainer/Filter
onready var copy_button : Button = $MarginContainer/VBoxContainer/HBoxContainer/Copy
onready var edit_button : Button = $MarginContainer/VBoxContainer/HBoxContainer/Edit
onready var snippet_editor : WindowDialog = $TextEditPopupPanel
	
export (String) var custom_keyboard_shortcut # go to "Editor > Editor Settings... > Shortcuts > Bindings" to see how a keyboard_shortcut looks as a String 
export (bool) var adapt_popup_height = true
	
var snippet_jump_marker = "" # [@X] -> X needs to be an integer. Using the same X multiple times will replace them by whatever you typed for the first X (after a shortcut press)
var current_snippet = ""
var _delayed_one_key_press : bool = false
var placeholder : String
	
var keyboard_shortcut : String = "Control+Tab" 
var current_main_screen : String = ""
var jump_stack : Array = [0, 0] # [0] = how many jumps left, [1] = start_pos [line, column] to search for markers
var code_snippets : ConfigFile
const snippet_config = "res://addons/CodeSnippetPopup/CodeSnippets.cfg"
var drop_down : PopupMenu
var screen_factor : int = OS.get_screen_dpi() / 100


func _ready() -> void:
	keyboard_shortcut = custom_keyboard_shortcut if custom_keyboard_shortcut else keyboard_shortcut
	filter.right_icon = get_icon("Search", "EditorIcons")
	_update_snippets()
	snippet_editor.connect("snippets_changed", self, "_update_snippets")


func _unhandled_key_input(event : InputEventKey) -> void:
	if event.as_text() == keyboard_shortcut and current_main_screen == "Script":
		if jump_stack[0] <= 0:
			_update_popup_list()
			popup_centered_clamped(Vector2(750, 500) * screen_factor)
			filter.grab_focus()
			_delayed_one_key_press = false
		else:
			var code_editor : TextEdit = _get_current_code_editor()
			_jump_to_and_delete_next_marker(code_editor)
	
	if event.is_action_pressed("ui_cancel") and not drop_down.visible and jump_stack[0] != 0:
		jump_stack[0] = 0
		placeholder = ""


func _on_main_screen_changed(new_screen : String) -> void:
	current_main_screen = new_screen


func _update_snippets() -> void:
	var file = ConfigFile.new()
	var error = file.load(snippet_config)
	if error != OK:
		push_warning("Code Snippet Plugin: Error loading the code_snippets. Error code: %s." % error)
	code_snippets = file
	filter.grab_focus()
	_update_popup_list()


func _update_popup_list() -> void:
	item_list.clear()
	var search_string : String = filter.text
	
	# typing " X" at the end of the search_string jumps to the X-th item in the list
	var quickselect_line = 0
	var qs_starts_at = search_string.find_last(" ")
	if qs_starts_at != -1:
		quickselect_line = search_string.substr(qs_starts_at + 1)
		if quickselect_line.is_valid_integer():
			search_string.erase(qs_starts_at + 1, quickselect_line.length())
	
	search_string = search_string.strip_edges()
	copy_button.visible = true
	edit_button.visible = true
	var counter = 0
	for snippet_name in code_snippets.get_sections():
		if search_string and not snippet_name.match("*" + search_string + "*") and not search_string.is_subsequence_ofi(snippet_name):
			continue
		item_list.add_item(" " + String(counter) + "  :: ", null, false)
		item_list.add_item(snippet_name)
		item_list.add_item(code_snippets.get_value(snippet_name, "additional_info"), null, false) \
				if code_snippets.has_section_key(snippet_name, "additional_info") else item_list.add_item("", null, false)
		item_list.set_item_disabled(item_list.get_item_count() - 1, true)
		counter += 1
	
	quickselect_line = clamp(quickselect_line as int, 0, item_list.get_item_count() / item_list.max_columns - 1)
	if item_list.get_item_count() > 0:
		item_list.select(quickselect_line * item_list.max_columns + 1)
		item_list.ensure_current_is_visible()
		
	call_deferred("_adapt_list_height")


func _paste_code_snippet(snippet_name : String) -> void:
	var code_editor : TextEdit = _get_current_code_editor()
	var use_type_hints = INTERFACE.get_editor_settings().get_setting("text_editor/completion/add_type_hints")
	var tab_count = code_editor.get_line(code_editor.cursor_get_line()).count("\t")
	var tabs = "\t".repeat(tab_count)
	
	current_snippet = code_snippets.get_value(snippet_name, "body") 
	if use_type_hints and code_snippets.has_section_key(snippet_name, "type_hint"):
		current_snippet += code_snippets.get_value(snippet_name, "type_hint")
	elif not use_type_hints and code_snippets.has_section_key(snippet_name, "no_type_hint"):
		current_snippet += code_snippets.get_value(snippet_name, "no_type_hint")
	current_snippet = current_snippet.replace("\n", "\n" + tabs)
	
	var curr_pos = [code_editor.cursor_get_line(), code_editor.cursor_get_column()]
	code_editor.insert_text_at_cursor(current_snippet)
	jump_stack[0] = current_snippet.count("[@")
	if jump_stack[0]:
		jump_stack[1] = curr_pos
		_jump_to_and_delete_next_marker(code_editor)


func _jump_to_and_delete_next_marker(code_editor : TextEdit) -> void:
	code_editor.deselect() # placeholders
	yield(get_tree(), "idle_frame") # placeholders
	
	if _delayed_one_key_press: # place the mirror vars after the keyboard shortcut was pressed
		var mirror_var = _get_mirror_var(code_editor)
		var specific_marker_count = current_snippet.count(snippet_jump_marker) - 1
		jump_stack[0] -= specific_marker_count
		while specific_marker_count:
			var res = code_editor.search(snippet_jump_marker, 1, jump_stack[1][0], jump_stack[1][1])
			if res:
				code_editor.select(res[TextEdit.SEARCH_RESULT_LINE], res[TextEdit.SEARCH_RESULT_COLUMN], res[TextEdit.SEARCH_RESULT_LINE], res[TextEdit.SEARCH_RESULT_COLUMN] \
						+ snippet_jump_marker.length())
				code_editor.insert_text_at_cursor(mirror_var)
			specific_marker_count -= 1
		current_snippet = current_snippet.replace(snippet_jump_marker, mirror_var)
	
	if jump_stack[0]:
		var result = code_editor.search("[@", 1, jump_stack[1][0], jump_stack[1][1])
		if result.size() > 0:
			if result[TextEdit.SEARCH_RESULT_LINE] < jump_stack[1][0]:
				# EOF reached, for example because user manually deleted markers
				jump_stack[0] = 0
				return
			_set_current_marker()
			_delayed_one_key_press = true
			jump_stack[1][0] = result[TextEdit.SEARCH_RESULT_LINE]
			jump_stack[1][1] = result[TextEdit.SEARCH_RESULT_COLUMN]
			code_editor.select(jump_stack[1][0], jump_stack[1][1], jump_stack[1][0], jump_stack[1][1] + snippet_jump_marker.length() + (placeholder.length() + 1 if placeholder else 0))
			
			if placeholder: # the PopupMenu needs to be called even if just one place holder is there; otherwise buggy (for ex: mirror example)
				code_editor.insert_text_at_cursor(snippet_jump_marker)
				code_editor.select(jump_stack[1][0], jump_stack[1][1], jump_stack[1][0], jump_stack[1][1] + snippet_jump_marker.length())
				drop_down.code_editor = code_editor
				drop_down.rect_global_position = _get_cursor_position()
				drop_down.emit_signal("show_options", placeholder)
				drop_down.popup()
				placeholder = ""
			else:
				var tmp = OS.clipboard
				code_editor.cut()
				OS.clipboard = tmp
			
			jump_stack[0] -= 1


func _get_mirror_var(code_editor : TextEdit) -> String:
	code_editor.select(0, 0, jump_stack[1][0], jump_stack[1][1])
	var _code_before_marker = code_editor.get_selection_text()
	var pos = current_snippet.find(snippet_jump_marker)
	var _text_in_snippet_after_marker = current_snippet.substr(pos + snippet_jump_marker.length() + 1)
	var _end_of_mirror_var = code_editor.text.find(_text_in_snippet_after_marker, _code_before_marker.length())
	code_editor.deselect()
	return code_editor.text.substr(_code_before_marker.length(), _end_of_mirror_var - _code_before_marker.length() - 1) 


func _set_current_marker() -> void:
	var pos = current_snippet.find("[@")
	var mid_pos = current_snippet.find(":", pos + 2)
	var end_pos = current_snippet.find("]", pos)
	if mid_pos != -1 and mid_pos < end_pos:
		placeholder = current_snippet.substr(mid_pos + 1, end_pos - mid_pos - 1)
		current_snippet.erase(mid_pos, placeholder.length() + 1)
		end_pos = current_snippet.find("]", pos)
	if current_snippet.substr(pos + 2, end_pos - pos - 2).is_valid_integer():
		snippet_jump_marker = current_snippet.substr(pos, end_pos - pos + 1)
	else:
		push_warning("Code Snippet Plugin: Jump marker is not set up properly. The format is [@X] where X needs to be an integer")


func _adapt_list_height() -> void:
	if adapt_popup_height:
		var script_icon = get_icon("Script", "EditorIcons")
		var row_height = script_icon.get_size().y + (8 * screen_factor)
		var rows = max(item_list.get_item_count() / item_list.max_columns, 1) + 1
		var margin = filter.rect_size.y + $MarginContainer.margin_top + abs($MarginContainer.margin_bottom)
		var height = row_height * rows + margin
		rect_size.y = clamp(height, 0, 500 * screen_factor)


func _get_current_code_editor() -> TextEdit:
	var script_index = 0
	for script in EDITOR.get_open_scripts():
		if script == EDITOR.get_current_script():
			break
		script_index += 1
	return EDITOR.get_child(0).get_child(1).get_child(1).get_child(script_index).get_child(0).get_child(0).get_child(0) as TextEdit # :(


func _on_Filter_text_changed(new_text: String) -> void:
	_update_popup_list()


func _on_Filter_text_entered(new_text: String) -> void:
	var selection = item_list.get_selected_items()
	if selection:
		_activate_item(selection[0])
	else:
		_activate_item()


func _on_ItemList_item_activated(index: int) -> void:
	_activate_item(index)


func _activate_item(selected_index : int = -1) -> void:
	if selected_index == -1 or item_list.is_item_disabled(selected_index):
		hide()
		return
	
	var selected_name = item_list.get_item_text(selected_index)
	_paste_code_snippet(selected_name)
	hide()


func _on_Copy_pressed() -> void:
	var selection = item_list.get_selected_items()
	if selection:
		var use_type_hints = INTERFACE.get_editor_settings().get_setting("text_editor/completion/add_type_hints")
		var snippet_name = item_list.get_item_text(selection[0])
		var snippet : String = code_snippets.get_value(snippet_name, "body")
		if use_type_hints and code_snippets.has_section_key(snippet_name, "type_hint"):
			snippet += code_snippets.get_value(snippet_name, "type_hint")
		elif not use_type_hints and code_snippets.has_section_key(snippet_name, "no_type_hint"):
			snippet += code_snippets.get_value(snippet_name, "no_type_hint")
		var marker_pos = snippet.find(snippet_jump_marker)
		if marker_pos != -1:
			snippet.erase(marker_pos, snippet_jump_marker.length()) 
		OS.clipboard = snippet
	hide()


func _on_CodeSnippetPopup_popup_hide() -> void:
	filter.clear()


func _on_Edit_pressed() -> void:
	var snippet_file : File = File.new()
	var error = snippet_file.open(snippet_config, File.READ)
	if error != OK:
		push_warning("Code Snippet Plugin: Error editing the code_snippets. Error code: %s." % error)
		return
	var txt = snippet_file.get_as_text()
	snippet_file.close()
	
	snippet_editor.edit_snippet(txt)


func _get_cursor_position() -> Vector2:
	var code_editor = _get_current_code_editor()
	var code_font = get_font("source", "EditorFonts") if not INTERFACE.get_editor_settings().get_setting("interface/editor/code_font") else load("interface/editor/code_font")
	var curr_line = code_editor.get_line(code_editor.get_selection_from_line() if code_editor.get_selection_text() else code_editor.cursor_get_line()).replace("\t", "    ")
	var line_size = code_font.get_string_size(curr_line.substr(0, curr_line.find("[@")) if code_editor.get_selection_text() else code_editor.get_line(code_editor.cursor_get_line()).substr(0, \
			code_editor.cursor_get_column()))
	
	var editor_height = code_editor.get_child(1).max_value / code_editor.get_child(1).page * code_editor.rect_size.y
	var line_height = editor_height / code_editor.get_line_count() if code_editor.get_child(1).visible else line_size.y + 6.5 * screen_factor # else: in case there is no scrollbar 
	
	return code_editor.rect_global_position + Vector2(line_size.x + 80 * screen_factor, ((code_editor.get_selection_from_line() + 1 if code_editor.get_selection_text() \
			else code_editor.cursor_get_line()) - code_editor.scroll_vertical) * line_height) # this assumes that scroll_vertical() = first visible line
