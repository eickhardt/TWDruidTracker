local addon = FeralDebuffTracker
local frame = addon.frame

-- Rip tick history: store recent tick damages per target key to infer combo points
addon._ripTickHistory = addon._ripTickHistory or {}
function addon:_RecordRipTick(key, dmg)
    -- Defensive logging to diagnose recording issues
    if not key or not dmg then
        if self.DEBUG_DEBUFF_CACHE then
            DEFAULT_CHAT_FRAME:AddMessage("FDT: _RecordRipTick called with nil key or dmg; key=" ..
                tostring(key) .. " dmg=" .. tostring(dmg))
        end
        return
    end
    if not self._ripTickHistory then self._ripTickHistory = {} end
    -- minimal logging here to avoid spamming chat on every Rip tick
    local now = GetTime()
    local hist = self._ripTickHistory[key]
    if not hist then
        hist = {}
        -- suppressed verbose creation log
    else
        -- show previous hist count
        -- suppressed verbose history-count log
        local prevCount = 0
        for _ in pairs(hist) do prevCount = prevCount + 1 end
    end

    table.insert(hist, { time = now, dmg = dmg })

    -- keep only last 4 ticks (avoid using '#' for compatibility)
    local histCount = 0
    for _ in pairs(hist) do histCount = histCount + 1 end
    -- suppressed per-insert history count log
    while histCount > 4 do
        table.remove(hist, 1); histCount = histCount - 1
    end
    -- drop very old entries (>10s)
    while histCount > 0 and (now - hist[1].time) > 10 do
        table.remove(hist, 1); histCount = histCount - 1
    end
    -- write back
    self._ripTickHistory[key] = hist
    -- suppressed stored history dump to reduce spam
    -- No calibration/sample collection in one-shot inference mode
end

-- Infer Rip combo from recent tick history. Returns combo or nil, and error metric.
-- Simplified inference: only use the most recent tick (and previous tick change)
-- to reverse-engineer combo points from an observed tick damage and current AP.
-- Returns inferred combo (1-5) and a relative error metric, or nil if none fits.
function addon:_InferRipComboFromHistory(key)
    local hist = self._ripTickHistory and self._ripTickHistory[key]
    if not hist then return nil, nil end
    -- count entries and collect last two damages
    local count = 0
    local last, prev = nil, nil
    for _, e in pairs(hist) do
        count = count + 1
        prev = last
        last = (e and e.dmg) or last
    end
    if not last then return nil, nil end

    -- We only infer when there's evidence of a damage change (new application)
    -- i.e., prev exists and last differs from prev by more than 1 (absolute).
    if not prev or math.abs((last or 0) - (prev or 0)) <= 1 then
        return nil, nil
    end

    local ap = (type(self.GetPlayerAP) == "function" and self:GetPlayerAP()) or 0
    local apFactor = (type(self.GetAPFactor) == "function" and self:GetAPFactor()) or 0
    local totals = { 225, 438, 707, 1032, 1413 }

    local bestCombo, bestErr = nil, 1e9
    for combo = 1, 5 do
        -- Prefer using addon:ExpectedRipTickForCombo if present
        local expectedTick = nil
        if type(self.ExpectedRipTickForCombo) == "function" then
            local ok, v = pcall(function() return self:ExpectedRipTickForCombo(combo) end)
            if ok and v then
                if type(v) == "table" then expectedTick = v[1] end
                if type(v) == "number" then expectedTick = v end
            end
        end
        if not expectedTick then
            local total = totals[combo]
            local duration = (self.GetDebuffDuration and self:GetDebuffDuration("Rip", combo)) or 10
            local ticks = math.max(1, math.floor((duration / 2) + 0.5))
            local adjustedTotal = (total or 0) + (apFactor * (ap or 0))
            expectedTick = adjustedTotal / ticks
        end
        if expectedTick and expectedTick > 0 then
            local err = math.abs(last - expectedTick) / expectedTick
            if err < bestErr then bestErr, bestCombo = err, combo end
        end
    end

    -- Accept the best match if error is reasonably small
    if bestCombo and bestErr and bestErr < 0.25 then
        -- Fix off-by-one bias observed in the field: inferred combo has been
        -- consistently one higher than expected. Adjust by -1 but clamp to 1.
        local adjusted = bestCombo - 1
        if adjusted < 1 then adjusted = 1 end
        return adjusted, bestErr
    end
    return nil, bestErr
