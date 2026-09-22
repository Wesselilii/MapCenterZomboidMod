-- MapCenter
--
-- Takes over the vanilla "C" button (on the mapUI) with my own button that can change modes
--
-- Modes: Off, Center, Follow
-- 
-- 1. Initialisation   - mode constants, colours, helpers
-- 2. Modes            - reading, setting and cycling modes
-- 3. Center button    - hooking, recolouring the vanilla "C" button
-- 4. Center mode      - the delayed center-on-open used by Center mode
-- 5. Follow mode      - the per-tick camera follow
-- 6. Map open / close - what happens when the map is shown or closed
-- 7. Hooks            - wrapping the ISWorldMap functions

-------------------------------------------------------------------------
-- 1. Initialisation
-------------------------------------------------------------------------

-- Mod namespace
local MapCenter = MapCenter or {}

-- Three modes the existing "C" button can cycle through
MapCenter.Mode = { Center = 1, Follow = 2, Off = 3 }

-- Sets the default button mode on games first boot
MapCenter.config = {
    mode = MapCenter.Mode.Center,
}

-- Button colours per mode, Center mode has no styling to keep the vanilla style
MapCenter.tints = {
    [MapCenter.Mode.Follow] = { -- Green RGBA
        background = { r = 0.10, g = 0.45, b = 0.20, a = 0.85 },
        border     = { r = 0.35, g = 0.90, b = 0.45, a = 1.00 },
    },
    [MapCenter.Mode.Off] = { -- Red RGBA
        background = { r = 0.50, g = 0.10, b = 0.10, a = 0.85 },
        border     = { r = 0.95, g = 0.30, b = 0.30, a = 1.00 },
    },
}

-- Readable names used for console logging.
MapCenter.modeNames = {
    [MapCenter.Mode.Center] = "Center",
    [MapCenter.Mode.Follow] = "Follow",
    [MapCenter.Mode.Off]    = "Off",
}

-- Order the button cycles through, in my case: Center -> Follow -> Off -> Center.
MapCenter.nextMode = {
    [MapCenter.Mode.Center] = MapCenter.Mode.Follow,
    [MapCenter.Mode.Follow] = MapCenter.Mode.Off,
    [MapCenter.Mode.Off]    = MapCenter.Mode.Center,
}

-- Number of game ticks to wait after the map opens before auto-centering onto the player (used later in code)
MapCenter.autoCenterDelay = 2

-- Used for recolloring the buttons by making copies of the RGBA values above
-- This doesnt overwrite the default button color
local function copyRGBA(src)
    if type(src) ~= "table" then return nil end
    return { r = src.r, g = src.g, b = src.b, a = src.a }
end

-- Used for checking if the current in-game map actually exist and if its ready to be used
local function getMap()
    local map = ISWorldMap_instance
    if map and map.javaObject then return map end
    return nil
end

-- Check if mapUI is created so later the follow mode timers can stop themselves once the mapUI is gone/closed by the player
local function isMapOpen(mapUI)
    return mapUI and mapUI.javaObject and mapUI:isVisible()
end

-- Centers the map on the player position using the games already existing center function
-- Doesnt center yet when no `mapUI` is ready
function MapCenter.centerOnPlayer(mapUI)
    mapUI = mapUI or getMap()
    if not mapUI then return end

    -- Both the mapAPI and the vanilla center function must exist to prevent crash when disabled by other mods
    if mapUI.mapAPI and mapUI.onCenterOnPlayer then
        mapUI:onCenterOnPlayer()
    end
end

-----------------------------------------------------------------------------
-- 2. Modes
-----------------------------------------------------------------------------

-- True if 'mode' is the currently active mode.
-- Used to check what mode the player is currently on
function MapCenter.isMode(mode)
    return MapCenter.config.mode == mode
end

