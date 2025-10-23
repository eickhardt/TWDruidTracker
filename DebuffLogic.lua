local addon = FeralDebuffTracker
-- Do not cache addon.debuffs / addon.timers / addon.cpTexts / addon.iconPaths at load-time.
-- UI.lua may recreate these tables during a UI rebuild, so resolve them inside functions.

local durations = {
    ["Rake"] = 9,
    ["Rip"] = 12,
    ["Pounce Bleed"] = 18,
    ["Faerie Fire (Feral)"] = 40,
}

-- Public helper: return canonical duration for a debuff name.
function addon:GetDebuffDuration(name, combo)
    if not name then return nil end
    if name == "Rip" then
        combo = combo or 0
        if combo == 1 then return 10 end
        if combo == 2 then return 12 end
        if combo == 3 then return 14 end
        if combo == 4 then return 16 end
        if combo >= 5 then return 18 end
        return durations["Rip"] or 10
    end
    return durations[name]
end

-- Attack Power helpers and Rip AP compensation
function addon:GetPlayerAP()
    -- Defensive checks for common API variants
    if type(UnitAttackPower) == "function" then
        local lowBase, posBuff, negBuff = UnitAttackPower("player")
        if lowBase then
            if type(posBuff) == "number" and type(negBuff) == "number" then
                return (lowBase or 0) + (posBuff or 0) - (negBuff or 0)
            end
            return lowBase or 0
        end
    end
    if type(GetAttackPower) == "function" then
        local ap = GetAttackPower()
        if ap then return ap end
    end
    -- Allow manual override via saved vars for testing
    if FeralDebuffTrackerDB and FeralDebuffTrackerDB.overrideAP then
        return tonumber(FeralDebuffTrackerDB.overrideAP) or 0
    end
    return 0
end

-- Return expected tick, adjusted total, and ticks for a given Rip combo
function addon:ExpectedRipTickForCombo(combo)
    local totals = { 225, 438, 707, 1032, 1413 }
    local baseTotal = totals[combo] or totals[5]
    local duration = 12
    if self.GetDebuffDuration and type(self.GetDebuffDuration) == "function" then
        local ok, d = pcall(function() return self:GetDebuffDuration("Rip", combo) end)
        if ok and type(d) == "number" then duration = d end
    end
    local ticks = math.max(1, math.floor((duration / 2) + 0.5))
    local ap = self:GetPlayerAP() or 0
    local apFactor = self:GetAPFactor() or 0
    local adjustedTotal = baseTotal + (apFactor * ap)
    local expectedTick = adjustedTotal / ticks
    return expectedTick, adjustedTotal, ticks
end

function addon:ResetIcons()
    local debuffs, timers, cpTexts = addon.debuffs, addon.timers, addon.cpTexts
    if debuffs then
        for _, v in pairs(debuffs) do
            local g = getglobal(v); if g then g:SetAlpha(0.3) end
        end
    end
    if timers then
        for _, v in pairs(timers) do
            local g = getglobal(v); if g then g:SetText("") end
        end
    end
    if cpTexts then
        for _, v in pairs(cpTexts) do
            local g = getglobal(v); if g then g:SetText("") end
        end
    end
    local activeDebuffs = addon.activeDebuffs
    if activeDebuffs then for k in pairs(activeDebuffs) do activeDebuffs[k] = nil end end
end

-- Helper: determine whether a spell (id or name) is one of our tracked debuffs
function addon:IsTrackedDebuff(spellIdOrName)
    if not spellIdOrName then return false end
    local name = nil
    if type(spellIdOrName) == "number" and type(GetSpellInfo) == "function" then
        name = GetSpellInfo(spellIdOrName)
    end
    if not name and type(spellIdOrName) == "string" then name = spellIdOrName end
    if not name then return false end
    -- Simple English-based matching (consistent with other code in the addon)
    if string.find(name, "Rake", 1, true) then return true end
    if string.find(name, "Rip", 1, true) then return true end
    if string.find(name, "Pounce", 1, true) then return true end
    if string.find(name, "Faerie Fire", 1, true) then return true end
    return false
end

