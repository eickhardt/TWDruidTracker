local _, class = UnitClass("player")
if class ~= "DRUID" then return end

FeralDebuffTracker = {}
FeralDebuffTracker.DEBUG_DEBUFF_CACHE = false
local addon = FeralDebuffTracker
addon.frame = getglobal("FeralDebuffTrackerFrame")
addon.activeDebuffs = {}
addon.lastKnownComboPoints = 0
addon.lastNonZeroComboPoints = 0
-- Per-target cache: map target key (GUID or name) -> table of debuffs
addon.debuffCache = {}
addon.currentTargetGUID = nil
addon.currentTargetName = nil
addon.currentTargetKey = nil
-- keys recently deleted with timestamp to avoid re-saving immediately after death
addon.recentlyDeleted = {}
addon.DEBUFF_CACHE_TTL_MINUTES = 10
-- Default to false to avoid spamming chat during normal play.
-- Toggle for concise per-Rip-tick logging (disabled by default).

function addon:SaveActiveDebuffs(key)
    if not key then return end
    -- don't re-save if this key was deleted very recently (grace period)
    local now = GetTime()
    local grace = 10 -- seconds
    if self.recentlyDeleted[key] and (now - self.recentlyDeleted[key]) < grace then
        if self.DEBUG_DEBUFF_CACHE then
            DEFAULT_CHAT_FRAME:AddMessage("FDT: skip save for recently deleted key=" ..
                tostring(key))
        end
        return
    end
    -- store a snapshot plus a saved timestamp
    local snapshot = {}
    local now = GetTime()
    for name, data in pairs(self.activeDebuffs or {}) do
        if data and data.expire and data.expire > now then
            -- only persist debuffs that were applied in combat, or if player is in combat now
            local playerInCombat = (type(UnitAffectingCombat) == "function" and UnitAffectingCombat("player")) or false
            if data.appliedInCombat or playerInCombat then
                snapshot[name] = {
                    expire = data.expire,
                    texture = data.texture,
                    comboPoints = data.comboPoints,
                    appliedInCombat =
                        data.appliedInCombat,
                    appliedAt = data.appliedAt
                }
            else
                if self.DEBUG_DEBUFF_CACHE then
                    DEFAULT_CHAT_FRAME:AddMessage("FDT: skipping save of " ..
                        tostring(name) .. " not applied in combat")
                end
            end
        end
    end
    -- If snapshot is empty (no debuffs), clear any existing cached entry
    if not next(snapshot) then
        self.debuffCache[key] = nil
        -- if self.DEBUG_DEBUFF_CACHE then DEFAULT_CHAT_FRAME:AddMessage("FDT: cache cleared for key=" .. tostring(key)) end
    else
        -- Use GetTime() for consistency with WoW API
        self.debuffCache[key] = { savedAt = GetTime(), data = snapshot }
        if self.DEBUG_DEBUFF_CACHE then
            local cnt = (function(t)
                local i = 0; for _ in pairs(t) do i = i + 1 end
                return i
            end)(snapshot)
            DEFAULT_CHAT_FRAME:AddMessage("FDT: saved cache for key=" .. tostring(key) .. " entries=" .. tostring(cnt))
            -- also dump snapshot names for debugging
            for n, _ in pairs(snapshot) do DEFAULT_CHAT_FRAME:AddMessage("  -> " .. tostring(n)) end
        end
    end
    -- prune old or already-expired entries
    self:PruneDebuffCache()
end

-- Compute a robust key for a unit: prefer GUID when available, otherwise compose name|level|classification|zone
function addon:ComputeTargetKey(unit)
    if not unit then return nil end
    -- prefer GUID when available
    if type(UnitGUID) == "function" then
        local guid = UnitGUID(unit)
        if guid then return guid end
    end
    local name = UnitExists(unit) and UnitName(unit) or nil
    local level = type(UnitLevel) == "function" and UnitLevel(unit) or nil
    local classif = type(UnitClassification) == "function" and UnitClassification(unit) or nil
    local zone = type(GetZoneText) == "function" and GetZoneText() or nil
    if not name then return nil end
    local parts = { name }
    if level then table.insert(parts, tostring(level)) end
    if classif then table.insert(parts, tostring(classif)) end
    if zone then table.insert(parts, tostring(zone)) end
    return table.concat(parts, "|")
