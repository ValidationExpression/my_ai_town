extends "res://tests/agent/support/AgentTestCase.gd"


const MEMORY_ORGANIZER := preload("res://agent/memory/MemoryOrganizer.gd")
const MEMORY_STORE := preload("res://agent/memory/ResidentMemoryStore.gd")
const AVATAR_ORGANIZER := preload("res://agent/avatar_memory/AvatarMemoryOrganizer.gd")
const AVATAR_STORE := preload("res://agent/avatar_memory/ResidentAvatarMemoryStore.gd")
const CATALOG := preload("res://agent/model/ModelProviderCatalog.gd")
const SETTINGS := preload("res://world/presentation/ui/TownProviderSettingsService.gd")
const TEST_DATA := preload("res://tests/support/AgentMemoryTestData.gd")


class ResultCollector:
	signal completed

	var value: Dictionary = {}
	var has_value := false

	func collect(result: Dictionary) -> void:
		if has_value:
			return
		has_value = true
		value = result.duplicate(true)
		completed.emit()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var initialization := TEST_DATA.initialization()
	var evidence := [{
		"evidence_id": "benchmark-evidence-1",
		"kind": "action_result",
		"payload": {
			"action_type": "做活动",
			"status": "completed",
			"reason": "木架已经打磨完成。",
		},
	}]
	var memory_store: RefCounted = MEMORY_STORE.new(
		"user://memory-prompt-usage-benchmark/resident_memory.json",
	)
	var memory_organizer: RefCounted = MEMORY_ORGANIZER.new(
		initialization,
		memory_store,
	)
	var memory_request := memory_organizer.call(
		"build_request",
		TEST_DATA.organized_memory(),
		evidence,
	) as Dictionary
	_print_request_metric("memory", memory_request)

	var avatar_store: RefCounted = AVATAR_STORE.new(
		"user://memory-prompt-usage-benchmark/avatar_memory.json",
		"resident-lin-lan",
		"avatar-traveler",
	)
	var avatar_organizer: RefCounted = AVATAR_ORGANIZER.new(
		initialization,
		"avatar-traveler",
		"旅行者",
		avatar_store,
	)
	var avatar_request := avatar_organizer.call(
		"build_request",
		avatar_store.call("empty_memory"),
		evidence,
	) as Dictionary
	_print_request_metric("avatar", avatar_request)

	if OS.get_environment("AI_TOWN_MEMORY_USAGE_BENCHMARK_LIVE") == "1":
		await _run_live(
			initialization,
			memory_request,
			avatar_request,
			memory_store,
			avatar_organizer,
		)
	_finish_suite("MEMORY_PROMPT_USAGE_BENCHMARK_PASS")


func _run_live(
	initialization: Dictionary,
	memory_request: Dictionary,
	avatar_request: Dictionary,
	memory_organizer: RefCounted,
	avatar_organizer: RefCounted,
) -> void:
	var saved := SETTINGS.new().load_saved_runtime_configuration() as Dictionary
	if saved.get("ok") != true:
		print("MEMORY_USAGE_LIVE unavailable=saved_provider_config")
		return
	var provider_id := String(saved.get("providerId", ""))
	var model_id := String(saved.get("modelId", ""))
	var configs := saved.get("providerConfigs", {}) as Dictionary
	var provider_config := configs.get(provider_id, {}) as Dictionary
	if provider_id.is_empty() or model_id.is_empty() or provider_config.is_empty():
		print("MEMORY_USAGE_LIVE unavailable=provider_selection")
		return
	var request_host := Node.new()
	request_host.name = "MemoryPromptUsageBenchmarkHost"
	root.add_child(request_host)
	var creation := CATALOG.new().call(
		"create_model",
		provider_id,
		model_id,
		request_host,
		provider_config,
	) as Dictionary
	if creation.get("ok") != true:
		print("MEMORY_USAGE_LIVE unavailable=model_creation")
		request_host.queue_free()
		return
	var provider := creation.get("provider") as RefCounted
	var configuration_errors := provider.call("validate_configuration") as Array
	if not configuration_errors.is_empty():
		print("MEMORY_USAGE_LIVE unavailable=provider_configuration")
		request_host.queue_free()
		return
	await _run_live_request("memory", provider, memory_request, memory_organizer)
	await _run_live_request("avatar", provider, avatar_request, avatar_organizer)
	request_host.queue_free()
	print("MEMORY_USAGE_LIVE provider=%s model=%s" % [provider_id, model_id])


