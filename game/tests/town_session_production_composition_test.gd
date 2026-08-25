extends SceneTree


const INTERNAL_CATALOG := preload("res://world/presentation/session/TownInternalPlaytestCatalog.gd")
const RESIDENT_CATALOG := preload(
	"res://world/presentation/session/TownResidentCatalog.gd"
)
const COMPILER := preload("res://world/presentation/session/TownNewGameOpeningCompiler.gd")
const NEW_GAME_DRAFT := preload(
	"res://world/presentation/session/TownNewGameDraft.gd"
)
const POPULATION_RULES := preload("res://world/runtime/TownPopulationRules.gd")
const MODEL_ASSIGNMENT_SERVICE := preload(
	"res://ui/resident_model_assignment/runtime/ResidentModelAssignmentService.gd"
)
const RESIDENT_EDITOR_SERVICE := preload(
	"res://world/presentation/session/TownResidentEditorService.gd"
)
const CUSTOM_POOL := preload(
	"res://world/presentation/session/TownCustomResidentCandidatePool.gd"
)
const CUSTOM_CREATOR := preload(
	"res://world/presentation/session/TownCustomResidentCreatorService.gd"
)
const BOOTSTRAP := preload("res://world/presentation/session/TownSessionBootstrap.gd")
const PROVIDER_SERVICE := preload("res://world/integration/TownAgentProviderService.gd")
const GATEWAY := preload("res://world/integration/TownWorldAgentGateway.gd")
const GAME_FLOW_HOST := preload(
	"res://world/presentation/game_flow/GameFlowHost.gd"
)
const RESIDENT_REPLACEMENT := preload(
	"res://world/runtime/lifecycle/TownResidentReplacementAdmission.gd"
)
const TOWN_RUNTIME_SCENE := preload("res://world/presentation/town_runtime/TownRuntime.tscn")
const AVATAR_HUD_SCENE := preload("res://ui/avatar_mode/runtime/AvatarModeHud.tscn")
const PAUSE_HOST_SCENE := preload("res://ui/pause_menu/PauseMenuNavigationHost.tscn")
const TOWN_HUD_SCENE := preload("res://ui/town/hud/runtime/TownHudOverlay.tscn")
const UI_RUNTIME_HOST := preload("res://world/presentation/ui/TownUiRuntimeHost.gd")
const WORLD := preload("res://world/runtime/TownWorldRuntime.gd")
const AGENT_CONTRACT := preload("res://agent/AgentContract.gd")
const TEST_KEYBOARD_DEVICE_ID := 16
const WORLD_UI_SCOPES: Array[String] = [
	"lifecycle",
	"environment",
	"avatar",
	"conversation",
	"announcements",
	"town_hud",
]

var _failures: Array[String] = []

class ResultCollector:
	extends RefCounted
	var result: Dictionary = {}

	func collect(value: Dictionary) -> void:
		result = value.duplicate(true)


class AgentGatewayPumpSpy:
	extends Node
	var pump_limits: Array[int] = []

	func pump(max_requests := -1) -> int:
		pump_limits.append(max_requests)
		return 0


