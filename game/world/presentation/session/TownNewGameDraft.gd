class_name TownNewGameDraft
extends RefCounted


const SCHEMA_VERSION := TownSaveSchemaRegistry.NEW_GAME_DRAFT_SCHEMA_VERSION
const SOURCE_SCOPE := "resident_selection"
const POPULATION_RULES := preload("res://world/runtime/TownPopulationRules.gd")
const WORLD_DATA_PATH := "res://world/data/town/town_world.json"


static func validate(draft: Dictionary) -> Dictionary:
	var errors: Array[Dictionary] = []
	if int(draft.get("schemaVersion", 0)) != SCHEMA_VERSION:
		errors.append(_error("schemaVersion", "SESSION_DRAFT_SCHEMA_UNSUPPORTED"))
	if String(draft.get("sourceScope", "")) != SOURCE_SCOPE:
		errors.append(_error("sourceScope", "SESSION_DRAFT_SOURCE_INVALID"))
	if int(draft.get("draftRevision", 0)) < 1:
		errors.append(_error("draftRevision", "SESSION_DRAFT_REVISION_INVALID"))
	var world_data := _load_world_data()
	var home_capacities := POPULATION_RULES.home_space_capacities(world_data)
	var expected_spaces := home_space_ids()
	var slots_variant: Variant = draft.get("slots", [])
	if not (slots_variant is Array):
		errors.append(_error("slots", "SESSION_DRAFT_SLOTS_INVALID"))
		slots_variant = []
	var slots: Array = slots_variant
	var occupants_by_space_id: Dictionary = {}
	var seen_resident_ids: Dictionary = {}
	for index in range(slots.size()):
		if not (slots[index] is Dictionary):
			errors.append(_error("slots[%d]" % index, "SESSION_DRAFT_SLOT_INVALID"))
			continue
		var slot: Dictionary = slots[index]
		var space_id := String(slot.get("spaceId", ""))
		var resident_id := String(slot.get("residentId", "")).strip_edges()
		if space_id.is_empty():
			errors.append(_error("slots[%d].spaceId" % index, "SESSION_HOME_SPACE_REQUIRED"))
		elif not expected_spaces.has(space_id):
			errors.append(_error("slots[%d].spaceId" % index, "SESSION_HOME_SPACE_UNKNOWN"))
		else:
			var occupants := int(occupants_by_space_id.get(space_id, 0)) + 1
			occupants_by_space_id[space_id] = occupants
			if occupants > int(home_capacities.get(space_id, 0)):
				errors.append(_error(
					"slots[%d].spaceId" % index,
					"SESSION_HOME_SPACE_CAPACITY_EXCEEDED",
					{
						"spaceId": space_id,
						"capacity": int(home_capacities.get(space_id, 0)),
						"actual": occupants,
					},
				))
		if resident_id.is_empty():
			errors.append(_error("slots[%d].residentId" % index, "SESSION_RESIDENT_ID_REQUIRED"))
		elif seen_resident_ids.has(resident_id):
			errors.append(_error("slots[%d].residentId" % index, "SESSION_RESIDENT_ID_DUPLICATED"))
		else:
			seen_resident_ids[resident_id] = true
		var binding_variant: Variant = slot.get("llmBinding", {})
		if not (binding_variant is Dictionary):
			errors.append(_error("slots[%d].llmBinding" % index, "SESSION_LLM_BINDING_INVALID"))
		else:
			var binding: Dictionary = binding_variant
			if String(binding.get("mode", "")) != "model":
				errors.append(_error(
					"slots[%d].llmBinding.mode" % index,
					"SESSION_LLM_BINDING_MODE_INVALID",
				))
			if String(binding.get("providerId", "")).is_empty():
				errors.append(_error(
					"slots[%d].llmBinding.providerId" % index,
					"SESSION_LLM_PROVIDER_REQUIRED",
				))
			if String(binding.get("modelId", "")).is_empty():
				errors.append(_error(
					"slots[%d].llmBinding.modelId" % index,
					"SESSION_LLM_MODEL_REQUIRED",
				))
	if not POPULATION_RULES.supports_resident_count_for_world(
		slots.size(),
		world_data,
	):
		errors.append(_error(
			"slots",
			"SESSION_RESIDENT_COUNT_OUT_OF_RANGE",
			{
				"minimum": POPULATION_RULES.MIN_RESIDENT_COUNT,
				"maximum": mini(
					POPULATION_RULES.MAX_RESIDENT_COUNT,
					POPULATION_RULES.housing_capacity(world_data),
				),
				"designMaximum": POPULATION_RULES.MAX_RESIDENT_COUNT,
				"actual": slots.size(),
			},
		))
	return {
		"ok": errors.is_empty(),
		"errorCode": "" if errors.is_empty() else "SESSION_DRAFT_INVALID",
		"retryable": false,
		"draftRevision": int(draft.get("draftRevision", 0)),
		"errors": errors,
		"residentCount": slots.size(),
		"minimumResidentCount": POPULATION_RULES.MIN_RESIDENT_COUNT,
		"defaultResidentCount": POPULATION_RULES.DEFAULT_RESIDENT_COUNT,
		"maximumResidentCount": POPULATION_RULES.MAX_RESIDENT_COUNT,
		"housingCapacity": POPULATION_RULES.housing_capacity(world_data),
		"expectedSpaceIds": expected_spaces,
	}


static func model_bindings(draft: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var slots: Array = (draft.get("slots", []) as Array).duplicate(true)
	slots.sort_custom(func(a: Variant, b: Variant) -> bool:
		var left := a as Dictionary
		var right := b as Dictionary
		var left_space := String(left.get("spaceId", ""))
		var right_space := String(right.get("spaceId", ""))
		if left_space == right_space:
			return String(left.get("residentId", "")) < String(right.get("residentId", ""))
		return left_space < right_space
	)
	for slot_variant in slots:
		var slot := slot_variant as Dictionary
		result.append({
			"residentId": String(slot.get("residentId", "")),
			"spaceId": String(slot.get("spaceId", "")),
			"llmBinding": (slot.get("llmBinding", {}) as Dictionary).duplicate(true),
		})
	return result


static func home_space_ids() -> Array[String]:
	var world_data := _load_world_data()
	return POPULATION_RULES.allocated_home_space_ids(
		world_data,
		POPULATION_RULES.housing_capacity(world_data),
	)


static func _load_world_data() -> Dictionary:
	if not FileAccess.file_exists(WORLD_DATA_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(WORLD_DATA_PATH)
	)
	return parsed as Dictionary if parsed is Dictionary else {}


static func _error(path: String, code: String, meta: Dictionary = {}) -> Dictionary:
	return {
		"path": path,
		"code": code,
		"meta": meta.duplicate(true),
	}
