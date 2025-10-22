This file contains short, actionable guidance for AI coding assistants working on the FeralDebuffTracker WoW addon.

High-level intent

- Purpose: lightweight World of Warcraft Classic-era (TurtleWoW) addon that tracks feral druid debuffs (Rake, Rip, Pounce Bleed, Faerie Fire (Feral)) and displays timers and combo point info in a small movable frame.
- Runtime: in-game Lua running inside the WoW client; no external build system. Edits must preserve load order as defined in `FeralDebuffTracker.toc`.

Key files & architecture

- `FeralDebuffTracker.toc` — load order and what the client loads. Keep file order intact when renaming or moving files.
- `FeralDebuffTracker.xml` — defines the global frame `FeralDebuffTrackerFrame` and mouse/drag scripts. UI elements are created in `UI.lua` and assume this frame name.
- `Core.lua` — initialization, slash commands (`/fdt`), persistent position saved to `FeralDebuffTrackerDB`, lock/unlock behavior. Sets `FeralDebuffTracker` global table and `frame` global reference.
- `UI.lua` — creates textures, fontstrings and maps them into tables `addon.debuffs`, `addon.timers`, `addon.cpTexts`. Uses texture paths from `addon.iconPaths`. Rebuilds UI on VARIABLES_LOADED if frame is not yet defined.
- `DebuffLogic.lua` — rules for registering, refreshing and removing debuffs. Contains hard-coded duration table and Rip duration logic based on combo points.
- `Events.lua` — registers WoW events (e.g. `CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE`, `PLAYER_COMBO_POINTS`) and parses combat log text to call `RegisterDebuff`/`RemoveDebuff`. Uses global `event`, `arg1`, `GetTime()`, and WoW API functions like `GetComboPoints`, `UnitExists`, `UnitCanAttack`.

Project-specific conventions and important details

- Global addon table: code assumes a single global `FeralDebuffTracker` table (set in `Core.lua`). Reference it with `local addon = FeralDebuffTracker` in modules.
- UI identification: UI code constructs global names like `FeralDebuffTracker_Pounce` and timers `FeralDebuffTracker_Pounce_Timer`. Use `getglobal(name)` when interoperating with XML-created frame children or when only the string name is available.
- Persistent settings: stored in `FeralDebuffTrackerDB` global; keys: `point`, `relPoint`, `x`, `y`, `locked`.
- String matching: combat events are parsed via plain `string.find(msg, "literal", 1, true)` (plain-text compare). Be careful when changing text to support localization — current code is English-specific.
- Time update cadence: `OnUpdate` runs every ~0.2s to refresh timers. Avoid heavy work inside `OnUpdate` and keep operations lightweight.

Safe edit rules for AI

- Preserve the `.toc` order. If you add new files, list them in the `.toc` in desired load order.
- Do not change global names (`FeralDebuffTracker`, `FeralDebuffTrackerFrame`, `FeralDebuffTrackerDB`) unless you update all references and the XML/toc accordingly.
- When modifying event parsing in `Events.lua`, respect the WoW event argument model (`event`, `arg1`, etc.). Tests outside the client can't fully validate event behavior — prefer small, localizable changes and explain assumptions.
- Avoid introducing dependencies or external packages — this addon runs entirely in-game with the WoW Lua runtime.

Examples of typical edits

- Add a new tracked spell: add icon path in `UI.lua`'s `iconPaths`, add duration in `DebuffLogic.lua`'s `durations` table, update the message parsing in `Events.lua` to recognize the combat log text, and ensure the order in `UI.lua` includes the key.
- Change Rip durations: modify logic in `DebuffLogic.lua:RegisterDebuff` where Rip sets duration based on combo points. Keep use of `addon.lastNonZeroComboPoints` for refresh behavior.

Developer workflows

- No build step. Install by placing folder under `Interface/AddOns/` in the TurtleWow client and reload UI in-game (`/reload` or relog). Use `/fdt unlock` to move the frame; `/fdt lock` to freeze it.
- Debugging: add `DEFAULT_CHAT_FRAME:AddMessage("...")` for in-game log, or use temporary `print()` for quick output. Be cautious — spammy output hurts playability.

If something is unclear

- Ask for the target change (example: add new debuff X) and whether localization is required. Provide exact in-game combat log samples if you want robust parsing.

Compatibility notes for AI editors

- Avoid using the `#` length operator on strings or tables in generated code — some classic/TurtleWoW Lua runtimes may not support `#` consistently. Use `string.len(s)` for string lengths or manual counting loops for tables.
- Avoid calling string methods in method form like `msg:match(...)` without a guard. Prefer `type(string) == "table" and type(string.match) == "function" and string.match(msg, ...)` or a safe fallback using `string.find`/`string.sub` to parse text.

End of file.