end

function addon:LoadActiveDebuffs(key)
    -- replace activeDebuffs with a copy of the cached table (or empty)
    self.activeDebuffs = {}
    -- prune before loading
    self:PruneDebuffCache()
    if not key then return end
    local entry = self.debuffCache[key]
    -- Fallbacks: try the alternate key (GUID vs name) if available
    if not entry then
        if self.currentTargetGUID and self.debuffCache[self.currentTargetGUID] then
            entry = self.debuffCache[self.currentTargetGUID]
        elseif self.currentTargetName and self.debuffCache[self.currentTargetName] then
            entry = self.debuffCache[self.currentTargetName]
        end
    end
    if not entry or not entry.data then return end
    for name, data in pairs(entry.data) do
        self.activeDebuffs[name] = {
            expire = data.expire,
            texture = data.texture,
            comboPoints = data.comboPoints,
            appliedInCombat =
                data.appliedInCombat,
            appliedAt = data.appliedAt
        }
    end
    if self.DEBUG_DEBUFF_CACHE then
        local cnt = (function(t)
            local i = 0; for _ in pairs(t) do i = i + 1 end
            return i
        end)(entry.data)
        DEFAULT_CHAT_FRAME:AddMessage("FDT: loaded cache for key=" .. tostring(key) .. " entries=" .. tostring(cnt))
        for n, d in pairs(entry.data) do
            DEFAULT_CHAT_FRAME:AddMessage("  <- " ..
                tostring(n) .. " exp=" .. tostring(d.expire))
        end
    end
end

function addon:PruneDebuffCache()
    local now = GetTime()
    local ttl = (self.DEBUFF_CACHE_TTL_MINUTES or 10) * 60
    for key, entry in pairs(self.debuffCache) do
        if not entry or not entry.data then
            self.debuffCache[key] = nil
        else
            -- remove if savedAt is too old
            if entry.savedAt and (now - entry.savedAt) > ttl then
                if self.DEBUG_DEBUFF_CACHE then
                    DEFAULT_CHAT_FRAME:AddMessage("FDT: pruning key=" ..
                        tostring(key) .. " reason=ttl")
                end
                self.debuffCache[key] = nil
            else
                -- remove if all debuffs expired already
                local keep = false
                for _, d in pairs(entry.data) do
                    if d and d.expire and d.expire > GetTime() then
                        keep = true; break
                    end
                end
                if not keep then
                    if self.DEBUG_DEBUFF_CACHE then
                        DEFAULT_CHAT_FRAME:AddMessage("FDT: pruning key=" ..
                            tostring(key) .. " reason=expired")
                    end
                    self.debuffCache[key] = nil
                end
            end
        end
    end
end

function addon:DeleteCachedDebuffs(key)
    if not key then return end
    -- Delete the provided key and any related GUID/name fallbacks if available
    if self.debuffCache[key] then
        self.debuffCache[key] = nil
        if self.DEBUG_DEBUFF_CACHE then DEFAULT_CHAT_FRAME:AddMessage("FDT: deleted cache for key=" .. tostring(key)) end
    end
    -- mark as recently deleted to avoid re-saving during a short grace period
    self.recentlyDeleted[key] = GetTime()
    -- If we have a currentTargetGUID/name, ensure those variants are cleared too
    if self.currentTargetGUID and self.debuffCache[self.currentTargetGUID] then
        self.debuffCache[self.currentTargetGUID] = nil
        if self.DEBUG_DEBUFF_CACHE then
            DEFAULT_CHAT_FRAME:AddMessage("FDT: deleted cache for currentTargetGUID=" ..
                tostring(self.currentTargetGUID))
        end
    end
    if self.currentTargetName and self.debuffCache[self.currentTargetName] then
        self.debuffCache[self.currentTargetName] = nil
        if self.DEBUG_DEBUFF_CACHE then
            DEFAULT_CHAT_FRAME:AddMessage("FDT: deleted cache for currentTargetName=" ..
                tostring(self.currentTargetName))
        end
    end
    -- also mark GUID and name as recently deleted
    if self.currentTargetGUID then self.recentlyDeleted[self.currentTargetGUID] = GetTime() end
    if self.currentTargetName then self.recentlyDeleted[self.currentTargetName] = GetTime() end