-- Update debuff info from UNIT_AURA data (spellId or spell name). This is a best-effort
-- mapping to our canonical debuff names and will create/refresh the activeDebuffs entry.
function addon:UpdateDebuff(spellIdOrName, duration, expirationTime)
    if not spellIdOrName then return end
    local name = nil
    if type(spellIdOrName) == "number" and type(GetSpellInfo) == "function" then
        name = GetSpellInfo(spellIdOrName)
    end
    if not name and type(spellIdOrName) == "string" then name = spellIdOrName end
    if not name then return end

    local canonical = nil
    if string.find(name, "Rake", 1, true) then
        canonical = "Rake"
    elseif string.find(name, "Rip", 1, true) then
        canonical = "Rip"
    elseif string.find(name, "Pounce", 1, true) then
        canonical = "Pounce Bleed"
    elseif string.find(name, "Faerie Fire", 1, true) then
        canonical = "Faerie Fire (Feral)"
    end
    if not canonical then return end

    local texKey = (canonical == "Pounce Bleed") and "Pounce" or
        (canonical == "Faerie Fire (Feral)" and "FF" or canonical)
    local tex = self.iconPaths and self.iconPaths[texKey]

    self.activeDebuffs = self.activeDebuffs or {}
    local now = GetTime()
    local dur = duration or (self.GetDebuffDuration and self:GetDebuffDuration(canonical)) or 12
    local expireAt = expirationTime or (now + dur)

    self.activeDebuffs[canonical] = {
        expire = expireAt,
        texture = tex,
        comboPoints = (self.activeDebuffs[canonical] and self.activeDebuffs[canonical].comboPoints) or 0,
        appliedInCombat = false,
        appliedAt = (expireAt - dur),
        caster = "player"
    }
    pcall(function() self:RefreshIcons() end)
end

function addon:RemoveDebuff(name)
    local activeDebuffs = addon.activeDebuffs
    local d = activeDebuffs and activeDebuffs[name]; if not d then return end
    local debuffs, timers, cpTexts = addon.debuffs, addon.timers, addon.cpTexts
    local dn = debuffs and debuffs[d.texture]
    if dn then
        local g = getglobal(dn); if g then g:SetAlpha(0.3) end
    end
    local tn = timers and timers[d.texture]
    if tn then
        local g = getglobal(tn); if g then g:SetText("") end
    end
    local cn = cpTexts and cpTexts[d.texture]
    if cn then
        local g = getglobal(cn); if g then g:SetText("") end
    end
    if activeDebuffs then activeDebuffs[name] = nil end
    -- If Rip was removed, also clear any pending calibration and recent tick history
    -- for the current target so a subsequent Rip doesn't reuse stale pending data.
    if name == "Rip" then
        -- prefer computed key, but also try GUID and plain name fallbacks
        local keysToClear = {}
        if addon.currentTargetKey then table.insert(keysToClear, addon.currentTargetKey) end
        if type(UnitGUID) == "function" and UnitExists("target") then
            local uGUID = UnitGUID("target")
            if uGUID then table.insert(keysToClear, uGUID) end
        end
        if addon.currentTargetName then table.insert(keysToClear, addon.currentTargetName) end
        -- also include plain UnitName("target") if available (capture single return value)
        if type(UnitName) == "function" and UnitExists("target") then
            local uName = UnitName("target")
            if uName then table.insert(keysToClear, uName) end
        end
        -- No pending calibration stored; nothing to clear here.
        -- clear rip tick history for these keys as well to avoid cross-application inference
        if addon._ripTickHistory then
            for _, k in ipairs(keysToClear) do
                if k and addon._ripTickHistory[k] then addon._ripTickHistory[k] = nil end
            end
            if addon.currentTargetName then
                for hk, _ in pairs(addon._ripTickHistory) do
                    if type(hk) == "string" and string.find(hk, addon.currentTargetName, 1, true) then
                        addon._ripTickHistory[hk] = nil
                    end
                end
            end
        end
    end
    if addon.DEBUG_DEBUFF_CACHE then
        local i = 0; for _ in pairs(addon.activeDebuffs or {}) do i = i + 1 end
        DEFAULT_CHAT_FRAME:AddMessage("FDT: RemoveDebuff(" .. tostring(name) .. ") active=" .. tostring(i))
    end
end

