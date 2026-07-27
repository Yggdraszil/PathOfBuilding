-- Path of Building
--
-- Module: Analysis JSON Exporter
-- Collects a stable, JSON-safe analysis snapshot of the current build.
--
local dkjson = require "dkjson"
local configOptionList = LoadModule("Modules/ConfigOptions")

local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local t_insert = table.insert
local t_sort = table.sort
local s_format = string.format
local m_huge = math.huge

local exporter = { }
local objectMeta = { __jsontype = "object" }
local supportedConfigTypes = {
	check = true,
	count = true,
	integer = true,
	countAllowZero = true,
	float = true,
	list = true,
	text = true,
}
local configTypes = { }
local ambiguousConfigTypes = { }

for _, option in ipairs(configOptionList) do
	if type(option.var) == "string" and supportedConfigTypes[option.type] then
		if not ambiguousConfigTypes[option.var] and not configTypes[option.var] then
			configTypes[option.var] = option.type
		elseif configTypes[option.var] ~= option.type then
			configTypes[option.var] = nil
			ambiguousConfigTypes[option.var] = true
		end
	end
end

local function newObject(values)
	return setmetatable(values or { }, objectMeta)
end

local function sortedKeys(tbl)
	local keys = { }
	local unsupported = 0
	for key in pairs(tbl or { }) do
		local keyType = type(key)
		if keyType == "string" or keyType == "number" then
			t_insert(keys, key)
		else
			unsupported = unsupported + 1
		end
	end
	t_sort(keys, function(a, b)
		local typeA, typeB = type(a), type(b)
		if typeA == typeB then
			return a < b
		end
		return typeA == "number"
	end)
	return keys, unsupported
end

local function isFinite(value)
	return value == value and value < m_huge and value > -m_huge
end

local function addWarning(warnings, message)
	t_insert(warnings, message)
end

local function normalisePrimitive(value, path, warnings)
	local valueType = type(value)
	if valueType == "number" then
		if not isFinite(value) then
			addWarning(warnings, path .. ": non-finite number replaced with null")
			return dkjson.null, true
		end
		return value, true
	elseif valueType == "string" or valueType == "boolean" then
		return value, true
	end
	return nil, false
end

local function collectPrimitiveObject(source, destination, path, warnings, warnSkipped)
	local keys, skipped = sortedKeys(source)
	for _, key in ipairs(keys) do
		local value, included = normalisePrimitive(source[key], path .. "." .. tostring(key), warnings)
		if included then
			destination[key] = value
		else
			skipped = skipped + 1
		end
	end
	if warnSkipped and skipped > 0 then
		addWarning(warnings, s_format("%s: skipped %d non-scalar value%s", path, skipped, skipped == 1 and "" or "s"))
	end
end

local function putPrimitive(destination, key, value)
	local valueType = type(value)
	if valueType == "string" or valueType == "boolean" or (valueType == "number" and isFinite(value)) then
		destination[key] = value
	end
end

local function valueOrFallback(value, fallback)
	if value ~= nil then
		return value
	end
	return fallback
end

local function activeSetTitle(sets, activeSetId)
	local activeSet = sets and sets[activeSetId]
	return activeSet and (activeSet.title or "Default")
end

