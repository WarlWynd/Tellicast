--[[
  Tellicast/init.lua  -  Heal/buff characters who send you a keyword in a tell.
  Version 1.3.1  (see CHANGELOG.md in this folder)

  Install:  put this file in your MacroQuest "lua" folder as Tellicast\init.lua.
  Run:      /lua run tellicast
  Stop:     /lua stop tellicast   (or /tellicast quit)

  In-game commands:
    /tellicast                      toggle the window
    /tellicast show                 show the window
    /tellicast hide                 hide the window (Tellicast keeps running)
    /tellicast add <kw> <spell>     add or change a keyword
    /tellicast remove <kw>          remove a keyword
    /tellicast allow <name>         always allow a character
    /tellicast deny <name>          remove a character from the allow list
    /tellicast on <kw>              make a keyword active
    /tellicast off <kw>             turn a keyword off (keeps it in the list)
    /tellicast pause                pause / resume answering requests
    /tellicast version              show the Tellicast version
    /tellicast quit                 stop the script

  Personas: keywords are saved separately for each persona (class), so a
  character's Cleric and Wizard personas each have their own list. Switching
  persona swaps the keyword list automatically. "Who can ask" settings are
  shared by all of a character's personas.
    config/Tellicast_<Server>_<Name>.lua          who can ask, replies, listening
    config/Tellicast_<Server>_<Name>_<CLASS>.lua  keywords for one persona
  Settings saved under the old TellBot name (config/TellBot_*.lua) are picked
  up automatically and saved again under the Tellicast name.
  On first run, keywords and allowed names are imported from the old
  TellBot_<Name>.ini if one is found.

  Players send:  /tell Yourname <keyword>    (or "help" for the list)
           or:   /tell Yourname menu        (if "Allow menu" is ticked: one line per
                                             keyword, like "[heal] Superior Healing")
           or:   /g <keyword>               (group chat, if enabled)
           or:   /gu <keyword>              (guild chat, if enabled)
           or:   /say <keyword>             (if "Allow say" is ticked)
  Replies go back by tell, group or guild, the same way the request came.
  Public chat (/say, /ooc, /shout and so on) never gets a reply: requests heard
  there just get the spell or command.

  Use Assist: tick "Use Assist" next to a keyword and Tellicast will
  /assist whoever asked, wait 2 seconds, and cast that spell on their target
  (e.g. a slow, a nuke, or a heal on a groupmate or pet) instead of on them. Resurrection spells work the same
  way: tick "Use Assist", target the corpse, and send the keyword.

  Commands: instead of a spell, a keyword can run any command that starts with
  "/", such as "/pet attack". With "Use Assist" ticked, Tellicast assists the
  requester first, so "/pet attack" sends your pet at their target.
  {who} in a command is replaced with the requester's name, e.g. "/target {who}".
]]

local VERSION = '1.3.1'   -- bump this and add a CHANGELOG.md entry with each change

local mq = require('mq')
local ImGui = require('ImGui')

local me = mq.TLO.Me.CleanName()
local server = mq.TLO.EverQuest.Server() or 'server'

-- Personas: one character can switch classes, so keywords are saved per class.
-- "Who can ask" settings are shared by all of a character's personas.
local function currentPersona()
    local short = mq.TLO.Me.Class.ShortName() or 'UNK'
    local name = mq.TLO.Me.Class.Name() or short
    return short, name
end

local personaShort, personaName = currentPersona()

local function charPath()
    return string.format('%s/Tellicast_%s_%s.lua', mq.configDir, server, me)
end
local function personaPath(short)
    return string.format('%s/Tellicast_%s_%s_%s.lua', mq.configDir, server, me, short or personaShort)
end
-- Settings files from before the project was renamed from TellBot to Tellicast
local function oldCharPath()
    return string.format('%s/TellBot_%s_%s.lua', mq.configDir, server, me)
end
local function oldPersonaPath(short)
    return string.format('%s/TellBot_%s_%s_%s.lua', mq.configDir, server, me, short or personaShort)
end
local legacyPath = string.format('%s/TellBot_%s.lua', mq.configDir, me)   -- before personas

-- Settings stored in the persona file; everything else is character-wide
local PERSONA_KEYS = { keywords = true, offensive = true, inactive = true, quiet = true, noSight = true }

