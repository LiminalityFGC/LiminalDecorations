local config_path = "liminal_decorations.json"

math.randomseed(os.time())

local model = require("models.decoration_models")
local decorations_by_rank = model.DecorationsByRank
local rampage_decorations_by_rank = model.RampageDecorationsByRank
local rank_type = model.RankType
local decoration_category = model.DecorationCategory
local rank_type_to_odds = model.RankTypeToDecorationCategoryOdds
local tmodel = require("models.talisman_models")
local quest_state_params = tmodel.QuestStateParams
local IS_RAMPAGE = false
local quest_params = {}
local quest_rank
local chat_headers = model.ChatHeader

---@return void
local function load_config()
	local config_file = json.load_file(config_path)
	if config_file then
		config = config_file
	else
		config = {}
	end
end

local quest_manager, facility_manager, enemy_manager, message_manager, chat_manager
local player_manager, progress_manager, progress_quest_manager, data_manager

---@return void
local function write_config()
	json.dump_file(config_path, config)
end

local function default_decoration_rewards()
	return {
		total_normal_rolls = 0,
		total_rampage_rolls = 0,
	}
end

local decoration_rewards = default_decoration_rewards()
local chat_messages = {
	[decoration_category.NORMAL] = { [0] = "Normal Decorations found: " },
	[decoration_category.RAMPAGE] = { [0] = "Rampage Decorations found: " },
}

---@return void
local function init_singletons()
	if not quest_manager then
		quest_manager = sdk.get_managed_singleton("snow.QuestManager")
	end

	if not chat_manager then
		chat_manager = sdk.get_managed_singleton("snow.gui.ChatManager")
	end

	if not facility_manager then
		facility_manager = sdk.get_managed_singleton("snow.data.FacilityDataManager")
	end

	if not enemy_manager then
		enemy_manager = sdk.get_managed_singleton("snow.enemy.EnemyManager")
	end

	if not message_manager then
		message_manager = sdk.get_managed_singleton("snow.gui.MessageManager")
	end

	if not player_manager then
		player_manager = sdk.get_managed_singleton("snow.player.PlayerManager")
	end

	if not data_manager then
		data_manager = sdk.get_managed_singleton("snow.data.DataManager")
	end

	if not progress_manager then
		progress_manager = sdk.get_managed_singleton("snow.progress.ProgressManager")
	end

	if not progress_quest_manager then
		progress_quest_manager = sdk.get_managed_singleton("snow.progress.quest.ProgressQuestManager")
	end
end

local check_quest_rank = {
	[0] = rank_type.LOW,
	[1] = rank_type.HIGH,
	[2] = rank_type.MASTER,
}

local function get_quest_rank()
	if not quest_params then
		return 0
	end
	quest_rank = check_quest_rank[quest_params.quest_rank_level]
end

---@return QuestParams
local function init_quest_params()
	quest_params = {}
	for key, value in pairs(quest_state_params) do
		quest_params[key] = quest_manager:call(value)
	end
end

---@return boolean
local function is_qualifying_quest()
	return (not quest_params.is_tour_quest and not quest_params.is_zako_target_quest)
end

local function roll_for(category, cur_chance)
	if cur_chance == 0 then
		cur_chance = rank_type_to_odds[quest_rank][category]
	end

	local progress_multiplier = 1 + (config.hunter_rank / 200) + (config.master_rank / 200)

	local chance
	local out_of

	local category_functions = {
		[decoration_category.NORMAL] = function()
			chance = cur_chance * progress_multiplier
			out_of = math.random(100)
			return chance > out_of
		end,
		[decoration_category.RAMPAGE] = function()
			chance = cur_chance * progress_multiplier
			out_of = math.random(100)
			return chance > out_of
		end,
		["IS_RAMPAGE"] = function()
			chance = cur_chance * progress_multiplier
			out_of = math.random(100)
			return chance > out_of
		end,
	}

	return category_functions[category]()
end

---@param gambling_category DecorationCategory
---@param min integer
---@param max integer
local function roll_for_many(gambling_category, min, max)
	if max - min <= 0 then
		return min
	end

	local collector = min

	for i = 1, max do
		if roll_for(gambling_category, 0) then
			collector = collector + 1
		end
	end

	return collector
end