local function collectActiveLoadout(build, metadata)
	local treeTab = build.treeTab
	if not treeTab or type(build.treeListSpecialLinks) ~= "table"
		or type(build.itemListSpecialLinks) ~= "table"
		or type(build.skillListSpecialLinks) ~= "table"
		or type(build.configListSpecialLinks) ~= "table" then
		return
	end

	-- SyncLoadouts' special-link maps are the only authoritative relationship
	-- between a loadout and all four active sets. Equal titles alone do not
	-- establish a loadout: independently named sets may happen to match.
	local matchedLink
	local matchedTree
	for _, linkId in ipairs(sortedKeys(build.treeListSpecialLinks)) do
		local treeLink = build.treeListSpecialLinks[linkId]
		local itemLink = build.itemListSpecialLinks[linkId]
		local skillLink = build.skillListSpecialLinks[linkId]
		local configLink = build.configListSpecialLinks[linkId]
		if type(linkId) == "string"
			and type(treeLink) == "table" and treeLink.setId == treeTab.activeSpec
			and type(itemLink) == "table" and itemLink.setId == (build.itemsTab and build.itemsTab.activeItemSetId)
			and type(skillLink) == "table" and skillLink.setId == (build.skillsTab and build.skillsTab.activeSkillSetId)
			and type(configLink) == "table" and configLink.setId == (build.configTab and build.configTab.activeConfigSetId) then
			if matchedLink then
				return
			end
			matchedLink = linkId
			matchedTree = treeLink
		end
	end
	if matchedLink then
		putPrimitive(metadata, "active_loadout_link_id", matchedLink)
		putPrimitive(metadata, "active_loadout_name", matchedTree.setName)
	end
end

local function collectMetadata(build)
	local metadata = newObject()
	metadata.schema_version = 1
	metadata.export_timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
	putPrimitive(metadata, "pob_version", launch and launch.versionNumber)
	putPrimitive(metadata, "target_game_version", build.targetVersion)
	putPrimitive(metadata, "build_name", build.buildName)
	putPrimitive(metadata, "build_source_filename", build.dbFileName)

	local treeTab = build.treeTab
	local spec = build.spec
	if treeTab and spec then
		putPrimitive(metadata, "active_passive_tree_index", treeTab.activeSpec)
		putPrimitive(metadata, "active_passive_tree_name", spec.title or "Default")
	end

	collectActiveLoadout(build, metadata)

	local itemsTab = build.itemsTab
	local skillsTab = build.skillsTab
	local configTab = build.configTab
	if itemsTab then
		putPrimitive(metadata, "active_item_set_id", itemsTab.activeItemSetId)
		putPrimitive(metadata, "active_item_set_name", activeSetTitle(itemsTab.itemSets, itemsTab.activeItemSetId))
	end
	if skillsTab then
		putPrimitive(metadata, "active_skill_set_id", skillsTab.activeSkillSetId)
		putPrimitive(metadata, "active_skill_set_name", activeSetTitle(skillsTab.skillSets, skillsTab.activeSkillSetId))
	end
	if configTab then
		putPrimitive(metadata, "active_config_set_id", configTab.activeConfigSetId)
		putPrimitive(metadata, "active_config_set_name", activeSetTitle(configTab.configSets, configTab.activeConfigSetId))
	end
	return metadata
end

local function collectCharacter(build)
	local character = newObject()
	local spec = build.spec
	local configInput = build.configTab and build.configTab.input
	putPrimitive(character, "level", build.characterLevel)
	putPrimitive(character, "class", spec and spec.curClassName)
	putPrimitive(character, "ascendancy", spec and spec.curAscendClassName)
	putPrimitive(character, "secondary_ascendancy", spec and spec.curSecondaryAscendClassName)
	putPrimitive(character, "bandit", valueOrFallback(configInput and configInput.bandit, build.bandit))
	putPrimitive(character, "pantheon_major_god", valueOrFallback(configInput and configInput.pantheonMajorGod, build.pantheonMajorGod))
	putPrimitive(character, "pantheon_minor_god", valueOrFallback(configInput and configInput.pantheonMinorGod, build.pantheonMinorGod))
	return character
end

local function findSelectedActiveSkill(group)
	if not group then
		return
	end
	local skillList = group.displaySkillList
	local selectedIndex = group.mainActiveSkill or 1
	return skillList and skillList[selectedIndex]
end