class VariablePopulationProvider:
	extends RefCounted

	func get_health_snapshot() -> Dictionary:
		return {
			"ok": true,
			"formalReady": true,
			"capabilityMode": "formal",
			"source": "runtime",
			"providers": [{
				"providerId": "fake",
				"label": "本地测试模型",
				"status": "available",
			}],
		}

	func list_available_models() -> Array:
		return [{
			"providerId": "fake",
			"modelId": "fake",
			"label": "本地测试模型",
			"available": true,
		}]

	func validate_resident_bindings(_bindings: Variant) -> Dictionary:
		return {"ok": true, "errorCode": "", "retryable": false}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Camera coordinates are defined against the shipped 1920x1080 logical
	# viewport. Headless DisplayServer sizes vary by host and otherwise turn this
	# product assertion into an unrelated map-edge clamp assertion.
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	var world_data := _read_json("res://world/data/town/town_world.json")
	_expect(
		not FileAccess.file_exists(
			"res://ui/resident_selection/mock/resident_selection_mock.json"
		),
		"internal playtest catalog does not depend on the retired UI mock",
	)
	var formal_selection_vm := RESIDENT_CATALOG.build_view_model(
		"fake",
		"fake",
		true,
		2,
	) as Dictionary
	var formal_selection_data := (
		formal_selection_vm.get("data", {}) as Dictionary
	)
	formal_selection_data["selected_resident_ids"] = (
		formal_selection_data.get("recommended_resident_ids", []) as Array
	).duplicate()
	RESIDENT_CATALOG.update_confirmation_payload(
		formal_selection_data,
		"fake",
		"fake",
		3,
	)
	var formal_draft := (
		formal_selection_data.get("confirmation_payload", {}) as Dictionary
	)
	var formal_catalog := RESIDENT_CATALOG.load_catalog()
	var formal_compiled := COMPILER.compile(
		formal_draft,
		world_data,
		formal_catalog,
	)
	_expect_ok(
		formal_compiled,
		"formal Catalog to confirmation draft to Compiler chain succeeds",
	)
	if bool(formal_compiled.get("ok", false)):
		var formal_owners := (
			formal_compiled.get("openingConfig", {}) as Dictionary
		).get("ownerAssignments", {}) as Dictionary
		_expect_equal(
			formal_owners.size(),
			POPULATION_RULES.DEFAULT_RESIDENT_COUNT,
			"new opening assigns ownership to resident homes only",
		)
		for place_value: Variant in world_data.get("places", []) as Array:
			var place := place_value as Dictionary
			if String(place.get("type", "")) == "铺面":
				_expect(
					not formal_owners.has(String(place.get("name", ""))),
					"formal shops do not require one resident owner",
				)
	var max_population_case := _verify_variable_population_openings(
		world_data,
		formal_catalog,
	)
	_verify_custom_resident_pipeline(world_data, formal_catalog)
	var bad_sprite_catalog := formal_catalog.duplicate(true)
	(
		(
			(bad_sprite_catalog.get("residents", []) as Array)[0]
			as Dictionary
		).get("presentation", {}) as Dictionary
	)["spritePath"] = "res://missing-resident-whitebody.png"
	_expect(
		_result_has_error_code(
			COMPILER.compile(formal_draft, world_data, bad_sprite_catalog),
			"SESSION_CATALOG_PORTRAIT_MISSING",
		),
		"Compiler rejects a formal catalog with a missing resident sprite",
	)
	var legacy_appearance_catalog := formal_catalog.duplicate(true)
	(
		(
			(legacy_appearance_catalog.get("residents", []) as Array)[0]
			as Dictionary
		).get("attributes", {}) as Dictionary
	)["appearance"] = "paper_doll_64:legacy"
	_expect(
		_result_has_error_code(
			COMPILER.compile(
				formal_draft,
				world_data,
				legacy_appearance_catalog,
			),
			"SESSION_CATALOG_APPEARANCE_INVALID",
		),
		"Compiler rejects an appearance outside the approved wardrobe catalog",
	)
	var selection_vm := INTERNAL_CATALOG.build_view_model("fake", "fake")
	var selection_data := selection_vm.get("data", {}) as Dictionary
	_expect_equal(selection_data.get("capabilityMode"), "development", "internal VM is visibly development")
	_expect_equal(selection_data.get("source"), "placeholder", "internal VM declares placeholder source")
	_expect_equal(selection_data.get("formalReady"), false, "internal VM never impersonates formal")
	_expect_equal(selection_data.get("internalPlaytest"), true, "internal VM requires explicit playtest flag")
	var draft := (selection_data.get("confirmation_payload", {}) as Dictionary).duplicate(true)
	_expect_equal((draft.get("slots", []) as Array).size(), 15, "internal draft has all 15 homes")
	for slot_value: Variant in draft.get("slots", []) as Array:
		var llm := (slot_value as Dictionary).get("llmBinding", {}) as Dictionary
		_expect_equal(llm.get("providerId"), "fake", "host owns development provider normalization")
		_expect_equal(llm.get("modelId"), "fake", "mock_provider never reaches Provider catalog")
	var catalog := INTERNAL_CATALOG.build_catalog(world_data, selection_vm)
	var compiled := COMPILER.compile(draft, world_data, catalog)
	_expect_ok(compiled, "development placeholder compiles through the production compiler")
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var bindings := compiled.get("residentBindings", []) as Array[Dictionary]
	_expect_equal(bindings.size(), 15, "compiler produces the complete resident binding set")
	var boundary_world: RefCounted = WORLD.new()
	var identities: Array[Dictionary] = []
	for binding in bindings:
		identities.append({
			"residentId": String(binding.get("residentId", "")),
			"residentName": String(binding.get("residentName", "")),
		})
	var boundary_start := boundary_world.call(
		"start",
		world_data,
		compiled.get("openingConfig", {}) as Dictionary,
		identities,
	) as Dictionary
	_expect_ok(boundary_start, "compiled opening starts a boundary World")
	for binding in bindings:
		var resident_id := String(binding.get("residentId", ""))
		var initialization := boundary_world.call("get_agent_initialization_by_id", resident_id) as Dictionary
		var contract_errors := AGENT_CONTRACT.validate_initialization(initialization)
		_expect(
			contract_errors.is_empty(),
			"World initialization satisfies AgentContract for %s: %s" % [resident_id, contract_errors],
		)
	boundary_world.call("stop")

	var request_host := Node.new()
	request_host.name = "ProductionProviderRequestHost"
	root.add_child(request_host)
	var provider_service: RefCounted = PROVIDER_SERVICE.new()
	_expect_ok(provider_service.call("configure", {
		"capabilityMode": "development",
		"source": "placeholder",
		"allowFake": true,
		"providerConfigs": {},
	}, request_host), "provider service configures explicitly")
	await _verify_max_population_gateway(
		max_population_case,
		world_data,
		provider_service,
		request_host,
	)

	var formal_gateway: Node = GATEWAY.new()
	var formal_runtime := Node.new()
	var formal_bootstrap: RefCounted = BOOTSTRAP.new()
	var formal_collector := ResultCollector.new()
	formal_bootstrap.call(
		"begin_new_game_from_catalog",
		draft,
		world_data,
		catalog,
		provider_service,
		formal_gateway,
		formal_runtime,
		{
			"worldStartMode": "formal",
			"internalPlaytest": false,
			"sessionId": "formal-preflight-session",
			"slotId": "formal-preflight-slot",
			"requestHost": request_host,
		},
		formal_collector.collect,
	)
	var formal_result := formal_collector.result
	_expect_equal(formal_result.get("ok"), false, "formal startup remains gated")
	_expect_equal(
		formal_result.get("errorCode"),
		"SESSION_RUNTIME_CONTRACT_MISSING",
		"formal startup accepts the arrival opening and stops at the intentionally incomplete runtime spy",
	)
	var unconfigured_bind := formal_gateway.call("bind_world", null) as Dictionary
	_expect_equal(
		unconfigured_bind.get("errorCode"),
		"AGENT_GATEWAY_SESSION_NOT_CONFIGURED",
		"formal World rejection has no Agent/Gateway side effect",
	)
	var agent_stage_failure := formal_gateway.call(
		"_agent_stage_failure",
		"AGENT_NEW_GAME_PREPARE_FAILED",
		"start_new_game",
		"",
		{"ok": false, "errors": ["Agent slot already exists"]},
	) as Dictionary
	_expect_equal(
		((((agent_stage_failure.get("errors", []) as Array)[0]) as Dictionary).get("agentErrors", []) as Array),
		["Agent slot already exists"],
		"Gateway preserves non-sensitive Agent stage errors for formal startup diagnosis",
	)
	formal_runtime.free()
	formal_gateway.free()

	var gateway: Node = GATEWAY.new()
	var runtime: Node = TOWN_RUNTIME_SCENE.instantiate()
	var bootstrap: RefCounted = BOOTSTRAP.new()
	var identity := str(Time.get_ticks_usec())
	var slot_id := "test-live-composition-slot-%s" % identity
	var session_id := "composition-session-%s" % identity
	var bootstrap_collector := ResultCollector.new()
	var accepted := bootstrap.call(
		"begin_new_game_from_catalog",
		draft,
		world_data,
		catalog,
		provider_service,
		gateway,
		runtime,
		{
			"worldStartMode": "development",
			"internalPlaytest": true,
			"sessionId": session_id,
			"slotId": slot_id,
			"requestHost": request_host,
			"useLiveModel": false,
			"enablePlayerAvatar": true,
		},
		bootstrap_collector.collect,
	) as Dictionary
	var bootstrap_result := bootstrap_collector.result
	_expect_equal(accepted.get("accepted"), true, "development bootstrap accepts the explicit request")
	_expect_ok(bootstrap_result, "bootstrap produces a configured Town Runtime")
	if not bool(bootstrap_result.get("ok", false)):
		runtime.free()
		gateway.free()
		request_host.queue_free()
		_finish()
		return
	root.add_child(runtime)
	# Agent preparation starts after the first rendered frame. Keep a bounded
	# margin here so slower renderers do not fail the composition test one frame
	# before the first provider dispatch becomes observable.
	for _frame_index in 96:
		await process_frame
	var startup := runtime.call("get_startup_result") as Dictionary
	_expect_ok(startup, "configured production Town Runtime starts")
	if not bool(startup.get("ok", false)):
		runtime.queue_free()
		await process_frame
		request_host.queue_free()
		_finish()
		return
	_expect_equal(runtime.call("get_connected_agent_names").size(), 15, "one gateway connects all 15 residents")
	_expect_equal(gateway.call("get_connected_resident_ids").size(), 15, "gateway routes the stable ID set")
	var first_id := String((bindings[0] as Dictionary).get("residentId", ""))
	await _verify_inner_observation_first_draw(
		gateway,
		runtime.call("get_world_runtime") as RefCounted,
		first_id,
	)
	_expect(
		not (gateway.call("get_last_submission", first_id) as Dictionary).is_empty(),
		"initial World wake triggers a real Fake AgentSystem decision and World submission",
	)
	_expect_equal((gateway.call("get_errors") as Array).size(), 0, "production Gateway has no hidden per-resident errors")
	_expect_equal(
		runtime.get_node_or_null("TownUi"),
		null,
		"formal runtime does not instantiate the legacy TownUi canvas or scene banner",
	)
	for legacy_node_name: String in [
		"PlayerUi",
		"CameraControls",
		"MapControlPanel",
		"CafeFurnitureEditEntryPanel",
		"CafeFurnitureEditorPanel",
	]:
		_expect(
			runtime.find_child(legacy_node_name, true, false) == null,
			"formal runtime never mounts legacy test control %s" % legacy_node_name,
		)
	var state_before_test_keys := runtime.call("get_runtime_state") as Dictionary
	_expect_equal(state_before_test_keys.get("testUiEnabled"), false, "formal runtime keeps test UI disabled")
	_expect_equal(state_before_test_keys.get("avatarMode"), "observer", "Town always opens in observer mode")
	_expect_equal(state_before_test_keys.get("playerAvatarEnabled"), false, "Town load never auto-descends into avatar control")
	_expect_equal(state_before_test_keys.get("viewMode"), "town", "observer starts on the outdoor Town map")
	_expect_equal(state_before_test_keys.get("activeInteriorId"), "", "observer does not inherit a resident interior")
	_expect_equal(state_before_test_keys.get("followedResident"), "", "observer does not auto-follow the first connected resident")
	_expect_equal(
		state_before_test_keys.get("observerCameraPosition"),
		Vector2(3250, 2050),
		"observer starts from the stable central plaza camera point",
	)
	_expect_equal(state_before_test_keys.get("cameraZoomIndex"), 1, "observer starts at a pannable outdoor zoom")
	_expect_equal(state_before_test_keys.get("cameraZoomBand"), "far", "observer start drives the far HUD density band")
	_expect_equal(state_before_test_keys.get("cameraZoomRatio"), 0.5, "observer start publishes the real 0.5x camera ratio")
	_expect_equal(state_before_test_keys.get("cameraZoomStepCount"), 4, "observer camera publishes all four discrete zoom steps")
	var observer_text_input := LineEdit.new()
	observer_text_input.name = "ObserverMovementInputFocusProbe"
	runtime.add_child(observer_text_input)
	observer_text_input.grab_focus()
	await process_frame
	var observer_position_before_typing := (
		(runtime.call("get_runtime_state") as Dictionary).get(
			"observerCameraPosition",
			Vector2.ZERO,
		) as Vector2
	)
	_send_physical_key(&"move_down", KEY_S, true)
	await physics_frame
	await physics_frame
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("observerCameraPosition"),
		observer_position_before_typing,
		"typing a movement key never pans the observer camera behind a text input",
	)
	observer_text_input.release_focus()
	await process_frame
	await physics_frame
	_expect(
		not Input.is_action_pressed("move_down"),
		"closing observer text input clears its stale movement action",
	)
	_send_physical_key(&"move_down", KEY_S, false)
	observer_text_input.queue_free()
	_send_physical_key(&"move_right", KEY_D, true)
	await physics_frame
	await physics_frame
	_send_physical_key(&"move_right", KEY_D, false)
	var state_after_observer_pan := runtime.call("get_runtime_state") as Dictionary
	_expect(
		(state_after_observer_pan.get("observerCameraPosition", Vector2.ZERO) as Vector2).x > 3250.0,
		"observer WASD input pans the camera without activating the avatar",
	)
	var blocked_camera_position := (
		state_after_observer_pan.get("observerCameraPosition", Vector2.ZERO) as Vector2
	)
	var camera_input_blocked := runtime.call(
		"set_observer_camera_input_enabled",
		false,
	) as Dictionary
	_expect_equal(camera_input_blocked.get("ok"), true, "formal host can block observer camera input")
	_expect_equal(camera_input_blocked.get("enabled"), false, "observer camera input reports blocked")
	Input.action_press("move_right")
	await physics_frame
	await physics_frame
	Input.action_release("move_right")
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("observerCameraPosition"),
		blocked_camera_position,
		"blocked observer camera ignores held WASD behind a formal page",
	)
	var wheel_up := InputEventMouseButton.new()
	wheel_up.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_up.pressed = true
	runtime.call("_unhandled_input", wheel_up)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("cameraZoomIndex"),
		1,
		"blocked observer camera ignores wheel zoom behind a formal page",
	)
	var camera_input_restored := runtime.call(
		"set_observer_camera_input_enabled",
		true,
	) as Dictionary
	_expect_equal(camera_input_restored.get("enabled"), true, "formal host restores observer camera input")
	runtime.call("_unhandled_input", wheel_up)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("cameraZoomIndex"),
		2,
		"observer mouse wheel changes the outdoor camera zoom",
	)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("cameraZoomBand"),
		"middle",
		"1x observer zoom drives the middle HUD density band",
	)
	var adapter: Node = runtime.call("get_ui_adapter")
	_expect(adapter != null, "Town Runtime exposes its unique Adapter")
	var world_runtime: RefCounted = runtime.call("get_world_runtime")
	var editor_pause_time := world_runtime.call("get_time") as Dictionary
	var editor_pause := adapter.call(
		"dispatch",
		"lifecycle.pause",
		{"reason": "resident_editor"},
	) as Dictionary
	_expect_ok(editor_pause, "resident editor pauses through the formal Adapter")
	world_runtime.call("advance", 3.0)
	_expect_equal(
		world_runtime.call("get_time"),
		editor_pause_time,
		"resident editor keeps formal World time stopped",
	)
	var editor_resume := adapter.call(
		"dispatch",
		"lifecycle.resume",
		{"reason": "resident_editor"},
	) as Dictionary
	_expect_ok(editor_resume, "resident editor resumes through the formal Adapter")
	world_runtime.call("advance", 1.0)
	_expect(
		world_runtime.call("get_time") != editor_pause_time,
		"formal World time advances after leaving resident editor",
	)
	var speed_three := adapter.call(
		"dispatch",
		"town_hud.set_time_speed",
		{"multiplier": 3},
	) as Dictionary
	_expect_ok(speed_three, "formal time controls select 3x speed")
	var manual_pause := adapter.call(
		"dispatch",
		"lifecycle.pause",
		{"reason": "manual"},
	) as Dictionary
	_expect_ok(manual_pause, "formal time controls pause manually")
	var normal_speed := adapter.call(
		"dispatch",
		"town_hud.set_time_speed",
		{"multiplier": 1},
	) as Dictionary
	_expect_ok(normal_speed, "selecting 1x clears manual pause")
	_expect_equal(
		world_runtime.call("get_simulation_speed"),
		1,
		"selecting 1x restores normal simulation speed",
	)
	_expect(
		not bool(
			(runtime.call("get_lifecycle_state") as Dictionary).get(
				"paused",
				true,
			)
		),
		"selecting 1x leaves the formal World running",
	)
	_expect_equal(
		(runtime.call("set_manual_paused", true) as Dictionary).get("ok"),
		true,
		"manual pause can coexist with the pause menu",
	)
	_expect_equal(
		(runtime.call("set_main_menu_open", true) as Dictionary).get("ok"),
		true,
		"pause menu adds only its own pause reason",
	)
	_expect_equal(
		(runtime.call("set_main_menu_open", false) as Dictionary).get("ok"),
		true,
		"closing pause menu clears only the menu pause reason",
	)
	var pause_after_menu_close := runtime.call("get_lifecycle_state") as Dictionary
	_expect(
		bool(pause_after_menu_close.get("paused", false))
		and (pause_after_menu_close.get("pauseReasons", []) as Array).has("manual"),
		"closing pause menu preserves an earlier manual pause",
	)
	var resume_after_menu_close := adapter.call(
		"dispatch",
		"town_hud.set_time_speed",
		{"multiplier": 1},
	) as Dictionary
	_expect_ok(
		resume_after_menu_close,
		"selecting a speed resumes the preserved manual pause",
	)
	_expect(
		not bool(
			(runtime.call("get_lifecycle_state") as Dictionary).get(
				"paused",
				true,
			)
		),
		"pause-menu and manual-pause sequence returns to running",
	)
	_expect_equal(
		(runtime.call("set_manual_paused", true) as Dictionary).get("ok"),
		true,
		"manual pause can coexist with an application background pause",
	)
	_expect_equal(
		(runtime.call("set_background_paused", true) as Dictionary).get("ok"),
		true,
		"background pause adds only its own pause reason",
	)
	var speed_while_background_paused := adapter.call(
		"dispatch",
		"town_hud.set_time_speed",
		{"multiplier": 2},
	) as Dictionary
	_expect_ok(
		speed_while_background_paused,
		"speed selection clears manual pause while backgrounded",
	)
	var background_only_pause := runtime.call("get_lifecycle_state") as Dictionary
	_expect(
		bool(background_only_pause.get("paused", false))
		and not (background_only_pause.get("pauseReasons", []) as Array).has("manual")
		and (background_only_pause.get("pauseReasons", []) as Array).has("background"),
		"speed selection never clears the application-owned background pause",
	)
	_expect_equal(
		(runtime.call("set_background_paused", false) as Dictionary).get("ok"),
		true,
		"foregrounding clears the final background pause reason",
	)
	_expect(
		not bool(
			(runtime.call("get_lifecycle_state") as Dictionary).get(
				"paused",
				true,
			)
		),
		"manual and background pause sequence returns to running",
	)
	var observer_hud := adapter.call("get_view_model", "town_hud") as Dictionary
	await _capture_resident_directory_if_requested(runtime, adapter, observer_hud)
	var observer_actions := observer_hud.get("actions", {}) as Dictionary
	for action_key: String in ["cameraZoomIn", "cameraZoomOut", "cameraReset"]:
		_expect(
			bool((observer_actions.get(action_key, {}) as Dictionary).get("enabled", false)),
			"formal observer HUD enables %s" % action_key,
		)
	var hud_zoom_out := adapter.call(
		"dispatch",
		"town_hud.camera_zoom_out",
		{},
	) as Dictionary
	_expect_equal(hud_zoom_out.get("ok"), true, "observer HUD zoom reaches TownRuntime")
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("cameraZoomIndex"),
		1,
		"observer HUD zoom changes the same formal camera state",
	)
	var hud_reset := adapter.call("dispatch", "town_hud.camera_reset", {}) as Dictionary
	_expect_equal(hud_reset.get("ok"), true, "observer HUD reset reaches TownRuntime")
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("observerCameraPosition"),
		Vector2(3250, 2050),
		"observer HUD reset restores the stable outdoor camera point",
	)
	var drag_start := (
		(runtime.call("get_runtime_state") as Dictionary).get(
			"observerCameraPosition",
			Vector2.ZERO,
		) as Vector2
	)
	var drag_press := InputEventMouseButton.new()
	drag_press.button_index = MOUSE_BUTTON_MIDDLE
	drag_press.pressed = true
	runtime.call("_unhandled_input", drag_press)
	var drag_motion := InputEventMouseMotion.new()
	drag_motion.relative = Vector2(-120.0, 80.0)
	runtime.call("_unhandled_input", drag_motion)
	var drag_release := InputEventMouseButton.new()
	drag_release.button_index = MOUSE_BUTTON_MIDDLE
	drag_release.pressed = false
	runtime.call("_unhandled_input", drag_release)
	_expect(
		(runtime.call("get_runtime_state") as Dictionary).get(
			"observerCameraPosition",
			Vector2.ZERO,
		) != drag_start,
		"observer middle-button drag pans the same formal camera",
	)
	runtime.call("reset_observer_camera")
	var manual_pause_for_observation := runtime.call(
		"set_manual_paused",
		true,
	) as Dictionary
	_expect_equal(
		manual_pause_for_observation.get("ok"),
		true,
		"manual time pause is accepted before observation input",
	)
	var paused_drag_start := (
		(runtime.call("get_runtime_state") as Dictionary).get(
			"observerCameraPosition",
			Vector2.ZERO,
		) as Vector2
	)
	runtime.call("_unhandled_input", drag_press)
	runtime.call("_unhandled_input", drag_motion)
	runtime.call("_unhandled_input", drag_release)
	_expect(
		(runtime.call("get_runtime_state") as Dictionary).get(
			"observerCameraPosition",
			Vector2.ZERO,
		) != paused_drag_start,
		"manual time pause still allows observer camera dragging",
	)
	var paused_place_request := runtime.call(
		"request_observe_place",
		"花房咖啡馆",
	) as Dictionary
	_expect(
		bool(paused_place_request.get("ok", false))
			and bool(paused_place_request.get("pending", false)),
		"manual time pause still accepts entering an indoor place",
	)
	for _frame_index in 80:
		await process_frame
		var paused_view := runtime.call("get_runtime_state") as Dictionary
		if String(paused_view.get("viewMode", "town")) == "interior":
			break
	await _wait_avatar_place_transition(runtime)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
		"interior",
		"manual time pause completes the indoor transition",
	)
	var paused_indoor_hud := adapter.call("get_view_model", "town_hud") as Dictionary
	var paused_indoor_actions := paused_indoor_hud.get("actions", {}) as Dictionary
	var paused_indoor_camera := (
		paused_indoor_hud.get("data", {}) as Dictionary
	).get("camera", {}) as Dictionary
	_expect_equal(
		(paused_indoor_hud.get("data", {}) as Dictionary).get("mapInteraction", {})
			.get("mode", ""),
		"interior",
		"indoor HUD publishes the active interior view mode",
	)
	_expect_equal(
		paused_indoor_camera.get("canDrag"),
		true,
		"indoor HUD keeps camera dragging enabled",
	)
	_expect_equal(
		paused_indoor_camera.get("canReset"),
		true,
		"indoor HUD keeps camera reset enabled",
	)
	for action_key: String in ["cameraZoomIn", "cameraZoomOut", "cameraReset"]:
		_expect(
			bool((paused_indoor_actions.get(action_key, {}) as Dictionary).get("enabled", false)),
			"indoor HUD enables %s" % action_key,
		)
	var paused_return_request := runtime.call(
		"request_return_to_town_overview",
	) as Dictionary
	_expect(
		bool(paused_return_request.get("ok", false))
			and bool(paused_return_request.get("pending", false)),
		"manual time pause accepts returning from an indoor place",
	)
	for _frame_index in 80:
		await process_frame
		var paused_view_after_return := runtime.call("get_runtime_state") as Dictionary
		if String(paused_view_after_return.get("viewMode", "town")) == "town":
			break
	await _wait_avatar_place_transition(runtime)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
		"town",
		"manual time pause completes the outdoor return",
	)
	_expect_equal(
		(runtime.call("set_manual_paused", false) as Dictionary).get("ok"),
		true,
		"manual time pause can be cleared after indoor observation",
	)
	var pause_result := runtime.call("set_main_menu_open", true) as Dictionary
	_expect_equal(pause_result.get("ok"), true, "Pause reason is accepted by the formal World")
	var paused_camera_state := runtime.call("get_runtime_state") as Dictionary
	var paused_camera_position := paused_camera_state.get(
		"observerCameraPosition",
		Vector2.ZERO,
	) as Vector2
	var paused_zoom_index := int(paused_camera_state.get("cameraZoomIndex", -1))
	runtime.call("_unhandled_input", drag_press)
	runtime.call("_unhandled_input", drag_motion)
	runtime.call("_unhandled_input", wheel_up)
	runtime.call("_unhandled_input", drag_release)
	var camera_after_paused_mouse := runtime.call("get_runtime_state") as Dictionary
	_expect_equal(
		camera_after_paused_mouse.get("observerCameraPosition"),
		paused_camera_position,
		"Pause blocks observer drag even if the Host input flag has not changed yet",
	)
	_expect_equal(
		camera_after_paused_mouse.get("cameraZoomIndex"),
		paused_zoom_index + 1,
		"Pause keeps observer wheel zoom available without advancing World time",
	)
	var paused_magnify := InputEventMagnifyGesture.new()
	paused_magnify.factor = 1.25
	runtime.call("_unhandled_input", paused_magnify)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("cameraZoomIndex"),
		paused_zoom_index + 2,
		"Pause keeps trackpad pinch zoom available without advancing World time",
	)
	_expect_equal(
		(runtime.call("set_main_menu_open", false) as Dictionary).get("ok"),
		true,
		"closing Pause resumes the formal World",
	)
	for logical_viewport: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		root.content_scale_size = logical_viewport
		root.size = logical_viewport
		await process_frame
		runtime.call("_reset_observer_camera", true)
		_expect_equal(
			(runtime.call("get_runtime_state") as Dictionary).get(
				"observerCameraPosition"
			),
			Vector2(3250, 2050),
			"%dx%d logical viewport preserves the central-plaza observer reset"
				% [logical_viewport.x, logical_viewport.y],
		)
		runtime.call("_set_observer_camera_position", Vector2.ZERO, true)
		_expect_equal(
			(runtime.call("get_runtime_state") as Dictionary).get(
				"observerCameraPosition"
			),
			Vector2(logical_viewport) / 0.5 * 0.5,
			"%dx%d logical viewport clamps against its own visible half extents"
				% [logical_viewport.x, logical_viewport.y],
		)
	root.content_scale_size = Vector2i(1920, 1080)
	root.size = Vector2i(1920, 1080)
	await process_frame
	runtime.call("_reset_observer_camera", true)
	var player_sprite := runtime.get_node("Player/PaperDoll64Visual/CharacterSprite") as Sprite2D
	_expect_equal(
		player_sprite.texture.resource_path,
		"res://assets/characters/player_avatar_white/player_avatar_white_walk_64.png",
		"formal Town consumes the delivered player avatar atlas",
	)
	_expect_equal(player_sprite.hframes, 4, "formal avatar atlas has four action columns")
	_expect_equal(player_sprite.vframes, 4, "formal avatar atlas has four direction rows")
	_expect_equal(player_sprite.position, Vector2(-32.0, -72.0), "formal avatar keeps the delivered root anchor")
	_expect_equal(
		player_sprite.get_parent().scale,
		Vector2.ONE * 1.65,
		"formal avatar keeps the town-door resident display size",
	)
	var avatar_hud := AVATAR_HUD_SCENE.instantiate() as Control
	runtime.add_child(avatar_hud)
	var avatar_issues := avatar_hud.call("bind_town_ui_adapter", adapter) as PackedStringArray
	_expect_equal(
		avatar_issues,
		PackedStringArray(),
		"approved AvatarModeHud binds without a parallel ViewModel",
	)
	runtime.call(
		"_set_observer_camera_position",
		Vector2(3260, 2050),
		true,
	)
	var descent := adapter.call("dispatch", "town_hud.select_tool", {"toolId": "avatar"}) as Dictionary
	_expect_equal(descent.get("ok"), true, "observer HUD explicitly starts avatar descent")
	_expect_equal(runtime.call("get_avatar_mode"), "avatar_descent", "descent is a distinct locked runtime state")
	var landing_state := (runtime.call("get_runtime_state") as Dictionary).get("playerAvatar", {}) as Dictionary
	_expect_equal(landing_state.get("spaceId"), "town_outdoor", "avatar descent is prepared on the outdoor map")
	_expect_equal(landing_state.get("currentPlace"), "中心广场", "avatar descent derives the current view-center membership")
	_expect(
		(
			landing_state.get("position", Vector2.INF) as Vector2
		).distance_to(Vector2(3260, 2050)) < 16.0,
		"avatar descent follows the live view center and uses its nearest safe point",
	)
	_expect_equal((runtime.call("get_avatar_descent_snapshot") as Dictionary).get("inputLocked"), true, "descent locks player input")
	var descent_player_position := (runtime.get_node("Player") as Node2D).position
	var descent_camera_state := runtime.call("get_runtime_state") as Dictionary
	Input.action_press("move_right")
	await physics_frame
	await physics_frame
	Input.action_release("move_right")
	runtime.call("_unhandled_input", wheel_up)
	_expect_equal(
		(runtime.get_node("Player") as Node2D).position,
		descent_player_position,
		"avatar descent ignores movement input until the unlock edge",
	)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("cameraZoomIndex"),
		descent_camera_state.get("cameraZoomIndex"),
		"avatar descent ignores observer wheel input",
	)
	await create_timer(0.35).timeout
	var beam_snapshot := runtime.call("get_avatar_descent_snapshot") as Dictionary
	_expect_equal(beam_snapshot.get("cueEmitted"), true, "300ms beam edge emits the delivered descent cue once")
	await create_timer(0.8).timeout
	_expect_equal(runtime.call("get_avatar_mode"), "avatar_active", "old 1100ms input edge activates avatar")
	var avatar_zoom_before_input := int(
		(runtime.call("get_runtime_state") as Dictionary).get(
			"cameraZoomIndex",
			-1,
		)
	)
	runtime.call("_unhandled_input", wheel_up)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("cameraZoomIndex"),
		avatar_zoom_before_input + 1,
		"active avatar mouse wheel zooms the gameplay camera",
	)
	var avatar_magnify := InputEventMagnifyGesture.new()
	avatar_magnify.factor = 0.8
	runtime.call("_unhandled_input", avatar_magnify)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("cameraZoomIndex"),
		avatar_zoom_before_input,
		"active avatar trackpad pinch zooms the gameplay camera",
	)
	var active_player_body := runtime.get_node("Player") as CharacterBody2D
	_expect_equal(
		active_player_body.collision_mask,
		13,
		"active avatar collides with the map, residents and ground animals",
	)
	_expect_equal(
		(
			runtime.call(
				"get_avatar_descent_snapshot",
			) as Dictionary
		).get("unlockEmitted"),
		true,
		"descent emits its input-unlock edge even if a slow headless frame also finishes the visual tail",
	)
	await create_timer(0.35).timeout
	_expect_equal((runtime.call("get_avatar_descent_snapshot") as Dictionary).get("active"), false, "old 1450ms edge completes all descent effects")
	var active_player_position := (runtime.get_node("Player") as Node2D).position
	Input.action_press("move_right")
	await physics_frame
	await physics_frame
	Input.action_release("move_right")
	_expect(
		(runtime.get_node("Player") as Node2D).position.x > active_player_position.x,
		"avatar active opens player movement only after descent unlock",
	)
	var text_input := LineEdit.new()
	text_input.name = "MovementInputFocusProbe"
	runtime.add_child(text_input)
	text_input.grab_focus()
	await process_frame
	var position_before_text_input := (runtime.get_node("Player") as Node2D).position
	_send_physical_key(&"move_down", KEY_S, true)
	await physics_frame
	await physics_frame
	_expect_equal(
		(runtime.get_node("Player") as Node2D).position,
		position_before_text_input,
		"typing a movement key never moves the avatar behind a text input",
	)
	text_input.release_focus()
	await process_frame
	await physics_frame
	_expect_equal(
		(runtime.get_node("Player") as Node2D).position,
		position_before_text_input,
		"closing text input clears a swallowed movement key instead of moving forever",
	)
	_expect(
		not Input.is_action_pressed("move_down"),
		"text-input handoff releases the stale down action",
	)
	_send_physical_key(&"move_down", KEY_S, false)
	_send_physical_key(&"move_right", KEY_D, true)
	await physics_frame
	await physics_frame
	_send_physical_key(&"move_right", KEY_D, false)
	_expect(
		(runtime.get_node("Player") as Node2D).position.x > position_before_text_input.x,
		"fresh movement input works after text input closes",
	)
	var long_run_avatar_start := (runtime.get_node("Player") as Node2D).position
	Input.action_press("move_right")
	for frame_index in 180:
		await physics_frame
		if frame_index % 30 == 0:
			_expect(
				avatar_hud.visible,
				"long avatar run keeps AvatarModeHud visible at frame %d" % frame_index,
			)
			_expect_equal(
				avatar_hud.process_mode,
				Node.PROCESS_MODE_ALWAYS,
				"long avatar run keeps HUD processing at frame %d" % frame_index,
			)
	Input.action_release("move_right")
	_expect(
		(runtime.get_node("Player") as Node2D).position != long_run_avatar_start,
		"long avatar run continues moving while the resident gateway is active",
	)
	text_input.queue_free()
	await _verify_conversation_first_visible_frame(
		runtime,
		adapter,
		world_runtime,
	)
	var avatar_player := runtime.get_node("Player") as Node2D
	avatar_player.position = Vector2(4225.0, 1120.0)
	avatar_player.force_update_transform()
	runtime.call("_check_interior_auto_portals")
	await _wait_avatar_place_transition(runtime)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
		"interior",
		"avatar enters from the visible clinic doorway",
	)
	_expect_equal(
		runtime.call("get_avatar_mode"),
		"avatar_active",
		"physical indoor entry preserves avatar mode",
	)
	_expect(
		avatar_hud.visible,
		"AvatarModeHud stays visible after physical indoor entry",
	)
	runtime.call("_exit_interior", avatar_player, "clinic")
	await _wait_avatar_place_transition(runtime)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
		"town",
		"avatar physically returns to the outdoor town",
	)
	_expect_equal(
		runtime.call("get_avatar_mode"),
		"avatar_active",
		"physical outdoor return preserves avatar mode until the player exits it",
	)
	_expect(
		avatar_hud.visible,
		"AvatarModeHud returns after the indoor-to-outdoor transition",
	)
	runtime.call("_check_interior_auto_portals")
	await process_frame
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
		"town",
		"the exit doorway does not immediately pull the avatar back indoors",
	)
	avatar_player.position = Vector2(4225.0, 1260.0)
	avatar_player.force_update_transform()
	runtime.call("_check_interior_auto_portals")
	avatar_player.position = Vector2(4225.0, 1120.0)
	avatar_player.force_update_transform()
	runtime.call("_check_interior_auto_portals")
	await _wait_avatar_place_transition(runtime)
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
		"interior",
		"leaving the doorway re-enables a later physical entry",
	)
	runtime.call("_exit_interior", avatar_player, "clinic")
	await _wait_avatar_place_transition(runtime)
	_expect(
		bool(avatar_hud.call("debug_activate_action", "exitMode")),
		"returned AvatarModeHud keeps the return-to-observer action enabled",
	)
	await _wait_frames(2)
	_expect_equal(
		runtime.call("get_avatar_mode"),
		"observer",
		"indoor roundtrip can still return to observer mode",
	)
	state_before_test_keys = runtime.call("get_runtime_state") as Dictionary
	var player_position_before_test_keys := (runtime.get_node("Player") as Node2D).position
	for keycode: Key in [KEY_P, KEY_C, KEY_T, KEY_J]:
		var key_event := InputEventKey.new()
		key_event.keycode = keycode
		key_event.pressed = true
		runtime.call("_unhandled_input", key_event)
	var state_after_test_keys := runtime.call("get_runtime_state") as Dictionary
	_expect_equal(
		state_after_test_keys.get("weather"),
		state_before_test_keys.get("weather"),
		"formal runtime ignores the C weather test shortcut",
	)
	_expect_equal(
		state_after_test_keys.get("time"),
		state_before_test_keys.get("time"),
		"formal runtime ignores the T time test shortcut",
	)
	_expect_equal(
		state_after_test_keys.get("lifecycle"),
		state_before_test_keys.get("lifecycle"),
		"formal runtime ignores the P manual-pause test shortcut",
	)
	_expect_equal(
		(runtime.get_node("Player") as Node2D).position,
		player_position_before_test_keys,
		"formal runtime ignores the J house-teleport test shortcut",
	)
	var avatar_vm := adapter.call("get_view_model", "avatar") as Dictionary
	_expect_equal(avatar_vm.get("scope"), "avatar", "AvatarModeHud receives the canonical avatar scope")
	var pause_vm := adapter.call("get_view_model", "pause_menu") as Dictionary
	_expect_equal(pause_vm.get("scope"), "pause_menu", "pause host uses the same canonical Adapter")
	_expect_equal(pause_vm.get("data", {}).get("internalPlaytest", null), null, "pause scope does not invent a second session draft")
	var save_vm := adapter.call("get_view_model", "save") as Dictionary
	_expect_equal(save_vm.get("status"), "disabled", "save stays disabled for tomorrow playtest")
	_expect_equal(
		save_vm.get("error", {}).get("code"),
		"SESSION_SAVE_SERVICE_NOT_BOUND",
		"save stays unavailable until the formal session save service is bound",
	)
	var pause_host := PAUSE_HOST_SCENE.instantiate() as Control
	runtime.add_child(pause_host)
	pause_host.call("bind_town_ui_adapter", adapter)
	await process_frame
	_expect_equal(
		bool((pause_host.call("debug_snapshot") as Dictionary).get("adapterBound", false)),
		true,
		"PauseMenuNavigationHost binds the same Adapter",
	)
	var failed_descent_camera := runtime.get_node("PlayerCamera") as Camera2D
	failed_descent_camera.zoom = Vector2.ONE * 1_000_000.0
	var failed_descent := adapter.call(
		"dispatch",
		"town_hud.select_tool",
		{"toolId": "avatar"},
	) as Dictionary
	_expect_equal(
		failed_descent.get("ok"),
		true,
		"avatar entry remains accepted when the optional descent presentation cannot start",
	)
	_expect_equal(
		runtime.call("get_avatar_mode"),
		"avatar_descent",
		"failed presentation keeps the transition locked until the deferred recovery turn",
	)
	_expect_equal(
		(runtime.call("get_avatar_descent_snapshot") as Dictionary).get("active"),
		false,
		"invalid camera transform makes the real descent presentation reject start",
	)
	var repeated_failed_descent := adapter.call(
		"dispatch",
		"town_hud.select_tool",
		{"toolId": "avatar"},
	) as Dictionary
	_expect_equal(
		repeated_failed_descent.get("errorCode"),
		"AVATAR_MODE_TRANSITION_IN_PROGRESS",
		"a repeated click cannot start or reverse the failed descent recovery",
	)
	await process_frame
	var recovered_avatar_state := runtime.call("get_runtime_state") as Dictionary
	var recovered_player := runtime.get_node("Player") as CharacterBody2D
	var recovered_feet := recovered_player.get_node("FeetCollision") as CollisionShape2D
	_expect_equal(
		runtime.call("get_avatar_mode"),
		"avatar_active",
		"failed descent presentation completes avatar entry on the next idle turn",
	)
	_expect_equal(
		recovered_avatar_state.get("playerAvatarEnabled"),
		true,
		"failed presentation recovery enables avatar control",
	)
	_expect_equal(recovered_player.collision_layer, 2, "failed presentation recovery restores the avatar collision layer")
	_expect_equal(recovered_player.collision_mask, 13, "failed presentation recovery restores the avatar collision mask")
	_expect_equal(recovered_feet.disabled, false, "failed presentation recovery restores feet collision")
	_expect_equal(failed_descent_camera.zoom, Vector2.ONE, "failed presentation recovery restores gameplay camera zoom")

	var agent_participant: RefCounted = gateway.call("get_agent_save_participant")
	var context := gateway.call("get_agent_save_context") as Dictionary
	runtime.queue_free()
	await process_frame
	if agent_participant != null and not context.is_empty():
		var deleted := agent_participant.call("delete_game", context) as Dictionary
		_expect_ok(deleted, "composition smoke removes its complete Agent slot")
	request_host.queue_free()
	_finish()


