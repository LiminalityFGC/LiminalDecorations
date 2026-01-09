local DEFAULT_MESSAGE = '<COL RED>This is a test Message</COL RED>'

local mod_name = 'Liminal Decorations'
local config_path = 'liminal_decorations.json'

math.randomseed(os.time())

local model = require('models.decoration_models')
local decorations_by_rank = model.DecorationsByRank
local rampage_decorations_by_rank = model.RampageDecorationsByRank
local rank_type = model.RankType
local decoration_category = model.DecorationCategory
local rank_type_to_odds = model.RankTypeToDecorationCategoryOdds
local tmodel = require('models.talisman_models')
local quest_state_params = tmodel.QuestStateParams
local IS_RAMPAGE = false
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
local chat_messages = {}

---@return void
local function init_singletons()
  if not quest_manager then
    quest_manager = sdk.get_managed_singleton('snow.QuestManager')
  end

  if not chat_manager then
    chat_manager = sdk.get_managed_singleton('snow.gui.ChatManager')
  end

  if not facility_manager then
    facility_manager = sdk.get_managed_singleton('snow.data.FacilityDataManager')
  end

  if not enemy_manager then
    enemy_manager = sdk.get_managed_singleton('snow.enemy.EnemyManager')
  end

  if not message_manager then
    message_manager = sdk.get_managed_singleton('snow.gui.MessageManager')
  end

  if not player_manager then
    player_manager = sdk.get_managed_singleton('snow.player.PlayerManager')
  end

  if not data_manager then
    data_manager = sdk.get_managed_singleton('snow.data.DataManager')
  end
end

local check_quest_rank = {
  [0] = rank_type.LOW,
  [1] = rank_type.HIGH,
  [2] = rank_type.MASTER,
}

local function get_quest_rank(quest_params)
  return check_quest_rank[quest_params.quest_rank_level]
end

---@return QuestParams
local function get_quest_params()
  local quest_params = {}
  for key, value in pairs(quest_state_params) do
    quest_params[key] = quest_manager:call(value)
  end
  return quest_params
end

---@param quest_params QuestParams
---@return boolean
local function is_qualifying_quest(quest_params)
  return (not quest_params.is_tour_quest and not quest_params.is_zako_target_quest)
end

local function roll_for(quest_params, category, cur_chance)
  progress_multiplier = 1 + (config.hunter_rank / 200) + (config.master_rank / 200)

  local quest_rank = get_quest_rank(quest_params)

  if cur_chance == 0 then
    local cur_chance = rank_type_to_odds[quest_rank][category]
  end

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
    ['IS_RAMPAGE'] = function()
      chance = cur_chance * progress_multiplier
      out_of = math.random(100)
      return chance > out_of
    end,
  }

  return category_functions[category]()
end

---@param quest_params QuestParams
---@param gambling_category DecorationCategory
---@param min integer
---@param max integer
local function roll_for_many(quest_params, gambling_category, min, max)
  local collector = min

  if max - min < 0 then
    return min
  end

  for i = 1, max - 1 do
    if roll_for(quest_params, gambling_category, 0) then
      collector = collector + 1
    end
  end

  return collector
end

local function dealer(quest_params)
  local quest_rank = get_quest_rank(quest_params)

  local normal = rank_type_to_odds[quest_rank][decoration_category.NORMAL]
  local rampage = rank_type_to_odds[quest_rank][decoration_category.RAMPAGE]

  decoration_rewards.total_normal_rolls = 0
  decoration_rewards.total_rampage_rolls = 0

  local min = 0
  local max = normal.max_additional_rolls
  decoration_rewards.total_normal_rolls = roll_for_many(quest_params, decoration_category.NORMAL, min, max) + 1

  IS_RAMPAGE = roll_for(quest_params, 'IS_RAMPAGE', rampage.base_chance)

  if not is_rampage then
    return
  end

  local min = 0
  local max = rampage.max_additional_rolls
  decoration_rewards.total_rampage_rolls = roll_for_many(quest_params, decoration_category.rampage, min, max)
end

---@return hunter_rank integer
---@return master_rank integer
local function get_player_rank()
  local hunter_rank = math.max(progress_manager:call('get_HunterRank'), 1)
  local master_rank = math.max(progress_manager:call('get_MasterRank'), 1)

  return hunter_rank, master_rank
end

---@return void
local function update_player_progress()
  config.hunter_rank, config.master_rank = get_player_rank()
  write_config()
end

local function roll_for_decorations(decoration_table, rolls, quest_rank)
  if not rolls then
    return
  end

  local item_box = data_manager:call('getDecorationsBox()')

  for i = 1, rolls do
    local decoration_id = math.random(1, #decoration_table)
    local decoration_message = tostring(decoration_table[decoration_id].name)
    table.insert(chat_messages, decoration_message)
    data_manager:call('getDecorationsList()')
    item_box:call('tryAddGameItem(snow.equip.DecorationsId, System.Int32)', decoration_table[decoration_id].mh_index, 1)
  end
end

local function create_chat(quest_params)
  local quest_rank = get_quest_rank(quest_params)

  local table_text = ''
  if quest_rank == rank_type.LOW then
    table_text = 'From the Low Rank Table\n'
  elseif quest_rank == rank_type.HIGH then
    table_text = 'From the High Rank Table\n'
  else
    table_text = 'From the Master Rank Table\n'
  end

  chat_manager:call(
    'reqAddChatInfomation',
    'You got some Normal Decorations! \n<COL YELLOW>-' .. table_text .. '-' .. table.concat(chat_messages, ', \n-'),
    2289944406
  ) --,message,0)
end

local function add_decoration_to_inv(quest_params)
  local quest_rank = get_quest_rank(quest_params)

  -- get quantity
  dealer(quest_params)

  local normal_rolls = math.max(1, decoration_rewards.total_normal_rolls) * rank_type_to_odds[quest_rank]['NORMAL'].base_quantity
  local rampage_rolls = math.max(0, decoration_rewards.total_rampage_rolls) * rank_type_to_odds[quest_rank]['RAMPAGE'].base_quantity

  if not IS_RAMPAGE then
    roll_for_decorations(decorations_by_rank[quest_rank], normal_rolls, quest_rank)
  else
    roll_for_decorations(rampage_decorations_by_rank[quest_rank], rampage_rolls, quest_rank)
  end
end

local function check_rewards_on_quest_complete(retval)
  init_singletons()
  if not progress_manager then
    progress_manager = sdk.get_managed_singleton('snow.progress.ProgressManager')
  end

  if not progress_quest_manager then
    progress_quest_manager = sdk.get_managed_singleton('snow.progress.quest.ProgressQuestManager')
  end

  local quest_params = get_quest_params()

  if not is_qualifying_quest(quest_params) then
    return
  end

  update_player_progress()

  add_decoration_to_inv(quest_params)

  create_chat(quest_params)

  print('*******************************************')
  print('DECORATION PARAMS')
  print('*******************************************')
  for key, value in pairs(decoration_rewards) do
    print(key .. ': ' .. value)
  end
  print('\n')

  chat_messages = {}
end

sdk.hook(sdk.find_type_definition('snow.QuestManager'):get_method('setQuestClear'), function(args) end, check_rewards_on_quest_complete)

load_config()