local function collectActiveContext(build, mainEnv, mainOutput)
	local context = newObject()
	local groupIndex = build.mainSocketGroup
	local skillsTab = build.skillsTab
	local group = skillsTab and skillsTab.socketGroupList and skillsTab.socketGroupList[groupIndex]
	putPrimitive(context, "active_skill_group_index", groupIndex)
	putPrimitive(context, "active_skill_group_label", group and (group.label and group.label:match("%S") and group.label or group.displayLabel))

	local mainSkill = mainEnv.player and mainEnv.player.mainSkill
	local activeEffect = mainSkill and mainSkill.activeEffect
	local grantedEffect = activeEffect and activeEffect.grantedEffect
	local sourceInstance = activeEffect and activeEffect.srcInstance
	local activeSkillSettings = newObject()
	context.active_skill_settings = activeSkillSettings
	putPrimitive(activeSkillSettings, "skill_part", sourceInstance and sourceInstance.skillPart)
	putPrimitive(activeSkillSettings, "skill_mode", sourceInstance and sourceInstance.skillMode)
	putPrimitive(activeSkillSettings, "skill_stage_count", sourceInstance and sourceInstance.skillStageCount)
	putPrimitive(activeSkillSettings, "skill_mine_count", sourceInstance and sourceInstance.skillMineCount)
	putPrimitive(activeSkillSettings, "skill_minion", sourceInstance and sourceInstance.skillMinion)
	putPrimitive(activeSkillSettings, "skill_minion_skill", sourceInstance and sourceInstance.skillMinionSkill)
	putPrimitive(activeSkillSettings, "skill_minion_item_set", sourceInstance and sourceInstance.skillMinionItemSet)
	putPrimitive(context, "active_main_skill_name", grantedEffect and grantedEffect.name)
	putPrimitive(context, "selected_skill_part", sourceInstance and sourceInstance.skillPart)
	putPrimitive(context, "selected_skill_part_name", mainSkill and mainSkill.skillPartName)
	putPrimitive(context, "selected_skill_mode", sourceInstance and sourceInstance.skillMode)

	local calcsInput = build.calcsTab and build.calcsTab.input
	putPrimitive(context, "selected_calculation_mode", calcsInput and calcsInput.misc_buffMode)
	putPrimitive(context, "calcs_skill_group_index", calcsInput and calcsInput.skill_number)
	context.calculation_output_mode = "MAIN"

	local fullDpsEnabled = false
	for _, socketGroup in ipairs(skillsTab and skillsTab.socketGroupList or { }) do
		if socketGroup.enabled and socketGroup.includeInFullDPS then
			fullDpsEnabled = true
			break
		end
	end
	context.full_dps_enabled = fullDpsEnabled
	context.full_dps_available = mainOutput.FullDPS ~= nil
	return context
end

local function slotEnabled(activeItemSet, slotName, slotState)
	if slotName:match("^Flask %d+$") then
		return slotState.active == true
	end
	if slotName:match("^Weapon [12]") then
		return (slotName:match(" Swap") ~= nil) == (activeItemSet.useSecondWeaponSet == true)
	end
	return true
end

local function collectSocketInformation(item)
	local sockets = { }
	for index, socket in ipairs(item.sockets or { }) do
		t_insert(sockets, newObject({
			index = index,
			color = socket.color,
			group = socket.group,
		}))
	end
	return sockets
end

local function collectSocketedGemReferences(build, slotName)
	local references = { }
	local socketGroups = build.skillsTab and build.skillsTab.socketGroupList or { }
	for index, group in ipairs(socketGroups) do
		if group.slot == slotName then
			local reference = newObject({ skill_group_index = index })
			putPrimitive(reference, "skill_group_label", group.label and group.label:match("%S") and group.label or group.displayLabel)
			t_insert(references, reference)
		end
	end
	return references
end