func _verify_max_population_gateway(
	max_population_case: Dictionary,
	world_data: Dictionary,
	provider_service: RefCounted,
	request_host: Node,
) -> void:
	_expect(
		not max_population_case.is_empty(),
		"variable-population matrix preserves the max-population runtime case",
	)
	if max_population_case.is_empty():
		return
	var draft := max_population_case.get("draft", {}) as Dictionary
	var catalog := max_population_case.get("catalog", {}) as Dictionary
	var resident_ids := max_population_case.get("residentIds", []) as Array
	_expect_equal(
		resident_ids.size(),
		POPULATION_RULES.MAX_RESIDENT_COUNT,
		"max-population Agent case contains all selected resident IDs",
	)
	var gateway: Node = GATEWAY.new()
	var runtime: Node = TOWN_RUNTIME_SCENE.instantiate()
	var bootstrap: RefCounted = BOOTSTRAP.new()
	var identity := str(Time.get_ticks_usec())
	var slot_id := "test-max-population-slot-%s" % identity
	var session_id := "max-population-session-%s" % identity
	var collector := ResultCollector.new()
	var accepted := bootstrap.call(
		"begin_new_game_from_catalog",
		draft,
		world_data,
		catalog,
		provider_service,
		gateway,
		runtime,
		{
			"worldStartMode": "development",
			"internalPlaytest": true,
			"sessionId": session_id,
			"slotId": slot_id,
			"requestHost": request_host,
			"useLiveModel": false,
			"enablePlayerAvatar": true,
		},
		collector.collect,
	) as Dictionary
	_expect_equal(
		accepted.get("accepted"),
		true,
		"thirty-resident bootstrap accepts the production composition request",
	)
	var bootstrap_result := collector.result
	_expect_ok(
		bootstrap_result,
		"thirty-resident bootstrap configures the real Town Runtime and Gateway",
	)
	if not bool(bootstrap_result.get("ok", false)):
		if is_instance_valid(runtime):
			runtime.free()
		if is_instance_valid(gateway) and gateway.get_parent() == null:
			gateway.free()
		return

	var scheduling_probe := {
		"dispatchCount": 0,
		"peakInflight": 0,
	}
	var gateway_weak: WeakRef = weakref(gateway)
	gateway.debug_decision_dispatched.connect(
		func(_event: Dictionary) -> void:
			var current_gateway: Object = gateway_weak.get_ref()
			scheduling_probe["dispatchCount"] = int(
				scheduling_probe.get("dispatchCount", 0),
			) + 1
			if current_gateway != null:
				scheduling_probe["peakInflight"] = maxi(
					int(scheduling_probe.get("peakInflight", 0)),
					int(current_gateway.call("get_debug_inflight_count")),
				)
	)
	var started_at_msec := Time.get_ticks_msec()
	root.add_child(runtime)
	var all_residents_submitted := false
	var observed_frames := 0
	for _frame_index in 720:
		await process_frame
		observed_frames += 1
		if gateway.call("get_connected_resident_ids").size() != resident_ids.size():
			continue
		all_residents_submitted = true
		for resident_id_value: Variant in resident_ids:
			if (
				gateway.call(
					"get_last_submission",
					String(resident_id_value),
				) as Dictionary
			).is_empty():
				all_residents_submitted = false
				break
		if all_residents_submitted:
			break
	var decision_elapsed_msec := Time.get_ticks_msec() - started_at_msec
	var startup := runtime.call("get_startup_result") as Dictionary
	_expect_ok(startup, "thirty-resident configured Town Runtime starts")
	_expect_equal(
		runtime.call("get_connected_agent_names").size(),
		POPULATION_RULES.MAX_RESIDENT_COUNT,
		"real Town Runtime connects all thirty Agent residents",
	)
	_expect_equal(
		gateway.call("get_connected_resident_ids").size(),
		POPULATION_RULES.MAX_RESIDENT_COUNT,
		"real Gateway routes all thirty stable resident IDs",
	)
	_expect(
		all_residents_submitted,
		"all thirty initial Agent decisions complete and submit to World within the bounded frame budget",
	)
	var request_metrics := gateway.call("get_request_metrics") as Dictionary
	_expect(
		int(request_metrics.get("providerDispatch", 0))
		>= POPULATION_RULES.MAX_RESIDENT_COUNT,
		"max population dispatches at least one model request per resident",
	)
	_expect(
		int(request_metrics.get("providerComplete", 0))
		>= POPULATION_RULES.MAX_RESIDENT_COUNT,
		"max population completes at least one model request per resident",
	)
	_expect(
		int(scheduling_probe.get("dispatchCount", 0))
		>= POPULATION_RULES.MAX_RESIDENT_COUNT,
		"Gateway dispatch signal observes the full thirty-resident scheduling wave",
	)
	_expect(
		int(scheduling_probe.get("peakInflight", 0)) > 0
		and int(scheduling_probe.get("peakInflight", 0))
		<= GATEWAY.MAX_CONCURRENT_MODEL_REQUESTS,
		"thirty-resident scheduling never exceeds the six-request concurrency limit",
	)
	_expect_equal(
		(gateway.call("get_errors") as Array).size(),
		0,
		"thirty-resident Gateway finishes without hidden resident errors",
	)
	var world: RefCounted = runtime.call("get_world_runtime")
	_expect_equal(
		(world.call("get_town_hud_resident_states") as Array).size(),
		POPULATION_RULES.MAX_RESIDENT_COUNT,
		"thirty-resident live Agent run keeps the complete HUD projection",
	)
	_expect(
		decision_elapsed_msec < 15_000,
		"thirty initial fake-model decisions complete within the fifteen-second stress budget (%d ms)"
		% decision_elapsed_msec,
	)
	var average_frame_msec := (
		float(decision_elapsed_msec) / float(maxi(observed_frames, 1))
	)
	_expect(
		average_frame_msec < 25.0,
		"thirty-resident startup and first decisions average below 25 ms per observed frame (%.2f ms)"
		% average_frame_msec,
	)
	print(
		"MAX_POPULATION_AGENT_STRESS population=%d decision_ms=%d observed_frames=%d average_frame_ms=%.2f provider_dispatch=%d provider_complete=%d pending_peak=%d inflight_peak=%d submission_count=%d errors=%d"
		% [
			POPULATION_RULES.MAX_RESIDENT_COUNT,
			decision_elapsed_msec,
			observed_frames,
			average_frame_msec,
			int(request_metrics.get("providerDispatch", 0)),
			int(request_metrics.get("providerComplete", 0)),
			int(request_metrics.get("pendingQueuePeak", 0)),
			int(scheduling_probe.get("peakInflight", 0)),
			resident_ids.size() if all_residents_submitted else 0,
			(gateway.call("get_errors") as Array).size(),
		],
	)

	var agent_participant: RefCounted = gateway.call("get_agent_save_participant")
	var context := gateway.call("get_agent_save_context") as Dictionary
	runtime.queue_free()
	for _frame_index in 3:
		await process_frame
	if agent_participant != null and not context.is_empty():
		_expect_ok(
			agent_participant.call("delete_game", context) as Dictionary,
			"max-population stress removes its complete Agent slot",
		)


