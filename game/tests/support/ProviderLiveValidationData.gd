class_name ProviderLiveValidationData
extends RefCounted


const AgentDebugScenariosScript := preload("res://agent/debug/AgentDebugScenarios.gd")


func connectivity_request(provider_id: String, model_id: String) -> Dictionary:
	return {
		"request_kind": "provider_connectivity_probe",
		"messages": [
			{
				"role": "system",
				"content": "你是 API 连通性探针。只返回合法 JSON 对象，不要 Markdown。",
			},
			{
				"role": "user",
				"content": (
					"请原样返回：{\"probe\":\"ok\",\"provider_id\":\"%s\",\"model_id\":\"%s\"}"
					% [provider_id, model_id]
				),
			},
		],
		"max_tokens": 128,
	}


func initialization() -> Dictionary:
	var data: Dictionary = AgentDebugScenariosScript.new().initialization()
	(data["places"] as Array).append({
		"name": "林岚家",
		"type": "住家",
		"owner": "林岚",
		"owner_resident_id": "resident-lin-lan",
		"summary": "林岚休息、吃饭和躲避恶劣天气的住处",
	})
	return data


func behavior_cases() -> Array[Dictionary]:
	return [
		_reply_required_case(),
		_eat_when_hungry_case(),
		_seek_storm_shelter_case(),
		_continue_current_work_case(),
		_answer_workshop_notice_case(),
		_conversation_follow_up_case(),
		_completed_action_reaction_case(),
		_memory_promise_case(),
		_social_candidate_case(),
		_weather_inside_case(),
		_player_announcement_interrupt_case(),
		_low_energy_rest_case(),
	]


func _reply_required_case() -> Dictionary:
	var packet := _base_packet("reply-required", "09:05", "上午")
	var turn := {
		"turn_id": 1,
		"speaker_resident_id": "resident-tang-xiao-man",
		"speaker": "唐小满",
		"say": "木架修好了吗？下午市集要用。",
		"narration": "唐小满看着林岚，等他回答。",
		"photos": [],
	}
	packet["snapshot"]["conversation"] = {
		"conversation_id": "conversation-live-reply",
		"with_resident_id": "resident-tang-xiao-man",
		"with": "唐小满",
		"turns": [turn.duplicate(true)],
	}
	packet["events"] = [{
		"event_id": "reply-required-event",
		"type": "对方答话",
		"conversation_id": "conversation-live-reply",
		"turn": turn,
		"time": packet["snapshot"]["time"].duplicate(true),
	}]
	return {
		"id": "reply_required",
		"title": "对方问话后必须答话",
		"wake_packet": packet,
		"expected": {
			"handling": "replace_current",
			"action": {
				"type": "答话",
				"conversation_id": "conversation-live-reply",
			},
		},
	}


func _eat_when_hungry_case() -> Dictionary:
	var packet := _base_packet("eat-when-hungry", "12:20", "中午")
	packet["snapshot"]["me"] = {
		"doing": "在工作坊收拾木料",
		"current_action": null,
		"body": {"困": "不困", "饿": "很饿", "累": "有点累"},
	}
	packet["snapshot"]["nearby"] = []
	packet["snapshot"]["place"] = {
		"name": "工作坊",
		"props": [{"name": "饭盒", "verbs": ["吃饭"]}],
	}
	return {
		"id": "eat_when_hungry",
		"title": "饥饿时使用眼前饭盒",
		"wake_packet": packet,
		"expected": {
			"handling": "replace_current",
			"action": {"type": "用道具", "prop": "饭盒", "verb": "吃饭"},
		},
	}


func _seek_storm_shelter_case() -> Dictionary:
	var packet := _base_packet("seek-storm-shelter", "15:10", "下午")
	packet["snapshot"]["weather"] = "雷暴"
	packet["snapshot"]["me"]["doing"] = "站在没有遮挡的广场上"
	packet["events"] = [{
		"event_id": "storm-event",
		"type": "天气变了",
		"weather": "雷暴",
		"time": packet["snapshot"]["time"].duplicate(true),
	}]
	return {
		"id": "seek_storm_shelter",
		"title": "雷暴时前往合法室内地点避雨",
		"wake_packet": packet,
		"expected": {
			"handling": "replace_current",
			"action": {"type": "去"},
		},
	}