local function collectEquipment(build)
	local equipment = { }
	local itemsTab = build.itemsTab
	local activeItemSet = itemsTab and itemsTab.activeItemSet
	if not itemsTab or not activeItemSet or not itemsTab.items then
		return equipment
	end

	local function addEquippedItem(slotName, itemId, enabled)
		local item = itemId and itemId > 0 and itemsTab.items[itemId]
		if item then
			local entry = newObject({
				slot = slotName,
				item_id = item.id or itemId,
				enabled = enabled,
				sockets = collectSocketInformation(item),
				socketed_gem_references = collectSocketedGemReferences(build, slotName),
			})
			putPrimitive(entry, "name", item.name)
			putPrimitive(entry, "base_type", item.baseName)
			putPrimitive(entry, "rarity", item.rarity)
			putPrimitive(entry, "item_level", item.itemLevel)
			putPrimitive(entry, "quality", item.quality)
			putPrimitive(entry, "raw_item_text", item.raw)
			t_insert(equipment, entry)
		end
	end

	for _, slotName in ipairs(sortedKeys(activeItemSet)) do
		local slotState = activeItemSet[slotName]
		if type(slotName) == "string" and type(slotState) == "table" then
			addEquippedItem(slotName, slotState.selItemId, slotEnabled(activeItemSet, slotName, slotState))
		end
	end
	local spec = build.spec
	for _, nodeId in ipairs(sortedKeys(spec and spec.jewels)) do
		addEquippedItem("Jewel " .. nodeId, spec.jewels[nodeId], spec.allocNodes and spec.allocNodes[nodeId] ~= nil)
	end
	return equipment
end

local function selectedGrantedSkillName(group, gem)
	local activeSkill = findSelectedActiveSkill(group)
	local activeEffect = activeSkill and activeSkill.activeEffect
	if activeEffect and activeEffect.srcInstance == gem and activeEffect.grantedEffect then
		return activeEffect.grantedEffect.name
	end
end

local function collectSkillGroups(build)
	local groups = { }
	local socketGroups = build.skillsTab and build.skillsTab.socketGroupList or { }
	for groupIndex, group in ipairs(socketGroups) do
		local entry = newObject({
			index = groupIndex,
			enabled = group.enabled == true,
			full_dps_included = group.includeInFullDPS == true,
			gems = { },
		})
		putPrimitive(entry, "label", group.label and group.label:match("%S") and group.label or group.displayLabel)
		putPrimitive(entry, "socketed_equipment_slot", group.slot)
		putPrimitive(entry, "source", group.source)
		putPrimitive(entry, "group_count", group.groupCount)
		putPrimitive(entry, "imbued_support", group.imbuedSupport)
		local selectedSkill = findSelectedActiveSkill(group)
		putPrimitive(entry, "trigger", selectedSkill and selectedSkill.infoTrigger)

		for gemIndex, gem in ipairs(group.gemList or { }) do
			local gemData = gem.gemData
			local grantedEffect = gemData and gemData.grantedEffect or gem.grantedEffect
			local gemEntry = newObject({
				index = gemIndex,
				enabled = gem.enabled == true,
				is_support = grantedEffect and grantedEffect.support == true or false,
			})
			putPrimitive(gemEntry, "name", gemData and gemData.name or grantedEffect and grantedEffect.name or gem.nameSpec)
			putPrimitive(gemEntry, "level", gem.level)
			putPrimitive(gemEntry, "quality", gem.quality)
			putPrimitive(gemEntry, "count", gem.count)
			putPrimitive(gemEntry, "internal_gem_id", gem.gemId or gemData and gemData.id)
			putPrimitive(gemEntry, "game_gem_id", gemData and gemData.gameId)
			putPrimitive(gemEntry, "internal_skill_id", gem.skillId or grantedEffect and grantedEffect.id)
			putPrimitive(gemEntry, "variant_id", gemData and gemData.variantId)
			putPrimitive(gemEntry, "selected_granted_active_skill", selectedGrantedSkillName(group, gem))
			t_insert(entry.gems, gemEntry)
		end
		t_insert(groups, entry)
	end
	return groups
end

