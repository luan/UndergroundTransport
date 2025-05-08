local Network = {
  -- Data model examples:
  -- [surfaceName] = {
  --   inputs = {
  --    [unitNumber] = {
  --      entity=entity,
  --      leftLane={ item=item, buffer={}, bufferLength=10 },
  --      rightLane={ item=item, buffer={}, bufferLength=10 },
  --    },
  --   },
  --   outputs = {
  --    [unitNumber] = {
  --      entity=entity,
  --      leftLane={ item=item, buffer={}, bufferLength=10 },
  --      rightLane={ item=item, buffer={}, bufferLength=10 },
  --    },
  --   },
  --   demands = {
  --    [itemFilterKey] = {
  --      { port=port1, lane=1 },
  --      { port=port1, lane=2 },
  --      lastIndex=#,
  --    },
  --   },
  --   animationEntities = {
  --     [portEntityUnitNumber] = [animationEntity],
  --   },
  -- }
}

local MIN_BUFFER_LENGTH = 6 * 4 -- 6 tiles
local BUFFER_LENGTH_RECALC_TICKS = 30 * 60 -- 30 seconds in ticks
local INSERTER_SCAN_RADIUS = 3

-- Helper functions for lane operations
function Network.forEachLane(port, callback)
  callback(port.leftLane, 1)
  callback(port.rightLane, 2)
end

function Network.getPortLane(port, lane)
  if lane == 1 then return port.leftLane
  elseif lane == 2 then return port.rightLane end
  return nil
end

function Network.init()
  if not storage.networks then
    storage.networks = {}
  end
end

local function trackInput(network, supplies, port, item, laneIndex, inserter)
  -- We have an item ready, now check if any outputs want it
  local itemKey = Util.itemFilterToKey(item)
  local demands = network.demands[itemKey]
  if not demands or #demands == 0 then return end

  -- Store this input for delivery down below
  local inputs = supplies[itemKey]
  if not inputs then
    inputs = {}
    supplies[itemKey] = inputs
  end
  table.insert(inputs, { port=port, lane=laneIndex, inserter=inserter })
end

-- Collect all inputs with items ready to deliver
local function collectSupplies(network, surface)
  local supplies = {}
  
  for _, inPort in pairs(network.inputs) do
    local entity = inPort.entity
    if not entity or not entity.valid then goto nextPort end
    
    -- Check for items ready on each input port lane
    local canDrop = false
    for idx = 1, 2 do
      local lane = entity.get_transport_line(idx)
      
      -- If there's room to insert an item at the end of the lane, it's not full yet
      if lane.can_insert_at(lane.line_length - 0.25) then
        canDrop = true
        goto nextLane
      end
      
      -- [1] should be the last item on the lane
      trackInput(network, supplies, inPort, lane[1], idx)
      ::nextLane::
    end
    
    if canDrop then
      -- Check if there's an inserter waiting to drop here as well
      local inserters = surface.find_entities_filtered{
        position = entity.position, 
        radius = INSERTER_SCAN_RADIUS, 
        type = "inserter"
      }
      
      for _, inserter in pairs(inserters) do
        if inserter.drop_target == entity
          and inserter.held_stack.count > 0
          and Util.positionsEqual(inserter.held_stack_position, inserter.drop_position) then
          trackInput(network, supplies, inPort, inserter.held_stack, nil, inserter)
        end
      end
    end
    
    ::nextPort::
  end
  
  return supplies
end

-- Distribute items from inputs to outputs
local function distributeItems(network, supplies, recalcBufferLenghts)
  if recalcBufferLenghts then
    -- Reset the buffer lengths for each output so they'll update to the farthest recent input
    for _, outPort in pairs(network.outputs) do
      outPort.bufferLength = MIN_BUFFER_LENGTH
    end
  end

  -- Deliver each input item to the next output buffer in the round-robin list
  for itemKey, inputs in pairs(supplies) do
    local demands = network.demands[itemKey]
    
    Util.tableShuffle(inputs)
    local lastSupplyIdx, inputEntry = next(inputs, nil)
    if not lastSupplyIdx then goto nextItem end

    for _ = 1, #demands do
      if not demands[demands.lastIndex] then
        demands.lastIndex = 1
      end
      
      local outputEntry = demands[demands.lastIndex]
      if outputEntry and outputEntry.port then
        local manhattanDistance = Util.manhattanDistance(
          inputEntry.port.entity.position, 
          outputEntry.port.entity.position
        )

        -- Advance to the next output
        demands.lastIndex = demands.lastIndex + 1

        -- Don't proceed unless there's room in this output buffer
        local output = Network.getPortLane(outputEntry.port, outputEntry.lane)
        output.bufferLength = math.max(output.bufferLength, manhattanDistance * 4) -- 4 items/square 

        if #output.buffer < output.bufferLength then
          if inputEntry.lane then
            -- Insert from one of the input's lanes
            local inputLane = inputEntry.port.entity.get_transport_line(inputEntry.lane)
            Network.insertItem(outputEntry.port, output, inputLane[1], manhattanDistance)
          else
            -- Insert from an inserter ready to drop on the input
            local inserter = inputEntry.inserter
            Network.insertItem(outputEntry.port, output, inserter.held_stack, manhattanDistance)
          end

          -- Advance to the next input
          lastSupplyIdx, inputEntry = next(inputs, lastSupplyIdx)
          if not lastSupplyIdx then goto nextItem end -- No more available
        end
      end
    end
    
    ::nextItem::
  end