-- 1. Switches 'mode'
-- 2. Stores current 'mode' the user is on
-- 3. Starts/stops the timers that belong to the new mode
function MapCenter.setMode(mode)
	-- Get mode
    MapCenter.config.mode = mode

    local mapUI = getMap()

	-- Center mode
    if MapCenter.isMode(MapCenter.Mode.Center) then
        MapCenter.stopFollowTimer()
	-- Follow mode
    elseif MapCenter.isMode(MapCenter.Mode.Follow) then
        MapCenter.stopAutoCenterTimer()
        MapCenter.startFollowTimer(mapUI)
	-- Off
    else
        MapCenter.stopAutoCenterTimer()
        MapCenter.stopFollowTimer()
    end

    MapCenter.applyButtonState(mapUI)

    return mode
end

-- Advances to the next mode in the cycle (see MapCenter.nextMode above in file) and returns the new mode
function MapCenter.cycleMode()
    -- Center is also used as a safety net in case the current mode is somehow unknown
    local nextMode = MapCenter.nextMode[MapCenter.config.mode] or MapCenter.Mode.Center
    return MapCenter.setMode(nextMode)
end

----------------------------------------------------------------------------
-- 3. Center button
----------------------------------------------------------------------------

-- Recolours the vanilla 'C' button to match the current mode: 
-- Currently, Green for Follow, Red for Off, Original for Center.
function MapCenter.applyButtonState(mapUI)
    -- Find existing Center button
	local btn = mapUI and mapUI.centerBtn

    -- No button found, so do nothing
    if not btn or not btn._mapCenterOrig then return end
	
	-- Create a local tint to apply the colors
    local tint = MapCenter.tints[MapCenter.config.mode]

    if tint then -- Use my own colors
        btn.backgroundColor = copyRGBA(tint.background)
        btn.borderColor = copyRGBA(tint.border)
    else -- Use games original color
        btn.backgroundColor = copyRGBA(btn._mapCenterOrig.backgroundColor) or btn.backgroundColor
        btn.borderColor = copyRGBA(btn._mapCenterOrig.borderColor) or btn.borderColor
    end
end

-- Click handler for the "C" button, replacing the vanilla button itself with my own
function MapCenter.onCenterClick(mapUI, button, ...)
    local newMode = MapCenter.cycleMode()

    -- Entering: Center or Follow 
	-- Centers the camera immediately after mode change then leaves the camera where it is and gives the control back to the player
    if newMode == MapCenter.Mode.Center or newMode == MapCenter.Mode.Follow then
        MapCenter.centerOnPlayer(mapUI)
    end
end

-- Replaced the vanilla button with my own every time the map is opened and adds my own handler from above
function MapCenter.hookCenterButton(mapUI)
    local btn = mapUI and mapUI.centerBtn
    if not btn then return false end

    -- Only hook if the current handler is not already mine
    if btn.onclick ~= MapCenter.onCenterClick then
        btn._mapCenterOrig = {
            onclick = btn.onclick,
            backgroundColor = copyRGBA(btn.backgroundColor),
            borderColor = copyRGBA(btn.borderColor),
        }

        btn.onclick = MapCenter.onCenterClick
        btn.target = mapUI
    end

    -- Always refresh to the color, for when another mod has restyled the button vanilla button
    MapCenter.applyButtonState(mapUI)
    return true
end

-----------------------------------------------------------------------------
-- 4. Center mode
-----------------------------------------------------------------------------

-- Local bookkeeping table with needed values to start the correct tick event/timer
local mapShownState = {
    mapUI = nil,
    handled = false,
    explicitLocation = false,
    generation = 0,
}

local autoCenterTimer = nil

-- Cancels a pending auto center
function MapCenter.stopAutoCenterTimer()
    -- Stops the tick event before dropping the timer, otherwise it would keep running forever
    if autoCenterTimer and autoCenterTimer.onTick then
        Events.OnTick.Remove(autoCenterTimer.onTick)
    end
    autoCenterTimer = nil
end

