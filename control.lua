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

-- Track entities marked for upgrade
if not storage.markedForUpgrade then 
  storage.markedForUpgrade = {} 
end

function markForUpgrade(entity)
  if not storage.markedForUpgrade then storage.markedForUpgrade = {} end
  storage.markedForUpgrade[entity.position.x .. "," .. entity.position.y] = entity
end

function getUpgradeEntity(position)
  if not storage.markedForUpgrade then storage.markedForUpgrade = {} end
  return storage.markedForUpgrade[position.x .. "," .. position.y]
end

function popUpgradeEntity(position)
  local key = position.x .. "," .. position.y
  local entity = storage.markedForUpgrade[key]
  if entity then
    storage.markedForUpgrade[key] = nil
  end
  return entity and entity.name ~= nil and entity or nil
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

  local upgradeEntity = popUpgradeEntity(event.entity.position)
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

-- Record settings from an existing port at the new build location
function handlePreBuildEntity(event)
  markForUpgrade({position=event.position})
end
script.on_event(defines.events.on_pre_build, handlePreBuildEntity)

--Handle preparing for upgrade
function handlePreUpgradeEntity(event)
  local entity = event.entity
  markForUpgrade({
    position=entity.position, 
    name=entity.name, 
    type=entity.type, 
    unit_number=entity.unit_number, 
    surface=entity.surface
  })
end
script.on_event(defines.events.on_marked_for_upgrade, handlePreUpgradeEntity, EVENT_TYPE_FILTER)

--Handle upgrade cancelled
function handleUpgradeCancelled(event)
  popUpgradeEntity(event.entity.position)
end
script.on_event(defines.events.on_cancelled_upgrade, handleUpgradeCancelled, EVENT_TYPE_FILTER)

---Handle the removal of a port
---@param event EventData.on_entity_died|EventData.on_robot_mined_entity|EventData.on_player_mined_entity|EventData.script_rad_destroy
function handleEntityRemoved(event)
  local entity = event.entity
  if not Util.isPort(entity) then return end

  local upgradeEntity = getUpgradeEntity(entity.position)
  if upgradeEntity then
    -- Upgrade this port in-place, save settings for use in handleEntityCreated
    local port = Network.getPort(entity)
    upgradeEntity.name = entity.name
    upgradeEntity.type = entity.type
    upgradeEntity.unit_number = entity.unit_number
    upgradeEntity.surface = entity.surface
    upgradeEntity.settings = entity.tags or Network.getSettings(port) or port.tags
    markForUpgrade(upgradeEntity) -- Update the stored entity
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