end

frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("PLAYER_COMBO_POINTS")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
frame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_SELF")
frame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_OTHER")
frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("UNIT_HEALTH")

frame:SetScript("OnEvent", function()
    local e = event

    if e == "VARIABLES_LOADED" then
        addon:LoadPosition()
        frame:Show()
        if FeralDebuffTrackerDB and FeralDebuffTrackerDB.locked then
            addon:Lock()
        else
            addon:Unlock()
        end
        -- Ensure UI elements are rebuilt/cleaned once on load to remove duplicate leftovers
        if type(FeralDebuffTracker_UI_Rebuild) == "function" then pcall(FeralDebuffTracker_UI_Rebuild) end
        -- Initialize current target key so first target-change can save correctly
        local curKey = addon:ComputeTargetKey("target")
        addon.currentTargetKey = curKey
        -- Store current target idents for fallback deletion/load
        if type(UnitGUID) == "function" then addon.currentTargetGUID = UnitGUID("target") end
        addon.currentTargetName = UnitExists("target") and UnitName("target") or nil
        -- Load any cached debuffs for the current target so UI shows on load, but never load for dead targets
        if curKey and UnitExists("target") and UnitCanAttack("player", "target") and (type(UnitIsDead) ~= "function" or not UnitIsDead("target")) then
            addon:LoadActiveDebuffs(curKey); addon:RefreshIcons()
        end
    elseif e == "PLAYER_TARGET_CHANGED" then
        -- Save previous target's debuffs using the computed key
        local prevKey = addon.currentTargetKey
        if prevKey then addon:SaveActiveDebuffs(prevKey) end

        -- Compute new target key and store it; also update GUID/name fields
        local newKey = addon:ComputeTargetKey("target")
        addon.currentTargetKey = newKey
        if type(UnitGUID) == "function" then addon.currentTargetGUID = UnitGUID("target") end
        addon.currentTargetName = UnitExists("target") and UnitName("target") or nil
        -- If the new target is dead, delete its cache and don't load it
        local newIsDead = false
        if UnitExists("target") then
            if type(UnitIsDeadOrGhost) == "function" and UnitIsDeadOrGhost("target") then newIsDead = true end
            if not newIsDead and type(UnitIsDead) == "function" and UnitIsDead("target") then newIsDead = true end
            if not newIsDead and type(UnitIsGhost) == "function" and UnitIsGhost("target") then newIsDead = true end
            if not newIsDead and type(UnitHealth) == "function" and (UnitHealth("target") or 0) <= 0 then newIsDead = true end
        end
        if newIsDead then
            if newKey then addon:DeleteCachedDebuffs(newKey) end
            if addon.DEBUG_DEBUFF_CACHE then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "FDT: PLAYER_TARGET_CHANGED - new target is dead, deleted cache for key=" .. tostring(newKey))
            end
            addon:ResetIcons()
            addon:RefreshIcons()
            return
        end

        -- Ensure UI mappings exist (UI.lua may rebuild them) but only rebuild if mappings are missing.
        if (not addon.debuffs or not addon.timers or not addon.cpTexts) and type(FeralDebuffTracker_UI_Rebuild) == "function" then
            pcall(FeralDebuffTracker_UI_Rebuild)
        end
        addon:ResetIcons()
        -- Only load cached debuffs for a valid, attackable target
        if newKey and UnitExists("target") and UnitCanAttack("player", "target") then
            addon:LoadActiveDebuffs(newKey)
        end
        addon:RefreshIcons()
    elseif e == "PLAYER_COMBO_POINTS" then
        local cp = GetComboPoints("player", "target") or 0
        if cp > 0 then addon.lastNonZeroComboPoints = cp end
        addon.lastKnownComboPoints = cp
    elseif e == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
        local msg = arg1
        -- periodic damage events are frequent; avoid logging every message
        if not msg then return end
        -- Only register if this combat message refers to the current target
        local tname = UnitExists("target") and UnitName("target") or nil
        if not tname then return end
        -- First handle 'is afflicted by' combat lines
        if string.find(msg, tname, 1, true) then
            if string.find(msg, " is afflicted by Rake", 1, true) then
                addon:RegisterDebuff("Rake")
            elseif string.find(msg, " is afflicted by Rip", 1, true) then
                if addon.DEBUG_DEBUFF_CACHE then
                    DEFAULT_CHAT_FRAME:AddMessage(
                        "FDT: Rip registered! CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
                end
                addon:RegisterDebuff("Rip")
                -- simple flow: infer directly from ticks; no pending calibration
            elseif string.find(msg, " is afflicted by Pounce", 1, true) then
                addon:RegisterDebuff("Pounce Bleed")
            elseif string.find(msg, " is afflicted by Faerie Fire", 1, true) then
                addon:RegisterDebuff("Faerie Fire (Feral)")
            end
        end

        -- Regardless of the above, also attempt to parse Rip periodic-damage ticks.
        -- Patterns vary; be permissive but require an explicit 'your Rip' mention.
        if string.find(msg, "your Rip") then
            -- parsing attempt (suppressed verbose log)
            local dmg = nil; local who = nil
            -- Try pattern match if available, otherwise use a safe fallback parser
            local a, b
            if type(string) == "table" and type(string.match) == "function" then
                a, b = string.match(msg, "^(.+) suffers (%d+) damage from your Rip%.$")
            end
            if a and b then
                who = a; dmg = tonumber(b)
            else
                -- Fallback parsing (avoid string.match/msg:match).
                -- Try to parse '<target> suffers X damage from your Rip.' using plain find/sub.
                local s_suff, s_end = string.find(msg, " suffers ", 1, true)
                local d_phrase_start = string.find(msg, " damage from your Rip", 1, true)
                if s_suff and d_phrase_start then
                    -- extract who (before ' suffers ')
                    local who_raw = string.sub(msg, 1, s_suff - 1)
                    -- extract number between ' suffers ' and ' damage'
                    local num_raw = string.sub(msg, s_suff + 9, d_phrase_start - 1)
                    -- extract digits from num_raw (avoid using '#' for compatibility)
                    local digits = ""
                    local nr_len = string.len(num_raw or "")
                    for i = 1, nr_len do
                        local ch = string.sub(num_raw, i, i)
                        if ch >= "0" and ch <= "9" then digits = digits .. ch end
                    end
                    if digits ~= "" then
                        who = who_raw; dmg = tonumber(digits)
                    end
                else
                    -- pattern without target at start: 'X damage from your Rip.'
                    local phrase_pos = string.find(msg, " damage from your Rip", 1, true)
                    if phrase_pos then
                        -- scan backwards from phrase_pos-1 to collect contiguous digits
                        local i = phrase_pos - 1
                        local digits_rev = ""
                        while i > 0 do
                            local ch = string.sub(msg, i, i)
                            if ch >= "0" and ch <= "9" then
                                digits_rev = digits_rev .. ch; i = i - 1
                            else
                                break
                            end
                        end
                        if digits_rev ~= "" then
                            -- reverse digits_rev (avoid '#' operator)
                            local digits = ""
                            local dr_len = string.len(digits_rev or "")
                            for j = dr_len, 1, -1 do digits = digits .. string.sub(digits_rev, j, j) end
                            dmg = tonumber(digits); who = tname
                        end
                    end
                end
            end
            if dmg and who then
                -- show parsed tick only if debugging and this target has pending calibration
                -- (otherwise ticks are routine and noisy)
                local key = nil
                if type(UnitGUID) == "function" then
                    if UnitExists("target") and UnitName("target") == who then key = addon:ComputeTargetKey("target") end
                end
                if not key then key = who end
                -- Log parsed tick only when main debug flag is enabled (keep behavior consistent)
                if addon.DEBUG_DEBUFF_CACHE then
                    local logKey = key
                    DEFAULT_CHAT_FRAME:AddMessage("FDT: RipTick who=" ..
                        tostring(who) .. " dmg=" .. tostring(dmg) .. " key=" .. tostring(logKey))
                end
                addon:_RecordRipTick(key, dmg)
                -- Gather current history and count
                local hist = addon._ripTickHistory and addon._ripTickHistory[key]
                local histCount = 0
                if hist then for _ in pairs(hist) do histCount = histCount + 1 end end
                -- Detect a damage-change between the last two ticks; if detected,
                -- treat it as a new application (reset history to the new tick)
                local damageChanged = false
                local prev_dmg, cur_dmg = nil, nil
                if histCount >= 2 then
                    prev_dmg = hist[histCount - 1] and hist[histCount - 1].dmg
                    cur_dmg = hist[histCount] and hist[histCount].dmg
                    -- Absolute difference threshold (>1) as requested by user
                    if prev_dmg and cur_dmg then
                        if math.abs(cur_dmg - prev_dmg) > 1 then damageChanged = true end
                    elseif prev_dmg ~= cur_dmg then
                        damageChanged = true
                    end
                end
                if damageChanged then
                    if addon.DEBUG_DEBUFF_CACHE then
                        DEFAULT_CHAT_FRAME:AddMessage("FDT: Rip damage changed; treating as new application prev=" ..
                            tostring(prev_dmg) .. " cur=" .. tostring(cur_dmg))
                    end
                    -- keep only the newest tick in history (new instance started ~2s ago)
                    local newHist = {}
                    table.insert(newHist, { time = hist[histCount].time, dmg = hist[histCount].dmg })
                    addon._ripTickHistory[key] = newHist
                    hist = newHist
                    histCount = 1
                end
                local combo, err = addon:_InferRipComboFromHistory(key)
                -- If no combo inferred but there's no active Rip (it faded), try a
                -- single-tick inference using the most recent tick so a lone
                -- tick after fade still creates a visible icon.
                if not combo then
                    local activeRip = addon.activeDebuffs and addon.activeDebuffs["Rip"]
                    local now = GetTime()
                    local ripExpired = true
                    if activeRip and activeRip.expire and activeRip.expire > now then ripExpired = false end
                    if (not activeRip) or ripExpired then
                        -- Use the most recent tick in hist
                        local cur_tick = nil
                        if hist and histCount >= 1 then cur_tick = hist[histCount] and hist[histCount].dmg end
                        if cur_tick then
                            local totals = { 225, 438, 707, 1032, 1413 }
                            local bestC, bestE = nil, 1e9
                            local ap = (type(addon.GetPlayerAP) == "function" and addon:GetPlayerAP()) or 0
                            local apFactor = (type(addon.GetAPFactor) == "function" and addon:GetAPFactor()) or 0
                            for c = 1, 5 do
                                local expectedTick = nil
                                if type(addon.ExpectedRipTickForCombo) == "function" then
                                    local ok, v = pcall(function() return addon:ExpectedRipTickForCombo(c) end)
                                    if ok and v then
                                        if type(v) == "table" then expectedTick = v[1] end
                                        if type(v) == "number" then expectedTick = v end
                                    end
                                end
                                if not expectedTick then
                                    local total = totals[c]
                                    local duration = (addon.GetDebuffDuration and addon:GetDebuffDuration("Rip", c)) or
                                        12
                                    local ticks = math.max(1, math.floor((duration / 2) + 0.5))
                                    local adjustedTotal = (total or 0) + (apFactor * (ap or 0))
                                    expectedTick = adjustedTotal / ticks
                                end
                                if expectedTick and expectedTick > 0 then
                                    local e = math.abs(cur_tick - expectedTick) / expectedTick
                                    if e < bestE then bestE, bestC = e, c end
                                end
                            end
                            if bestC and bestE and bestE < 0.25 then
                                -- Adjust for observed +1 bias
                                local adj = bestC - 1
                                if adj < 1 then adj = 1 end
                                combo = adj
                                err = bestE
                            end
                        end
                    end
                end
                -- If damageChanged, compute best combo from the single current tick
                -- so we can immediately update the icon and expire.
                local forcedCombo = nil
                if damageChanged and cur_dmg then
                    local totals = { 225, 438, 707, 1032, 1413 }
                    local bestC, bestE = nil, 1e9
                    for c = 1, 5 do
                        local expectedTick
                        if type(addon.ExpectedRipTickForCombo) == "function" then
                            local ok, v = pcall(function() return addon:ExpectedRipTickForCombo(c) end)
                            if ok then
                                -- ExpectedRipTickForCombo may return expectedTick, adjustedTotal, ticks
                                if type(v) == "table" then
                                    expectedTick = v[1]
                                elseif type(v) == "number" then
                                    expectedTick =
                                        v
                                end
                            end
                        end
                        if not expectedTick then
                            local total = totals[c]
                            local duration = (addon.GetDebuffDuration and addon:GetDebuffDuration("Rip", c)) or 12
                            local ticks = duration / 2
                            expectedTick = total / ticks
                        end
                        if expectedTick and expectedTick > 0 then
                            local e = math.abs(cur_dmg - expectedTick) / expectedTick
                            if e < bestE then bestE, bestC = e, c end
                        end
                    end
                    if bestC then
                        -- bestC is the best combo candidate; adjust by -1 to fix observed bias
                        local adj = bestC - 1
                        if adj < 1 then adj = 1 end
                        forcedCombo = adj
                        combo = forcedCombo
                        err = bestE
                    end
                    -- Conservative fallback: if new tick is far smaller than prev, bias to 1
                    if prev_dmg and cur_dmg and cur_dmg < (prev_dmg * 0.7) then
                        forcedCombo = forcedCombo or 1; combo = forcedCombo
                    end
                end
                if combo then
                    -- Count recent ticks for this key (may have changed above)
                    hist = addon._ripTickHistory and addon._ripTickHistory[key]
                    histCount = 0
                    if hist then for _ in pairs(hist) do histCount = histCount + 1 end end

                    -- No pending calibration flow; inference applies immediately.

                    local now = GetTime()
                    local dur = addon.GetDebuffDuration and addon:GetDebuffDuration("Rip", combo) or 10
                    -- At the time we observe the first Rip tick in the combat log,
                    -- ~2s have already elapsed since the application. Reduce the
                    -- remaining duration accordingly when inferring an application.
                    local elapsed = 2
                    local remainingDur = (dur or 0) - elapsed
                    if remainingDur < 1 then remainingDur = 1 end
                    addon.activeDebuffs = addon.activeDebuffs or {}
                    addon.activeDebuffs["Rip"] = addon.activeDebuffs["Rip"] or {}
                    local prev = addon.activeDebuffs["Rip"]

                    -- If we have no previous record, accept inference (or reported combo) and set expire.
                    if (not prev) or (not prev.comboPoints) then
                        prev = prev or {}
                        prev.expire = now + remainingDur
                        -- appliedAt should reflect the original application time (~2s ago)
                        prev.appliedAt = now - elapsed
                        prev.caster = "player"
                    else
                        -- Immediately refresh expire/appliedAt when inferred combo
                        -- differs from stored combo. We no longer require multiple
                        -- corroborating ticks.
                        if combo ~= (prev.comboPoints or 0) then
                            prev.expire = now + remainingDur
                            prev.appliedAt = now - elapsed
                            prev.caster = "player"
                            -- No pending calibration to clear in one-shot inference flow.
                        else
                            prev.expire = prev.expire or (now + remainingDur)
                        end
                    end
                    prev.texture = prev.texture or (addon.iconPaths and addon.iconPaths["Rip"]) or prev.texture
                    -- Update comboPoints for display only (apply forcedCombo if set)
                    prev.comboPoints = forcedCombo or combo
                    prev.appliedInCombat = (type(UnitAffectingCombat) == "function" and UnitAffectingCombat("player")) or
                        false
                    if addon.DEBUG_DEBUFF_CACHE then
                        DEFAULT_CHAT_FRAME:AddMessage("FDT: Inferred Rip combo=" ..
                            tostring(combo) ..
                            " err=" .. tostring(err) .. " dur=" .. tostring(dur) .. " histCount=" .. tostring(histCount))
                    end
                    pcall(function() addon:RefreshIcons() end)
                else
                    if addon.DEBUG_DEBUFF_CACHE then
                        DEFAULT_CHAT_FRAME:AddMessage(
                            "FDT: Rip tick recorded but combo not inferred yet. err=" .. tostring(err))
                    end
                end
            end
        end
    elseif e == "CHAT_MSG_SPELL_AURA_GONE_SELF" or e == "CHAT_MSG_SPELL_AURA_GONE_OTHER" then
        local msg = arg1
        if msg then
            if string.find(msg, "Rake fades", 1, true) then addon:RemoveDebuff("Rake") end
            if string.find(msg, "Rip fades", 1, true) then addon:RemoveDebuff("Rip") end
            if string.find(msg, "Pounce Bleed fades", 1, true) then addon:RemoveDebuff("Pounce Bleed") end
            if string.find(msg, "Faerie Fire fades", 1, true) then addon:RemoveDebuff("Faerie Fire (Feral)") end
        end
    elseif e == "CHAT_MSG_SPELL_SELF_DAMAGE" then
        local msg = arg1
        if not msg then return end

        -- Detect your damage line for each tracked ability
        if string.find(msg, "Your Rake hits", 1, true) or string.find(msg, "Your Rake crits", 1, true) then
            addon:RegisterDebuff("Rake")
        elseif string.find(msg, "Your Rip hits", 1, true) or string.find(msg, "Your Rip crits", 1, true) then
            if addon.DEBUG_DEBUFF_CACHE then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "FDT: Rip registered! CHAT_MSG_SPELL_SELF_DAMAGE")
            end
            addon:RegisterDebuff("Rip")
        elseif string.find(msg, "Your Pounce hits", 1, true) or string.find(msg, "Your Pounce crits", 1, true) then
            addon:RegisterDebuff("Pounce Bleed")
        elseif string.find(msg, "Your Faerie Fire hits", 1, true) or string.find(msg, "Your Faerie Fire crits", 1, true) then
            addon:RegisterDebuff("Faerie Fire (Feral)")
        end

        -- UNIT_HEALTH events (arg1 contains unit id)
        if e == "UNIT_HEALTH" then
            local unit = arg1
            -- Determine whether this health update refers to the current target
            local refersToTarget = false
            if unit == "target" then refersToTarget = true end
            if not refersToTarget and type(UnitGUID) == "function" and addon.currentTargetGUID then
                local uGUID = UnitGUID(unit)
                if uGUID and uGUID == addon.currentTargetGUID then refersToTarget = true end
            end
            if not refersToTarget then return end

            -- Robust death detection for the target
            local dead = false
            if type(UnitIsDeadOrGhost) == "function" then
                dead = UnitIsDeadOrGhost("target")
            end
            if not dead and type(UnitIsDead) == "function" then
                dead = UnitIsDead("target")
            end
            if not dead and type(UnitIsGhost) == "function" then
                dead = UnitIsGhost("target")
            end
            if not dead and type(UnitHealth) == "function" then
                local hp = UnitHealth("target") or 0
                if hp <= 0 then dead = true end
            end

            if dead then
                local key = addon.currentTargetKey or (type(UnitGUID) == "function" and UnitGUID("target")) or
                    addon.currentTargetName
                if key then
                    if addon.DEBUG_DEBUFF_CACHE then
                        DEFAULT_CHAT_FRAME:AddMessage(
                            "FDT: UNIT_HEALTH death detected, deleting cache for key=" .. tostring(key))
                    end
                    addon:DeleteCachedDebuffs(key)
                else
                    if addon.DEBUG_DEBUFF_CACHE then
                        DEFAULT_CHAT_FRAME:AddMessage(
                            "FDT: UNIT_HEALTH death detected, but no key available to delete")
                    end
                end
                addon:ResetIcons()
            end
        end
    elseif e == "UNIT_AURA" then
        for i = 1, 16 do
            local name, _, _, _, _, duration, expirationTime, _, _, spellId = UnitBuff("target", i)
            if not name then break end
            if addon:IsTrackedDebuff(spellId) then
                addon:UpdateDebuff(spellId, duration, expirationTime)
            end
        end
    end
end)

-- OnUpdate
local t = 0
frame:SetScript("OnUpdate", function()
    local e = arg1 or 0.05
    t = t + e
    if t >= 0.2 then
        t = 0; addon:RefreshIcons()
        if not UnitExists("target") or not UnitCanAttack("player", "target") then addon:ResetIcons() end
    end
end)