-- Auto-centers on the player after opening the map (with a small delay)
function MapCenter.scheduleAutoCenter(mapUI)
    -- Only one timer is allowed at a time
    MapCenter.stopAutoCenterTimer()
    autoCenterTimer = {
        count = MapCenter.autoCenterDelay,
        mapUI = mapUI,
        generation = mapShownState.generation,
    }

    -- Runs every game tick until the timer reaches zero
    autoCenterTimer.onTick = function()
        -- Timer was cancelled while this tick was already queued.
        if not autoCenterTimer then return end

        autoCenterTimer.count = autoCenterTimer.count - 1
        if autoCenterTimer.count > 0 then return end

        -- Timer done, then decide whether the auto-center is still wanted
        local timer = autoCenterTimer
        MapCenter.stopAutoCenterTimer()

        -- End if the map was closed/reopened
        if timer.generation ~= mapShownState.generation then return end
        -- End if the player switched to Follow or Off mode during centering animation
        if not MapCenter.isMode(MapCenter.Mode.Center) then return end

        if isMapOpen(timer.mapUI) then
            MapCenter.centerOnPlayer(timer.mapUI)
        end
    end

    Events.OnTick.Add(autoCenterTimer.onTick)
end

---------------------------------------------------------------------------
-- 5. Follow mode
---------------------------------------------------------------------------

-- Instead of follow mode snapping to the player (with version 1.2) it now uses the player as anchor point
-- Allowing any camera offset to the player to still drag the map 
-- Keeping free camera movement and a camera that follows the player at the same time
local followTimer = nil

-- Stops following
function MapCenter.stopFollowTimer()
    -- Stops the tick eventk before dropping the timer, otherwise it would keep running forever
    if followTimer and followTimer.onTick then
        Events.OnTick.Remove(followTimer.onTick)
    end
    followTimer = nil
end

-- Starts following the player on the 'mapUI' 
-- Does nothing to the mapUI if the player or its mapAPI aren't available
function MapCenter.startFollowTimer(mapUI)
    -- Only one follow timer at a time
    MapCenter.stopFollowTimer()

    -- Needs a map, Needs the player it belongs to, Needs the mapAPI to move the camera
    if not (mapUI and mapUI.character and mapUI.mapAPI) then return end

    followTimer = {
        mapUI = mapUI,
        lastPlayerX = mapUI.character:getX(),
        lastPlayerY = mapUI.character:getY(),
    }

    -- Runs every game tick while following
    followTimer.onTick = function()
        local map = followTimer and followTimer.mapUI

        -- Map closed stop following
        if not isMapOpen(map) then
            MapCenter.stopFollowTimer()
            return
        end

        -- Prevent crash when Player or mapAPI dissappiers whilst tick event is running
        local player = map.character
        if not player or not map.mapAPI then return end

        -- How far the player moved since last tick
        local currentX = player:getX()
        local currentY = player:getY()
        local deltaX = currentX - followTimer.lastPlayerX
        local deltaY = currentY - followTimer.lastPlayerY

        -- Only move the camera if the player is currently moving and not while the player is dragging the map so the drag isn't fought
        if (deltaX ~= 0 or deltaY ~= 0) and not map.dragging then
            local centerX = map.mapAPI:getCenterWorldX()
            local centerY = map.mapAPI:getCenterWorldY()
            map.mapAPI:centerOn(centerX + deltaX, centerY + deltaY)
        end

        -- Remember where the player is for the next tick
        followTimer.lastPlayerX = currentX
        followTimer.lastPlayerY = currentY
    end

    Events.OnTick.Add(followTimer.onTick)
end

------------------------------------------------------------------------------
-- 6. Map open / close handling
------------------------------------------------------------------------------

-- Used for when the map is opened by in-game items such as Fliers so it doesnt apply the auto centering
local pendingExplicitLocation = nil