func _continue_current_work_case() -> Dictionary:
	var packet := _base_packet("continue-current-work", "10:00", "上午")
	packet["snapshot"]["me"] = {
		"doing": "在工作坊专心打磨木板",
		"current_action": {
			"action_id": "current-work-action",
			"type": "用道具",
			"prop": "刨子",
			"verb": "打磨木板",
		},
		"body": {"困": "不困", "饿": "不饿", "累": "不累"},
	}
	packet["snapshot"]["nearby"] = []
	packet["snapshot"]["place"] = {
		"name": "工作坊",
		"props": [{"name": "刨子", "verbs": ["打磨木板"]}],
	}
	return {
		"id": "continue_current_work",
		"title": "没有新事件时继续手头工作",
		"wake_packet": packet,
		"expected": {"handling": "continue_current"},
	}


func _answer_workshop_notice_case() -> Dictionary:
	var packet := _base_packet("answer-workshop-notice", "08:40", "上午")
	packet["events"] = [{
		"event_id": "workshop-notice-event",
		"type": "公告发布",
		"announcement_id": "workshop-rack-loose",
		"text": "工作坊的木架松动，请木匠林岚尽快前往检查。",
		"time": packet["snapshot"]["time"].duplicate(true),
	}]
	return {
		"id": "answer_workshop_notice",
		"title": "木匠响应工作坊公告",
		"wake_packet": packet,
		"expected": {
			"handling": "replace_current",
			"action": {"type": "去", "place": "工作坊"},
		},
	}


func _conversation_follow_up_case() -> Dictionary:
	var packet := _base_packet("conversation-follow-up", "09:20", "上午")
	var first_turn := {
		"turn_id": 1,
		"speaker_resident_id": "resident-tang-xiao-man",
		"speaker": "唐小满",
		"say": "木架明天能好吗？",
		"narration": "她在木工台旁等着答复。",
		"photos": [],
	}
	var second_turn := {
		"turn_id": 2,
		"speaker_resident_id": "resident-lin-lan",
		"speaker": "林岚",
		"say": "能，明早给你送去。",
		"narration": "我没有停下手里的活。",
		"photos": [],
	}
	var latest_turn := {
		"turn_id": 3,
		"speaker_resident_id": "resident-tang-xiao-man",
		"speaker": "唐小满",
		"say": "那我等你，别又熬夜。",
		"narration": "她皱了皱眉。",
		"photos": [],
	}
	packet["snapshot"]["conversation"] = {
		"conversation_id": "conversation-follow-up",
		"with_resident_id": "resident-tang-xiao-man",
		"with": "唐小满",
		"turns": [first_turn, second_turn, latest_turn],
	}
	packet["events"] = [{
		"event_id": "conversation-follow-up-event",
		"type": "对方答话",
		"conversation_id": "conversation-follow-up",
		"turn": latest_turn.duplicate(true),
		"time": packet["snapshot"]["time"].duplicate(true),
	}]
	return {
		"id": "conversation_follow_up",
		"title": "连续对话承接前一句并继续回应",
		"wake_packet": packet,
		"expected": {
			"handling": "replace_current",
			"action": {
				"type": "答话",
				"conversation_id": "conversation-follow-up",
			},
		},
	}


func _completed_action_reaction_case() -> Dictionary:
	var packet := _base_packet("completed-action-reaction", "11:35", "上午")
	packet["snapshot"]["me"] = {
		"doing": "刚在工作坊把木架收尾",
		"current_action": null,
		"body": {"困": "不困", "饿": "不饿", "累": "有点累"},
	}
	packet["snapshot"]["place"] = {
		"name": "工作坊",
		"props": [{"name": "饭盒", "verbs": ["吃饭"]}],
	}
	packet["action_results"] = [{
		"action_id": "finish-frame-action",
		"status": "completed",
		"reason": "木架收尾完成，手腕有点酸。",
		"time": packet["snapshot"]["time"].duplicate(true),
	}]
	return {
		"id": "completed_action_reaction",
		"title": "动作完成后先表达真实感受再决定下一步",
		"wake_packet": packet,
		"expected": {
			"handling": "replace_current",
			"reaction": {"source_action_id": "finish-frame-action"},
		},
	}


func _memory_promise_case() -> Dictionary:
	var packet := _base_packet("memory-promise", "08:30", "上午")
	packet["snapshot"]["me"] = {
		"doing": "站在广场上",
		"current_action": null,
		"body": {"困": "不困", "饿": "不饿", "累": "不累"},
	}
	packet["snapshot"]["place"] = {
		"name": "广场",
		"props": [],
	}
	return {
		"id": "memory_promise",
		"title": "记忆中的承诺继续影响当前行动",
		"wake_packet": packet,
		"memory": "\n".join([
			"[重要记忆]",
			"昨天我答应唐小满，今天上午把修好的木架送到市集。",
			"",
			"[人物关系]",
			"唐小满：她信任我的手艺，我不想让她等太久。",
			"",
			"[短期目标]",
			"先回工作坊确认木架，再送去市集。",
		]),
		"expected": {
			"handling": "replace_current",
		},
	}


