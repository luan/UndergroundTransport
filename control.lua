Util = require("scripts/util")
InventoryPool = require("scripts/inventory_pool")
AnimationTracker = require("scripts/animation_tracker")
Network = require("scripts/network")
GUI = require("scripts/gui")
UndoTracker = require("scripts/undo_tracker")

require("scripts/constants")

script.on_init(Network.init)
script.on_event(defines.events.on_tick, function ()
  Network.tick()
  GUI.updateInventory()
  UndoTracker.tick()
end)

local PRE_BUILD_ENTITY = nil

function markForUpgrade(entity, settings)
  if not storage.markedForUpgrade then storage.markedForUpgrade = {} end
  storage.markedForUpgrade[entity.unit_number] = { position=entity.position, settings=settings }
end

function peekUpgradeEntity(unitNumber)
  if not storage.markedForUpgrade then storage.markedForUpgrade = {} end
  return storage.markedForUpgrade[unitNumber]
end

function popUpgradeEntity(unitNumber)
  if not storage.markedForUpgrade then storage.markedForUpgrade = {} end
  local upgradeEntity = storage.markedForUpgrade[unitNumber]
  storage.markedForUpgrade[unitNumber] = nil
  return upgradeEntity
end

---Handles creation of a port
---@param event EventData.on_built_entity|EventData.on_robot_built_entity|EventData.on_entity_cloned|EventData.script_raised_built|EventData.script_raised_revive
function handleEntityCreated(event)
  if Util.isGhost(event.entity) then
    local settings = Network.tryGetCombinatorSettings(event.entity)
    if settings then
      local entities = event.entity.surface.find_entities_filtered({position=event.entity.position, radius=0, type="entity-ghost"})
      for _, entity in pairs(entities) do
        if Util.isPort(entity) then
          entity.tags = settings
        end
      end
    end
  end

  local upgradeEntity = popUpgradeEntity(event.entity.unit_number)
  if not upgradeEntity and PRE_BUILD_ENTITY and Util.positionsEqual(PRE_BUILD_ENTITY.position, event.entity.position) and PRE_BUILD_ENTITY.name then
    upgradeEntity = PRE_BUILD_ENTITY
    PRE_BUILD_ENTITY = nil
  end
  local entity = event.entity or event.destination
  if not Util.isPort(entity) then return end
  Network.addPort(entity, upgradeEntity)

  local settings = (upgradeEntity and upgradeEntity.settings) or event.tags or (event.stack and event.stack.tags)
  if settings and next(settings) ~= nil then
    Network.configurePort(entity, settings[MOD_DATA_LEFT_LANE], settings[MOD_DATA_RIGHT_LANE])
  end
end
script.on_event(defines.events.on_entity_cloned, handleEntityCreated, EVENT_TYPE_FILTER)
script.on_event(defines.events.on_built_entity, handleEntityCreated, EVENT_TYPE_FILTER)
script.on_event(defines.events.on_robot_built_entity, handleEntityCreated, EVENT_TYPE_FILTER)
script.on_event(defines.events.script_raised_built, handleEntityCreated, EVENT_TYPE_FILTER)
script.on_event(defines.events.script_raised_revive, handleEntityCreated, EVENT_TYPE_FILTER)
script.on_event(defines.events.on_space_platform_built_entity, handleEntityCreated, EVENT_TYPE_FILTER)

-- Handle changes to the logistic slot of a combinator
function handleEntityLogisticSlotChanged(event)
  log("Logistic slot changed: "..event.entity.name)
end
script.on_event(defines.events.on_entity_logistic_slot_changed, handleEntityLogisticSlotChanged)

-- Record settings from an existing port at the new build locaation so we can transfer them to the new port
function handlePreBuildEntity(event)
  PRE_BUILD_ENTITY = {position=event.position}
end
script.on_event(defines.events.on_pre_build, handlePreBuildEntity)


--Handle preparing for upgrade
function handlePreUpgradeEntity(event)
  markForUpgrade(event.entity)
end
script.on_event(defines.events.on_marked_for_upgrade, handlePreUpgradeEntity, EVENT_TYPE_FILTER)

--Handle upgrade cancelled
function handleUpgradeCancelled(event)
  popUpgradeEntity(event.entity.unit_number)
end
script.on_event(defines.events.on_cancelled_upgrade, handleUpgradeCancelled, EVENT_TYPE_FILTER)


