extends "res://tests/agent/support/AgentTestCase.gd"


const MEMORY_ORGANIZER := preload("res://agent/memory/MemoryOrganizer.gd")
const MEMORY_STORE := preload("res://agent/memory/ResidentMemoryStore.gd")
const AVATAR_ORGANIZER := preload("res://agent/avatar_memory/AvatarMemoryOrganizer.gd")
const AVATAR_STORE := preload("res://agent/avatar_memory/ResidentAvatarMemoryStore.gd")
const TEST_DATA := preload("res://tests/support/AgentMemoryTestData.gd")


func _initialize() -> void:
	var initialization := TEST_DATA.initialization()
	var evidence := [{
		"evidence_id": "prompt-scope-evidence",
		"kind": "action_result",
		"payload": {"status": "completed", "reason": "木架已经完成。"},
	}]
	var memory_store: RefCounted = MEMORY_STORE.new(
		"user://tests/memory-prompt-scope/resident_memory.json",
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
	_expect_ok(memory_request, "resident memory organizer builds a request")
	var memory_system := _system_text(memory_request)
	_expect(
		not memory_system.contains("玩家填写的完整 OC"),
		"resident memory organization omits ordinary decision behavior rules",
	)
	_expect(
		memory_system.contains("居民记忆整理规则"),
		"resident memory organization keeps its dedicated rules",
	)
	_expect(
		memory_system.length() < 6000,
		"resident memory organization fixed prompt stays below the usage budget",
	)

	var avatar_store: RefCounted = AVATAR_STORE.new(
		"user://tests/memory-prompt-scope/avatar_memory.json",
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
	_expect_ok(avatar_request, "avatar memory organizer builds a request")
	var avatar_system := _system_text(avatar_request)
	_expect(
		not avatar_system.contains("玩家填写的完整 OC"),
		"avatar memory organization omits ordinary decision behavior rules",
	)
	_expect(
		avatar_system.contains("化身记忆整理"),
		"avatar memory organization keeps its dedicated rules",
	)
	_expect(
		avatar_system.length() < 6000,
		"avatar memory organization fixed prompt stays below the usage budget",
	)
	_finish_suite("MEMORY_PROMPT_SCOPE_PASS", [
		"user://tests/memory-prompt-scope",
	])


func _system_text(request: Dictionary) -> String:
	var messages := request.get("messages", []) as Array
	if messages.is_empty() or not messages[0] is Dictionary:
		return ""
	return String((messages[0] as Dictionary).get("content", ""))
