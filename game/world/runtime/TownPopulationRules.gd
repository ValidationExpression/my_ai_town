class_name TownPopulationRules
extends RefCounted


const MIN_RESIDENT_COUNT := 1
const DEFAULT_RESIDENT_COUNT := 15
const MAX_RESIDENT_COUNT := 30
const LEGACY_HOME_RESIDENT_CAPACITY := 1
const MAX_HOME_RESIDENT_CAPACITY := 2


static func supports_resident_count(count: int) -> bool:
	return count >= MIN_RESIDENT_COUNT and count <= MAX_RESIDENT_COUNT


static func supports_resident_count_for_world(
	count: int,
	world_data: Dictionary,
) -> bool:
	return (
		supports_resident_count(count)
		and count <= housing_capacity(world_data)
	)


static func rule_snapshot(world_data: Dictionary = {}) -> Dictionary:
	var snapshot := {
		"minimum": MIN_RESIDENT_COUNT,
		"default": DEFAULT_RESIDENT_COUNT,
		"maximum": MAX_RESIDENT_COUNT,
	}
	if not world_data.is_empty():
		snapshot["housingCapacity"] = housing_capacity(world_data)
		snapshot["homeCount"] = home_space_capacities(world_data).size()
	return snapshot


static func housing_capacity(world_data: Dictionary) -> int:
	var total := 0
	for capacity_value: Variant in home_space_capacities(world_data).values():
		total += int(capacity_value)
	return mini(total, MAX_RESIDENT_COUNT)


static func home_space_capacities(world_data: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for place_value: Variant in world_data.get("places", []) as Array:
		if not place_value is Dictionary:
			continue
		var place := place_value as Dictionary
		if String(place.get("type", "")) != "住家":
			continue
		var space_id := String(place.get("spaceId", "")).strip_edges()
		if space_id.is_empty() or result.has(space_id):
			return {}
		var capacity_value: Variant = place.get(
			"residentCapacity",
			LEGACY_HOME_RESIDENT_CAPACITY,
		)
		if (
			typeof(capacity_value) not in [TYPE_INT, TYPE_FLOAT]
			or not is_finite(float(capacity_value))
			or floorf(float(capacity_value)) != float(capacity_value)
			or int(capacity_value) < 1
			or int(capacity_value) > MAX_HOME_RESIDENT_CAPACITY
		):
			return {}
		result[space_id] = int(capacity_value)
	return result


static func allocated_home_space_ids(
	world_data: Dictionary,
	resident_count: int,
) -> Array[String]:
	if not supports_resident_count_for_world(resident_count, world_data):
		return []
	var capacities := home_space_capacities(world_data)
	var space_ids: Array[String] = []
	for space_id_value: Variant in capacities:
		space_ids.append(String(space_id_value))
	space_ids.sort()
	var result: Array[String] = []
	# 先让每套住宅入住一人，再分配第二位住户。这样旧 15 人开局的
	# 一人一宅映射保持不变，只有第 16 位起才开始共享住宅。
	for occupancy_index in MAX_HOME_RESIDENT_CAPACITY:
		for space_id: String in space_ids:
			if int(capacities.get(space_id, 0)) <= occupancy_index:
				continue
			result.append(space_id)
			if result.size() == resident_count:
				return result
	return []