end

-- Process output buffers and push items onto output belts
local function processOutputBuffers(network)
  for _, output in pairs(network.outputs) do
    if not output.entity or not output.entity.valid then goto nextOutput end
    
    for idx = 1, 2 do
      local lane = output.entity.get_transport_line(idx)
      if lane.can_insert_at_back() then
        local portLane = Network.getPortLane(output, idx)
        local buffer = portLane.buffer
        if buffer[1] and buffer[1].arriveTick <= game.tick then
          lane.insert_at_back(buffer[1].inventory[1])
          Network.removeItem(output, portLane, 1)
        end
      end
    end
    
    ::nextOutput::
  end
end

function Network.tick()
  local recalcBufferLenghts = not storage.nextRecalcTick or game.tick >= storage.nextRecalcTick
  if recalcBufferLenghts then
    storage.nextRecalcTick = game.tick + BUFFER_LENGTH_RECALC_TICKS
  end

  for _, surface in pairs(game.surfaces) do
    local network = Network.get(surface.name)
    
    -- Step 1: Collect supplies from inputs
    local supplies = collectSupplies(network, surface)
    
    -- Step 2: Distribute items to outputs
    distributeItems(network, supplies, recalcBufferLenghts)
    
    -- Step 3: Process output buffers
    processOutputBuffers(network)
  end
end

function Network.get(surfaceName)
  local network = storage.networks[surfaceName]
  if not network then
    network = { inputs={}, outputs={}, demands={} }
    storage.networks[surfaceName] = network
  end
  return network
end

function Network.getPortGroup(entity)
  local network = Network.get(entity.surface.name)
  return network[Util.isInput(entity) and 'inputs' or 'outputs']
end

function Network.getPort(entity)
  if not Util.isPort(entity) then return nil end
  if Util.isGhost(entity) then
    return {
      entity = entity,
      itemCounts = {},
      leftLane = {},
      rightLane = {},
    }
  end
  return Network.getPortGroup(entity)[entity.unit_number]
end

-- Creates a new port data structure
function Network.createPort(entity, combinator)
  return {
    entity = entity,
    combinator = combinator,
    itemCounts = {},
    leftLane = {
      buffer = {},
      bufferLength = MIN_BUFFER_LENGTH,
    },
    rightLane = {
      buffer = {},
      bufferLength = MIN_BUFFER_LENGTH,
    },
  }
end

-- Inserts an item into the given port and lane's buffer and updates the stack's count
function Network.insertItem(port, lane, itemStack, manhattanDistance)
  local beltStackSize = 1 + port.entity.force.belt_stack_size_bonus
  local insertCount = math.min(itemStack.count, beltStackSize)
  local remainCount = itemStack.count - insertCount

  -- Calculate when the item should arrive based on belt speed and distance
  local outputSpeed = prototypes.entity[port.entity.name].belt_speed

  local entry = {
    inventory = InventoryPool.checkout(),
    arriveTick = game.tick + manhattanDistance / outputSpeed,
  }
  entry.inventory.insert(itemStack)
  entry.inventory[1].count = insertCount
  table.insert(lane.buffer, entry)

  updateItemCount(port, Util.itemFilterToKey(itemStack), insertCount)
  itemStack.count = remainCount
end

-- Removes an item by index from the given port and lane's buffer
function Network.removeItem(port, lane, bufferIndex)
  local entry = lane.buffer[bufferIndex]
  local itemKey = Util.itemFilterToKey(entry.inventory[1])
  local itemCount = entry.inventory[1].count
  InventoryPool.checkin(entry.inventory)
  table.remove(lane.buffer, bufferIndex)

  updateItemCount(port, itemKey, -itemCount)
end

-- Returns a map of itemKey->count for the given port
function Network.getItemCounts(port)
  if not port.itemCounts then
    updateItemCount(port)
  end
  return port.itemCounts
end