local function collectPassiveTree(build)
	local passiveTree = newObject({
		allocated_node_ids = { },
		allocated_ascendancy_node_ids = { },
		mastery_selections = { },
		jewel_socket_node_ids = { },
		equipped_jewels = { },
		node_modifications = { },
		allocated_tattoo_types = { },
	})
	local spec = build.spec
	if not spec then
		return passiveTree
	end
	putPrimitive(passiveTree, "version", spec.treeVersion)
	putPrimitive(passiveTree, "class_start_node_id", spec.curClass and spec.curClass.startNodeId)

	for _, nodeId in ipairs(sortedKeys(spec.allocNodes)) do
		local node = spec.allocNodes[nodeId]
		if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			if node.ascendancyName then
				t_insert(passiveTree.allocated_ascendancy_node_ids, nodeId)
			else
				t_insert(passiveTree.allocated_node_ids, nodeId)
			end
			if node.type == "Socket" then
				t_insert(passiveTree.jewel_socket_node_ids, nodeId)
			end
		end
	end

	for _, nodeId in ipairs(sortedKeys(spec.masterySelections)) do
		t_insert(passiveTree.mastery_selections, newObject({
			node_id = nodeId,
			effect_id = spec.masterySelections[nodeId],
		}))
	end

	local items = build.itemsTab and build.itemsTab.items or { }
	for _, nodeId in ipairs(sortedKeys(spec.jewels)) do
		local itemId = spec.jewels[nodeId]
		local reference = newObject({ node_id = nodeId, item_id = itemId })
		putPrimitive(reference, "item_name", items[itemId] and items[itemId].name)
		t_insert(passiveTree.equipped_jewels, reference)
	end

	for _, nodeId in ipairs(sortedKeys(spec.hashOverrides)) do
		local override = spec.hashOverrides[nodeId]
		local modification = newObject({
			node_id = nodeId,
			is_tattoo = override.isTattoo == true,
			stat_lines = { },
		})
		putPrimitive(modification, "name", override.dn or override.name)
		putPrimitive(modification, "type", override.overrideType)
		putPrimitive(modification, "target_type", override.targetType)
		putPrimitive(modification, "target_value", override.targetValue)
		putPrimitive(modification, "icon", override.icon)
		putPrimitive(modification, "active_effect_image", override.activeEffectImage)
		putPrimitive(modification, "minimum_connected", override.MinimumConnected)
		putPrimitive(modification, "maximum_connected", override.MaximumConnected)
		putPrimitive(modification, "legacy", override.legacy)
		for _, statLine in ipairs(override.sd or { }) do
			local value, included = normalisePrimitive(statLine, "passive_tree.node_modifications.stat_lines", { })
			if included then
				t_insert(modification.stat_lines, value)
			end
		end
		t_insert(passiveTree.node_modifications, modification)
	end

	for _, tattooType in ipairs(sortedKeys(spec.allocatedTattooTypes)) do
		local count = spec.allocatedTattooTypes[tattooType]
		if type(tattooType) == "string" and type(count) == "number" and isFinite(count) then
			t_insert(passiveTree.allocated_tattoo_types, newObject({
				type = tattooType,
				count = count,
			}))
		end
	end
	return passiveTree
end

local function resolveEffectiveConfiguration(optionType, inputValue, placeholderValue)
	if optionType == "check" then
		if inputValue then
			return true
		end
	elseif optionType == "count" or optionType == "integer" or optionType == "float" then
		if inputValue and inputValue ~= 0 then
			return inputValue
		elseif placeholderValue and placeholderValue ~= 0 then
			return placeholderValue
		end
	elseif optionType == "countAllowZero" then
		if inputValue then
			return inputValue
		elseif placeholderValue then
			return placeholderValue
		end
	elseif optionType == "list" or optionType == "text" then
		if inputValue then
			return inputValue
		end
	end
end