local settings = {
    allowAnyone = false,
    allowGroup  = true,
    allowGuild  = true,
    allowSay    = false, -- take requests heard in /say (they never get a reply)
    replies     = true,
    listenGroup = true,
    listenGuild = false,
    allowMenu   = false, -- reply to "menu" with each keyword and its spell/command
    offensive   = {},   -- keyword -> true: /assist the requester and cast on their target
    inactive    = {},   -- keyword -> true: turned off (kept in the list, but ignored)
    quiet       = {},   -- keyword -> true: no replies for this keyword
    noSight     = {     -- lowercase spell name -> true: skip line-of-sight and range checks
        ['call of the hero'] = true,
    },
    paused      = false,
    allowed     = {},   -- lowercase name -> display name
    keywords    = {     -- lowercase keyword -> spell name
        heal = 'Superior Healing',
        hot  = 'Celestial Remedy',
        sow  = 'Spirit of Wolf',
    },
}

local running   = true
local openGUI   = true
local dirty     = false
local queue     = {}
local history   = {}
local MAX_QUEUE = 10
local MAX_LOG   = 15

-- UI input buffers
local newKw, newSpell, newName = '', '', ''

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function trim(s)
    return (s or ''):match('^%s*(.-)%s*$')
end

local function echo(fmt, ...)
    print(string.format('\at[Tellicast]\ax ' .. fmt, ...))
end

local function addLog(fmt, ...)
    table.insert(history, 1, os.date('%H:%M:%S') .. '  ' .. string.format(fmt, ...))
    while #history > MAX_LOG do table.remove(history) end
end

-- Reply on the channel the request came from: 'tell', 'group', 'guild' or 'self'.
-- Any other channel is public chat (/say, /ooc ...) and never gets a reply.
local function say(who, channel, text)
    if channel == 'self' then
        echo('%s', text)
    elseif channel == 'group' then
        mq.cmdf('/g %s', text)
    elseif channel == 'guild' then
        mq.cmdf('/gu %s', text)
    elseif channel == 'tell' then
        mq.cmdf('/tell %s %s', who, text)
    end
end

-- Public chat channels: requests are taken, but nothing is ever said back
local PUBLIC = { say = true }

-- The keyword being handled right now, so replies can follow its "Send Replies" box
local replyKw = nil

local function keywordReplies(kw)
    return not (settings.quiet and settings.quiet[kw])
end

-- Replies need both the global "Send replies" setting and the keyword's own box
local function reply(who, channel, fmt, ...)
    if not settings.replies then return end
    if replyKw and not keywordReplies(replyKw) then return end
    say(who, channel, string.format(fmt, ...))
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function isActive(kw)
    return not (settings.inactive and settings.inactive[kw])
end