func _social_candidate_case() -> Dictionary:
	var packet := _base_packet("social-candidate", "13:10", "中午")
	packet["snapshot"]["me"] = {
		"doing": "在工作坊整理木料",
		"current_action": null,
		"body": {"困": "不困", "饿": "不饿", "累": "有点累"},
	}
	packet["snapshot"]["social_matters"] = [{
		"matter_id": "matter-garden-help-live",
		"revision": 2,
		"kind": "resident_request",
		"summary": "唐小满请人下午去社区花园帮忙修一张木桌。",
		"expires_at": 900,
		"response_round_id": "matter-garden-help-live-r1",
		"response_window_until": 840,
		"options": [
			{
				"option_id": "accept",
				"meaning": "愿意在今天下午去帮忙。",
				"allows_public_text": true,
			},
			{
				"option_id": "decline",
				"meaning": "今天不参加。",
				"allows_public_text": true,
			},
			{
				"option_id": "defer",
				"meaning": "现在先不答应，稍后再决定。",
				"allows_public_text": true,
			},
		],
		"assignment": null,
	}]
	return {
		"id": "social_candidate",
		"title": "面对社会请求时独立权衡是否回应",
		"wake_packet": packet,
		"expected": {
			"handling": "replace_current",
		},
	}


func _weather_inside_case() -> Dictionary:
	var packet := _base_packet("weather-inside", "15:20", "下午")
	packet["snapshot"]["weather"] = "雷暴"
	packet["snapshot"]["me"] = {
		"doing": "在工作坊屋檐下打磨木板",
		"current_action": {
			"action_id": "indoor-work-action",
			"type": "用道具",
			"prop": "刨子",
			"verb": "打磨木板",
		},
		"body": {"困": "不困", "饿": "不饿", "累": "不累"},
	}
	packet["snapshot"]["place"] = {
		"name": "工作坊",
		"props": [{"name": "刨子", "verbs": ["打磨木板"]}],
	}
	packet["events"] = [{
		"event_id": "weather-inside-event",
		"type": "天气变了",
		"weather": "雷暴",
		"time": packet["snapshot"]["time"].duplicate(true),
	}]
	return {
		"id": "weather_inside",
		"title": "室内工作不因户外雷暴机械回家",
		"wake_packet": packet,
		"expected": {"handling": "continue_current"},
	}


func _player_announcement_interrupt_case() -> Dictionary:
	var packet := _base_packet("player-announcement-interrupt", "16:00", "下午")
	packet["snapshot"]["me"] = {
		"doing": "在工作坊打磨木板",
		"current_action": {
			"action_id": "player-priority-work",
			"type": "用道具",
			"prop": "刨子",
			"verb": "打磨木板",
		},
		"body": {"困": "不困", "饿": "不饿", "累": "有点累"},
	}
	packet["snapshot"]["place"] = {
		"name": "工作坊",
		"props": [{"name": "刨子", "verbs": ["打磨木板"]}],
	}
	packet["events"] = [{
		"event_id": "player-announcement-event",
		"type": "公告到点",
		"announcement_id": "player-call-town-square",
		"publisher_resident_id": "avatar-1",
		"announcement_priority": "player",
		"scheduled_time_label": "现在",
		"text": "请现在到广场集合，有事要商量。",
		"time": packet["snapshot"]["time"].duplicate(true),
	}]
	return {
		"id": "player_announcement_interrupt",
		"title": "玩家公告打断普通工作并进入真实行动",
		"wake_packet": packet,
		"expected": {
			"handling": "replace_current",
			"action": {"type": "去", "place": "广场"},
		},
	}


func _low_energy_rest_case() -> Dictionary:
	var packet := _base_packet("low-energy-rest", "18:20", "傍晚")
	packet["snapshot"]["me"] = {
		"doing": "在工作坊门口收拾工具",
		"current_action": null,
		"body": {"困": "很困", "饿": "不饿", "累": "很累"},
	}
	packet["snapshot"]["nearby"] = []
	packet["snapshot"]["place"] = {
		"name": "工作坊",
		"props": [],
	}
	return {
		"id": "low_energy_rest",
		"title": "疲惫时在继续工作与休息之间作生活化选择",
		"wake_packet": packet,
		"expected": {"handling": "replace_current"},
	}


func _base_packet(decision_id: String, clock: String, period: String) -> Dictionary:
	var packet: Dictionary = AgentDebugScenariosScript.new().wake_packet(
		decision_id,
		1,
		clock,
	)
	packet["snapshot"]["time"]["period"] = period
	return packet