function addon:RegisterDebuff(name)
    local key = (name == "Pounce Bleed") and "Pounce" or (name == "Faerie Fire (Feral)" and "FF" or name)
    local iconPaths = addon.iconPaths
    local tex = iconPaths and iconPaths[key]
    if not tex then return end
    local duration = durations[name] or 10
    -- Prefer direct query for current combo points when possible; fallback to stored values
    local reportedCombo = 0
    if type(GetComboPoints) == "function" then
        reportedCombo = GetComboPoints("player", "target") or 0
    end
    if not reportedCombo or reportedCombo == 0 then
        reportedCombo = addon.lastNonZeroComboPoints or addon.lastKnownComboPoints or 0
    end
    local activeDebuffs = addon.activeDebuffs
    if not activeDebuffs then
        addon.activeDebuffs = {}; activeDebuffs = addon.activeDebuffs
    end
    local prev = activeDebuffs[name]
    -- Prefer previous non-zero comboPoints when refreshing if the new reported combo is zero
    local combo = reportedCombo
    if name == "Rip" and prev and (not combo or combo == 0) and prev.comboPoints and prev.comboPoints > 0 then
        combo = prev.comboPoints
    end
    if name == "Rip" then
        if combo == 1 then duration = 10 elseif combo == 2 then duration = 12 elseif combo == 3 then duration = 14 elseif combo == 4 then duration = 16 elseif combo >= 5 then duration = 18 end
    end
    local appliedInCombat = (type(UnitAffectingCombat) == "function" and UnitAffectingCombat("player")) or false
    local now = GetTime()
    if prev then
        -- refresh existing debuff
        if addon.DEBUG_DEBUFF_CACHE then
            DEFAULT_CHAT_FRAME:AddMessage("FDT: Refreshing existing '" ..
                tostring(name) .. "' prev.expire=" .. tostring(prev.expire) .. " now=" .. tostring(now))
        end
        -- always update expire to reflect the most recent application (allow shortening when CP is lower)
        prev.expire = now + duration
        if addon.DEBUG_DEBUFF_CACHE then
            DEFAULT_CHAT_FRAME:AddMessage("FDT: Refreshing existing '" ..
                tostring(name) .. "' new.expire=" .. tostring(prev.expire))
        end
        prev.texture = tex
        prev.comboPoints = combo
        prev.appliedInCombat = appliedInCombat
        prev.appliedAt = now
        -- mark that this was applied by the player
        prev.caster = "player"
        addon._lastPlayerApply = addon._lastPlayerApply or {}
        addon._lastPlayerApply[name] = now
        addon._lastPlayerApply_byTexture = addon._lastPlayerApply_byTexture or {}
        addon._lastPlayerApply_byTexture[tex] = now
        if addon.DEBUG_DEBUFF_CACHE then
            DEFAULT_CHAT_FRAME:AddMessage("FDT: RefreshDebuff(" ..
                tostring(name) ..
                ") dur=" ..
                tostring(duration) ..
                " active=" ..
                tostring((function(t)
                    local i = 0; for _ in pairs(t) do i = i + 1 end
                    return i
                end)(addon.activeDebuffs)))
            if name == "Rip" then
                DEFAULT_CHAT_FRAME:AddMessage("FDT: Rip refresh details prevCombo=" ..
                    tostring(prev.comboPoints) ..
                    " newCombo=" .. tostring(combo) .. " prevExpire=" .. tostring(prev.expire))
            end
        end
    else
        activeDebuffs[name] = {
            expire = now + duration,
            texture = tex,
            comboPoints = combo,
            appliedInCombat = appliedInCombat,
            appliedAt = now,
            caster = "player"
        }
        addon._lastPlayerApply = addon._lastPlayerApply or {}
        addon._lastPlayerApply[name] = now
        -- record by texture as well for UNIT_AURA attribution when name is missing
        addon._lastPlayerApply_byTexture = addon._lastPlayerApply_byTexture or {}
        addon._lastPlayerApply_byTexture[tex] = now
        if addon.DEBUG_DEBUFF_CACHE and name == "Rip" then
            DEFAULT_CHAT_FRAME:AddMessage("FDT: Rip created new expire=" ..
                tostring(now + duration) .. " combo=" .. tostring(combo))
        end
    end
    local debuffs, timers, cpTexts = addon.debuffs, addon.timers, addon.cpTexts
    local dn = debuffs and debuffs[tex]
    if dn then
        local g = getglobal(dn); if g then g:SetAlpha(1) end
    end
    local tn = timers and timers[tex]
    if tn then
        local g = getglobal(tn); if g then g:SetText(string.format("%d", duration)) end
    end

    if name == "Rip" and combo > 0 then
        local cn = cpTexts and cpTexts[tex]
        if cn then
            local cp = getglobal(cn)
            local r, g, b = 1, 1, 1
            if combo >= 5 then r, g, b = 0, 1, 0 elseif combo >= 3 then r, g, b = 1, 1, 0 else r, g, b = 1, 0.4, 0.4 end
            if cp then
                cp:SetTextColor(r, g, b); cp:SetText("CP:" .. combo)
            end
        end
    else
        -- ensure cp text is cleared if no combo
        local cn = cpTexts and cpTexts[tex]
        if cn then
            local cp = getglobal(cn)
            if cp and cp.SetText then cp:SetText("") end
        end
    end
    -- Detailed debug: report which UI globals were touched and refresh icons immediately
    if addon.DEBUG_DEBUFF_CACHE then
        local dnName = dn
        local tnName = tn
        local cnName = (name == "Rip") and (cpTexts and cpTexts[tex]) or nil
        -- DEFAULT_CHAT_FRAME:AddMessage("FDT: UI map for "..tostring(name).." -> tex="..tostring(tex).." dn="..tostring(dnName).." tn="..tostring(tnName).." cn="..tostring(cnName))
        -- show current timer text if available
        -- if tnName then local txt = getglobal(tnName); if txt and txt.GetText then DEFAULT_CHAT_FRAME:AddMessage("FDT: timer text now="..tostring(txt:GetText())) end end
    end
    -- Force a UI refresh so reapplications are immediately visible
    pcall(function() addon:RefreshIcons() end)
