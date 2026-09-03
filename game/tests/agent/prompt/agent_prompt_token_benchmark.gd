extends "res://tests/agent/support/AgentPromptTestCase.gd"


const EMPTY_MEMORY := ""


func _initialize() -> void:
	var compiler_script := _load_prompt_compiler()
	if compiler_script == null:
		_finish_prompt_test("AGENT_PROMPT_TOKEN_BENCHMARK_FAIL")
		return
	var phase := OS.get_environment("AI_TOWN_PROMPT_BENCHMARK_PHASE")
	if phase.is_empty():
		phase = "baseline"
	var compiler: RefCounted = compiler_script.new(_initialization())
	for scenario: Dictionary in _scenarios():
		var result := compiler.call(
			"compile",
			scenario.get("wake", {}) as Dictionary,
			String(scenario.get("memory", EMPTY_MEMORY)),
		) as Dictionary
		var messages := result.get("messages", []) as Array
		if messages.size() != 2:
			_record_failure(
				"提示词基准场景编译失败",
				"compile_messages",
				2,
				messages.size(),
			)
			continue
		var system_text := String((messages[0] as Dictionary).get("content", ""))
		var user_text := String((messages[1] as Dictionary).get("content", ""))
		var total_text := system_text + user_text
		print((
			"PROMPT_METRIC phase=%s scenario=%s system_chars=%d user_chars=%d "
			+ "total_chars=%d system_bytes=%d user_bytes=%d total_bytes=%d "
			+ "estimated_tokens=%d"
			) % [
				phase,
				String(scenario.get("name", "unknown")),
				system_text.length(),
				user_text.length(),
				total_text.length(),
				system_text.to_utf8_buffer().size(),
				user_text.to_utf8_buffer().size(),
				total_text.to_utf8_buffer().size(),
				_estimate_tokens(total_text),
			],
		)
	_finish_prompt_test("AGENT_PROMPT_TOKEN_BENCHMARK_PASS")


func _scenarios() -> Array[Dictionary]:
	return [
		{
			"name": "ordinary",
			"wake": _wake_packet("benchmark-ordinary", "晴天"),
			"memory": EMPTY_MEMORY,
		},
		{
			"name": "life",
			"wake": _life_wake(),
			"memory": EMPTY_MEMORY,
		},
		{
			"name": "work",
			"wake": _work_wake(),
			"memory": "",
		},
		{
			"name": "conversation_duplicate",
			"wake": _conversation_wake(),
			"memory": EMPTY_MEMORY,
		},
		{
			"name": "events",
			"wake": _event_wake(),
			"memory": EMPTY_MEMORY,
		},
		{
			"name": "memory",
			"wake": _wake_packet("benchmark-memory", "小雨"),
			"memory": "\n".join([
				"[重要记忆]",
				"唐小满问木架何时完成，我答应明早送过去。",
				"",
				"[人物关系]",
				"唐小满：她信任我的手艺，我不能让她失望。",
				"",
				"[当前想法]",
				"今晚要把木架收尾。",
				"",
				"[长期目标]",
				"成为守信可靠的木匠。",
				"",
				"[短期目标]",
				"明早把木架送给唐小满。",
			]),
		},
	]


func _life_wake() -> Dictionary:
	var wake := _wake_packet("benchmark-life", "晴天")
	var snapshot := wake.get("snapshot", {}) as Dictionary
	var place := snapshot.get("place", {}) as Dictionary
	place["destinations"] = ["花房咖啡馆", "公共食堂"]
	place["message_recipients"] = [{
		"resident_id": "resident-tang-xiao-man",
		"name": "唐小满",
	}]
	place["activities"] = [{
		"activity_id": "activity-cafe-rest",
		"label": "在咖啡馆歇一会儿",
		"interest_match": false,
		"matched_interests": [],
	}]
	snapshot["life_destination_options"] = [{
		"place_id": "花房咖啡馆",
		"activities": place["activities"],
	}]
	snapshot["known_announcements"] = [{
		"announcement_id": "announcement-benchmark",
		"text": "今晚广场有露天电影。",
		"publisher_resident_id": "resident-tang-xiao-man",
		"acquired_via": "town_bell",
		"active": true,
	}]
	wake["snapshot"] = snapshot
	return wake


