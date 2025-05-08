
-- Adds in combinators for previously-existing ports
if not storage.networks then return end
if storage.combinatorsAdded then return end

-- Returns configuration settings for the given entity in a tags-compatible table
function exportSettings(entity)
  if Util.isGhost(entity) then
    return entity.tags or {}
  else
    local port = Network.getPort(entity)
    return createSettings(port.leftLane.item, port.rightLane.item)
  end
end

for _, surface in pairs(game.surfaces) do
  local network = Network.get(surface.name)
  if not network then goto nextSurface end
  log("migrating to combinators on "..surface.name)

  for _, output in pairs(network.outputs) do
    local settings = exportSettings(output.entity)
    if settings then
      log("creating combinator for "..output.entity.unit_number)
      local port = Network.getPort(output.entity)
      if not port then goto nextOutput end
      if port.combinator then goto nextOutput end
      local combinator = output.entity.surface.create_entity{
        name = COMBINATOR_TYPE,
        position = output.entity.position,
        force = output.entity.force,
        create_build_effect_smoke = false,
        raise_built = false
      }
      port.combinator = combinator
      local leftLane = settings[MOD_DATA_LEFT_LANE] and settings[MOD_DATA_LEFT_LANE].name or "nil"
      local rightLane = settings[MOD_DATA_RIGHT_LANE] and settings[MOD_DATA_RIGHT_LANE].name or "nil"
      log("left lane: "..leftLane)
      log("right lane: "..rightLane)
      Network.configurePort(output.entity, settings[MOD_DATA_LEFT_LANE], settings[MOD_DATA_RIGHT_LANE])
    end
    ::nextOutput::
  end
  ::nextSurface::
end

storage.combinatorsAdded = true