local function collectConfiguration(build, warnings)
	local configuration = newObject({
		input = newObject(),
		placeholder = newObject(),
		effective = newObject(),
	})
	local configTab = build.configTab
	if not configTab then
		return configuration
	end

	local input = configTab.input or { }
	local placeholder = configTab.placeholder or { }
	collectPrimitiveObject(input, configuration.input, "configuration.input", warnings, true)
	collectPrimitiveObject(placeholder, configuration.placeholder, "configuration.placeholder", warnings, true)

	local variables = { }
	for key in pairs(input) do
		variables[key] = true
	end
	for key in pairs(placeholder) do
		variables[key] = true
	end
	local unknownVariables = { }
	for _, var in ipairs(sortedKeys(variables)) do
		local optionType = type(var) == "string" and configTypes[var]
		if optionType then
			local effectiveValue = resolveEffectiveConfiguration(optionType, input[var], placeholder[var])
			if effectiveValue ~= nil then
				local value, included = normalisePrimitive(effectiveValue, "configuration.effective." .. tostring(var), warnings)
				if included then
					configuration.effective[var] = value
				end
			end
		else
			t_insert(unknownVariables, tostring(var))
		end
	end
	if #unknownVariables > 0 then
		addWarning(warnings, s_format(
			"configuration.effective: omitted %d unknown configuration variable%s (%s)",
			#unknownVariables,
			#unknownVariables == 1 and "" or "s",
			table.concat(unknownVariables, ", ")
		))
	end
	putPrimitive(configuration, "effective_enemy_level", configTab.enemyLevel)
	return configuration
end

local summaryMappings = {
	{ "life", "Life" },
	{ "energy_shield", "EnergyShield" },
	{ "mana", "Mana" },
	{ "unreserved_mana", "ManaUnreserved" },
	{ "ward", "Ward" },
	{ "strength", "Str" },
	{ "dexterity", "Dex" },
	{ "intelligence", "Int" },
	{ "armour", "Armour" },
	{ "evasion", "Evasion" },
	{ "spell_suppression_chance", "EffectiveSpellSuppressionChance", "SpellSuppressionChance" },
	{ "attack_block_chance", "EffectiveBlockChance", "BlockChance" },
	{ "spell_block_chance", "EffectiveSpellBlockChance", "SpellBlockChance" },
	{ "life_regeneration", "LifeRegenRecovery" },
	{ "energy_shield_regeneration", "EnergyShieldRegenRecovery" },
	{ "effective_hit_pool", "TotalEHP" },
	{ "physical_maximum_hit", "PhysicalMaximumHitTaken" },
	{ "fire_maximum_hit", "FireMaximumHitTaken" },
	{ "cold_maximum_hit", "ColdMaximumHitTaken" },
	{ "lightning_maximum_hit", "LightningMaximumHitTaken" },
	{ "chaos_maximum_hit", "ChaosMaximumHitTaken" },
	{ "full_dps", "FullDPS" },
	{ "combined_dps", "CombinedDPS" },
	{ "total_dps", "TotalDPS" },
	{ "average_hit", "AverageHit", "AverageDamage" },
	{ "hit_rate", "HitSpeed" },
	{ "critical_strike_chance", "CritChance", "PreEffectiveCritChance" },
	{ "critical_strike_multiplier", "CritMultiplier" },
	{ "mana_cost", "ManaCost" },
	{ "life_cost", "LifeCost" },
	{ "projectile_count", "ProjectileCount" },
	{ "area_of_effect_radius_metres", "AreaOfEffectRadiusMetres" },
	{ "skill_duration_seconds", "Duration" },
	{ "movement_speed_multiplier", "EffectiveMovementSpeedMod" },
}

local function copyFirstOutput(summary, scalarOutputs, mapping)
	for index = 2, #mapping do
		local value = scalarOutputs[mapping[index]]
		if value ~= nil then
			summary[mapping[1]] = value
			return
		end
	end
end

local function addResistanceSummary(summary, scalarOutputs, damageType)
	local prefix = damageType:sub(1, 1):upper() .. damageType:sub(2)
	local capped = scalarOutputs[prefix .. "Resist"]
	local overCap = scalarOutputs[prefix .. "ResistOverCap"]
	if capped ~= nil then
		summary[damageType .. "_resistance_capped"] = capped
	end
	if type(capped) == "number" and type(overCap) == "number" then
		summary[damageType .. "_resistance_uncapped"] = capped + overCap
	elseif capped ~= nil and overCap == nil then
		summary[damageType .. "_resistance_uncapped"] = capped
	elseif capped == dkjson.null or overCap == dkjson.null then
		summary[damageType .. "_resistance_uncapped"] = dkjson.null
	end
end