-- Updates the static count of items in the given ports buffers
function updateItemCount(port, itemKey, itemCount)
  if not port.itemCounts then
    -- First time accessed we have to count everything in the buffer
    port.itemCounts = {}
    local function countLane(lane)
      for _, entry in ipairs(lane.buffer) do
        local item = entry.inventory[1]
        local key = Util.itemFilterToKey(item)
        if not port.itemCounts[key] then
          port.itemCounts[key] = 0
        end
        port.itemCounts[key] = port.itemCounts[key] + item.count
      end
    end
    countLane(port.leftLane)
    countLane(port.rightLane)
  else
    -- After that we can just increment the existing counts
    if itemKey then
      if not port.itemCounts[itemKey] then
        port.itemCounts[itemKey] = 0
      end
      port.itemCounts[itemKey] = port.itemCounts[itemKey] + itemCount

      if port.itemCounts[itemKey] < 1 then
        port.itemCounts[itemKey] = nil
      end
    end
  end
end

function Network.getDemands(network, itemFilter)
  local demandKey = Util.itemFilterToKey(itemFilter)
  return network.demands[demandKey]
end

function Network.trackDemand(network, itemKey, port, lane)
  if not network.demands[itemKey] then
    network.demands[itemKey] = { lastIndex = 0 }
  end
  table.insert(network.demands[itemKey], { port = port, lane = lane })
end

function Network.removeDemand(network, itemKey, port, lane)
  local demands = network.demands[itemKey]
  if demands then
    Util.tableRemove(demands, function(entry)
      return entry.port == port and entry.lane == lane
    end)
    if #demands == 0 then
      network.demands[itemKey] = nil
    end
  end
end

function Network.updateDemands(network, port, laneIndex, newItemFilter)
  local oldItemFilter = Network.getPortLane(port, laneIndex).item
  if Util.itemFiltersEqual(oldItemFilter, newItemFilter) then return end
  
  if oldItemFilter then
    -- Remove the old demand
    local oldDemandKey = Util.itemFilterToKey(oldItemFilter)
    Network.removeDemand(network, oldDemandKey, port, laneIndex)
  end
  
  if newItemFilter then
    -- Add the new demand
    local newDemandKey = Util.itemFilterToKey(newItemFilter)
    Network.trackDemand(network, newDemandKey, port, laneIndex)
  end
end

-- Gets or creates a combinator for the port
local function getOrCreateCombinator(entity)
  return entity.surface.find_entity(COMBINATOR_TYPE, entity.position) or 
         entity.surface.create_entity{
           name = COMBINATOR_TYPE,
           position = entity.position,
           force = entity.force,
           create_build_effect_smoke = false,
           raise_built = false
         }
end

-- Handle port upgrade scenarios
local function handlePortUpgrade(entity, priorEntity, combinator)
  local isSameDirection = priorEntity and Util.isInput(entity) == Util.isInput(priorEntity)
  local priorGroup = priorEntity and Network.getPortGroup(priorEntity)
  local port = priorGroup and priorGroup[priorEntity.unit_number]
  
  if priorEntity and isSameDirection and port then
    -- For in-place upgrade, preserve the prior port's settings and buffers
    port.entity = entity
    port.combinator = combinator
    priorGroup[priorEntity.unit_number] = nil
    AnimationTracker.teardown(priorEntity)
    return port
  else
    -- Create a new port
    if priorEntity then
      -- Remove the old port if upgrading with a different direction
      Network.removePort(priorEntity)
    end
    return Network.createPort(entity, combinator)
  end
end

function Network.addPort(entity, priorEntity)
  entity.disconnect_linked_belts()
  entity.linked_belt_type = Util.isInput(entity) and 'input' or 'output'

  if Util.isGhost(entity) then return end

  local priorIsGhost = priorEntity and Util.isGhost(priorEntity)
  local network = Network.get(entity.surface.name)
  local portGroup = Network.getPortGroup(entity)
  local combinator = getOrCreateCombinator(entity)
  
  -- Handle upgrades or new ports
  local port = handlePortUpgrade(entity, priorEntity, combinator)
  portGroup[entity.unit_number] = port

  if priorIsGhost and priorEntity.tags then
    Network.importSettings(entity, priorEntity.tags)
  end
  
  AnimationTracker.setup(entity)
  log("Added port: " .. entity.name .. " with unit_number " .. entity.unit_number .. " on surface " .. entity.surface.name)
end