local function dealer()
	local normal = rank_type_to_odds[quest_rank][decoration_category.NORMAL]
	local rampage = rank_type_to_odds[quest_rank][decoration_category.RAMPAGE]

	decoration_rewards.total_normal_rolls = 0
	decoration_rewards.total_rampage_rolls = 0

	local normal_min = 1
	local normal_max = normal.max_additional_rolls + normal_min

	decoration_rewards.total_normal_rolls = roll_for_many(decoration_category.NORMAL, normal_min, normal_max)

	IS_RAMPAGE = roll_for("IS_RAMPAGE", rampage.base_chance)

	if not IS_RAMPAGE then
		return
	end

	local rampage_min = 0
	local rampage_max = rampage.max_additional_rolls + rampage_min

	decoration_rewards.total_rampage_rolls = roll_for_many(decoration_category.rampage, rampage_min, rampage_max)

	if quest_rank == rank_type.HIGH then
		decoration_rewards.catchup_quest_rank = rank_type.LOW
	end

	if quest_rank == rank_type.MASTER then
		decoration_rewards.catchup_quest_rank = rank_type.HIGH
	end
end

---@return hunter_rank integer
---@return master_rank integer
local function get_player_rank()
	local hunter_rank = math.max(progress_manager:call("get_HunterRank"), 1)
	local master_rank = math.max(progress_manager:call("get_MasterRank"), 1)

	return hunter_rank, master_rank
end

---@return void
local function update_player_progress()
	config.hunter_rank, config.master_rank = get_player_rank()
	write_config()
end

local function roll_for_decorations(deco_category, quantity, qrank)
	if not quantity then
		return
	end

	local rank = qrank or quest_rank

	local decoration_category_table = deco_category == decoration_category.NORMAL and decorations_by_rank
		or rampage_decorations_by_rank

	local decoration_table = decoration_category_table[rank]

	local item_box = data_manager:call("getDecorationsBox()")

	local messages = {}

	table.insert(messages[deco_category], tostring(quantity) .. "\n")

	local pair_buffer = {}

	for i = 1, quantity do
		local decoration_id = math.random(1, #decoration_table)
		local decoration_message = tostring(decoration_table[decoration_id].name)

		data_manager:call("getDecorationsList()")
		item_box:call(
			"tryAddGameItem(snow.equip.DecorationsId, System.Int32)",
			decoration_table[decoration_id].mh_index,
			1
		)
		table.insert(pair_buffer, decoration_message)

		if #pair_buffer == 2 then
			table.insert(messages[deco_category], "-" .. pair_buffer[1] .. ", " .. pair_buffer[2] .. "\n")
			pair_buffer = {}
		end
	end

	if pair_buffer == 1 then
		table.insert(messages[deco_category], "-" .. pair_buffer[1] .. "\n")
	end

	chat_messages[deco_category] = messages[deco_category]
end

local function create_chat()
	if decoration_rewards.total_normal_rolls > 0 then
		chat_manager:call(
			"reqAddChatInfomation",
			chat_headers[quest_rank] .. "<COL YELLOW>-" .. table.concat(chat_messages[decoration_category.NORMAL]),
			2289944406
		)
	end

	if decoration_rewards.total_rampage_rolls > 0 then
		chat_manager:call(
			"reqAddChatInfomation",
			chat_headers[quest_rank] .. "<COL PURPLE>-" .. table.concat(chat_messages[decoration_category.RAMPAGE]),
			2289944406
		)
	end
end

local function add_decoration_to_inv()
	dealer()

	local normal_talisman_quantity = math.max(1, decoration_rewards.total_normal_rolls)
		* rank_type_to_odds[quest_rank]["NORMAL"].base_quantity

	local rampage_talisman_quantity = math.max(0, decoration_rewards.total_rampage_rolls)
		* rank_type_to_odds[quest_rank]["RAMPAGE"].base_quantity

	roll_for_decorations(decoration_category.NORMAL, normal_talisman_quantity)

	roll_for_decorations(decoration_category.RAMPAGE, rampage_talisman_quantity)

	if decoration_rewards.catchup_quest_rank == rank_type.HIGH then
		roll_for_decorations(decoration_category.NORMAL, 3, rank_type.HIGH)
		roll_for_decorations(decoration_category.NORMAL, 3, rank_type.LOW)
	end

	if decoration_rewards.catchup_quest_rank == rank_type.LOW then
		roll_for_decorations(decoration_category.NORMAL, 3, rank_type.LOW)
	end
end

local function check_rewards_on_quest_complete(retval)
	init_singletons()
	init_quest_params()

	quest_rank = get_quest_rank()

	if not is_qualifying_quest() then
		return
	end

	update_player_progress()

	add_decoration_to_inv()

	create_chat()

	chat_messages = {}
	decoration_rewards = {}
end

sdk.hook(
	sdk.find_type_definition("snow.QuestManager"):get_method("setQuestClear"),
	function(args) end,
	check_rewards_on_quest_complete
)

load_config()