local function collectCalculations(build, mainEnv, mainOutput, warnings)
	local scalarOutputs = newObject()
	collectPrimitiveObject(mainOutput, scalarOutputs, "calculations.scalar_outputs", warnings, true)

	local summary = newObject()
	for _, mapping in ipairs(summaryMappings) do
		copyFirstOutput(summary, scalarOutputs, mapping)
	end
	for _, damageType in ipairs({ "fire", "cold", "lightning", "chaos" }) do
		addResistanceSummary(summary, scalarOutputs, damageType)
	end
	local skillFlags = mainEnv.player.mainSkill and mainEnv.player.mainSkill.skillFlags or { }
	if scalarOutputs.Speed ~= nil then
		if skillFlags.attack then
			summary.attack_rate = scalarOutputs.Speed
		end
		if skillFlags.spell then
			summary.cast_rate = scalarOutputs.Speed
		end
	end
	return newObject({
		summary = summary,
		scalar_outputs = scalarOutputs,
	})
end

local function getCurrentCalculations(build)
	if type(build) ~= "table" then
		return nil, nil, "No current build is available to export."
	end
	-- Build:OnFrame rebuilds mainOutput only when buildFlag is set. modFlag is
	-- independently used to track unsaved build metadata and is not a pending
	-- calculation signal, so rejecting it would block exports after harmless edits.
	if build.buildFlag then
		return nil, nil, "Calculations are out of date. Wait for Path of Building to finish recalculating, then try the export again."
	end
	local calcsTab = build.calcsTab
	local mainEnv = calcsTab and calcsTab.mainEnv
	local mainOutput = calcsTab and calcsTab.mainOutput
	if type(mainEnv) ~= "table" or type(mainEnv.player) ~= "table" or type(mainOutput) ~= "table"
		or mainEnv.player.output ~= mainOutput then
		return nil, nil, "Current calculation output is unavailable. Finish loading the build and wait for calculations to complete, then try the export again."
	end
	return mainEnv, mainOutput
end

function exporter.collect(build)
	local mainEnv, mainOutput, calculationError = getCurrentCalculations(build)
	if not mainEnv then
		return nil, calculationError
	end

	local warnings = { }
	local exportTable = newObject({
		schema = "pob-analysis-export-v1",
		metadata = collectMetadata(build),
		character = collectCharacter(build),
		active_context = collectActiveContext(build, mainEnv, mainOutput),
		equipment = collectEquipment(build),
		skill_groups = collectSkillGroups(build),
		passive_tree = collectPassiveTree(build),
		configuration = collectConfiguration(build, warnings),
		calculations = collectCalculations(build, mainEnv, mainOutput, warnings),
		export_warnings = warnings,
	})
	return exportTable
end

function exporter.encode(exportTable)
	local ok, encoded = pcall(dkjson.encode, exportTable, { indent = true })
	if not ok then
		return nil, "Could not encode analysis JSON: " .. tostring(encoded)
	end
	return encoded .. "\n"
end

local function fileExists(path)
	local file = io.open(path, "rb")
	if not file then
		return false
	end
	file:close()
	return true
end

local function collisionSafePath(path)
	if not fileExists(path) then
		return path
	end
	local stem, extension = path:match("^(.*)(%.[^/\\%.]+)$")
	if not stem then
		stem, extension = path, ""
	end
	local suffix = 2
	local candidate
	repeat
		candidate = stem .. "_" .. suffix .. extension
		suffix = suffix + 1
	until not fileExists(candidate)
	return candidate
end

local function temporaryPath(path)
	local directory, fileName = path:match("^(.*[/\\])([^/\\]+)$")
	directory = directory or ""
	fileName = fileName or path
	local base = directory .. "." .. fileName .. ".tmp"
	local candidate = base
	local suffix = 2
	while fileExists(candidate) do
		candidate = base .. "_" .. suffix
		suffix = suffix + 1
	end
	return candidate
end

local function cleanupTemporaryFile(path)
	pcall(os.remove, path)
end