func _work_wake() -> Dictionary:
	var wake := _wake_packet("benchmark-work", "阴天")
	var snapshot := wake.get("snapshot", {}) as Dictionary
	snapshot["place"]["name"] = "工作坊"
	snapshot["place"]["props"] = [{
		"name": "木工台",
		"verbs": ["使用", "整理"],
	}]
	snapshot["place"]["activities"] = [{
		"activity_id": "activity-finish-frame",
		"label": "把木架收尾",
		"interest_match": true,
		"matched_interests": ["手工"],
	}]
	snapshot["work_tasks"] = [{
		"task_id": "task-bench-frame",
		"label": "完成木架",
		"status": "进行中",
		"due": "明早",
	}]
	snapshot["current_task"] = {
		"task_id": "task-bench-frame",
		"label": "完成木架",
	}
	wake["snapshot"] = snapshot
	return wake


func _conversation_wake() -> Dictionary:
	var wake := _wake_packet("benchmark-conversation", "晴天")
	var turn := {
		"turn_id": 1,
		"speaker_resident_id": "resident-tang-xiao-man",
		"speaker": "唐小满",
		"say": "木架明天能好吗？",
		"narration": "她在木工台旁等着答复。",
		"photos": [],
	}
	wake["snapshot"]["conversation"] = {
		"conversation_id": "conversation-benchmark",
		"with_resident_id": "resident-tang-xiao-man",
		"with": "唐小满",
		"turns": [turn],
	}
	wake["events"] = [{
		"event_id": "event-conversation-benchmark",
		"time": {"day": 1, "clock": "08:10", "period": "上午"},
		"type": "对方答话",
		"conversation_id": "conversation-benchmark",
		"turn": turn,
	}]
	return wake


func _event_wake() -> Dictionary:
	var wake := _wake_packet("benchmark-events", "小雨")
	wake["events"] = [
		{
			"event_id": "event-arrival-benchmark",
			"time": {"day": 1, "clock": "08:11", "period": "上午"},
			"type": "有人来了",
			"who_resident_id": "resident-tang-xiao-man",
			"who": "唐小满",
		},
		{
			"event_id": "event-announcement-benchmark",
			"time": {"day": 1, "clock": "08:12", "period": "上午"},
			"type": "公告发布",
			"announcement_id": "announcement-benchmark",
			"text": "今晚广场有露天电影。",
		},
		{
			"event_id": "event-action-benchmark",
			"time": {"day": 1, "clock": "08:13", "period": "上午"},
			"type": "行动完成",
			"action_id": "action-benchmark",
			"action_type": "用道具",
			"result": "木架打磨完成了一部分。",
		},
	]
	return wake


func _estimate_tokens(text: String) -> int:
	# 这是离线比较用的稳定估算，不代表具体 Provider 的 tokenizer 账单。
	# 中文字符按 1 个近似 token，连续 ASCII 字母数字按每 4 个近似 1 token。
	var tokens := 0
	var ascii_run := 0
	for index in text.length():
		var codepoint := text.unicode_at(index)
		if (codepoint >= 48 and codepoint <= 57) or (codepoint >= 65 and codepoint <= 90) or (codepoint >= 97 and codepoint <= 122):
			ascii_run += 1
			continue
		if ascii_run > 0:
			tokens += int(ceil(float(ascii_run) / 4.0))
			ascii_run = 0
		if codepoint == 32 or codepoint == 9 or codepoint == 10 or codepoint == 13:
			continue
		tokens += 1
	if ascii_run > 0:
		tokens += int(ceil(float(ascii_run) / 4.0))
	return tokens