-- Only active keywords are offered to players
local function keywordList()
    local active = {}
    for _, kw in ipairs(sortedKeys(settings.keywords)) do
        if isActive(kw) then active[#active + 1] = kw end
    end
    return #active > 0 and table.concat(active, ', ') or '(none right now)'
end

---------------------------------------------------------------------
-- Settings: load / save / import from the old .ini
---------------------------------------------------------------------
local function readTable(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if ok and type(data) == 'table' then return data end
    return nil
end

local function saveSettings()
    local charData, personaData = {}, {}
    for k, v in pairs(settings) do
        if PERSONA_KEYS[k] then personaData[k] = v else charData[k] = v end
    end
    mq.pickle(charPath(), charData)
    mq.pickle(personaPath(), personaData)
end

-- Fresh, empty keyword settings for a persona that has never been set up
local function emptyPersona()
    return {
        keywords  = {},
        offensive = {},
        inactive  = {},
        quiet     = {},
        noSight   = { ['call of the hero'] = true },
    }
end

-- Load this persona's keywords (character settings are left as they are).
-- Returns false if the persona has no saved file yet.
-- Keywords, names and spell flags are matched without regard to case, so store
-- every key in lowercase (fixes keys typed by hand in the settings files)
local function lowerKeys(t)
    if type(t) ~= 'table' then return {} end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == 'string' then out[k:lower()] = v else out[k] = v end
    end
    return out
end

local function normalizeSettings()
    for _, key in ipairs({ 'keywords', 'offensive', 'inactive', 'quiet', 'noSight', 'allowed' }) do
        settings[key] = lowerKeys(settings[key])
    end
end

local function loadPersona()
    local data = readTable(personaPath()) or readTable(oldPersonaPath())
    local fresh = emptyPersona()
    for k in pairs(PERSONA_KEYS) do
        settings[k] = (data and data[k] ~= nil) and data[k] or fresh[k]
    end
    normalizeSettings()
    return data ~= nil
end

-- Returns true if any saved settings were found (new or pre-persona format)
local function loadSettings()
    local charData = readTable(charPath())
    if not charData then
        charData = readTable(oldCharPath())
        if charData then echo('Brought over your settings from TellBot.') end
    end
    if charData then
        for k, v in pairs(charData) do
            if not PERSONA_KEYS[k] then settings[k] = v end
        end
        settings.allowed = lowerKeys(settings.allowed)
        if not loadPersona() then
            echo('First time on the %s persona: no keywords yet. Add them in the Tellicast window.', personaName)
        end
        return true
    end

    -- Settings from before personas: everything was in one file per character.
    -- Its keywords go to the persona you're on now.
    local legacy = readTable(legacyPath)
    if legacy then
        for k, v in pairs(legacy) do settings[k] = v end
        normalizeSettings()
        echo('Moved your Tellicast settings to the %s persona. Other personas start with no keywords.', personaName)
        return true
    end
    return false
end

-- Switched persona: save the old one's keywords, load the new one's
local function checkPersona()
    local short, name = currentPersona()
    if short == personaShort or short == 'UNK' then return end
    saveSettings()
    personaShort, personaName = short, name
    queue = {}
    if loadPersona() then
        echo('Persona changed to %s. Keywords: %s', name, keywordList())
    else
        echo('Persona changed to %s. No keywords set up for it yet.', name)
    end
end

local function importIni()
    local fileName = string.format('TellBot_%s.ini', me)
    local candidates = { mq.configDir .. '/' .. fileName }
    local ok, macroDir = pcall(function() return mq.TLO.MacroQuest.Path('macros')() end)
    if ok and macroDir then candidates[#candidates + 1] = macroDir .. '/' .. fileName end

    for _, path in ipairs(candidates) do
        local f = io.open(path, 'r')
        if f then
            local section
            local keywords, allowed = {}, {}
            for rawLine in f:lines() do
                local line = trim(rawLine)
                local s = line:match('^%[(.+)%]$')
                if s then
                    section = s:lower()
                else
                    local k, v = line:match('^([^=]+)=(.*)$')
                    if k then
                        k, v = trim(k), trim(v)
                        if section == 'keywords' then
                            keywords[k:lower()] = v
                        elseif section == 'allowed' and v ~= '0' and k ~= 'Exampletoon' then
                            allowed[k:lower()] = k
                        elseif section == 'settings' then
                            local on = (v == '1')
                            if k == 'AllowAnyone' then settings.allowAnyone = on
                            elseif k == 'AllowGroup' then settings.allowGroup = on
                            elseif k == 'AllowGuild' then settings.allowGuild = on
                            elseif k == 'Replies' then settings.replies = on end
                        end
                    end
                end
            end
            f:close()
            if next(keywords) then settings.keywords = keywords end
            settings.allowed = allowed
            echo('Imported settings from %s', path)
            return true
        end
    end
    return false
end

---------------------------------------------------------------------
-- Permission check
---------------------------------------------------------------------
local function isAllowed(who)
    if settings.allowAnyone then return true end
    if settings.allowed[who:lower()] then return true end
    if settings.allowGroup and mq.TLO.Group.Member(who)() then return true end
    if settings.allowGuild then
        local myGuild = mq.TLO.Me.Guild()
        if myGuild and myGuild ~= '' and mq.TLO.Spawn('pc =' .. who).Guild() == myGuild then
            return true
        end
    end
    return false
end

---------------------------------------------------------------------
-- Tell handling: queue requests, cast from the main loop
---------------------------------------------------------------------
local isOffensive   -- defined below; used by the menu

local function handleRequest(sender, msg, channel)
    local kw = trim(msg):lower()
    if kw == '' then return end

    -- Group chat (others or ourselves) is always allowed; tells and public chat
    -- go through the permission check
    if (channel == 'tell' or PUBLIC[channel]) and not isAllowed(sender) then return end

    -- Public chat gets no replies, so "help" and "menu" do nothing there
    if PUBLIC[channel] and (kw == 'help' or kw == 'list' or kw == 'menu') then return end

    if kw == 'help' or kw == 'list' then
        say(sender, channel, 'Keywords: ' .. keywordList())
        return
    end

    -- "menu": one line per active keyword, e.g. "[heal] Superior Healing"
    if kw == 'menu' and settings.allowMenu then
        local lines = 0
        for _, k in ipairs(sortedKeys(settings.keywords)) do
            if isActive(k) then
                if lines > 0 then mq.delay(300) end   -- space the lines out so none get dropped
                say(sender, channel, string.format('[%s] %s%s', k, settings.keywords[k],
                    isOffensive(k) and ' (Use Assist)' or ''))
                lines = lines + 1
            end
        end
        if lines == 0 then say(sender, channel, 'No keywords right now.') end
        return
    end

    local spell = settings.keywords[kw]
    if not spell or not isActive(kw) then return end
    replyKw = kw

    if settings.paused then
        reply(sender, channel, 'Tellicast is paused right now.')
        return
    end

    for _, r in ipairs(queue) do
        if r.who:lower() == sender:lower() and r.kw == kw then return end
    end
    if #queue >= MAX_QUEUE then
        reply(sender, channel, 'Busy, try again in a moment.')
        return
    end

    table.insert(queue, { who = sender, kw = kw, spell = spell, channel = channel })
    addLog('%s asked for %s (%s) via %s', sender, kw, spell, channel)
end

local function onTell(line, sender, msg)
    handleRequest(sender, msg, 'tell')
end

local function onGroup(line, sender, msg)
    if settings.listenGroup then
        handleRequest(sender, msg, 'group')
    end
end

-- Our own group messages show as "You tell your party, '...'"
local function onSelfGroup(line, msg)
    if settings.listenGroup then
        handleRequest(me, msg, 'self')
    end
end

-- Guild chat works like group chat: only guildmates can speak there
local function onGuild(line, sender, msg)
    if settings.listenGuild then
        handleRequest(sender, msg, 'guild')
    end
end

-- Our own guild messages show as "You say to your guild, '...'"
local function onSelfGuild(line, msg)
    if settings.listenGuild then
        handleRequest(me, msg, 'self')
    end
end

-- /say: anyone nearby can hear it, so only players who pass "Who can ask" count,
-- and they never get a reply in /say. NPCs and pets saying things are ignored.
local function onSay(line, sender, msg)
    if not settings.allowSay then return end
    if not mq.TLO.Spawn('pc =' .. sender)() then return end
    handleRequest(sender, msg, 'say')
end

-- Our own /say shows as "You say, '...'"
local function onSelfSay(line, msg)
    if settings.allowSay then
        handleRequest(me, msg, 'self')
    end
end

-- True if this spell skips the line-of-sight and range checks: either ticked in
-- the window, or a "summon player" spell (spell effect 82, e.g. Call of the Hero)
local function ignoresSight(spellName)
    settings.noSight = settings.noSight or {}
    if settings.noSight[spellName:lower()] then return true end
    local ok, summons = pcall(function() return mq.TLO.Spell(spellName).HasSPA(82)() end)
    return ok and summons == true
end

function isOffensive(kw)
    settings.offensive = settings.offensive or {}
    return settings.offensive[kw] == true
end

-- Range and line-of-sight check against a spawn; replies and returns false if it fails
local function inReach(r, spellName, spawn, whatFor)
    if ignoresSight(spellName) then return true end
    local range = mq.TLO.Spell(spellName).MyRange() or 0
    if range > 0 and (spawn.Distance() or 9999) > range then
        reply(r.who, r.channel, "%s is out of range for %s.", whatFor, spellName)
        return false
    end
    if not spawn.LineOfSight() then
        reply(r.who, r.channel, "I can't see %s (no line of sight).", whatFor)
        return false
    end
    return true
end

-- A keyword's action is a command (like "/pet attack") instead of a spell when it starts with "/"
local function isCommand(action)
    return (action or ''):match('^%s*/') ~= nil
end

-- /assist the requester, wait 2 seconds (EverQuest's "/pause 20"), and return the
-- name of their target, or nil (with a reply) if there's nothing valid to act on.
-- If I asked for it myself, use my current target.
-- True for resurrection spells (spell effect 81), which are cast on corpses
local function isRez(spellName)
    local ok, rez = pcall(function() return mq.TLO.Spell(spellName).HasSPA(81)() end)
    if ok and rez == true then return true end
    local okSub, sub = pcall(function() return mq.TLO.Spell(spellName).Subcategory() end)
    if okSub and sub and sub:lower():find('resurrect', 1, true) then return true end
    local lower = (spellName or ''):lower()
    return lower:find('resurrect', 1, true) ~= nil or lower:find('reviv', 1, true) ~= nil
end

-- True for beneficial spells (heals, buffs), which may be cast on players when on Assist
local function isBeneficial(spellName)
    local ok, ben = pcall(function() return mq.TLO.Spell(spellName).Beneficial() end)
    if ok and ben ~= nil then return ben == true end
    local okT, stype = pcall(function() return mq.TLO.Spell(spellName).SpellType() end)
    return okT and stype ~= nil and stype:lower():find('beneficial', 1, true) ~= nil
end

-- corpses: 'only' (rez spells), 'allow' (commands) or nil (other spells: never a corpse)
-- friendly: true for beneficial spells, so a player (even the requester) is a valid target
local function assistTarget(r, requesterID, isMe, what, corpses, friendly)
    if not isMe then
        mq.cmdf('/assist %s', r.who)
        mq.delay(2000)
    end
    local tid = mq.TLO.Target.ID() or 0
    local ttype = mq.TLO.Target.Type() or ''

    if corpses == 'only' then
        if tid == 0 or ttype ~= 'Corpse' then
            reply(r.who, r.channel, isMe and 'Target a corpse for %s.' or 'Target a corpse for %s, then ask again.', what)
            return nil
        end
    elseif friendly then
        if tid == 0 or ttype == 'Corpse' then
            reply(r.who, r.channel, isMe and 'Target someone for %s.' or "You don't have a target for %s.", what)
            return nil
        end
    elseif tid == 0 or tid == requesterID or ttype == 'PC' or (ttype == 'Corpse' and corpses ~= 'allow') then
        reply(r.who, r.channel, isMe and 'Target something for %s.' or "You don't have a target for %s.", what)
        return nil
    end
    return mq.TLO.Target.CleanName() or 'your target'
end

-- Run a command keyword. {who} in the command is replaced with the requester's name.
local function runCommand(r, requesterID, isMe, offensive)
    local cmd = trim(r.spell):gsub('{who}', r.who)
    local targetName
    if offensive then
        targetName = assistTarget(r, requesterID, isMe, cmd, 'allow')
        if not targetName then return end
    end
    echo('Running %s%s (for %s)', cmd, targetName and (' on ' .. targetName) or '', r.who)
    addLog('  running %s%s', cmd, targetName and (' on ' .. targetName) or '')
    mq.cmd(cmd)
    if targetName then
        reply(r.who, r.channel, 'Done: %s on %s', cmd, targetName)
    else
        reply(r.who, r.channel, 'Done: %s', cmd)
    end
end

-- The memorized spell matching this name, ignoring case ("spirit of wolf" finds
-- "Spirit of Wolf"); returns the spell's exact name, or nil if it isn't memorized
local function memorizedName(spellName)
    local want = trim(spellName):lower()
    for i = 1, (mq.TLO.Me.NumGems() or 12) do
        local name = mq.TLO.Me.Gem(i).Name()
        if name and name:lower() == want then return name end
    end
    if mq.TLO.Me.Gem(spellName)() then return mq.TLO.Me.Gem(mq.TLO.Me.Gem(spellName)()).Name() or spellName end
    return nil
end

local function processRequest(r)
    replyKw = r.kw
    local who, spellName = r.who, r.spell
    local isMe = (r.channel == 'self' or who:lower() == me:lower())
    local offensive = isOffensive(r.kw)

    local id = isMe and mq.TLO.Me.ID() or mq.TLO.Spawn('pc =' .. who).ID()
    if not id or id == 0 then
        reply(who, r.channel, "You're not in my zone.")
        return
    end

    -- Commands skip all the spell checks
    if isCommand(spellName) then
        runCommand(r, id, isMe, offensive)
        return
    end

    local exact = memorizedName(spellName)
    if exact then spellName = exact end
    if not exact then
        echo('%s is not memorized (requested by %s)', spellName, who)
        addLog('  %s not memorized', spellName)
        reply(who, r.channel, "I don't have %s memorized right now.", spellName)
        return
    end

    -- Beneficial spells: check reach to the person asking before doing anything
    if not offensive and not inReach(r, spellName, mq.TLO.Spawn('id ' .. id), isMe and 'myself' or 'you') then
        return
    end

    if (mq.TLO.Me.CurrentMana() or 0) < (mq.TLO.Spell(spellName).Mana() or 0) then
        reply(who, r.channel, 'Not enough mana for %s.', spellName)
        return
    end

    -- Wait for any current cast to finish and for us to stop moving
    if mq.TLO.Me.Casting() then
        mq.delay(15000, function() return not mq.TLO.Me.Casting() end)
    end
    if mq.TLO.Me.Moving() then
        mq.delay(3000, function() return not mq.TLO.Me.Moving() end)
    end

    -- Wait for the gem to come off cooldown
    if not mq.TLO.Me.SpellReady(spellName)() then
        mq.delay(10000, function() return mq.TLO.Me.SpellReady(spellName)() end)
    end
    if not mq.TLO.Me.SpellReady(spellName)() then
        reply(who, r.channel, "%s isn't ready yet, try again shortly.", spellName)
        return
    end

    local targetName
    if offensive then
        -- Offensive: take the requester's target with /assist, wait, then cast on it.
        -- (If I asked for it myself, just use my current target.)
        local rez = isRez(spellName)
        targetName = assistTarget(r, id, isMe, spellName, rez and 'only' or nil,
            (not rez) and isBeneficial(spellName))
        if not targetName then return end
        if not inReach(r, spellName, mq.TLO.Target, targetName) then return end
    else
        mq.cmdf('/target id %d', id)
        mq.delay(2000, function() return mq.TLO.Target.ID() == id end)
        if mq.TLO.Target.ID() ~= id then return end
        targetName = who
    end

    echo('Casting %s on %s (for %s)', spellName, targetName, who)
    addLog('  casting %s on %s', spellName, targetName)
    reply(who, r.channel, 'Casting %s on %s', spellName, targetName)
    mq.cmdf('/cast "%s"', spellName)
    mq.delay(1000, function() return mq.TLO.Me.Casting() ~= nil end)
    mq.delay(20000, function() return not mq.TLO.Me.Casting() end)
end

---------------------------------------------------------------------
-- Window
---------------------------------------------------------------------
local function gemPicker()
    if ImGui.BeginCombo('##gempick', 'From gems') then
        local numGems = mq.TLO.Me.NumGems() or 8
        for i = 1, numGems do
            local name = mq.TLO.Me.Gem(i).Name()
            if name and ImGui.Selectable(string.format('%d: %s', i, name), false) then
                newSpell = name
            end
        end
        ImGui.EndCombo()
    end
end

local function drawKeywords()
    local toRemove
    if ImGui.BeginTable('##keywords', 8, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable + ImGuiTableFlags.Reorderable + ImGuiTableFlags.Hideable) then
        ImGui.TableSetupColumn('Active')
        ImGui.TableSetupColumn('Keyword')
        ImGui.TableSetupColumn('Spell or /command')
        ImGui.TableSetupColumn('Memmed')
        ImGui.TableSetupColumn('Use Assist')
        ImGui.TableSetupColumn('No LoS')
        ImGui.TableSetupColumn('Send Replies')
        ImGui.TableSetupColumn('')
        ImGui.TableHeadersRow()

        for _, kw in ipairs(sortedKeys(settings.keywords)) do
            local spell = settings.keywords[kw]
            ImGui.PushID(kw)
            ImGui.TableNextRow()

            -- Active: unticked keywords stay in the list but are ignored
            ImGui.TableNextColumn()
            settings.inactive = settings.inactive or {}
            local wasOn = isActive(kw)
            local nowOn = ImGui.Checkbox('##active', wasOn)
            if nowOn ~= wasOn then
                settings.inactive[kw] = (not nowOn) or nil
                dirty = true
            end

            ImGui.TableNextColumn()
            if wasOn then
                ImGui.Text(kw)
            else
                ImGui.TextColored(0.55, 0.55, 0.55, 1.0, kw .. ' (off)')
            end

            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(-1)
            local edited = ImGui.InputText('##spell', spell)
            if edited and edited ~= spell then
                settings.keywords[kw] = edited
                dirty = true
            end

            ImGui.TableNextColumn()
            if isCommand(spell) then
                ImGui.Text('Command')
            else
                ImGui.Text(memorizedName(spell) and 'Yes' or 'No')
            end

            -- Offensive: /assist the requester and cast on their target
            ImGui.TableNextColumn()
            settings.offensive = settings.offensive or {}
            local wasOff = settings.offensive[kw] == true
            local nowOff = ImGui.Checkbox('##offensive', wasOff)
            if nowOff ~= wasOff then
                settings.offensive[kw] = nowOff or nil
                dirty = true
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Assist whoever asked, wait 2 seconds, and cast on their target')
            end

            -- Tick for spells that don't need line of sight or range (e.g. Call of the Hero)
            ImGui.TableNextColumn()
            settings.noSight = settings.noSight or {}
            local key = spell:lower()
            local was = settings.noSight[key] == true
            local now = ImGui.Checkbox('##nolos', was)
            if now ~= was then
                settings.noSight[key] = now or nil
                dirty = true
            end

            -- Send Replies for this keyword (only matters while the global setting is on)
            ImGui.TableNextColumn()
            settings.quiet = settings.quiet or {}
            local wasReply = keywordReplies(kw)
            if not settings.replies then ImGui.BeginDisabled() end
            local nowReply = ImGui.Checkbox('##replies', wasReply)
            if not settings.replies then ImGui.EndDisabled() end
            if nowReply ~= wasReply then
                settings.quiet[kw] = (not nowReply) or nil
                dirty = true
            end
            if ImGui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled) then
                ImGui.SetTooltip(settings.replies and 'Send replies for this keyword'
                    or 'Replies are off for every keyword (Settings > Send replies)')
            end

            ImGui.TableNextColumn()
            if ImGui.SmallButton('Remove') then toRemove = kw end

            ImGui.PopID()
        end
        ImGui.EndTable()
    end

    if toRemove then
        settings.keywords[toRemove] = nil
        if settings.offensive then settings.offensive[toRemove] = nil end
        if settings.inactive then settings.inactive[toRemove] = nil end
        if settings.quiet then settings.quiet[toRemove] = nil end
        dirty = true
    end

    -- Add a new keyword
    ImGui.Text('Add keyword (spell name, or a command starting with / such as /pet attack):')
    ImGui.SetNextItemWidth(100)
    newKw = ImGui.InputText('##newkw', newKw)
    ImGui.SameLine()
    ImGui.SetNextItemWidth(200)
    newSpell = ImGui.InputText('##newspell', newSpell)
    ImGui.SameLine()
    ImGui.SetNextItemWidth(120)
    gemPicker()
    ImGui.SameLine()
    if ImGui.Button('Add') then
        local kw, spell = trim(newKw):lower(), trim(newSpell)
        if kw ~= '' and spell ~= '' then
            settings.keywords[kw] = spell
            newKw, newSpell = '', ''
            dirty = true
        end
    end
end

local function drawPermissions()
    local v
    v = ImGui.Checkbox('Allow anyone', settings.allowAnyone)
    if v ~= settings.allowAnyone then settings.allowAnyone = v; dirty = true end
    v = ImGui.Checkbox('Allow group members', settings.allowGroup)
    if v ~= settings.allowGroup then settings.allowGroup = v; dirty = true end
    v = ImGui.Checkbox('Allow guildmates', settings.allowGuild)
    if v ~= settings.allowGuild then settings.allowGuild = v; dirty = true end
    v = ImGui.Checkbox('Allow say', settings.allowSay == true)
    if v ~= (settings.allowSay == true) then settings.allowSay = v; dirty = true end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Take requests heard in /say from anyone allowed above. No replies are sent in /say.')
    end

    ImGui.Separator()
    ImGui.Text('Always allowed:')
    local toRemove
    for _, key in ipairs(sortedKeys(settings.allowed)) do
        ImGui.PushID('allow_' .. key)
        if ImGui.SmallButton('X') then toRemove = key end
        ImGui.SameLine()
        ImGui.Text(settings.allowed[key])
        ImGui.PopID()
    end
    if toRemove then
        settings.allowed[toRemove] = nil
        dirty = true
    end

    ImGui.SetNextItemWidth(150)
    newName = ImGui.InputText('##newname', newName)
    ImGui.SameLine()
    if ImGui.Button('Allow') then
        local name = trim(newName)
        if name ~= '' then
            settings.allowed[name:lower()] = name
            newName = ''
            dirty = true
        end
    end
    ImGui.SameLine()
    if ImGui.Button('Allow target') then
        local name = mq.TLO.Target.CleanName()
        if name and mq.TLO.Target.Type() == 'PC' then
            settings.allowed[name:lower()] = name
            dirty = true
        end
    end
end

local function drawSettings()
    local v
    v = ImGui.Checkbox('Listen to group chat', settings.listenGroup)
    if v ~= settings.listenGroup then settings.listenGroup = v; dirty = true end
    v = ImGui.Checkbox('Listen to guild chat', settings.listenGuild)
    if v ~= settings.listenGuild then settings.listenGuild = v; dirty = true end
    v = ImGui.Checkbox('Send replies', settings.replies)
    if v ~= settings.replies then settings.replies = v; dirty = true end
    v = ImGui.Checkbox('Allow menu', settings.allowMenu == true)
    if v ~= (settings.allowMenu == true) then settings.allowMenu = v; dirty = true end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Reply to "menu" with every active keyword and its spell or command, one per line')
    end
end

local function drawUI()
    if not openGUI then return end
    local show
    openGUI, show = ImGui.Begin(string.format('Tellicast - %s (%s)###Tellicast%s', me, personaName, me), openGUI)
    if show then
        ImGui.Text(string.format('v%s    Persona: %s    Status: %s    Queue: %d', VERSION, personaName,
            settings.paused and 'PAUSED' or 'Listening', #queue))
        ImGui.SameLine()
        if ImGui.Button(settings.paused and 'Resume' or 'Pause') then
            settings.paused = not settings.paused
            dirty = true
        end

        if ImGui.CollapsingHeader('Keywords', ImGuiTreeNodeFlags.DefaultOpen) then
            drawKeywords()
        end
        if ImGui.CollapsingHeader('Who can ask') then
            drawPermissions()
        end
        if ImGui.CollapsingHeader('Settings') then
            drawSettings()
        end
        if ImGui.CollapsingHeader('Recent requests') then
            if #history == 0 then ImGui.Text('Nothing yet.') end
            for _, entry in ipairs(history) do ImGui.Text(entry) end
        end
    end
    ImGui.End()
end

---------------------------------------------------------------------
-- /tellicast command
---------------------------------------------------------------------
local function command(...)
    local args = { ... }
    local sub = (args[1] or ''):lower()

    if sub == '' then
        openGUI = not openGUI
    elseif sub == 'show' then
        openGUI = true
    elseif sub == 'hide' then
        openGUI = false
    elseif sub == 'add' and args[2] and args[3] then
        local kw = args[2]:lower()
        local spell = table.concat(args, ' ', 3):gsub('^"(.*)"$', '%1')
        settings.keywords[kw] = spell
        dirty = true
        echo('Added %s = %s', kw, spell)
    elseif sub == 'remove' and args[2] then
        settings.keywords[args[2]:lower()] = nil
        if settings.offensive then settings.offensive[args[2]:lower()] = nil end
        if settings.inactive then settings.inactive[args[2]:lower()] = nil end
        if settings.quiet then settings.quiet[args[2]:lower()] = nil end
        dirty = true
        echo('Removed %s', args[2]:lower())
    elseif sub == 'allow' and args[2] then
        settings.allowed[args[2]:lower()] = args[2]
        dirty = true
        echo('Allowed %s', args[2])
    elseif sub == 'deny' and args[2] then
        settings.allowed[args[2]:lower()] = nil
        dirty = true
        echo('Removed %s from the allow list', args[2])
    elseif (sub == 'on' or sub == 'off') and args[2] then
        local kw = args[2]:lower()
        if not settings.keywords[kw] then
            echo('No keyword "%s".', kw)
        else
            settings.inactive = settings.inactive or {}
            settings.inactive[kw] = (sub == 'off') or nil
            dirty = true
            echo('%s is now %s.', kw, sub == 'on' and 'active' or 'off')
        end
    elseif sub == 'version' then
        echo('Version %s', VERSION)
    elseif sub == 'pause' then
        settings.paused = not settings.paused
        dirty = true
        echo(settings.paused and 'Paused' or 'Resumed')
    elseif sub == 'quit' then
        running = false
    else
        echo('Commands: show | hide | add <kw> <spell> | remove <kw> | on <kw> | off <kw> | allow <name> | deny <name> | pause | version | quit')
    end
end

---------------------------------------------------------------------
-- Start up
---------------------------------------------------------------------
if not loadSettings() then
    importIni()
end
settings.allowOoc = nil   -- "Allow ooc" was in 1.3.0 only; drop it from saved settings
saveSettings()   -- writes the per-character and per-persona files

mq.event('TellicastTell', "#1# tells you, '#2#'", onTell)
mq.event('TellicastGroup', "#1# tells the group, '#2#'", onGroup)
mq.event('TellicastSelfGroup', "You tell your party, '#1#'", onSelfGroup)
mq.event('TellicastGuild', "#1# tells the guild, '#2#'", onGuild)
mq.event('TellicastSelfGuild', "You say to your guild, '#1#'", onSelfGuild)
mq.event('TellicastSay', "#1# says, '#2#'", onSay)
mq.event('TellicastSelfSay', "You say, '#1#'", onSelfSay)
mq.bind('/tellicast', command)
mq.imgui.init('Tellicast', drawUI)

echo('v%s running as %s (%s). Keywords: %s', VERSION, me, personaName, keywordList())
echo('Type /tellicast to show or hide the window.')

local nextPersonaCheck = 0
while running do
    if os.time() >= nextPersonaCheck then
        checkPersona()
        nextPersonaCheck = os.time() + 1
    end
    mq.doevents()
    if #queue > 0 then
        processRequest(table.remove(queue, 1))
    end
    if dirty then
        saveSettings()
        dirty = false
    end
    mq.delay(100)
end

mq.unbind('/tellicast')
echo('Stopped.')