end

function addon:RefreshIcons()
    local now = GetTime()
    local activeDebuffs = addon.activeDebuffs
    if not activeDebuffs then return end
    -- If there's no valid target, ensure icons are dimmed and don't show cached debuffs
    if not UnitExists("target") or not UnitCanAttack("player", "target") then
        addon:ResetIcons()
        return
    end
    for name, data in pairs(activeDebuffs) do
        local remaining = data.expire - now
        if remaining <= 0.5 then
            -- If this debuff was very recently (re)applied, skip removal to avoid race with refresh
            local appliedAt = data.appliedAt or 0
            local sinceApplied = now - appliedAt
            local grace = 1.2
            if sinceApplied < grace then
                -- if addon.DEBUG_DEBUFF_CACHE then DEFAULT_CHAT_FRAME:AddMessage("FDT: RefreshIcons skip removal for '"..tostring(name).."' sinceApplied="..tostring(sinceApplied) .." grace="..tostring(grace)) end
            else
                if addon.DEBUG_DEBUFF_CACHE then
                    DEFAULT_CHAT_FRAME:AddMessage("FDT: RefreshIcons removing '" ..
                        tostring(name) ..
                        "' remaining=" ..
                        tostring(remaining) ..
                        " expire=" ..
                        tostring(data.expire) ..
                        " now=" .. tostring(now) ..
                        " appliedAt=" .. tostring(data.appliedAt) .. " caster=" .. tostring(data.caster))
                end
                addon:RemoveDebuff(name)
            end
        else
            local secs = math.ceil(remaining)
            local debuffs, timers, cpTexts = addon.debuffs, addon.timers, addon.cpTexts
            local dn = debuffs and debuffs[data.texture]
            if dn then
                local g = getglobal(dn); if g then g:SetAlpha(1) end
            end
            local tn = timers and timers[data.texture]
            if tn then
                local txt = getglobal(tn)
                if txt then
                    if secs <= 3 then
                        txt:SetTextColor(1, 0.3, 0.3)
                    elseif secs <= 6 then
                        txt:SetTextColor(1, 0.8, 0.3)
                    else
                        txt:SetTextColor(1, 1, 1)
                    end
                    txt:SetText(secs)
                end
            end
            if name == "Rip" and data.comboPoints > 0 then
                local cn = cpTexts and cpTexts[data.texture]
                if cn then
                    local cp = getglobal(cn)
                    local c = data.comboPoints
                    local r, g, b = 1, 1, 1
                    if c >= 5 then r, g, b = 0, 1, 0 elseif c >= 3 then r, g, b = 1, 1, 0 else r, g, b = 1, 0.4, 0.4 end
                    if cp then
                        cp:SetTextColor(r, g, b); cp:SetText("CP:" .. c)
                    end
                end
            end
        end
    end
end
