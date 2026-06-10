local function isSkippableWindow(w)
    if not w then return true end

    -- Skip minimized/hidden or non-standard windows
    if w:isMinimized() then return true end
    if not w:isStandard() then return true end

    -- Skip always-on-top / floating windows (PiP commonly appears like this)
    local role = w:role()
    if role == "AXFloatingWindow" then return true end

    local subrole = w:subrole()
    if subrole == "AXSystemDialog" then return true end

    -- Common PiP heuristics by title
    local title = w:title() or ""
    if title:lower():find("picture in picture", 1, true) then return true end
    if title:lower():find("pip", 1, true) then return true end
    if title:lower():find("picture-in-picture", 1, true) then return true end

    -- App-specific exclusions (uncomment/add as needed):
    -- local app = w:application()
    -- local appName = app and app:name() or ""
    -- if appName == "Safari" and title == "" and role == "AXFloatingWindow" then return true end

    return false
end

local function nowMs()
    return hs.timer.absoluteTime() / 1000000
end

local function logStep(startMs, label)
    local t = nowMs()
    print(string.format("[focus-screen] +%.3f ms | %s", t - startMs, label))
    return t
end

local cachedWindowFilter = hs.window.filter.default
local recentWindowByScreen = {}

-- Set to false if you want fastest focus switching without moving pointer.
local MOVE_MOUSE_TO_FOCUSED_WINDOW = true
local MOUSE_WARP_DELAY_SEC = 0

local function isUsableWindow(w)
    if not w then return false end
    local okScreen, s = pcall(function() return w:screen() end)
    if not okScreen or not s then return false end
    local okMinimized, minimized = pcall(function() return w:isMinimized() end)
    if okMinimized and minimized then return false end
    return true
end

local function screenKey(screen)
    if not screen then return nil end
    local uuid = screen.getUUID and screen:getUUID() or nil
    local name = screen.name and screen:name() or nil
    return uuid or name or tostring(screen)
end

local function rememberRecentWindow(w)
    if not w or isSkippableWindow(w) then return end
    if not isUsableWindow(w) then return end

    local s = w:screen()
    local key = screenKey(s)
    if not key then return end

    recentWindowByScreen[key] = w
end

cachedWindowFilter:subscribe(hs.window.filter.windowFocused, function(w)
    rememberRecentWindow(w)
end)

cachedWindowFilter:subscribe(hs.window.filter.windowVisible, function(w)
    rememberRecentWindow(w)
end)

cachedWindowFilter:subscribe(hs.window.filter.windowCreated, function(w)
    rememberRecentWindow(w)
end)

-- Prime cache at config load so first hotkey press is less likely to miss.
for _, w in ipairs(cachedWindowFilter:getWindows()) do
    rememberRecentWindow(w)
end

local function getCandidateWindows(startMs, targetScreen)
    local targetKey = screenKey(targetScreen)
    local recent = targetKey and recentWindowByScreen[targetKey] or nil
    if recent and isUsableWindow(recent) and recent:screen() == targetScreen and not isSkippableWindow(recent) then
        logStep(startMs, "recent cache hit")
        return { recent }, "recent-cache"
    end
    logStep(startMs, "recent cache miss")

    -- Prefer window.filter cache to avoid synchronous AX walk in hs.window.orderedWindows().
    local windowsFromFilter = cachedWindowFilter:getWindows(hs.window.filter.sortByFocusedLast)
    logStep(startMs, string.format("window.filter windows count=%d", #windowsFromFilter))
    if #windowsFromFilter > 0 then
        return windowsFromFilter, "window.filter"
    end

    -- Fallback for rare cases where filter cache is empty.
    local windowsFromOrdered = hs.window.orderedWindows()
    logStep(startMs, string.format("fallback ordered windows count=%d", #windowsFromOrdered))
    return windowsFromOrdered, "orderedWindows"
end

local function focusWindowOnScreen(direction)
    local startMs = nowMs()
    print(string.format("[focus-screen] t=%.3f ms | start direction=%s", startMs, direction))

    local currentWin = hs.window.focusedWindow()
    if not currentWin then
        logStep(startMs, "no focused window")
        return
    end
    logStep(startMs, "got focused window")

    local currentScreen = currentWin:screen()
    if not currentScreen then
        logStep(startMs, "focused window has no screen")
        return
    end
    logStep(startMs, "got current screen")

    local screens = hs.screen.allScreens()
    logStep(startMs, string.format("loaded screens count=%d", #screens))

    local targetScreen = nil
    local curFrame = currentScreen:frame()
    logStep(startMs, "loaded current screen frame")

    if direction == "right" then
        local minX = math.huge
        for _, s in ipairs(screens) do
            local f = s:frame()
            if f.x > curFrame.x and f.x < minX then
                minX = f.x
                targetScreen = s
            end
        end
    elseif direction == "left" then
        local maxX = -math.huge
        for _, s in ipairs(screens) do
            local f = s:frame()
            if f.x < curFrame.x and f.x > maxX then
                maxX = f.x
                targetScreen = s
            end
        end
    end
    logStep(startMs, "finished target screen scan")

    if not targetScreen then
        logStep(startMs, "no target screen found")
        return
    end
    logStep(startMs, "target screen selected")

    -- Focus most recent *non-PiP* window on target screen
    local candidateWindows, source = getCandidateWindows(startMs, targetScreen)
    logStep(startMs, string.format("using window source=%s", source))

    for idx, w in ipairs(candidateWindows) do
        if w:screen() == targetScreen and not isSkippableWindow(w) then
            logStep(startMs, string.format("candidate found at index=%d", idx))
            w:focus()
            logStep(startMs, "focus() called")

            if MOVE_MOUSE_TO_FOCUSED_WINDOW then
                -- Run pointer warp asynchronously so keybind returns immediately.
                hs.timer.doAfter(MOUSE_WARP_DELAY_SEC, function()
                    local f = w:frame()
                    hs.mouse.absolutePosition({
                        x = f.x + f.w / 2,
                        y = f.y + f.h / 2
                    })
                    logStep(startMs, "mouse moved to center (async)")
                end)
                logStep(startMs, "mouse move scheduled")
            else
                logStep(startMs, "mouse move skipped")
            end
            return
        end
    end

    logStep(startMs, "no eligible target window found")
end

-- Key bindings
hs.hotkey.bind({ "ctrl", "shift" }, "Right", function()
    print(string.format("[focus-screen] t=%.3f ms | hotkey Right pressed", nowMs()))
    focusWindowOnScreen("right")
end)

hs.hotkey.bind({ "ctrl", "shift" }, "Left", function()
    print(string.format("[focus-screen] t=%.3f ms | hotkey Left pressed", nowMs()))
    focusWindowOnScreen("left")
end)