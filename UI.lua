local addon = FeralDebuffTracker
local frame = addon.frame

addon.iconPaths = {
    Pounce = "Interface\\Icons\\Ability_Druid_SupriseAttack",
    Rake   = "Interface\\Icons\\Ability_Druid_Disembowel",
    Rip    = "Interface\\Icons\\Ability_GhoulFrenzy",
    FF     = "Interface\\Icons\\Spell_Nature_FaerieFire",
}

addon.debuffs, addon.timers, addon.cpTexts, addon.order = {}, {}, {}, {"Pounce","Rake","Rip","FF"}

local last
function FeralDebuffTracker_UI_Rebuild()
    local addon = FeralDebuffTracker
    local frame = addon.frame or getglobal("FeralDebuffTrackerFrame")
    if not frame then return end

    addon.iconPaths = {
        Pounce = "Interface\\Icons\\Ability_Druid_SupriseAttack",
        Rake   = "Interface\\Icons\\Ability_Druid_Disembowel",
        Rip    = "Interface\\Icons\\Ability_GhoulFrenzy",
        FF     = "Interface\\Icons\\Spell_Nature_FaerieFire",
    }

    addon.debuffs, addon.timers, addon.cpTexts = {}, {}, {}
    local last
    for _, key in ipairs({"Pounce","Rake","Rip","FF"}) do
        local path = addon.iconPaths[key]
        local texName = "FeralDebuffTracker_"..key
        local tex = getglobal(texName)
        if not tex then
            tex = frame:CreateTexture(texName, "ARTWORK")
            tex:SetWidth(40)
            tex:SetHeight(40)
        end
        if not last then
            tex:SetPoint("LEFT", frame, "LEFT", 6, 0)
        else
            tex:SetPoint("LEFT", last, "RIGHT", 10, 0)
        end
        tex:SetTexture(path)
        tex:SetAlpha(0.3)

        local textName = "FeralDebuffTracker_"..key.."_Timer"
        local text = getglobal(textName)
        if not text then
            text = frame:CreateFontString(textName, "OVERLAY", "GameFontNormal")
            text:SetPoint("CENTER", tex, "CENTER")
            text:SetFont("Fonts\\FRIZQT__.TTF", 20, "OUTLINE")
        end

        local cpName = "FeralDebuffTracker_"..key.."_CP"
        local cpText = getglobal(cpName)
        if not cpText then
            cpText = frame:CreateFontString(cpName, "OVERLAY", "GameFontNormalSmall")
            cpText:SetPoint("BOTTOM", tex, "BOTTOM", 0, -2)
            cpText:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
        end

        addon.debuffs[path], addon.timers[path], addon.cpTexts[path] =
            tex:GetName(), text:GetName(), cpText:GetName()
        last = tex
    end
    -- Cleanup any leftover globals from previous runs that match our naming but are not expected
    local expected = {}
    for _, name in pairs(addon.debuffs) do expected[name] = true end
    for _, name in pairs(addon.timers) do expected[name] = true end
    for _, name in pairs(addon.cpTexts) do expected[name] = true end
    -- Scan globals and hide unexpected FeralDebuffTracker_ objects
    for k, v in pairs(_G) do
        if type(k) == "string" and string.sub(k,1,19) == "FeralDebuffTracker_" then
            if not expected[k] and type(v) == "table" then
                -- Best-effort hide/clear to remove visual duplicates
                pcall(function()
                    if v.Hide then v:Hide() end
                    if v.SetTexture then v:SetTexture(nil) end
                    if v.SetText then v:SetText("") end
                end)
            end
        end
    end
end


-- Ensure Core.lua has run and frame exists
if not FeralDebuffTracker.frame then
    -- If frame isn't ready yet, wait until VARIABLES_LOADED
    local temp = CreateFrame("Frame")
    temp:RegisterEvent("VARIABLES_LOADED")
    temp:SetScript("OnEvent", function()
        temp:UnregisterAllEvents()
        -- Run icon creation again now that frame exists
        FeralDebuffTracker_UI_Rebuild()
    end)
else
    FeralDebuffTracker_UI_Rebuild()
end