local function writeEncodedToPath(encoded, requestedPath)
	local tempPath = temporaryPath(requestedPath)
	local file, openError = io.open(tempPath, "wb")
	if not file then
		return nil, "Could not open a temporary analysis export for writing:\n" .. tempPath .. "\n" .. tostring(openError or "Check that the directory exists and is writable.")
	end
	local writeOk, writeResult, writeError = pcall(file.write, file, encoded)
	if not writeOk or not writeResult then
		pcall(file.close, file)
		cleanupTemporaryFile(tempPath)
		return nil, "Could not write the analysis export:\n" .. requestedPath .. "\n" .. tostring(writeOk and writeError or writeResult)
	end
	local closeCallOk, closeOk, closeError = pcall(file.close, file)
	if not closeCallOk or not closeOk then
		cleanupTemporaryFile(tempPath)
		return nil, "Could not finish writing the analysis export:\n" .. requestedPath .. "\n" .. tostring(closeCallOk and closeError or closeOk)
	end

	-- Resolve the destination only after the complete temporary document is
	-- closed, so an existing export is never opened or truncated.
	local finalPath = collisionSafePath(requestedPath)
	local renameCallOk, renamed, renameError = pcall(os.rename, tempPath, finalPath)
	if not renameCallOk or not renamed then
		cleanupTemporaryFile(tempPath)
		return nil, "Could not move the completed analysis export into place:\n" .. finalPath .. "\n" .. tostring(renameCallOk and renameError or renamed)
	end
	return finalPath
end

local function writeExportTableToPath(exportTable, path)
	local encoded, encodeError = exporter.encode(exportTable)
	if not encoded then
		return nil, encodeError
	end
	return writeEncodedToPath(encoded, path)
end

function exporter.writeToPath(build, path)
	if type(path) ~= "string" or not path:match("%S") then
		return nil, "No output path was provided for the analysis export."
	end
	local exportTable, collectError = exporter.collect(build)
	if not exportTable then
		return nil, collectError
	end
	return writeExportTableToPath(exportTable, path)
end

function exporter.getDefaultDirectory()
	if not main or type(main.userPath) ~= "string" or not main.userPath:match("%S") then
		return nil, "The Path of Building user-data directory is unavailable."
	end
	return main.userPath:gsub("/+$", "") .. "/Exports/"
end

local function sanitiseBuildName(buildName)
	local name = tostring(buildName or ""):lower()
	name = name:gsub("[^%w%._%-]+", "-"):gsub("%-+", "-")
	name = name:gsub("^[%._%-]+", ""):gsub("[%._%-]+$", "")
	if name == "" then
		name = "unnamed-build"
	end
	return name:sub(1, 80)
end

function exporter.getDefaultPath(build, timestamp)
	local directory, directoryError = exporter.getDefaultDirectory()
	if not directory then
		return nil, directoryError
	end
	timestamp = timestamp or os.date("%Y%m%d-%H%M%S")
	local path = directory .. "pob_analysis_" .. sanitiseBuildName(build and build.buildName) .. "_" .. timestamp .. ".json"
	return collisionSafePath(path)
end

function exporter.exportToDefaultPath(build, timestamp)
	local exportTable, collectError = exporter.collect(build)
	if not exportTable then
		return nil, collectError
	end
	local encoded, encodeError = exporter.encode(exportTable)
	if not encoded then
		return nil, encodeError
	end
	local directory, directoryError = exporter.getDefaultDirectory()
	if not directory then
		return nil, directoryError
	end
	if type(MakeDir) ~= "function" then
		return nil, "Path of Building cannot create the analysis export directory on this runtime."
	end
	local makeDirOk, created, makeDirError = pcall(MakeDir, directory)
	if not makeDirOk or not created then
		return nil, "Could not create the analysis export directory:\n" .. directory .. "\n" .. tostring(makeDirOk and makeDirError or created)
	end
	timestamp = timestamp or os.date("%Y%m%d-%H%M%S")
	local path = directory .. "pob_analysis_" .. sanitiseBuildName(build and build.buildName) .. "_" .. timestamp .. ".json"
	return writeEncodedToPath(encoded, path)
end

return exporter