func _verify_variable_population_openings(
	world_data: Dictionary,
	formal_catalog: Dictionary,
) -> Dictionary:
	var max_population_case: Dictionary = {}
	_expect_equal(
		POPULATION_RULES.rule_snapshot(world_data),
		{
			"minimum": 1,
			"default": 15,
			"maximum": 30,
			"housingCapacity": 30,
			"homeCount": 15,
		},
		"variable population publishes one explicit 1-to-30 rule and housing capacity",
	)
	_expect_equal(
		GATEWAY.MAX_CONCURRENT_MODEL_REQUESTS,
		6,
		"higher population keeps the bounded Agent model-request concurrency limit",
	)
	for resident_count in [1, 5, 15, 16, 30]:
		var selection_vm := RESIDENT_CATALOG.build_view_model(
			"fake",
			"fake",
			true,
			30 + resident_count,
		) as Dictionary
		var selection_data := selection_vm.get("data", {}) as Dictionary
		var recommended := (
			selection_data.get("recommended_resident_ids", []) as Array
		)
		var selected: Array = recommended.slice(
			0,
			mini(resident_count, recommended.size()),
		)
		var session_catalog := formal_catalog.duplicate(true)
		_append_capacity_safe_custom_residents(
			selection_data,
			session_catalog,
			world_data,
			selected,
			resident_count,
		)
		selection_data["selected_resident_ids"] = selected
		RESIDENT_CATALOG.update_confirmation_payload(
			selection_data,
			"fake",
			"fake",
			40 + resident_count,
		)
		var draft := (
			selection_data.get("confirmation_payload", {}) as Dictionary
		)
		_expect_equal(
			(draft.get("slots", []) as Array).size(),
			resident_count,
			"%d-resident selection creates only occupied home slots" % resident_count,
		)
		_expect_ok(
			NEW_GAME_DRAFT.validate(draft),
			"%d-resident draft satisfies the shared population rule" % resident_count,
		)
		var compiled := COMPILER.compile(draft, world_data, session_catalog)
		_expect_ok(
			compiled,
			"%d-resident draft compiles into a formal opening" % resident_count,
		)
		if compiled.get("ok") != true:
			continue
		var opening := compiled.get("openingConfig", {}) as Dictionary
		_expect_equal(
			(opening.get("residents", []) as Array).size(),
			resident_count,
			"%d-resident opening contains only the selected residents" % resident_count,
		)
		var owners := opening.get("ownerAssignments", {}) as Dictionary
		_expect_equal(
			owners.size(),
			mini(resident_count, POPULATION_RULES.DEFAULT_RESIDENT_COUNT),
			"%d-resident opening assigns one responsible resident per occupied home"
			% resident_count,
		)
		var occupancy_by_home: Dictionary = {}
		for slot_value: Variant in draft.get("slots", []) as Array:
			var space_id := String((slot_value as Dictionary).get("spaceId", ""))
			occupancy_by_home[space_id] = int(occupancy_by_home.get(space_id, 0)) + 1
		for occupancy_value: Variant in occupancy_by_home.values():
			_expect(
				int(occupancy_value) <= 2,
				"%d-resident opening respects two residents per home" % resident_count,
			)
		if resident_count == 16:
			_expect_equal(
				occupancy_by_home.get("home_01"),
				2,
				"the sixteenth resident shares home_01 after all homes receive one resident",
			)
		if resident_count < POPULATION_RULES.DEFAULT_RESIDENT_COUNT:
			var first_unused_home_name := ""
			for place_value: Variant in world_data.get("places", []) as Array:
				var place := place_value as Dictionary
				if String(place.get("spaceId", "")) == "home_%02d" % (resident_count + 1):
					first_unused_home_name = String(place.get("name", ""))
					break
			_expect(
				not first_unused_home_name.is_empty()
				and not owners.has(first_unused_home_name),
				"first unused home remains empty for %d-resident opening" % resident_count,
			)
		var selected_ids: Array[String] = []
		for slot_value: Variant in draft.get("slots", []) as Array:
			selected_ids.append(String((slot_value as Dictionary).get("residentId", "")))
		if resident_count == POPULATION_RULES.MAX_RESIDENT_COUNT:
			max_population_case = {
				"draft": draft.duplicate(true),
				"catalog": session_catalog.duplicate(true),
				"residentIds": selected_ids.duplicate(),
			}
		var projected_catalog := session_catalog.duplicate(true)
		var projected_residents: Array[Dictionary] = []
		for resident_value: Variant in session_catalog.get("residents", []) as Array:
			var resident := resident_value as Dictionary
			if selected_ids.has(String(resident.get("residentId", ""))):
				projected_residents.append(resident.duplicate(true))
		projected_catalog["residents"] = projected_residents
		var assignment_service := MODEL_ASSIGNMENT_SERVICE.new()
		var configured := assignment_service.configure(
			VariablePopulationProvider.new(),
			projected_catalog,
			draft,
		) as Dictionary
		_expect_ok(
			configured,
			"model assignment uses the actual %d-resident draft" % resident_count,
		)
		_expect_equal(
			configured.get("residentCount"),
			resident_count,
			"model assignment reports the actual resident count",
		)
		var resident_editor := RESIDENT_EDITOR_SERVICE.new()
		var editor_configured := resident_editor.configure(
			session_catalog,
			world_data,
			draft,
		) as Dictionary
		_expect_ok(
			editor_configured,
			"resident editor uses the actual %d-resident draft" % resident_count,
		)
		_expect_equal(
			(
				(resident_editor.get_view_model().get("data", {}) as Dictionary)
				.get("slotCount")
			),
			resident_count,
			"resident editor reports the actual resident count",
		)
		var identities: Array[Dictionary] = []
		for binding_value: Variant in compiled.get("residentBindings", []) as Array:
			var binding := binding_value as Dictionary
			identities.append({
				"residentId": String(binding.get("residentId", "")),
				"residentName": String(binding.get("residentName", "")),
			})
		var world: RefCounted = WORLD.new()
		var start_begin_msec := Time.get_ticks_msec()
		var started := world.call("start", world_data, opening, identities) as Dictionary
		var start_elapsed_msec := Time.get_ticks_msec() - start_begin_msec
		_expect_ok(
			started,
			"formal World starts with %d residents" % resident_count,
		)
		if started.get("ok") == true:
			var running_resident_ids := world.call("get_resident_ids") as Array
			_expect_equal(
				running_resident_ids.size(),
				resident_count,
				"running World keeps the selected %d-resident set" % resident_count,
			)
			if resident_count == POPULATION_RULES.MAX_RESIDENT_COUNT:
				_expect(
					_verify_max_population_profession_work(world, opening),
					"max-population World completes a real three-stage profession task",
				)
			if resident_count in [15, 30]:
				_expect(
					start_elapsed_msec < 10_000,
					"%d-resident World starts within the ten-second stress budget (%d ms)"
					% [resident_count, start_elapsed_msec],
				)
				var advance_begin_msec := Time.get_ticks_msec()
				world.call("advance", 720.0)
				var advance_elapsed_msec := Time.get_ticks_msec() - advance_begin_msec
				var activity_query_begin_msec := Time.get_ticks_msec()
				var activity_option_count := 0
				var activity_query_count := 0
				for resident_id_value: Variant in running_resident_ids:
					var resident_id := String(resident_id_value)
					var initialization := world.call(
						"get_agent_initialization_by_id",
						resident_id,
					) as Dictionary
					_expect(
						AGENT_CONTRACT.validate_initialization(initialization).is_empty(),
						"%d-resident stress exposes a valid Agent initialization for %s"
						% [resident_count, resident_id],
					)
					var activity_query := world.call(
						"query_activity_options",
						resident_id,
						{},
						2,
					) as Dictionary
					_expect_ok(
						activity_query,
						"%d-resident activity and reachability query succeeds for %s"
						% [resident_count, resident_id],
					)
					if bool(activity_query.get("ok", false)):
						activity_query_count += 1
					activity_option_count += (
						activity_query.get("options", []) as Array
					).size()
				var activity_query_elapsed_msec := (
					Time.get_ticks_msec() - activity_query_begin_msec
				)
				_expect(
					activity_query_count == resident_count,
					"%d-resident stress completes one activity/reachability query per resident"
					% resident_count,
				)
				_expect_equal(
					(world.call("get_town_hud_resident_states") as Array).size(),
					resident_count,
					"HUD projection includes all %d residents" % resident_count,
				)
				if resident_count == POPULATION_RULES.MAX_RESIDENT_COUNT:
					var staffing_snapshot := world.call("get_staffing_snapshot") as Dictionary
					var has_productive_team := false
					for post_value: Variant in staffing_snapshot.get("posts", []) as Array:
						var post := post_value as Dictionary
						if (
							int(post.get("staffedHeadcount", 0)) >= 2
							and int(post.get("serviceThroughputCapacity", 0)) >= 2
						):
							has_productive_team = true
							break
					_expect(
						has_productive_team,
						"max-population staffing turns repeated professions into productive teams",
					)
					var has_multi_worker_service_capacity := false
					for service_value: Variant in world.call(
						"get_place_service_state_snapshots",
					) as Array:
						var service := service_value as Dictionary
						if (
							int(service.get("service_capacity", 0)) >= 2
						):
							has_multi_worker_service_capacity = true
							break
					_expect(
						has_multi_worker_service_capacity,
						"max-population services expose capacity for multiple workers",
					)
				_expect_equal(
					(world.call("get_all_resident_states") as Array).size(),
					resident_count,
					"%d-resident advancement keeps every resident queryable" % resident_count,
				)
				var save_begin_msec := Time.get_ticks_msec()
				var save_result := world.call("create_save_snapshot") as Dictionary
				_expect_ok(
					save_result,
					"%d-resident World creates a save snapshot" % resident_count,
				)
				var snapshot_text := JSON.stringify(
					save_result.get("snapshot", {}) as Dictionary,
				)
				var decoded_snapshot: Variant = JSON.parse_string(snapshot_text)
				var restored := world.call(
					"restore_from_snapshot",
					world_data,
					opening,
					decoded_snapshot as Dictionary,
					identities,
				) as Dictionary
				_expect_ok(
					restored,
					"%d-resident JSON snapshot restores" % resident_count,
				)
				_expect_equal(
					(world.call("get_resident_ids") as Array).size(),
					resident_count,
					"%d-resident restore keeps the full resident identity set" % resident_count,
				)
				var save_restore_elapsed := Time.get_ticks_msec() - save_begin_msec
				var static_memory_bytes := int(
					Performance.get_monitor(Performance.MEMORY_STATIC),
				)
				_expect(
					save_restore_elapsed < 10_000,
					"%d-resident save and restore stays within the ten-second stress budget (%d ms)"
					% [resident_count, save_restore_elapsed],
				)
				print(
					"VARIABLE_POPULATION_STRESS population=%d start_ms=%d activity_query_ms=%d advance_720m_ms=%d save_restore_ms=%d save_bytes=%d static_memory_bytes=%d activity_queries=%d activity_options=%d model_request_limit=%d"
					% [
						resident_count,
						start_elapsed_msec,
						activity_query_elapsed_msec,
						advance_elapsed_msec,
						save_restore_elapsed,
						snapshot_text.to_utf8_buffer().size(),
						static_memory_bytes,
						activity_query_count,
						activity_option_count,
						GATEWAY.MAX_CONCURRENT_MODEL_REQUESTS,
					],
				)
			if resident_count == POPULATION_RULES.MAX_RESIDENT_COUNT:
				_verify_max_population_replacement(world, opening, draft, identities)
			world.call("stop")
	return max_population_case