function MapCenter.onMapShown(mapUI, explicitLocation)
    if not mapUI then return end

	-- Rechecks if a mod has restyled the in-games items mapUI button
    MapCenter.hookCenterButton(mapUI)

	-- Resets the bookkeeping table so a new one can be created
    if mapShownState.mapUI ~= mapUI then
        mapShownState.mapUI = mapUI
        mapShownState.handled = false
        mapShownState.explicitLocation = false
        mapShownState.generation = mapShownState.generation + 1
    end

    -- Only overwrite the mapShownState.explicitLocation when the caller actually knows the explicitLocation
    if explicitLocation ~= nil then
        mapShownState.explicitLocation = explicitLocation
    end

	-- Makes sure only the ShowWorldMap(mapUI) is loaded and makes it true for bookkeeper
    if mapShownState.handled then return end
    mapShownState.handled = true

	-- Centers the camera back to the player when the mapUI is opened for a second time after explicitLocation has been seen
    if MapCenter.isMode(MapCenter.Mode.Follow) then
        MapCenter.centerOnPlayer(mapUI)
        MapCenter.startFollowTimer(mapUI)
    elseif MapCenter.isMode(MapCenter.Mode.Center) then
        -- If opened by a explicitLocation keep the mapUI camera there and don't center to player
        if not mapShownState.explicitLocation then
            MapCenter.scheduleAutoCenter(mapUI)
        end
    end
    -- If 'mode' is Off then leave the mapUI exactly where the map was last opened
end

-- Resets all timers and resets the bookkeeper so a fresh one can be made without existing conflicts
function MapCenter.onMapClosed()
    MapCenter.stopFollowTimer()
    MapCenter.stopAutoCenterTimer()
	
    pendingExplicitLocation = nil
	
    mapShownState.generation = mapShownState.generation + 1
    mapShownState.mapUI = nil
    mapShownState.handled = false
    mapShownState.explicitLocation = false
end

------------------------------------------------------------------------------
-- 7. Hooks
------------------------------------------------------------------------------

-- Load vanilla functions first then replaces them with my own
local function installHooks()
    -- ISWorldMap might not yet exist when the OnGameStart function is called 
    -- Keeps retrying to prevent _MapCenterHooked from wrapping twice
    if not ISWorldMap or ISWorldMap._MapCenterHooked then return end
    ISWorldMap._MapCenterHooked = true

	-- ShowWorldMap is the vanilla function for when the map is opened
	-- Create my own cx and cy coordinates for explicitLocation, 
	-- so the map can be opened at a specific place without auto centering to the player
    local origShowWorldMap = ISWorldMap.ShowWorldMap
    if origShowWorldMap then
        ISWorldMap.ShowWorldMap = function(playerNum, cx, cy, zoom)
            local explicitLocation = (cx ~= nil and cy ~= nil)
            pendingExplicitLocation = explicitLocation

            origShowWorldMap(playerNum, cx, cy, zoom)

            local mapUI = getMap()
            if mapUI then
                MapCenter.onMapShown(mapUI, explicitLocation)
            end
            pendingExplicitLocation = nil
        end
    end

	-- Create a child for my button in the vanilla mapUI buttons so i can overwrite the vanilla 'C' center button
    local origCreateChildren = ISWorldMap.createChildren
    if origCreateChildren then
        ISWorldMap.createChildren = function(self, ...)
            origCreateChildren(self, ...)
            MapCenter.hookCenterButton(self)
        end
    end

	-- Adds a second enrty point to opening the map so the map can be opened by explicitLocation
    local origAddToUIManager = ISWorldMap.addToUIManager
    if origAddToUIManager then
        ISWorldMap.addToUIManager = function(self, ...)
            origAddToUIManager(self, ...)

            local explicitLocation = pendingExplicitLocation
            pendingExplicitLocation = nil

            MapCenter.onMapShown(self, explicitLocation)
        end
    end

    -- On players map close read the fucntions ment to reset everything,
	-- so my created functions can't duplicate or run in the background whilst the mapUI is closed
    local origClose = ISWorldMap.close
    if origClose then
        ISWorldMap.close = function(self, ...)
            MapCenter.onMapClosed()
            return origClose(self, ...)
        end
    end
end

-- Installs my hooks to overwrite vanilla functions
installHooks()
-- Double check hook install when a game is booted
Events.OnGameStart.Add(installHooks)