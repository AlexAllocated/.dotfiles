local lutils = require ("linking-utils")
local cutils = require ("common-utils")

local function process_name (name)
  return (name or ""):lower ():gsub ("^%.", ""):gsub ("%-wrapped$", ""):gsub ("%.exe$", "")
end

SimpleEventHook {
  name = "amps/default-application-route",
  after = { "linking/find-defined-target", "linking/find-filter-target", "linking/find-media-role-target", "linking/find-media-role-sink-target" },
  before = "linking/find-default-target",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
      Constraint { "media.class", "c", "Stream/Input/Audio", "Stream/Output/Audio" },
    },
  },
  execute = function (event)
    local _, om, si, props, flags, selected = lutils:unwrap_select_target_event (event)
    if selected or cutils.parseBool (props ["stream.capture.sink"]) or
        cutils.parseBool (props ["stream.monitor"]) or
        (props ["application.name"] or ""):match ("^AMPS") or
        (props ["node.name"] or ""):match ("^amps[.]") then
      return
    end
    local input = props ["media.class"] == "Stream/Input/Audio"
    local bus = input and "comms_send" or "game"
    local executable = process_name (props ["application.process.binary"])
    local application = process_name (props ["application.name"])
    local metadata = cutils.get_default_metadata_object ()
    local raw = metadata and metadata:find (0, "amps.routes")
    if raw then
      local ok, routes = pcall (function () return Json.Raw (raw):parse () end)
      if ok and routes then
        for _, route in ipairs (routes) do
          local name = process_name (route.process)
          if name == executable or name == application then
            bus = (input and route.input or route.output) or bus
            break
          end
        end
      end
    end
    local target = om:lookup {
      type = "SiLinkable",
      Constraint { "node.name", "=", "amps." .. bus .. (input and "" or ".sink") },
      Constraint { "item.node.direction", "=", input and "output" or "input" },
    }
    if target and lutils.canLink (props, target) then
      local compatible, passthrough = lutils.checkPassthroughCompatibility (si, target)
      if compatible then
        flags.can_passthrough = passthrough
        event:set_data ("target", target)
      end
    end
  end,
}:register ()