func _verify_max_population_profession_work(
	world: RefCounted,
	opening: Dictionary,
) -> bool:
	var craftsperson_id := ""
	for resident_value: Variant in opening.get("residents", []) as Array:
		var resident := resident_value as Dictionary
		if String(
			(resident.get("socialState", {}) as Dictionary).get("job", ""),
		) == "工匠":
			craftsperson_id = String(resident.get("residentId", ""))
			break
	if craftsperson_id.is_empty():
		return false
	var requests: Array = []
	for _attempt in 20:
		requests = world.call(
			"take_pending_decision_requests_by_ids",
			[craftsperson_id],
		) as Array
		if not requests.is_empty():
			break
		world.call("advance", 1.0)
	if requests.is_empty():
		return false
	var wake := (
		(requests[0] as Dictionary).get("wakePacket", {}) as Dictionary
	)
	var decision_id := String(wake.get("decision_id", ""))
	var moved := world.call(
		"submit_agent_decision_by_id",
		craftsperson_id,
		{
			"decision_id": decision_id,
			"handling": "replace_current",
			"action": {
				"action_id": "%s-max-population-workshop" % decision_id,
				"type": "去",
				"place": "工作坊",
				"line": "前往工作坊完成正式生产任务。",
			},
		},
	) as Dictionary
	if String(moved.get("status", "")) != "accepted":
		return false
	if not _advance_resident_action_until_clear(
		world,
		craftsperson_id,
		900,
	):
		return false
	var state := world.call(
		"get_resident_state",
		craftsperson_id,
	) as Dictionary
	if String(state.get("currentPlace", "")) != "工作坊":
		return false
	var activity_ids: Array[String] = [
		"activity_workshop_take_lumber",
		"activity_workshop_grind_parts",
		"activity_workshop_assemble_item",
	]
	for index in activity_ids.size():
		var activity_id := activity_ids[index]
		var performed := world.call(
			"perform_activity_step",
			craftsperson_id,
			"max-population-craft-plan",
			index,
			{
				"stepId": "max-population-craft-step-%d" % index,
				"operation": "activity.perform",
				"target": {
					"activityId": activity_id,
					"placeId": "工作坊",
				},
				"params": {
					"reason": "验证三十人小镇仍能完成真实职业生产",
				},
			},
		) as Dictionary
		if not bool(performed.get("ok", false)):
			return false
		if not _advance_resident_action_until_clear(
			world,
			craftsperson_id,
			240,
		):
			return false
	for lot_value: Variant in (
		world.call("get_cargo_inventory_snapshot") as Dictionary
	).get("cargoLots", []) as Array:
		var lot := lot_value as Dictionary
		if (
			String(lot.get("itemId", "")) == "crafted_item"
			and String(lot.get("sourcePlaceId", "")) == "工作坊"
		):
			return true
	return false


func _advance_resident_action_until_clear(
	world: RefCounted,
	resident_id: String,
	maximum_minutes: int,
) -> bool:
	for _minute in maximum_minutes:
		var state := world.call(
			"get_resident_state",
			resident_id,
		) as Dictionary
		if state.get("currentAction") == null:
			return true
		world.call("advance", 1.0)
	return false