---Handle the removal of a port
---@param event EventData.on_entity_died|EventData.on_robot_mined_entity|EventData.on_player_mined_entity|EventData.script_rad_destroy
function handleEntityRemoved(event)
  local entity = event.entity
  if not Util.isPort(entity) then return end

  local upgradeEntity = PRE_BUILD_ENTITY or peekUpgradeEntity(entity.unit_number)
  if upgradeEntity and Util.positionsEqual(upgradeEntity.position, entity.position) then
    -- Upgrade this port in-place, so save some data_ModSetting for use in handleEntityCreated
    local port = Network.getPort(entity)
    if PRE_BUILD_ENTITY then
      PRE_BUILD_ENTITY.name = entity.name
      PRE_BUILD_ENTITY.type = entity.type
      PRE_BUILD_ENTITY.unit_number = entity.unit_number
      PRE_BUILD_ENTITY.surface = entity.surface
      PRE_BUILD_ENTITY.settings = entity.tags or Network.getSettings(port) or port.tags
    else
      markForUpgrade(entity, entity.tags or Network.getSettings(port) or port.tags)
    end
  else
    Network.removePort(entity, event.buffer)
  end
  AnimationTracker.teardown(entity)
  GUI.checkClose(entity)
end
script.on_event(defines.events.on_entity_died, handleEntityRemoved, EVENT_TYPE_FILTER)
script.on_event(defines.events.on_robot_mined_entity, handleEntityRemoved, EVENT_TYPE_FILTER)
script.on_event(defines.events.on_player_mined_entity, handleEntityRemoved, EVENT_TYPE_FILTER)
script.on_event(defines.events.script_raised_destroy, handleEntityRemoved, EVENT_TYPE_FILTER)
script.on_event(defines.events.on_space_platform_mined_entity, handleEntityRemoved, EVENT_TYPE_FILTER)



-- Copy output configuration to the blueprint entities
function handleBlueprintSetup(event)
  if not event.stack or not event.stack.is_blueprint_setup() then return end

  local blueprintEntities = event.stack.get_blueprint_entities()
  if not blueprintEntities then return end

  local mapping = event.mapping.get()
  for _, bpEntity in pairs(blueprintEntities) do
    if not Util.isPort(bpEntity) then goto continue end

    local worldEntity = mapping[bpEntity.entity_number]
    if not worldEntity then goto continue end
    local port = Network.getPort(worldEntity)
    if not port then goto continue end

    -- local settings = Network.getSettings(port)
    -- event.stack.set_blueprint_entity_tags(bpEntity.entity_number, settings)
    -- event.stack.set_entity_filter(bpEntity.entity_number, worldEntity.name)
    ::continue::
  end
end
script.on_event(defines.events.on_player_setup_blueprint, handleBlueprintSetup)


-- function handleBluePrintConfigure(event)
--   log("Blueprint configured: "..event.entity.name)
-- end
-- script.on_event(defines.events.on_built_entity, handleBluePrintConfigure)


-- Handle settings paste
function handleSettingsPaste(event)
  if not Util.isOutput(event.source) then return end
  local sourcePort = Network.getPort(event.source)
  if not sourcePort then return end
  local settings = Network.getSettings(sourcePort)
  if not settings then return end

  local entity = event.destination
  if not Util.isOutput(entity) then return end
  Network.importSettings(entity, settings)
end
script.on_event(defines.events.on_entity_settings_pasted, handleSettingsPaste)

-- Open output port GUI
function handleLeftClick(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  GUI.closeOutputPortGui(event)

  local entity = player.selected
  if not entity or not Util.isPort(entity) or Util.isInput(entity) then return end

  -- TODO: Don't open on clicking for copy/paste!
  -- check if copy/paste tool is active?
  GUI.openOutputPortGui(player, entity)
end
script.on_event(LEFT_CLICK_EVENT, handleLeftClick)



-- function handleGuiOpened(event)
--   if event.gui_type ~= defines.gui_type.entity then return end
  
--   local entity = event.entity
--   if not Util.isPort(entity) then return end

--   log("Opened: "..entity.name)
-- end
-- script.on_event(defines.events.on_gui_opened, handleGuiOpened)


-- function handleEntitySelected(event)
--   local player = game.get_player(event.player_index)
--   local entity = player.selected
--   if not entity or not Util.isPort(entity) then return end

--   log("Opened: "..entity.name)
-- end
-- script.on_event(defines.events.on_selected_entity_changed , handleEntitySelected)

-- function handleCursorChanged(event)
--   local player = game.get_player(event.player_index)
--   local item = player.cursor_stack
--   if not item or not item.valid_for_read then return end
--   if not Util.isPort(item) then return end
  
--   -- TODO: Show correct entity ghost for output ports
--   if Util.isOutput(item) then
--     -- player.cursor_stack.direc
--   end
--   -- log(serpent.line(item))
--   -- item.linked_belt_type = Util.isInput(item) and 'input' or 'output'
-- end
-- script.on_event(defines.events.on_player_cursor_stack_changed, handleCursorChanged)

-- Handle rotation of port entities
function handleEntityRotated(event)
  local entity = event.entity
  if not Util.isPort(entity) then return end
  
  local network = Network.get(entity.surface.name)
  local animEntity = network.animationEntities[entity.unit_number]
  if animEntity and animEntity.valid then
    animEntity.direction = entity.direction
  end
end
script.on_event(defines.events.on_player_rotated_entity, handleEntityRotated)