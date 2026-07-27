describe("AnalysisJsonExporter", function()
	local dkjson = require "dkjson"
	local exporter = LoadModule("Modules/AnalysisJsonExporter")

	local function unusedTempPath()
		local path = os.tmpname()
		os.remove(path)
		return path
	end

	local function readFile(path)
		local file = assert(io.open(path, "rb"))
		local contents = file:read("*a")
		assert(file:close())
		return contents
	end

	local function makeBuild()
		local output = {
			Life = 1234,
			TotalDPS = 456.5,
			EnabledOutput = true,
			OutputLabel = "current",
		}
		local mainSkill = {
			activeEffect = {
				grantedEffect = { name = "Test Strike" },
				srcInstance = { skillPart = 2 },
			},
			skillFlags = { attack = true },
			skillPartName = "Second Hit",
		}
		local mainEnv = {
			player = {
				output = output,
				mainSkill = mainSkill,
			},
		}
		return {
			buildFlag = false,
			modFlag = false,
			buildName = "Exporter Test",
			dbFileName = "/tmp/exporter-test.xml",
			targetVersion = "3_0",
			characterLevel = 90,
			bandit = "Oak",
			pantheonMajorGod = "Solaris",
			pantheonMinorGod = "Shakari",
			mainSocketGroup = 1,
			controls = { },
			spec = {
				title = "Test Tree",
				treeVersion = "3_27",
				curClassName = "Marauder",
				curAscendClassName = "Juggernaut",
				curSecondaryAscendClassName = "None",
				curClass = { startNodeId = 100 },
				allocNodes = { },
				masterySelections = { },
				jewels = { },
				hashOverrides = { },
			},
			treeTab = {
				activeSpec = 1,
			},
			itemsTab = {
				orderedSlots = { },
				slots = { },
				items = { },
				activeItemSetId = 1,
				activeItemSet = { useSecondWeaponSet = false },
				itemSets = {
					[1] = { title = "Test Items" },
				},
			},
			skillsTab = {
				activeSkillSetId = 1,
				skillSets = {
					[1] = { title = "Test Skills" },
				},
				socketGroupList = { },
			},
			configTab = {
				activeConfigSetId = 1,
				configSets = {
					[1] = { title = "Test Config" },
				},
				input = {
					bandit = "Alira",
					pantheonMajorGod = "Lunaris",
					pantheonMinorGod = "Ryslatha",
					conditionEnemyShocked = true,
				},
				placeholder = { },
				enemyLevel = 83,
			},
			calcsTab = {
				input = {
					skill_number = 1,
					misc_buffMode = "EFFECTIVE",
				},
				mainEnv = mainEnv,
				mainOutput = output,
			},
		}
	end

	it("exports all required top-level sections as valid JSON", function()
		local exportTable, collectError = exporter.collect(makeBuild())
		assert.is_nil(collectError)
		for _, key in ipairs({
			"schema",
			"metadata",
			"character",
			"active_context",
			"equipment",
			"skill_groups",
			"passive_tree",
			"configuration",
			"calculations",
			"export_warnings",
		}) do
			assert.is_not_nil(exportTable[key])
		end

		local encoded, encodeError = exporter.encode(exportTable)
		assert.is_nil(encodeError)
		local decoded, _, decodeError = dkjson.decode(encoded)
		assert.is_nil(decodeError)
		assert.are.equal("pob-analysis-export-v1", decoded.schema)
	end)

	it("handles an otherwise empty or partial build", function()
		local build = makeBuild()
		build.spec = nil
		build.treeTab = nil
		build.itemsTab = nil
		build.skillsTab = nil
		build.configTab = nil
		build.mainSocketGroup = nil

		local exportTable = assert(exporter.collect(build))
		local encoded = assert(exporter.encode(exportTable))
		assert.is_not_nil(dkjson.decode(encoded))
		assert.are.same({ }, exportTable.equipment)
		assert.are.same({ }, exportTable.skill_groups)
	end)

	it("does not emit functions, cyclic tables, or other complex outputs", function()
		local build = makeBuild()
		local cycle = { }
		cycle.self = cycle
		build.configTab.input.cycle = cycle
		build.configTab.input.callback = function() end
		build.calcsTab.mainOutput.Cycle = cycle
		build.calcsTab.mainOutput.Callback = function() end

		local exportTable = assert(exporter.collect(build))
		assert.is_nil(exportTable.configuration.input.cycle)
		assert.is_nil(exportTable.configuration.input.callback)
		assert.is_nil(exportTable.calculations.scalar_outputs.Cycle)
		assert.is_nil(exportTable.calculations.scalar_outputs.Callback)
		local encoded = assert(exporter.encode(exportTable))
		assert.is_nil(encoded:match("function:"))
		assert.is_nil(encoded:match("table: 0x"))
	end)

	it("replaces NaN and infinities with JSON null and warnings", function()
		local build = makeBuild()
		build.calcsTab.mainOutput.NaN = 0 / 0
		build.calcsTab.mainOutput.PositiveInfinity = math.huge
		build.calcsTab.mainOutput.NegativeInfinity = -math.huge

		local exportTable = assert(exporter.collect(build))
		assert.is_true(exportTable.calculations.scalar_outputs.NaN == dkjson.null)
		assert.is_true(exportTable.calculations.scalar_outputs.PositiveInfinity == dkjson.null)
		assert.is_true(exportTable.calculations.scalar_outputs.NegativeInfinity == dkjson.null)
		local encoded = assert(exporter.encode(exportTable))
		assert.is_not_nil(encoded:match('"NaN":null'))
		assert.is_not_nil(encoded:match('"PositiveInfinity":null'))
		assert.is_not_nil(encoded:match('"NegativeInfinity":null'))
		assert.is_true(#exportTable.export_warnings >= 3)
	end)

	it("retains canonical equipment text, sockets, and gem group references", function()
		local build = makeBuild()
		local raw = "Rarity: RARE\nTest Crown\nIron Hat\n--------\n+10 to maximum Life"
		local item = {
			id = 7,
			name = "Test Crown, Iron Hat",
			baseName = "Iron Hat",
			rarity = "RARE",
			itemLevel = 82,
			quality = 20,
			raw = raw,
			sockets = {
				{ color = "R", group = 1 },
				{ color = "G", group = 1 },
			},
		}
		local slot = {
			slotName = "Helmet",
			selItemId = 7,
			controls = { },
		}
		build.itemsTab.items[7] = item
		build.itemsTab.slots.Helmet = slot
		build.itemsTab.orderedSlots[1] = slot
		build.itemsTab.activeItemSet.Helmet = { selItemId = 7 }
		build.skillsTab.socketGroupList[1] = {
			label = "Helmet Skill",
			slot = "Helmet",
			enabled = true,
			gemList = { },
		}

		local exportTable = assert(exporter.collect(build))
		assert.are.equal(raw, exportTable.equipment[1].raw_item_text)
		assert.are.equal("R", exportTable.equipment[1].sockets[1].color)
		assert.are.equal(1, exportTable.equipment[1].socketed_gem_references[1].skill_group_index)
	end)

	it("exports every primitive calculation output and a stable summary", function()
		local exportTable = assert(exporter.collect(makeBuild()))
		assert.are.equal(1234, exportTable.calculations.scalar_outputs.Life)
		assert.are.equal(456.5, exportTable.calculations.scalar_outputs.TotalDPS)
		assert.is_true(exportTable.calculations.scalar_outputs.EnabledOutput)
		assert.are.equal("current", exportTable.calculations.scalar_outputs.OutputLabel)
		assert.are.equal(1234, exportTable.calculations.summary.life)
		assert.are.equal(456.5, exportTable.calculations.summary.total_dps)
	end)

	it("uses deterministic pretty encoding", function()
		local exportTable = assert(exporter.collect(makeBuild()))
		local first = assert(exporter.encode(exportTable))
		local second = assert(exporter.encode(exportTable))
		assert.are.equal(first, second)
		assert.is_not_nil(first:match("\n  "))
		assert.is_true(first:find('"active_context"', 1, true) < first:find('"schema"', 1, true))
	end)

	it("does not mutate or mark the build modified when writing", function()
		local build = makeBuild()
		local originalOutput = build.calcsTab.mainOutput
		local originalInput = build.configTab.input
		local path = unusedTempPath()
		local writtenPath, writeError = exporter.writeToPath(build, path)

		assert.is_nil(writeError)
		assert.are.equal(path, writtenPath)
		assert.is_false(build.buildFlag)
		assert.is_false(build.modFlag)
		assert.is_true(build.calcsTab.mainOutput == originalOutput)
		assert.is_true(build.configTab.input == originalInput)
		os.remove(path)
	end)

	it("places the default file beneath the PoB user-data directory", function()
		local directory = assert(exporter.getDefaultDirectory())
		local path = assert(exporter.getDefaultPath({ buildName = "My Unsafe / Build" }, "20260726-123456"))
		assert.are.equal(directory, path:sub(1, #directory))
		assert.is_not_nil(path:match("pob_analysis_my%-unsafe%-build_20260726%-123456%.json$"))
	end)

	it("selects the next available default path without changing the existing file", function()
		assert(os.execute("mkdir -p /tmp/Exports"))
		local oldUserPath = main.userPath
		local uniqueName = unusedTempPath():gsub("[^%w]+", "-")
		main.userPath = "/tmp"
		local build = { buildName = "Existing " .. uniqueName }
		local timestamp = "20260726-123456"
		local existingPath = assert(exporter.getDefaultPath(build, timestamp))
		local file = assert(io.open(existingPath, "wb"))
		assert(file:write("keep me"))
		assert(file:close())

		local nextPath = assert(exporter.getDefaultPath(build, timestamp))
		main.userPath = oldUserPath

		assert.are.equal(existingPath:gsub("%.json$", "_2.json"), nextPath)
		assert.are.equal("keep me", readFile(existingPath))
		os.remove(existingPath)
	end)

	it("preserves an existing export and selects the next collision-safe path", function()
		local requestedPath = unusedTempPath() .. ".json"
		local file = assert(io.open(requestedPath, "wb"))
		assert(file:write("existing export"))
		assert(file:close())

		local writtenPath, writeError = exporter.writeToPath(makeBuild(), requestedPath)
		assert.is_nil(writeError)
		assert.are.equal(requestedPath:gsub("%.json$", "_2.json"), writtenPath)
		assert.are.equal("existing export", readFile(requestedPath))
		assert.is_not_nil(dkjson.decode(readFile(writtenPath)))

		os.remove(requestedPath)
		os.remove(writtenPath)
	end)

	it("makes two default exports with the same timestamp use different files", function()
		assert(os.execute("mkdir -p /tmp/Exports"))
		local oldUserPath = main.userPath
		local oldMakeDir = _G.MakeDir
		local uniqueName = unusedTempPath():gsub("[^%w]+", "-")
		main.userPath = "/tmp"
		_G.MakeDir = function()
			return true
		end
		local build = makeBuild()
		build.buildName = "Collision " .. uniqueName
		local timestamp = "20260726-123456"

		local firstPath, firstError = exporter.exportToDefaultPath(build, timestamp)
		local firstContents = firstPath and readFile(firstPath)
		local secondPath, secondError = exporter.exportToDefaultPath(build, timestamp)
		_G.MakeDir = oldMakeDir
		main.userPath = oldUserPath

		assert.is_nil(firstError)
		assert.is_nil(secondError)
		assert.is_not_equal(firstPath, secondPath)
		assert.are.equal(firstPath:gsub("%.json$", "_2.json"), secondPath)
		assert.are.equal(firstContents, readFile(firstPath))
		assert.is_not_nil(dkjson.decode(readFile(secondPath)))

		os.remove(firstPath)
		os.remove(secondPath)
	end)

	it("cleans up the temporary file when writing fails", function()
		local requestedPath = unusedTempPath() .. ".json"
		local realOpen = io.open
		local tempPath
		io.open = function(path, mode)
			if mode == "wb" and path:match("%.tmp") then
				tempPath = path
				local underlying = assert(realOpen(path, mode))
				return {
					write = function(_, contents)
						underlying:write(contents:sub(1, 12))
						return nil, "forced write failure"
					end,
					close = function()
						return underlying:close()
					end,
				}
			end
			return realOpen(path, mode)
		end

		local writtenPath, writeError = exporter.writeToPath(makeBuild(), requestedPath)
		io.open = realOpen

		assert.is_nil(writtenPath)
		assert.is_not_nil(writeError:match("forced write failure"))
		assert.is_nil(realOpen(requestedPath, "rb"))
		assert.is_not_nil(tempPath)
		assert.is_nil(realOpen(tempPath, "rb"))
	end)

	it("cleans up the temporary file when closing fails", function()
		local requestedPath = unusedTempPath() .. ".json"
		local realOpen = io.open
		local tempPath
		io.open = function(path, mode)
			if mode == "wb" and path:match("%.tmp") then
				tempPath = path
				local underlying = assert(realOpen(path, mode))
				return {
					write = function(_, contents)
						return underlying:write(contents)
					end,
					close = function()
						underlying:close()
						return nil, "forced close failure"
					end,
				}
			end
			return realOpen(path, mode)
		end

		local writtenPath, writeError = exporter.writeToPath(makeBuild(), requestedPath)
		io.open = realOpen

		assert.is_nil(writtenPath)
		assert.is_not_nil(writeError:match("forced close failure"))
		assert.is_nil(realOpen(requestedPath, "rb"))
		assert.is_not_nil(tempPath)
		assert.is_nil(realOpen(tempPath, "rb"))
	end)

	it("cleans up the temporary file when the atomic rename fails", function()
		local requestedPath = unusedTempPath() .. ".json"
		local realRename = os.rename
		local tempPath
		os.rename = function(from)
			tempPath = from
			return nil, "forced rename failure"
		end

		local writtenPath, writeError = exporter.writeToPath(makeBuild(), requestedPath)
		os.rename = realRename

		assert.is_nil(writtenPath)
		assert.is_not_nil(writeError:match("forced rename failure"))
		assert.is_nil(io.open(requestedPath, "rb"))
		assert.is_not_nil(tempPath)
		assert.is_nil(io.open(tempPath, "rb"))
	end)

	it("uses current configuration character choices instead of stale legacy build fields", function()
		local exportTable = assert(exporter.collect(makeBuild()))
		assert.are.equal("Alira", exportTable.character.bandit)
		assert.are.equal("Lunaris", exportTable.character.pantheon_major_god)
		assert.are.equal("Ryslatha", exportTable.character.pantheon_minor_god)
		assert.are.equal("Alira", exportTable.configuration.input.bandit)
		assert.are.equal("Lunaris", exportTable.configuration.input.pantheonMajorGod)
		assert.are.equal("Ryslatha", exportTable.configuration.input.pantheonMinorGod)
		assert.are.equal("Alira", exportTable.configuration.effective.bandit)
	end)

	it("falls back to legacy build character choices when configuration values are unavailable", function()
		local build = makeBuild()
		build.configTab.input.bandit = nil
		build.configTab.input.pantheonMajorGod = nil
		build.configTab.input.pantheonMinorGod = nil

		local character = assert(exporter.collect(build)).character
		assert.are.equal("Oak", character.bandit)
		assert.are.equal("Solaris", character.pantheon_major_god)
		assert.are.equal("Shakari", character.pantheon_minor_god)
	end)

	it("exports primitive active skill settings including Winter Orb stages", function()
		local build = makeBuild()
		local mainSkill = build.calcsTab.mainEnv.player.mainSkill
		mainSkill.activeEffect.grantedEffect.name = "Winter Orb"
		mainSkill.activeEffect.srcInstance = {
			skillPart = 3,
			skillMode = "CHANNEL",
			skillStageCount = 10,
			skillMineCount = 7,
			skillMinion = "SummonedPhantasm",
			skillMinionSkill = 2,
			skillMinionItemSet = 4,
			effect = { internal = true },
			cache = { internal = true },
			callback = function() end,
		}

		local context = assert(exporter.collect(build)).active_context
		assert.are.same({
			skill_part = 3,
			skill_mode = "CHANNEL",
			skill_stage_count = 10,
			skill_mine_count = 7,
			skill_minion = "SummonedPhantasm",
			skill_minion_skill = 2,
			skill_minion_item_set = 4,
		}, context.active_skill_settings)
		assert.are.equal(3, context.selected_skill_part)
		assert.are.equal("CHANNEL", context.selected_skill_mode)
		assert.is_nil(context.active_skill_settings.effect)
		assert.is_nil(context.active_skill_settings.cache)
		assert.is_nil(context.active_skill_settings.callback)
	end)

	it("exports raw and effective configuration using ConfigTab resolution rules", function()
		local build = makeBuild()
		build.configTab.input.conditionStationary = 0
		build.configTab.placeholder.conditionStationary = 4
		build.configTab.input.enemyFireResist = 0
		build.configTab.placeholder.enemyFireResist = -10
		build.configTab.input.overrideCrabBarriers = 0
		build.configTab.placeholder.overrideCrabBarriers = 8
		build.configTab.placeholder.linkedSourceRate = 1.25
		build.configTab.input.conditionMoving = true
		build.configTab.placeholder.conditionMoving = true
		build.configTab.input.customMods = ""
		build.configTab.placeholder.customMods = "placeholder text is not applied"
		build.configTab.placeholder.pantheonMajorGod = "Solaris"

		local configuration = assert(exporter.collect(build)).configuration
		assert.are.equal(0, configuration.input.conditionStationary)
		assert.are.equal(4, configuration.placeholder.conditionStationary)
		assert.are.equal(4, configuration.effective.conditionStationary)
		assert.are.equal(-10, configuration.effective.enemyFireResist)
		assert.are.equal(0, configuration.effective.overrideCrabBarriers)
		assert.are.equal(1.25, configuration.effective.linkedSourceRate)
		assert.is_true(configuration.effective.conditionMoving)
		assert.are.equal("", configuration.effective.customMods)
		assert.are.equal("Lunaris", configuration.effective.pantheonMajorGod)
		assert.are.equal(83, configuration.effective_enemy_level)
	end)

	it("preserves unknown configuration values but omits uncertain effective values", function()
		local build = makeBuild()
		build.configTab.input.futureOption = 17
		build.configTab.placeholder.futureOption = 9

		local exportTable = assert(exporter.collect(build))
		assert.are.equal(17, exportTable.configuration.input.futureOption)
		assert.are.equal(9, exportTable.configuration.placeholder.futureOption)
		assert.is_nil(exportTable.configuration.effective.futureOption)
		assert.are.equal(1, #exportTable.export_warnings)
		assert.is_not_nil(exportTable.export_warnings[1]:match("unknown configuration variable"))
		assert.is_not_nil(exportTable.export_warnings[1]:match("futureOption"))
	end)

	it("filters unsupported key types before deterministic sorting", function()
		local build = makeBuild()
		build.configTab.input[{ }] = "table key"
		build.configTab.input[true] = "boolean key"
		build.configTab.input[function() end] = "function key"
		build.calcsTab.mainOutput[{ }] = "table key"
		build.calcsTab.mainOutput[false] = "boolean key"

		local exportTable = assert(exporter.collect(build))
		assert.is_not_nil(exporter.encode(exportTable))
		local warnings = table.concat(exportTable.export_warnings, "\n")
		assert.is_not_nil(warnings:match("configuration%.input: skipped 3"))
		assert.is_not_nil(warnings:match("calculations%.scalar_outputs: skipped 2"))
	end)

	it("exports passive override stat lines and deterministic tattoo counts", function()
		local build = makeBuild()
		build.spec.hashOverrides[42] = {
			dn = "Tattoo of Testing",
			overrideType = "TestingTattoo",
			isTattoo = true,
			sd = { "+5 to Testing", false, 2, { internal = true } },
			targetType = "Small Attribute",
			targetValue = "+10 to Strength",
			icon = "Art/Test.png",
			activeEffectImage = "Art/TestBackground.png",
			MinimumConnected = 1,
			MaximumConnected = 3,
			legacy = false,
			stats = { internal = true },
			modList = { internal = true },
		}
		build.spec.allocatedTattooTypes = {
			ZuluTattoo = 2,
			AlphaTattoo = 1,
		}

		local passiveTree = assert(exporter.collect(build)).passive_tree
		local modification = passiveTree.node_modifications[1]
		assert.are.equal(42, modification.node_id)
		assert.are.equal("Tattoo of Testing", modification.name)
		assert.are.equal("TestingTattoo", modification.type)
		assert.is_true(modification.is_tattoo)
		assert.are.same({ "+5 to Testing", false, 2 }, modification.stat_lines)
		assert.are.equal("Small Attribute", modification.target_type)
		assert.are.equal("+10 to Strength", modification.target_value)
		assert.is_nil(modification.stats)
		assert.is_nil(modification.modList)
		assert.are.same({
			{ type = "AlphaTattoo", count = 1 },
			{ type = "ZuluTattoo", count = 2 },
		}, passiveTree.allocated_tattoo_types)
	end)

	it("does not infer an active loadout from matching titles", function()
		local build = makeBuild()
		build.spec.title = "Coincidental Name"
		build.itemsTab.itemSets[1].title = "Coincidental Name"
		build.skillsTab.skillSets[1].title = "Coincidental Name"
		build.configTab.configSets[1].title = "Coincidental Name"

		local metadata = assert(exporter.collect(build)).metadata
		assert.is_nil(metadata.active_loadout_index)
		assert.is_nil(metadata.active_loadout_link_id)
		assert.is_nil(metadata.active_loadout_name)
		assert.are.equal(1, metadata.active_passive_tree_index)
		assert.are.equal(1, metadata.active_item_set_id)
		assert.are.equal(1, metadata.active_skill_set_id)
		assert.are.equal(1, metadata.active_config_set_id)
	end)

	it("exports a loadout only from exact special-link mappings", function()
		local build = makeBuild()
		build.treeListSpecialLinks = { boss = { setId = 1, setName = "Bossing" } }
		build.itemListSpecialLinks = { boss = { setId = 1 } }
		build.skillListSpecialLinks = { boss = { setId = 1 } }
		build.configListSpecialLinks = { boss = { setId = 1 } }

		local metadata = assert(exporter.collect(build)).metadata
		assert.are.equal("boss", metadata.active_loadout_link_id)
		assert.are.equal("Bossing", metadata.active_loadout_name)
		assert.is_nil(metadata.active_loadout_index)
	end)

	it("aborts instead of exporting stale calculations", function()
		local build = makeBuild()
		build.buildFlag = true
		local exportTable, errMsg = exporter.collect(build)
		assert.is_nil(exportTable)
		assert.is_not_nil(errMsg:match("out of date"))
		assert.is_not_nil(errMsg:match("finish recalculating"))

		local path = os.tmpname()
		local file = assert(io.open(path, "wb"))
		assert(file:write("existing contents"))
		assert(file:close())
		local writtenPath, writeError = exporter.writeToPath(build, path)
		assert.is_nil(writtenPath)
		assert.is_not_nil(writeError:match("out of date"))
		file = assert(io.open(path, "rb"))
		assert.are.equal("existing contents", file:read("*a"))
		assert(file:close())
		os.remove(path)
	end)

	it("does not treat the save-dirty modFlag as stale calculation state", function()
		local build = makeBuild()
		build.modFlag = true
		assert.is_not_nil(exporter.collect(build))
	end)

	it("aborts when the authoritative calculation environment is unavailable", function()
		local build = makeBuild()
		build.calcsTab.mainEnv.player.output = { Life = 9999 }
		local exportTable, errMsg = exporter.collect(build)
		assert.is_nil(exportTable)
		assert.is_not_nil(errMsg:match("unavailable"))
		assert.is_not_nil(errMsg:match("wait for calculations"))
	end)

	it("collects and encodes the initialized Path of Building model", function()
		newBuild()
		local exportTable, collectError = exporter.collect(build)
		assert.is_nil(collectError)
		assert.are.equal(build.characterLevel, exportTable.character.level)
		assert.are.equal(build.calcsTab.mainOutput.Life, exportTable.calculations.scalar_outputs.Life)
		assert.is_not_nil(exporter.encode(exportTable))
	end)
end)