func _verify_max_population_replacement(
	world: RefCounted,
	opening: Dictionary,
	draft: Dictionary,
	identities: Array[Dictionary],
) -> void:
	var shared_record := (
		(opening.get("residents", []) as Array)[15] as Dictionary
	).duplicate(true)
	var resident_id := String(shared_record.get("residentId", ""))
	var expected_space_id := ""
	for slot_value: Variant in draft.get("slots", []) as Array:
		var slot := slot_value as Dictionary
		if String(slot.get("residentId", "")) == resident_id:
			expected_space_id = String(slot.get("spaceId", ""))
			break
	var host := GAME_FLOW_HOST.new()
	host.set("_active_session_config", {"openingConfig": opening.duplicate(true)})
	_expect_equal(
		host.call("_replacement_home_space_id", resident_id),
		expected_space_id,
		"a replacement for the sixteenth resident keeps the authored shared home",
	)
	host.free()
	var death := world.call(
		"confirm_resident_death",
		resident_id,
		"三十人补位压力回归",
	) as Dictionary
	_expect_ok(death, "max-population World accepts one resident death")
	_expect_equal(
		RESIDENT_REPLACEMENT.target_resident_count(world),
		POPULATION_RULES.MAX_RESIDENT_COUNT,
		"death keeps the thirty-resident session target",
	)
	_expect_equal(
		RESIDENT_REPLACEMENT.living_resident_count(world),
		POPULATION_RULES.MAX_RESIDENT_COUNT - 1,
		"one death leaves twenty-nine living residents",
	)
	var death_save := world.call("create_save_snapshot") as Dictionary
	_expect_ok(death_save, "max-population death state saves before replacement")
	var restored_world: RefCounted = WORLD.new()
	var restored := restored_world.call(
		"restore_from_snapshot",
		_read_json("res://world/data/town/town_world.json"),
		opening,
		death_save.get("snapshot", {}) as Dictionary,
		identities,
	) as Dictionary
	_expect_ok(restored, "max-population death state restores before replacement")
	var replacement_attributes := (
		shared_record.get("attributes", {}) as Dictionary
	).duplicate(true)
	replacement_attributes["name"] = "三十人镇补位居民"
	shared_record["attributes"] = replacement_attributes
	var admitted := RESIDENT_REPLACEMENT.admit(
		restored_world,
		shared_record,
		resident_id,
	) as Dictionary
	_expect_ok(admitted, "max-population restored World admits the replacement")
	_expect_equal(
		RESIDENT_REPLACEMENT.living_resident_count(restored_world),
		POPULATION_RULES.MAX_RESIDENT_COUNT,
		"replacement restores exactly thirty living residents",
	)
	var replacement_initialization := restored_world.call(
		"get_agent_initialization_by_id",
		resident_id,
	) as Dictionary
	_expect_equal(
		(
			(replacement_initialization.get("me", {}) as Dictionary)
			.get("social_state", {}) as Dictionary
		).get("home"),
		(shared_record.get("socialState", {}) as Dictionary).get("home"),
		"replacement keeps the shared-home relationship after restore",
	)
	_expect_equal(
		(
			(replacement_initialization.get("me", {}) as Dictionary)
			.get("social_state", {}) as Dictionary
		).get("job"),
		(shared_record.get("socialState", {}) as Dictionary).get("job"),
		"replacement restores the original legal occupation assignment",
	)
	_expect_equal(
		(
			restored_world.call("get_staffing_snapshot") as Dictionary
		).get("overCapacityPostIds"),
		[],
		"replacement does not create a hidden occupation-capacity conflict",
	)
	restored_world.call("stop")

	var empty_draft := {
		"schemaVersion": 1,
		"sourceScope": "resident_selection",
		"draftRevision": 1,
		"slots": [],
	}
	_expect(
		_result_has_error_code(
			NEW_GAME_DRAFT.validate(empty_draft),
			"SESSION_RESIDENT_COUNT_OUT_OF_RANGE",
		),
		"zero-resident opening is rejected by the shared population rule",
	)
	var overflow_slots: Array[Dictionary] = []
	var allocated_home_spaces := NEW_GAME_DRAFT.home_space_ids()
	for index in POPULATION_RULES.MAX_RESIDENT_COUNT + 1:
		overflow_slots.append({
			"residentId": "custom_resident_overflow_%02d" % (index + 1),
			"spaceId": allocated_home_spaces[index % allocated_home_spaces.size()],
			"llmBinding": {
				"mode": "model",
				"providerId": "fake",
				"modelId": "fake",
			},
		})
	var overflow_draft := empty_draft.duplicate(true)
	overflow_draft["slots"] = overflow_slots
	_expect(
		_result_has_error_code(
			NEW_GAME_DRAFT.validate(overflow_draft),
			"SESSION_RESIDENT_COUNT_OUT_OF_RANGE",
		),
		"thirty-first resident is rejected by the shared population rule",
	)
	var overfilled_home_draft := empty_draft.duplicate(true)
	var overfilled_slots: Array[Dictionary] = []
	for index in 3:
		overfilled_slots.append({
			"residentId": "custom_resident_home_capacity_%02d" % (index + 1),
			"spaceId": "home_01",
			"llmBinding": {
				"mode": "model",
				"providerId": "fake",
				"modelId": "fake",
			},
		})
	overfilled_home_draft["slots"] = overfilled_slots
	_expect(
		_result_has_error_code(
			NEW_GAME_DRAFT.validate(overfilled_home_draft),
			"SESSION_HOME_SPACE_CAPACITY_EXCEEDED",
		),
		"a third resident in one home is rejected even below the town population cap",
	)


func _append_capacity_safe_custom_residents(
	selection_data: Dictionary,
	session_catalog: Dictionary,
	world_data: Dictionary,
	selected: Array,
	target_count: int,
) -> void:
	if selected.size() >= target_count:
		return
	var session_entries := selection_data.get("resident_catalog", []) as Array
	var selection_entries := selection_data.get("residents", []) as Array
	var compiled_entries := session_catalog.get("residents", []) as Array
	var entries_by_id: Dictionary = {}
	for entry_value: Variant in session_entries:
		var entry := entry_value as Dictionary
		entries_by_id[String(entry.get("residentId", ""))] = entry
	var occupation_counts: Dictionary = {}
	for resident_id_value: Variant in selected:
		var selected_entry := entries_by_id.get(String(resident_id_value), {}) as Dictionary
		var occupation_label := String(
			(selected_entry.get("occupation", {}) as Dictionary).get("name", ""),
		)
		occupation_counts[occupation_label] = int(
			occupation_counts.get(occupation_label, 0),
		) + 1
	var source_templates := compiled_entries.duplicate(true)
	var custom_index := 0
	while selected.size() < target_count:
		var added := false
		for occupation_value: Variant in world_data.get("occupations", []) as Array:
			var occupation := occupation_value as Dictionary
			var label := String(occupation.get("label", ""))
			var profile := occupation.get("staffingProfile", {}) as Dictionary
			var maximum := int(profile.get("maximumHeadcount", 1))
			if int(occupation_counts.get(label, 0)) >= maximum:
				continue
			var template := source_templates[custom_index % source_templates.size()] as Dictionary
			custom_index += 1
			var custom := _custom_resident_for_occupation(
				template,
				occupation,
				custom_index,
			)
			_expect(
				RESIDENT_CATALOG._session_custom_catalog_entry_is_valid(
					custom,
					world_data,
				),
				"generated variable-population resident is a valid custom candidate",
			)
			var resident_id := String(custom.get("residentId", ""))
			session_entries.append(custom.duplicate(true))
			compiled_entries.append(custom.duplicate(true))
			selection_entries.append({"resident_id": resident_id})
			selected.append(resident_id)
			occupation_counts[label] = int(occupation_counts.get(label, 0)) + 1
			added = true
			if selected.size() >= target_count:
				break
		if not added:
			break
	selection_data["resident_catalog"] = session_entries
	selection_data["residents"] = selection_entries
	session_catalog["residents"] = compiled_entries
	_expect_equal(
		selected.size(),
		target_count,
		"occupation capacities can host the requested population",
	)


func _custom_resident_for_occupation(
	template: Dictionary,
	occupation: Dictionary,
	index: int,
) -> Dictionary:
	var attributes := (template.get("attributes", {}) as Dictionary).duplicate(true)
	attributes["name"] = "扩展居民%02d" % index
	attributes["selectionSummary"] = "参与扩展人口测试"
	if not attributes.has("interests"):
		attributes["interests"] = []
	if not attributes.has("customInterests"):
		attributes["customInterests"] = []
	var workplace := String(occupation.get("primaryWorkplacePlace", ""))
	var presentation := (template.get("presentation", {}) as Dictionary).duplicate(true)
	presentation["locationLabel"] = workplace
	return {
		"residentId": "custom_resident_population_%02d" % index,
		"attributes": attributes,
		"occupation": {
			"name": String(occupation.get("label", "")),
			"workplacePlace": workplace,
		},
		"presentation": presentation,
		"source": "custom",
	}