func _run_live_request(
	request_kind: String,
	provider: RefCounted,
	request: Dictionary,
	validator: RefCounted,
) -> void:
	var collector := ResultCollector.new()
	provider.call("request_decision", request, collector.collect)
	if not collector.has_value:
		await collector.completed
	var diagnostic: Dictionary = {}
	var diagnostics := provider.call("get_diagnostics") as Array
	if not diagnostics.is_empty() and diagnostics.back() is Dictionary:
		diagnostic = (diagnostics.back() as Dictionary).duplicate(true)
	var usage := diagnostic.get("usage", {}) as Dictionary
	var validation := {}
	if collector.has_value and collector.value.get("ok") == true:
		if request_kind == "memory":
			validation = validator.call(
				"validate",
				collector.value.get("decision", {}),
			) as Dictionary
		else:
			validation = validator.call(
				"validate_candidate",
				collector.value.get("decision", {}),
				request.get("old_memory", {}) as Dictionary,
				request.get("evidence_items", []) as Array,
			) as Dictionary
	print((
		"MEMORY_USAGE_LIVE_METRIC kind=%s ok=%s valid=%s prompt_tokens=%d "
		+ "completion_tokens=%d total_tokens=%d request_max_tokens=%d"
		) % [
			request_kind,
			str(collector.has_value and collector.value.get("ok") == true),
			str(validation.get("ok", false)),
			int(usage.get("prompt_tokens", 0)),
			int(usage.get("completion_tokens", 0)),
			int(usage.get("total_tokens", 0)),
			int(request.get("max_tokens", 0)),
		])


func _print_request_metric(kind: String, request: Dictionary) -> void:
	var messages := request.get("messages", []) as Array
	var system_text := ""
	var user_text := ""
	if messages.size() >= 1 and messages[0] is Dictionary:
		system_text = String((messages[0] as Dictionary).get("content", ""))
	if messages.size() >= 2 and messages[1] is Dictionary:
		user_text = String((messages[1] as Dictionary).get("content", ""))
	var total_text := system_text + user_text
	print((
		"MEMORY_PROMPT_METRIC kind=%s system_chars=%d user_chars=%d "
		+ "total_chars=%d estimated_tokens=%d max_tokens=%d"
		) % [
			kind,
			system_text.length(),
			user_text.length(),
			total_text.length(),
			_estimate_tokens(total_text),
			int(request.get("max_tokens", 0)),
		])
	print("MEMORY_PROMPT_CONTENT kind=%s behavior=%s organizer=%s" % [
		kind,
		system_text.contains("玩家填写的完整 OC"),
		system_text.contains("居民记忆整理规则") or system_text.contains("化身记忆整理"),
	])


func _estimate_tokens(text: String) -> int:
	var tokens := 0
	var ascii_run := 0
	for index in text.length():
		var codepoint := text.unicode_at(index)
		if (
			(codepoint >= 48 and codepoint <= 57)
			or (codepoint >= 65 and codepoint <= 90)
			or (codepoint >= 97 and codepoint <= 122)
		):
			ascii_run += 1
			continue
		if ascii_run > 0:
			tokens += int(ceil(float(ascii_run) / 4.0))
			ascii_run = 0
		if codepoint not in [32, 9, 10, 13]:
			tokens += 1
	if ascii_run > 0:
		tokens += int(ceil(float(ascii_run) / 4.0))
	return tokens