end

function addon:LoadPosition()
    if FeralDebuffTrackerDB and FeralDebuffTrackerDB.point then
        local f = self.frame
        f:ClearAllPoints()
        f:SetPoint(FeralDebuffTrackerDB.point, UIParent,
            FeralDebuffTrackerDB.relPoint,
            FeralDebuffTrackerDB.x, FeralDebuffTrackerDB.y)
    end
end

function addon:Lock()
    self.frame:SetBackdropColor(0, 0, 0, 0)
    self.frame:SetBackdropBorderColor(0, 0, 0, 0)
    self.frame:EnableMouse(false)
    self.frame:SetBackdrop(nil)
    FeralDebuffTrackerDB = FeralDebuffTrackerDB or {}
    FeralDebuffTrackerDB.locked = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00FeralDebuffTracker locked.|r")
end

function addon:Unlock()
    self.frame:SetBackdropColor(1, 1, 1, 0.1)
    self.frame:SetBackdropBorderColor(1, 1, 1, 0.2)
    self.frame:EnableMouse(true)
    self.frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    FeralDebuffTrackerDB = FeralDebuffTrackerDB or {}
    FeralDebuffTrackerDB.locked = false
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00FeralDebuffTracker unlocked. Drag to move.|r")
end

function FeralDebuffTracker_OnMouseDown(this, button)
    if button == "LeftButton" and (not FeralDebuffTrackerDB or not FeralDebuffTrackerDB.locked) then this:StartMoving() end
end

function FeralDebuffTracker_OnMouseUp(this)
    this:StopMovingOrSizing()
    if this:IsMouseEnabled() then
        local point, _, relPoint, xOfs, yOfs = this:GetPoint()
        FeralDebuffTrackerDB = FeralDebuffTrackerDB or {}
        FeralDebuffTrackerDB.point, FeralDebuffTrackerDB.relPoint = point, relPoint
        FeralDebuffTrackerDB.x, FeralDebuffTrackerDB.y = xOfs, yOfs
    end
end

SLASH_FERALDEBUFFTRACKER1 = "/fdt"
SlashCmdList["FERALDEBUFFTRACKER"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "lock" then
        addon:Lock()
    elseif msg == "unlock" then
        addon:Unlock()
    elseif msg == "cache" then
        -- Print cache summary and active debuffs
        DEFAULT_CHAT_FRAME:AddMessage("FDT: cache dump:")
        for k, v in pairs(addon.debuffCache or {}) do
            local count = 0
            if v and v.data then for _ in pairs(v.data) do count = count + 1 end end
            DEFAULT_CHAT_FRAME:AddMessage("  key=" ..
                tostring(k) .. " savedAt=" .. tostring(v and v.savedAt) .. " entries=" .. tostring(count))
        end
        DEFAULT_CHAT_FRAME:AddMessage("FDT: active debuffs:")
        for n, d in pairs(addon.activeDebuffs or {}) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. tostring(n) ..
                " exp=" .. tostring(d.expire) .. " tex=" .. tostring(d.texture))
        end
        return
    elseif msg == "riphist" then
        -- Dump recent rip tick history and any pending calibration for current target
        local key = addon.currentTargetKey or ((type(UnitName) == "function" and UnitName("target")) or "(unknown)")
        DEFAULT_CHAT_FRAME:AddMessage("FDT: riphist for key=" .. tostring(key))
        DEFAULT_CHAT_FRAME:AddMessage("  no pending calibration (calibration removed)")
        if addon._ripTickHistory and addon._ripTickHistory[key] then
            local hist = addon._ripTickHistory[key]
            local i = 0
            for _, e in ipairs(hist) do
                i = i + 1; DEFAULT_CHAT_FRAME:AddMessage("  hist[" ..
                    tostring(i) .. "] time=" .. tostring(e.time) .. " dmg=" .. tostring(e.dmg))
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("  no rip tick history for this key")
        end
        return
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Feral Debuff Tracker commands:|r")
        DEFAULT_CHAT_FRAME:AddMessage("/fdt lock   - Lock frame")
        DEFAULT_CHAT_FRAME:AddMessage("/fdt unlock - Unlock frame")
    end
end