func _capture_resident_directory_if_requested(
	runtime: Node,
	adapter: Node,
	view_model: Dictionary,
) -> void:
	var output_dir := OS.get_environment(
		"AI_TOWN_HUD_RESIDENT_DIRECTORY_CAPTURE_DIR"
	).strip_edges()
	if output_dir.is_empty():
		return
	var directory := (
		(view_model.get("data", {}) as Dictionary)
		.get("residentDirectory", {}) as Dictionary
	)
	_expect_equal(directory.get("totalCount"), 15, "resident directory capture uses all 15 runtime residents")
	var overlay := runtime.find_child("TownHudOverlay", true, false) as TownHudOverlay
	var capture_layer: CanvasLayer
	if overlay == null:
		capture_layer = CanvasLayer.new()
		capture_layer.name = &"ResidentDirectoryCaptureLayer"
		runtime.add_child(capture_layer)
		overlay = TOWN_HUD_SCENE.instantiate() as TownHudOverlay
		capture_layer.add_child(overlay)
		await _wait_frames(3)
	_expect(overlay != null, "resident directory capture mounts the formal Town HUD wrapper")
	if not overlay.intent_requested.is_connected(adapter.dispatch):
		overlay.intent_requested.connect(
			func(intent: StringName, payload: Dictionary) -> void:
				adapter.call("dispatch", String(intent), payload.duplicate(true))
		)
	overlay.require_formal_ready = false
	overlay.allow_placeholder_fixture = true
	_expect(overlay.apply_view_model(view_model), "resident directory capture applies the live runtime VM")
	await _wait_frames(3)
	var nav_button := (overlay.get("_buttons") as Dictionary).get("nav_residents") as Button
	_expect(nav_button != null and not nav_button.disabled, "resident directory runtime entry is enabled")
	if nav_button == null or nav_button.disabled:
		return
	nav_button.pressed.emit()
	await _wait_frames(3)
	var drawer := overlay.get("_resident_directory") as ResidentDirectoryDrawer
	_expect(drawer != null and drawer.visible, "resident directory drawer opens in the real Town")
	if drawer == null or not drawer.visible:
		return
	var items := directory.get("items", []) as Array
	DirAccess.make_dir_recursive_absolute(output_dir)
	for viewport in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		DisplayServer.window_set_size(viewport)
		root.size = viewport
		await _wait_frames(5)
		RenderingServer.force_draw(false)
		var image := root.get_texture().get_image()
		var path := output_dir.path_join(
			"observer_hud_resident_directory_runtime_%dx%d.png" % [viewport.x, viewport.y]
		)
		_expect(image != null and not image.is_empty(), "resident directory runtime image is readable")
		if image != null and not image.is_empty():
			if image.get_size() != viewport:
				image.resize(viewport.x, viewport.y, Image.INTERPOLATE_NEAREST)
			_expect_equal(image.save_png(path), OK, "resident directory runtime image is saved")
	if items.size() > 1:
		var camera_follow_action := (
			(view_model.get("actions", {}) as Dictionary).get("cameraFollow", {}) as Dictionary
		)
		_expect(
			bool(camera_follow_action.get("enabled", false)),
			"resident directory live camera-follow action is enabled: %s" % camera_follow_action,
		)
		drawer.call("_on_row_pressed", 1)
		await _wait_frames(3)
		var expected_name := String((items[1] as Dictionary).get("residentName", ""))
		_expect_equal(
			(runtime.call("get_runtime_state") as Dictionary).get("followedResident"),
			expected_name,
			"resident directory row dispatches the real camera follow",
		)
		runtime.call("cancel_resident_follow")
		await create_timer(0.6).timeout
		if String((runtime.call("get_runtime_state") as Dictionary).get("viewMode", "")) != "town":
			var returned: Variant = await runtime.call("return_to_town_overview")
			_expect(bool(returned), "resident directory capture restores the outdoor overview")
		await create_timer(0.4).timeout
		_expect_equal(
			(runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
			"town",
			"resident directory capture leaves the observer outdoors",
		)
	var place_nav_button := (
		(overlay.get("_buttons") as Dictionary).get("nav_places") as Button
	)
	_expect(
		place_nav_button != null and not place_nav_button.disabled,
		"place directory runtime entry is enabled",
	)
	if place_nav_button != null and not place_nav_button.disabled:
		place_nav_button.pressed.emit()
		await _wait_frames(3)
		var place_drawer := overlay.get("_place_directory") as PlaceDirectoryDrawer
		_expect(
			place_drawer != null and place_drawer.visible and not drawer.visible,
			"place directory opens and closes resident directory",
		)
		if place_drawer != null and place_drawer.visible:
			for viewport in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
				DisplayServer.window_set_size(viewport)
				root.size = viewport
				await _wait_frames(5)
				RenderingServer.force_draw(false)
				var image := root.get_texture().get_image()
				var path := output_dir.path_join(
					"observer_hud_place_directory_runtime_%dx%d.png"
					% [viewport.x, viewport.y]
				)
				_expect(image != null and not image.is_empty(), "place directory runtime image is readable")
				if image != null and not image.is_empty():
					if image.get_size() != viewport:
						image.resize(viewport.x, viewport.y, Image.INTERPOLATE_NEAREST)
					_expect_equal(image.save_png(path), OK, "place directory runtime image is saved")
			place_drawer.close()
	else:
		drawer.close()
	if capture_layer != null:
		capture_layer.queue_free()
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	await _wait_frames(3)


func _wait_frames(count: int) -> void:
	for _index in count:
		await process_frame


func _wait_avatar_place_transition(runtime: Node) -> void:
	var deadline := Time.get_ticks_msec() + 4000
	while (
		(
			bool(runtime.get("_avatar_place_change_active"))
			or bool(runtime.get("_portal_transition_active"))
		)
		and Time.get_ticks_msec() < deadline
	):
		await process_frame
	_expect(
		not bool(runtime.get("_avatar_place_change_active"))
		and not bool(runtime.get("_portal_transition_active")),
		"avatar physical place transition completes",
	)


func _verify_custom_resident_pipeline(
	world_data: Dictionary,
	base_catalog: Dictionary,
) -> void:
	var pool: RefCounted = CUSTOM_POOL.new()
	_expect_ok(
		pool.call("configure", base_catalog) as Dictionary,
		"custom candidate pool accepts the strict 16-resident base catalog",
	)
	var creator: RefCounted = CUSTOM_CREATOR.new()
	_expect_ok(
		creator.call(
			"configure",
			pool,
			base_catalog,
			world_data,
			{"draftId": "formal-custom-pipeline", "revision": 1},
		) as Dictionary,
		"custom creator configures against the formal catalog and World",
	)
	var creator_vm := creator.call("get_view_model") as Dictionary
	var creator_data := creator_vm.get("data", {}) as Dictionary
	_expect_ok(
		creator.call(
			"dispatch",
			"custom_resident_creator.update_fields",
			{
				"revision": int(creator_vm.get("revision", 0)),
				"draftId": String(creator_data.get("draftId", "")),
				"fields": {
					"name": "正式管线居民",
					"gender": "女",
					"age": 29,
					"desire": "参与正式小镇生活",
					"personality": "耐心且谨慎，愿意核对事实",
					"speech": "先核对事实再回答",
				},
			},
		) as Dictionary,
		"custom creator accepts a complete formal profile",
	)
	creator_vm = creator.call("get_view_model") as Dictionary
	creator_data = creator_vm.get("data", {}) as Dictionary
	var created := creator.call(
		"dispatch",
		"custom_resident_creator.create",
		{
			"revision": int(creator_vm.get("revision", 0)),
			"draftId": String(creator_data.get("draftId", "")),
			"candidatePoolRevision": int(
				creator_data.get("candidatePoolRevision", -1),
			),
		},
	) as Dictionary
	_expect_ok(created, "custom creator publishes one formal candidate")
	if created.get("ok") != true:
		return
	var candidate := created.get("candidate", {}) as Dictionary
	var attributes := candidate.get("attributes", {}) as Dictionary
	_expect(
		String(attributes.get("appearance", "")).begins_with(
			"resident_wardrobe_v1:",
		),
		"custom creator publishes one approved World appearance id",
	)
	_expect(
		candidate.get("appearance") is Dictionary,
		"custom creator keeps appearance as a top-level authority",
	)
	var legacy_candidate := candidate.duplicate(true)
	(
		legacy_candidate.get("attributes", {}) as Dictionary
	)["appearance"] = "paper_doll_64:legacy"
	var legacy_result := pool.call(
		"create_candidate",
		legacy_candidate,
		int(pool.call("candidate_pool_revision")),
	) as Dictionary
	_expect_equal(
		legacy_result.get("errorCode"),
		"CUSTOM_RESIDENT_APPEARANCE_NOT_READY",
		"candidate pool rejects an appearance outside the approved wardrobe",
	)
	var custom_id := String(candidate.get("residentId", ""))
	var merged_catalog := pool.call("get_merged_catalog") as Dictionary
	var projection := pool.call(
		"get_resident_selection_projection",
	) as Dictionary
	var selection_vm := RESIDENT_CATALOG.build_view_model(
		"fake",
		"fake",
		true,
		20,
	) as Dictionary
	var selection_data := selection_vm.get("data", {}) as Dictionary
	(selection_data.get("resident_catalog", []) as Array).append_array(
		(projection.get("catalogEntries", []) as Array).duplicate(true),
	)
	(selection_data.get("residents", []) as Array).append_array(
		(projection.get("selectionEntries", []) as Array).duplicate(true),
	)
	var selected := (
		selection_data.get("recommended_resident_ids", []) as Array
	).duplicate()
	var candidate_occupation := String(
		(candidate.get("occupation", {}) as Dictionary).get("name", ""),
	)
	var replacement_index := -1
	for index in selected.size():
		for catalog_value: Variant in (
			selection_data.get("resident_catalog", []) as Array
		):
			if not catalog_value is Dictionary:
				continue
			var catalog_entry := catalog_value as Dictionary
			if String(catalog_entry.get("residentId", "")) != String(selected[index]):
				continue
			if String(
				(catalog_entry.get("occupation", {}) as Dictionary).get("name", ""),
			) == candidate_occupation:
				replacement_index = index
			break
		if replacement_index >= 0:
			break
	_expect(replacement_index >= 0, "custom candidate replaces the same occupation")
	if replacement_index < 0:
		return
	selected.remove_at(replacement_index)
	selected.append(custom_id)
	selection_data["selected_resident_ids"] = selected
	RESIDENT_CATALOG.update_confirmation_payload(
		selection_data,
		"fake",
		"fake",
		21,
	)
	var custom_draft := (
		selection_data.get("confirmation_payload", {}) as Dictionary
	)
	_expect_equal(
		(custom_draft.get("slots", []) as Array).size(),
		POPULATION_RULES.DEFAULT_RESIDENT_COUNT,
		"merged custom candidate produces a complete 15-resident draft",
	)
	var compiled := COMPILER.compile(custom_draft, world_data, merged_catalog)
	_expect_ok(
		compiled,
		"Creator to CandidatePool to Catalog selection compiles formally",
	)
	_verify_all_custom_resident_opening(world_data, base_catalog, candidate)


func _verify_all_custom_resident_opening(
	world_data: Dictionary,
	base_catalog: Dictionary,
	candidate: Dictionary,
) -> void:
	var capacity_safe_catalog := base_catalog.duplicate(true)
	var capacity_safe_residents := (
		capacity_safe_catalog.get("residents", []) as Array
	)
	var capacity_safe_ids: Array[String] = []
	var occupations := world_data.get("occupations", []) as Array
	for index in POPULATION_RULES.DEFAULT_RESIDENT_COUNT:
		var custom := _custom_resident_for_occupation(
			candidate,
			occupations[index] as Dictionary,
			100 + index,
		)
		capacity_safe_residents.append(custom)
		capacity_safe_ids.append(String(custom.get("residentId", "")))
	capacity_safe_catalog["residents"] = capacity_safe_residents
	var capacity_safe_vm := RESIDENT_CATALOG.build_view_model(
		"fake",
		"fake",
		true,
		22,
	) as Dictionary
	var capacity_safe_data := capacity_safe_vm.get("data", {}) as Dictionary
	capacity_safe_data["resident_catalog"] = capacity_safe_residents.duplicate(true)
	var capacity_safe_selection := capacity_safe_data.get("residents", []) as Array
	for resident_id: String in capacity_safe_ids:
		capacity_safe_selection.append({"resident_id": resident_id})
	capacity_safe_data["selected_resident_ids"] = capacity_safe_ids.duplicate()
	RESIDENT_CATALOG.update_confirmation_payload(
		capacity_safe_data,
		"fake",
		"fake",
		23,
	)
	_expect_equal(
		(capacity_safe_data.get("staffing_blockers", []) as Array).size(),
		0,
		"十五位全自定义居民按合法职业分配时没有容量阻塞",
	)
	var capacity_safe_draft := (
		capacity_safe_data.get("confirmation_payload", {}) as Dictionary
	)
	_expect_equal(
		(capacity_safe_draft.get("slots", []) as Array).size(),
		POPULATION_RULES.DEFAULT_RESIDENT_COUNT,
		"十五位全自定义居民生成完整入镇草稿",
	)
	var capacity_safe_compiled := COMPILER.compile(
		capacity_safe_draft,
		world_data,
		capacity_safe_catalog,
	)
	_expect_ok(
		capacity_safe_compiled,
		"十五位全自定义居民可通过正式编译进入小镇",
	)
	if bool(capacity_safe_compiled.get("ok", false)):
		var opening := (
			capacity_safe_compiled.get("openingConfig", {}) as Dictionary
		)
		_expect_equal(
			(opening.get("residents", []) as Array).size(),
			POPULATION_RULES.DEFAULT_RESIDENT_COUNT,
			"全自定义入镇配置保留十五位居民",
		)
		var identities: Array[Dictionary] = []
		for binding_value: Variant in capacity_safe_compiled.get(
			"residentBindings",
			[],
		) as Array:
			var binding := binding_value as Dictionary
			identities.append({
				"residentId": String(binding.get("residentId", "")),
				"residentName": String(binding.get("residentName", "")),
			})
		var world: RefCounted = WORLD.new()
		var started := world.call(
			"start",
			world_data,
			opening,
			identities,
		) as Dictionary
		_expect_ok(started, "十五位全自定义居民可启动正式 World")
		if bool(started.get("ok", false)):
			_expect_equal(
				(world.call("get_resident_ids") as Array).size(),
				POPULATION_RULES.DEFAULT_RESIDENT_COUNT,
				"全自定义正式 World 保留完整居民身份",
			)
			for resident_id: String in capacity_safe_ids:
				var initialization := world.call(
					"get_agent_initialization_by_id",
					resident_id,
				) as Dictionary
				_expect(
					AGENT_CONTRACT.validate_initialization(
						initialization,
					).is_empty(),
					"全自定义居民满足 Agent 初始化合同：%s" % resident_id,
				)
		world.call("stop")

	var merged_catalog := base_catalog.duplicate(true)
	var residents := merged_catalog.get("residents", []) as Array
	var selected_ids: Array[String] = []
	for index in POPULATION_RULES.DEFAULT_RESIDENT_COUNT:
		var resident_id := "custom_resident_full_%02d" % (index + 1)
		var attributes := (
			candidate.get("attributes", {}) as Dictionary
		).duplicate(true)
		attributes["name"] = (
			"全自定义居民%02d" % (index + 1)
		)
		var presentation := (
			candidate.get("presentation", {}) as Dictionary
		).duplicate(true)
		presentation["locationLabel"] = "中心广场"
		var custom := {
			"residentId": resident_id,
			"attributes": attributes,
			"occupation": {
			"name": "乐师",
			"workplacePlace": "中心广场",
			},
			"presentation": presentation,
			"source": "custom",
		}
		residents.append(custom)
		selected_ids.append(resident_id)
	merged_catalog["residents"] = residents
	_expect(
		RESIDENT_CATALOG._session_custom_catalog_entry_is_valid(
			residents[residents.size() - 1] as Dictionary,
			world_data,
		),
		"one-occupation custom warning fixture remains a valid custom resident",
	)
	var warning_vm := RESIDENT_CATALOG.build_view_model(
		"fake",
		"fake",
		true,
		22,
	) as Dictionary
	var warning_data := warning_vm.get("data", {}) as Dictionary
	warning_data["resident_catalog"] = residents.duplicate(true)
	var warning_residents := warning_data.get("residents", []) as Array
	for resident_id: String in selected_ids:
		warning_residents.append({"resident_id": resident_id})
	warning_data["selected_resident_ids"] = selected_ids.duplicate()
	RESIDENT_CATALOG.update_confirmation_payload(
		warning_data,
		"fake",
		"fake",
		23,
	)
	var staffing_warnings := warning_data.get("staffing_warnings", []) as Array
	_expect_equal(
		staffing_warnings.size(),
		14,
		"one-occupation custom roster reports every vacant occupation",
	)
	_expect_equal(
		(
			warning_data.get("confirmation_payload", {}) as Dictionary
		).get("slots", []).size(),
		0,
		"a roster exceeding one occupation's map capacity has no confirmation draft",
	)
	var staffing_blockers := warning_data.get("staffing_blockers", []) as Array
	_expect_equal(
		staffing_blockers.size(),
		1,
		"one-occupation custom roster reports one capacity blocker",
	)
	if not staffing_blockers.is_empty():
		_expect_equal(
			(staffing_blockers[0] as Dictionary).get("maximumHeadcount"),
			1,
			"musician capacity blocker comes from the authored staffing profile",
		)
	var dining_warning := {}
	for warning_value: Variant in staffing_warnings:
		var warning := warning_value as Dictionary
		if String(warning.get("occupationId", "")) == "occupation_dining_operator":
			dining_warning = warning
			break
	_expect(
		not String(dining_warning.get("vacancyEffect", "")).is_empty(),
		"vacancy warning keeps the authoritative service effect",
	)
	var slots: Array[Dictionary] = []
	var home_space_ids := NEW_GAME_DRAFT.home_space_ids()
	for index in POPULATION_RULES.DEFAULT_RESIDENT_COUNT:
		slots.append({
			"residentId": selected_ids[index],
			"spaceId": home_space_ids[index],
			"llmBinding": {
				"mode": "model",
				"providerId": "fake",
				"modelId": "fake",
			},
		})
	var draft := {
		"schemaVersion": 1,
		"sourceScope": "resident_selection",
		"draftRevision": 1,
		"slots": slots,
	}
	var compiled := COMPILER.compile(draft, world_data, merged_catalog)
	_expect(
		_result_has_error_code(
			compiled,
			"SESSION_OCCUPATION_CAPACITY_EXCEEDED",
		),
		"Compiler also rejects a crafted roster that bypasses the selection warning",
	)


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _send_physical_key(
	action: StringName,
	keycode: Key,
	pressed: bool,
) -> void:
	var event := InputEventKey.new()
	event.device = TEST_KEYBOARD_DEVICE_ID
	event.keycode = keycode
	event.pressed = pressed
	if pressed:
		_expect(
			InputMap.event_is_action(event, action),
			"physical key %s uses the shipped %s InputMap binding" % [
				keycode,
				action,
			],
		)
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _expect_ok(result: Dictionary, message: String) -> void:
	_expect(bool(result.get("ok", false)), "%s: %s" % [message, result])


func _result_has_error_code(result: Dictionary, error_code: String) -> bool:
	for error_value: Variant in result.get("errors", []) as Array:
		if (
			error_value is Dictionary
			and String((error_value as Dictionary).get("code", ""))
			== error_code
		):
			return true
	return false


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s: expected %s, got %s" % [message, expected, actual])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	var exit_code := 0 if _failures.is_empty() else 1
	if _failures.is_empty():
		print("TOWN_SESSION_PRODUCTION_COMPOSITION_PASS")
	else:
		for failure in _failures:
			printerr("TOWN_SESSION_PRODUCTION_COMPOSITION_FAIL: %s" % failure)
	var audio_controller := root.get_node_or_null("TownAudioController")
	if audio_controller != null and audio_controller.has_method("prepare_shutdown"):
		audio_controller.call("prepare_shutdown")
	await create_timer(0.5, true, false, true).timeout
	quit(exit_code)


func _verify_conversation_first_visible_frame(
	runtime: Node,
	adapter: Node,
	world_runtime: RefCounted,
) -> void:
	var host := UI_RUNTIME_HOST.new() as Control
	runtime.add_child(host)
	var bind_result := host.call("bind_town_ui_adapter", adapter) as Dictionary
	_expect_ok(bind_result, "production UI Host binds the real Adapter for conversation timing")
	var avatar_state := world_runtime.call("get_player_avatar_state") as Dictionary
	var avatar_space_id := String(avatar_state.get("spaceId", ""))
	var target_state: Dictionary = {}
	for state_value: Variant in world_runtime.call("get_all_resident_states") as Array:
		var state := state_value as Dictionary
		if (
			String(state.get("spaceId", "")) == avatar_space_id
			and (state.get("position", Vector2.INF) as Vector2).is_finite()
		):
			target_state = state
			break
	_expect(not target_state.is_empty(), "production conversation timing finds an outdoor resident")
	if target_state.is_empty():
		host.queue_free()
		await process_frame
		return
	var player := runtime.get_node("Player") as Node2D
	player.position = target_state.get("position", Vector2.ZERO) as Vector2
	player.force_update_transform()
	var position_result := runtime.call("_submit_player_avatar_position", true) as Dictionary
	_expect_ok(position_result, "production conversation timing moves the avatar beside a resident")
	var avatar_view_model := adapter.call("get_view_model", "avatar") as Dictionary
	var nearby_targets := (
		avatar_view_model.get("data", {}) as Dictionary
	).get("nearbyTargets", []) as Array
	_expect(not nearby_targets.is_empty(), "real Avatar view model exposes the nearby conversation target")
	if nearby_targets.is_empty():
		host.queue_free()
		await process_frame
		return
	var resident_id := String((nearby_targets[0] as Dictionary).get("residentId", ""))
	var conversation_click_started_usec := Time.get_ticks_usec()
	var started := adapter.call(
		"dispatch",
		"conversation.start",
		{
			"residentId": resident_id,
			"say": "你好。",
			"narration": "旅行者走近打招呼",
		},
	) as Dictionary
	var queued_after_start := adapter.get("_pending_world_refresh_scopes") as Array
	for scope: String in WORLD_UI_SCOPES:
		_expect(
			queued_after_start.has(scope),
			"conversation start defers the %s projection to a following frame" % scope,
		)
	var conversation_click_return_msec := (
		Time.get_ticks_usec() - conversation_click_started_usec
	) / 1000.0
	if DisplayServer.get_name() != "headless":
		print("CONVERSATION_CLICK_RETURN_MSEC=%.2f" % conversation_click_return_msec)
	_expect_ok(started, "real Adapter starts the production conversation")
	_expect_equal(host.call("current_route"), &"chat", "conversation click routes to the real chat page synchronously")
	var page := host.get("_active_page") as Control
	_expect(
		is_instance_valid(page) and page.visible,
		"the real conversation page is visible before Agent preparation resumes",
	)
	_expect_equal(
		int(runtime.get("_agent_dispatch_hold_process_turns")),
		1,
		"conversation start keeps Agent preparation out of the click call stack",
	)
	var conversation_before_draw := adapter.call("get_view_model", "conversation") as Dictionary
	var messages_before_draw := (
		conversation_before_draw.get("data", {}) as Dictionary
	).get("messages", []) as Array
	_expect_equal(messages_before_draw.size(), 1, "only the player's opening message exists before the first draw")
	if DisplayServer.get_name() == "headless":
		runtime.call("_pump_agent_gateway_for_frame")
	else:
		await RenderingServer.frame_post_draw
		var first_draw_msec := (
			Time.get_ticks_usec() - conversation_click_started_usec
		) / 1000.0
		print("CONVERSATION_FIRST_DRAW_MSEC=%.2f" % first_draw_msec)
		_expect(
			first_draw_msec <= 100.0,
			"production conversation draws its first stable frame within 100ms",
		)
	var conversation_after_draw := adapter.call("get_view_model", "conversation") as Dictionary
	var messages_after_draw := (
		conversation_after_draw.get("data", {}) as Dictionary
	).get("messages", []) as Array
	_expect_equal(messages_after_draw.size(), 1, "the resident reply does not overtake the first rendered frame")
	runtime.call("_pump_agent_gateway_for_frame")
	# World presentation deferral can legitimately consume several frames after
	# the first draw. Keep the first-frame assertion above strict, then allow the
	# budgeted queue to resume and prove that it eventually delivers the reply.
	for _frame_index: int in 64:
		await process_frame
		var current := adapter.call("get_view_model", "conversation") as Dictionary
		if ((current.get("data", {}) as Dictionary).get("messages", []) as Array).size() >= 2:
			break
	var conversation_after_agent := adapter.call("get_view_model", "conversation") as Dictionary
	var messages_after_agent := (
		conversation_after_agent.get("data", {}) as Dictionary
	).get("messages", []) as Array
	_expect(messages_after_agent.size() >= 2, "the prioritized resident reply still arrives after the first frame")
	var message_count_before_reply := messages_after_agent.size()
	var reply_click_started_usec := Time.get_ticks_usec()
	var replied := adapter.call(
		"dispatch",
		"conversation.reply",
		{
			"say": "今天天气怎么样？",
			"narration": "旅行者继续交谈",
		},
	) as Dictionary
	var queued_after_reply := adapter.get("_pending_world_refresh_scopes") as Array
	for scope: String in WORLD_UI_SCOPES:
		_expect(
			queued_after_reply.has(scope),
			"conversation reply defers the %s projection to a following frame" % scope,
		)
	var reply_click_return_msec := (
		Time.get_ticks_usec() - reply_click_started_usec
	) / 1000.0
	if DisplayServer.get_name() != "headless":
		print("CONVERSATION_REPLY_CLICK_RETURN_MSEC=%.2f" % reply_click_return_msec)
	_expect_ok(replied, "real Adapter sends the production conversation reply")
	_expect_equal(
		int(runtime.get("_agent_dispatch_hold_process_turns")),
		1,
		"conversation reply also keeps Agent preparation out of the input call stack",
	)
	var conversation_before_reply_frame := adapter.call("get_view_model", "conversation") as Dictionary
	var messages_before_reply_frame := (
		conversation_before_reply_frame.get("data", {}) as Dictionary
	).get("messages", []) as Array
	_expect_equal(
		messages_before_reply_frame.size(),
		message_count_before_reply + 1,
		"the player's reply is visible before the resident request resumes",
	)
	if DisplayServer.get_name() == "headless":
		runtime.call("_pump_agent_gateway_for_frame")
	else:
		await RenderingServer.frame_post_draw
		var reply_first_draw_msec := (
			Time.get_ticks_usec() - reply_click_started_usec
		) / 1000.0
		print("CONVERSATION_REPLY_FIRST_DRAW_MSEC=%.2f" % reply_first_draw_msec)
		_expect(
			reply_first_draw_msec <= 100.0,
			"production reply draws the player's message within 100ms",
		)
	var conversation_after_reply_frame := adapter.call("get_view_model", "conversation") as Dictionary
	var messages_after_reply_frame := (
		conversation_after_reply_frame.get("data", {}) as Dictionary
	).get("messages", []) as Array
	_expect_equal(
		messages_after_reply_frame.size(),
		message_count_before_reply + 1,
		"the resident reply does not overtake the player's visible reply frame",
	)
	runtime.call("_pump_agent_gateway_for_frame")
	for _frame_index: int in 64:
		await process_frame
		var current := adapter.call("get_view_model", "conversation") as Dictionary
		if (
			((current.get("data", {}) as Dictionary).get("messages", []) as Array).size()
			>= message_count_before_reply + 2
		):
			break
	var conversation_after_reply_agent := adapter.call("get_view_model", "conversation") as Dictionary
	var messages_after_reply_agent := (
		conversation_after_reply_agent.get("data", {}) as Dictionary
	).get("messages", []) as Array
	_expect(
		messages_after_reply_agent.size() >= message_count_before_reply + 2,
		"the prioritized resident reply still arrives after the player's reply frame",
	)
	# 回归真实生产页面的连续三轮交谈：第一轮覆盖上面的启动+回复，
	# 这里再连续发送两次玩家回复，并等待每次居民回应。这个路径会
	# 反复触发消息树退役、流式显示、焦点恢复和 Agent 下一帧派发，
	# 是旧 Android 设备报告“第三轮崩溃”最接近的组合。
	var chained_message_count := messages_after_reply_agent.size()
	for round_index: int in 2:
		var chained_reply := adapter.call(
			"dispatch",
			"conversation.reply",
			{
				"say": "继续聊第 %d 轮。" % (round_index + 2),
				"narration": "旅行者继续交谈第 %d 轮" % (round_index + 2),
			},
		) as Dictionary
		_expect_ok(
			chained_reply,
			"连续对话第 %d 轮的玩家回复仍由生产 Adapter 接受" % (round_index + 2),
		)
		var chained_player_frame := adapter.call("get_view_model", "conversation") as Dictionary
		var chained_player_messages := (
			chained_player_frame.get("data", {}) as Dictionary
		).get("messages", []) as Array
		_expect_equal(
			chained_player_messages.size(),
			chained_message_count + 1,
			"连续对话第 %d 轮先显示玩家消息" % (round_index + 2),
		)
		runtime.call("_pump_agent_gateway_for_frame")
		var resident_reply_visible := false
		for _frame_index: int in 64:
			await process_frame
			var chained_current := adapter.call("get_view_model", "conversation") as Dictionary
			var chained_current_messages := (
				chained_current.get("data", {}) as Dictionary
			).get("messages", []) as Array
			if chained_current_messages.size() >= chained_message_count + 2:
				resident_reply_visible = true
				chained_message_count = chained_current_messages.size()
				break
		_expect(
			resident_reply_visible,
			"连续对话第 %d 轮的居民回复在 64 帧内可见" % (round_index + 2),
		)
	var conversation_id := String(
		(conversation_after_reply_agent.get("data", {}) as Dictionary).get("conversationId", "")
	)
	if not conversation_id.is_empty():
		adapter.call(
			"dispatch",
			"conversation.end",
			{"narration": "旅行者结束交谈"},
		)
	var real_gateway := adapter.get("_gateway") as Node
	var pump_spy := AgentGatewayPumpSpy.new()
	adapter.set("_gateway", pump_spy)
	adapter.call("_execute_intent", "conversation.retry", {})
	_expect_equal(
		pump_spy.pump_limits,
		[],
		"conversation retry leaves Agent dispatch to TownRuntime's next-frame budget",
	)
	adapter.set("_gateway", real_gateway)
	pump_spy.free()
	host.queue_free()
	await process_frame


func _verify_inner_observation_first_draw(
	gateway: Node,
	world_runtime: RefCounted,
	resident_id: String,
) -> void:
	var collector := ResultCollector.new()
	var accepted := gateway.call(
		"request_resident_inner_observation",
		resident_id,
		"production-inner-first-draw",
		int(world_runtime.call("get_world_revision")),
		collector.collect,
	) as Dictionary
	_expect_ok(accepted, "production Gateway accepts the inner observation read")
	_expect(
		collector.result.is_empty(),
		"inner observation does not read memory in the page-open call stack",
	)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		_expect(
			collector.result.is_empty(),
			"inner observation keeps its loading state through the first visible draw",
		)
	for _frame_index: int in 3:
		await process_frame
		if not collector.result.is_empty():
			break
	_expect_equal(
		collector.result.get("status"),
		"ready",
		"inner observation publishes content after the loading frame",
	)