-- Helper function to set combinator signals based on item settings
function Network.setSettings(port, settings)
  if not port.combinator or not port.combinator.valid then return end
  local control = port.combinator.get_or_create_control_behavior()
  if control then
    local section1 = control.get_section(1) or control.add_section()
    local section2 = control.get_section(2) or control.add_section()
    if settings[MOD_DATA_LEFT_LANE] and settings[MOD_DATA_LEFT_LANE].name then
      section1.set_slot(1, {
        value = {
          type = "item",
          name = settings[MOD_DATA_LEFT_LANE].name,
          quality = settings[MOD_DATA_LEFT_LANE].quality or "normal"
        },
        min = 1
      })
    else
      section1.clear_slot(1)
    end
    if settings[MOD_DATA_RIGHT_LANE] and settings[MOD_DATA_RIGHT_LANE].name then
      section2.set_slot(1, {
        value = {
          type = "item",
          name = settings[MOD_DATA_RIGHT_LANE].name,
          quality = settings[MOD_DATA_RIGHT_LANE].quality or "normal"
        },
        min = 1
      })
    else
      section2.clear_slot(1)
    end
  end
end

function Network.getSettings(port)
  if Util.isGhost(port.entity) then
    return port.entity.tags or {}
  end

  if not port.combinator or not port.combinator.valid then return end
  local control = port.combinator.get_or_create_control_behavior()
  if not control then return end
  local section1 = control.get_section(1)
  local section2 = control.get_section(2)
  local leftSlot = section1 and section1.get_slot(1)
  local rightSlot = section2 and section2.get_slot(1)
  return {
    [MOD_DATA_LEFT_LANE] = leftSlot and leftSlot.value,
    [MOD_DATA_RIGHT_LANE] = rightSlot and rightSlot.value
  }
end

function Network.tryGetCombinatorSettings(entity)
  if not entity or not entity.valid then return end
  if entity.ghost_name ~= COMBINATOR_TYPE then return end
  local control = entity.get_or_create_control_behavior()
  if not control then return end
  local section1 = control.get_section(1)
  local section2 = control.get_section(2)
  if not section1 or not section2 then return end
  local leftSlot = section1.get_slot(1)
  local rightSlot = section2.get_slot(1)
  return {
    [MOD_DATA_LEFT_LANE] = leftSlot and leftSlot.value,
    [MOD_DATA_RIGHT_LANE] = rightSlot and rightSlot.value
  }
end

function Network.configurePort(entity, leftLane, rightLane)
  if not entity or not entity.valid then return end
  local settings = createSettings(leftLane, rightLane)
  entity.tags = settings

  if not Util.isGhost(entity) then
    local network = Network.get(entity.surface.name)
    local port = Network.getPort(entity)
    port.tags = settings

    Network.updateDemands(network, port, 1, leftLane)
    Network.updateDemands(network, port, 2, rightLane)
    
    -- Update combinator signals
    if port.combinator and port.combinator.valid then
      Network.setSettings(port, settings)
    end
  end
end

-- Spill lane items onto the ground or to the provided inventory
local function spillLaneItems(entity, lane, spillInventory)
  for _, slot in pairs(lane.buffer) do
    if spillInventory then
      -- Insert into the given inventory
      spillInventory.insert(slot.inventory[1])
    else
      -- Otherwise, spill onto the ground around the port
      entity.surface.spill_item_stack{
        position = entity.position,
        stack = slot.inventory[1],
        allow_belts = false,
      }
    end
    InventoryPool.checkin(slot.inventory)
  end
end

function Network.removePort(entity, spillInventory)
  GUI.checkClose(entity)
  if Util.isGhost(entity) then return end

  local network = Network.get(entity.surface.name)
  local portGroup = Network.getPortGroup(entity)
  local port = portGroup[entity.unit_number]
  if not port then return end

  Network.updateDemands(network, port, 1, nil)
  Network.updateDemands(network, port, 2, nil)
  
  -- Destroy combinator when removing port
  if port.combinator and port.combinator.valid then
    port.combinator.destroy()
  end
  
  portGroup[entity.unit_number] = nil

  spillLaneItems(entity, port.leftLane, spillInventory)
  spillLaneItems(entity, port.rightLane, spillInventory)
  
  AnimationTracker.teardown(entity)
  log("Removed: "..entity.name..", "..entity.surface.name)
end

function createSettings(leftItem, rightItem)
  return {
    [MOD_DATA_LEFT_LANE] = leftItem,
    [MOD_DATA_RIGHT_LANE] = rightItem,
  }
end

-- Updates configuration settings for the given entity from the given tags-compatible table
function Network.importSettings(entity, tags)
  if Util.isGhost(entity) then
    entity.tags = tags
  else
    local leftItem = tags[MOD_DATA_LEFT_LANE]
    local rightItem = tags[MOD_DATA_RIGHT_LANE]
    
    Network.configurePort(entity, leftItem, rightItem)
  end
end

return Network