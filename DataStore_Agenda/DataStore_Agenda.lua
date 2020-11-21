--[[	*** DataStore_Agenda ***
Written by : Thaoky, EU-Marécages de Zangar
April 2nd, 2011
--]]

if not DataStore then return end

local addonName = "DataStore_Agenda"

_G[addonName] = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0", "AceTimer-3.0")

local addon = _G[addonName]

local THIS_ACCOUNT = "Default"

local AddonDB_Defaults = {
	global = {
		Options = {
			WeeklyResetDay = nil,		-- weekday (0 = Sunday, 6 = Saturday)
			WeeklyResetHour = nil,		-- 0 to 23
			NextWeeklyReset = nil,
		},
		Characters = {
			['*'] = {				-- ["Account.Realm.Name"]
				lastUpdate = nil,
				Calendar = {},
				Contacts = {},
				DungeonIDs = {		-- raid timers
                    ['*'] = { -- dungeon ID
                        name = nil,
                        resetTime = 0,
                        extended = false,
                        isRaid = false,
                        numEncounters = 0,
                        progress = 0,
                        bosses = {     -- raid timers for individual bosses
                            ['*'] = false, -- boss name
                        },
                    }
                },

				ItemCooldowns = {},	-- mysterious egg, disgusting jar, etc..
				LFGDungeons = {		-- info about LFG dungeons/raids
                    ['*'] = { -- dungeon ID
                        resetTime = 0,
                        count = 0,
                        bosses = {
                            ['*'] = false, -- boss name
                        }
                    }
                },
                WorldBosses = {
                    ['*'] = 0, -- bossID (same as instanceID)
                },
                
                expiredCalendar = {},
			}
		}
	}
}

-- *** Utility functions ***
local function GetOption(option)
	return addon.db.global.Options[option]
end

local function SetOption(option, value)
	addon.db.global.Options[option] = value
end

-- *** Scanning functions ***
local function ScanContacts()
	local contacts = addon.ThisCharacter.Contacts

	local oldValues = {}

	-- if a known contact disconnected, preserve the info we know about him
	for name, info in pairs(contacts) do
		if type(info) == "table" then		-- contacts were only saved as strings in earlier versions,  make sure they're not taken into account
			if info.level then
				oldValues[name] = {}
				oldValues[name].level = info.level
				oldValues[name].class = info.class
			end
		end
	end

	wipe(contacts)

	for i = 1, C_FriendList.GetNumFriends() do	-- only friends, not real id, as they're always visible
	   local name, level, class, zone, isOnline, note = C_FriendList.GetFriendInfoByIndex(i);

		if name then
			contacts[name] = contacts[name] or {}
			contacts[name].note = note

			if isOnline then	-- level, class, zone will be ok
				contacts[name].level = level
				contacts[name].class = class
			elseif oldValues[name] then	-- did we save information earlier about this contact ?
				contacts[name].level = oldValues[name].level
				contacts[name].class = oldValues[name].class
			end
		end
	end

	addon.ThisCharacter.lastUpdate = time()
end

local function ScanDungeonIDs()
	local dungeons = addon.ThisCharacter.DungeonIDs
	wipe(dungeons)

	for i = 1, GetNumSavedInstances() do
        -- Update 2020/06/03: adding tracking of numEncounters and encounterProgress.
        -- These were added to the game in patch 4.0.1, its about time we track them with this addon, too!
		local instanceName, instanceID, instanceReset, difficulty, _, extended, _, isRaid, maxPlayers, difficultyName, numEncounters, encounterProgress = GetSavedInstanceInfo(i)

		if instanceReset > 0 then		-- in 3.2, instances with reset = 0 are also listed (to support raid extensions)
			extended = extended and 1 or 0
			isRaid = isRaid and 1 or 0

			if difficulty > 1 then
				instanceName = format("%s %s", instanceName, difficultyName)
			end
 
			local dungeon = dungeons[instanceID]
            dungeon.name = instanceName
            dungeon.resetTime = (instanceReset + time())
            dungeon.extended = extended
            dungeon.isRaid = isRaid
            dungeon.numEncounters = numEncounters
            dungeon.progress = encounterProgress
            
            -- track all the bosses killed / left alive
            for j = 1, numEncounters do
                local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, j)
                dungeon.bosses[bossName] = isKilled
            end
		end
	end
    
    local worldBosses = addon.ThisCharacter.WorldBosses
    wipe(worldBosses)
    for i = 1, GetNumSavedWorldBosses() do
        local instanceName, instanceID, instanceReset = GetSavedWorldBossInfo(i)

		if instanceReset > 0 then
			local dungeon = dungeons[instanceID]
            dungeon.name = instanceName
            dungeon.resetTime = (instanceReset + time())
            dungeon.extended = 0
            dungeon.isRaid = 1
            dungeon.numEncounters = 1
            dungeon.progress = 1
            dungeon.bosses[instanceName] = true
            
            worldBosses[instanceID] = (instanceReset + time())
		end
	end
end

local function ScanLFGDungeon(dungeonID)
   -- name, typeId, subTypeID, 
	-- minLvl, maxLvl, recLvl, minRecLvl, maxRecLvl, 
	-- expansionId, groupId, textureName, difficulty, 
	-- maxPlayers, dungeonDesc, isHoliday  = GetLFGDungeonInfo(dungeonID)
   
	local dungeonName, typeID, subTypeID, _, _, _, _, _, expansionID, _, _, difficulty = GetLFGDungeonInfo(dungeonID)
	
	-- unknown ? exit
	if not dungeonName then return end
	
	-- type 1 = instance, 2 = raid. We don't want the rest
	if typeID > 2 then return end
		
	-- difficulty levels we need
    -- 2 = heroic dungeon (daily reset)
    -- 7 = LFR
    local resetTime
    if (difficulty == 2) then
        resetTime = (GetQuestResetTime() + time()) -- TODO: confirm this is the same as LFG dungeon reset times
    elseif (difficulty == 7) then 
        resetTime = (C_DateAndTime.GetSecondsUntilWeeklyReset() + time())
    else
        return
    end

	-- how many did we kill in that instance ?
	local numEncounters, numCompleted = GetLFGDungeonNumEncounters(dungeonID)
	if not numCompleted or numCompleted == 0 then return end		-- no kills ? exit
	
	local dungeon = addon.ThisCharacter.LFGDungeons[dungeonID]
	local killCount = 0
    dungeon.resetTime = resetTime
	
	for i = 1, numEncounters do
		local bossName, _, isKilled = GetLFGDungeonEncounterInfo(dungeonID, i)

		if isKilled then
			dungeon.bosses[bossName] = true
			killCount = killCount + 1
		else
			dungeons[bossName] = false
		end
	end

	-- save how many we have killed in that dungeon
	if killCount > 0 then
		dungeon.count = count
	end
end

local function ScanLFGDungeons()
	local dungeons = addon.ThisCharacter.LFGDungeons
	wipe(dungeons)
	
	for i = 1, 3000 do  -- watch this, increase it if LfgDungeons.db2 increases past 3000
		ScanLFGDungeon(i)
	end
end

local function ScanCalendar()
	-- Save the current month
	local CurDateInfo = C_Calendar.GetMonthInfo()
	local currentMonth, currentYear = CurDateInfo.month, CurDateInfo.year
	local DateInfo = C_DateAndTime.GetCurrentCalendarTime()
	local thisMonth, thisDay, thisYear = DateInfo.month, DateInfo.monthDay, DateInfo.year
	C_Calendar.SetAbsMonth(thisMonth, thisYear)

	local calendar = addon.ThisCharacter.Calendar
	wipe(calendar)

	local today = date("%Y-%m-%d")
	local now = date("%H:%M")

	-- Save this month (from today) + 6 following months
	for monthOffset = 0, 6 do
		local charMonthInfo = C_Calendar.GetMonthInfo(monthOffset)
		local month, year, numDays = charMonthInfo.month, charMonthInfo.year, charMonthInfo.numDays
		local startDay = (monthOffset == 0) and thisDay or 1

		for day = startDay, numDays do
			for i = 1, C_Calendar.GetNumDayEvents(monthOffset, day) do		-- number of events that day ..
				-- http://www.wowwiki.com/API_CalendarGetDayEvent
                local info = C_Calendar.GetDayEvent(monthOffset, day, i)
				local title, hour, minute, calendarType, eventType, inviteStatus = info.title, info.startTime.hour, info.startTime.minute, info.calendarType, info.eventType, info.inviteStatus 

				-- 8.0 : for some events, the calendar type may be nil, filter them out
				if calendarType and calendarType ~= "HOLIDAY" and calendarType ~= "RAID_LOCKOUT"
					and calendarType ~= "RAID_RESET" and inviteStatus ~= CALENDAR_INVITESTATUS_INVITED
					and inviteStatus ~= CALENDAR_INVITESTATUS_DECLINED then
										
					-- don't save holiday events, they're the same for all chars, and would be redundant..who wants to see 10 fishing contests every sundays ? =)

					local eventDate = format("%04d-%02d-%02d", year, month, day)
					local eventTime = format("%02d:%02d", hour, minute)

					-- Only add events newer than "now"
					if eventDate > today or (eventDate == today and eventTime > now) then
						table.insert(calendar, format("%s|%s|%s|%d|%d", eventDate, eventTime, title, eventType, inviteStatus ))
					end
				end
			end
		end
	end

	-- Restore current month
	C_Calendar.SetAbsMonth(currentMonth, currentYear)

	addon:SendMessage("DATASTORE_CALENDAR_SCANNED")
end

-- *** Event Handlers ***
local function OnPlayerAlive()
	ScanContacts()
end

local function OnFriendListUpdate()
	ScanContacts()
end

local function OnUpdateInstanceInfo()
	ScanDungeonIDs()
end

local pendingBossKillScan = false
local function OnBossKill()
    -- Delay the dungeon ID scan for 5 seconds after a boss kill, and only request it once
    if not pendingBossKillScan then
        pendingBossKillScan = true
        C_Timer.After(5, function()
            pendingBossKillScan = false
            RequestRaidInfo()
        end)
    end
end

local function OnRaidInstanceWelcome()
	RequestRaidInfo()
end

local function OnLFGUpdateRandomInfo()
	ScanLFGDungeons()
end

local function OnEncounterEnd(event, dungeonID, name, difficulty, raidSize, endStatus)
	ScanLFGDungeon(dungeonID)
end

local function OnChatMsgSystem(event, arg)
	if arg then
		if tostring(arg) == INSTANCE_SAVED then
			RequestRaidInfo()
		end
	end
end

local function OnCalendarUpdateEventList()
	-- The Calendar addon is LoD, and most functions return nil if the calendar is not loaded, so unless the CalendarFrame is valid, exit right away
	if not CalendarFrame then return end

	-- prevent CalendarSetAbsMonth from triggering a scan (= avoid infinite loop)
	addon:UnregisterEvent("CALENDAR_UPDATE_EVENT_LIST")
	ScanCalendar()
	addon:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST", OnCalendarUpdateEventList)
end

local trackedItems = {
	[39878] = 259200, -- Mysterious Egg, 3 days
	[44717] = 259200, -- Disgusting Jar, 3 days
	[94295] = 259200, -- Primal Egg, 3 days
	[153190] = 432000, -- Fel-Spotted Egg, 5 days
}

local lootMsg = gsub(LOOT_ITEM_SELF, "%%s", "(.+)")
local purchaseMsg = gsub(LOOT_ITEM_PUSHED_SELF, "%%s", "(.+)")

local function OnChatMsgLoot(event, arg)
	local _, _, link = strfind(arg, lootMsg)
	if not link then _, _, link = strfind(arg, purchaseMsg) end
	if not link then return end

	local id = tonumber(link:match("item:(%d+)"))
	id = tonumber(id)
	if not id then return end

	for itemID, duration in pairs(trackedItems) do
		if itemID == id then
			local name = GetItemInfo(itemID)
			if name then
				table.insert(addon.ThisCharacter.ItemCooldowns, format("%s|%s|%s", name, time(), duration))
				addon:SendMessage("DATASTORE_ITEM_COOLDOWN_UPDATED", itemID)
			end
		end
	end
end

-- ** Mixins **

--[[ clientServerTimeGap

	Number of seconds between client time & server time
	A positive value means that the server time is ahead of local time.
	Ex: server: 21:05, local 21.02 could lead to something like 180 (or close to it, depending on seconds)
--]]
local clientServerTimeGap

local function _GetClientServerTimeGap()
	return clientServerTimeGap or 0
end

-- * Contacts *
local function _GetContactInfo(character, key)
	local contact = character.Contacts[key]
	if type(contact) == "table" then
		return contact.level, contact.class, contact.note
	end
end

-- * Dungeon IDs *
local function _GetSavedInstances(character)
	return character.DungeonIDs

	--[[	Typical usage:
		for dungeonID, dungeon in pairs(DataStore:GetSavedInstances(character)) do
			name, resetTime, lastCheck, isExtended, isRaid, numEncounters, encounterProgress, bosses = DataStore:GetSavedInstanceInfo(character, dungeonID)
		end
	--]]
end

--[[
    Changes made 12/November/2020:
    Name is no longer in the key.
    Name is now the first return value from this function
    Reset is now the timestamp when the dungeon resets rather than the seconds remaining
    The time of checking the dungeon IDs is no longer stored
    Dungeon Bosses are no longer stored separately from Dungeons
--]]
local function _GetSavedInstanceInfo(character, dungeonID)
	local instanceInfo = character.DungeonIDs[dungeonID]
	if not instanceInfo then return end

	local hasExpired
    local name = instanceInfo.name
	local reset = instanceInfo.resetTime
    local isExtended = instanceInfo.isExtended
    local isRaid = instanceInfo.isRaid
    local numEncounters = instanceInfo.numEncounters
    local encounterProgress = instanceInfo.progress

	return name, tonumber(reset), (isExtended == "1") and true or nil, (isRaid == "1") and true or nil, numEncounters or 0, encounterProgress or 0, instanceInfo.bosses
end

local function _HasSavedInstanceExpired(character, dungeonID)
	local _, reset = _GetSavedInstanceInfo(character, dungeonID)
	if not reset then return end

	local hasExpired = (time() > reset)
	local expiresIn = (reset - time())

	return hasExpired, expiresIn
end

local function _DeleteSavedInstance(character, dungeonID)
	character.DungeonIDs[dungeonID] = nil
end

--[[
   allows iterations like:
    for bossID, resetTime in pairs(DataStore:GetSavedWorldBosses(character)) do
    local bossName = DataStore:GetSavedInstanceInfo(character, bossID)
--]]
local function _GetSavedWorldBosses(character)
    return character.WorldBosses
end

-- * LFG Dungeons *
local function _IsBossAlreadyLooted(character, dungeonID, boss)
	return character.LFGDungeons[dungeonID].bosses[boss]
end

local function _GetLFGDungeonKillCount(character, dungeonID)
	return character.LFGDungeons[dungeonID].count or 0
end

-- * Calendar *
local function _GetNumCalendarEvents(character)
	return #character.Calendar
end

local function _GetCalendarEventInfo(character, index)
	local event = character.Calendar[index]
	if event then
		return strsplit("|", event)		-- eventDate, eventTime, title, eventType, inviteStatus
	end
end

local function _HasCalendarEventExpired(character, index)
	local eventDate, eventTime = _GetCalendarEventInfo(character, index)
	if eventDate and eventTime then
		local today = date("%Y-%m-%d")
		local now = date("%H:%M")

		if eventDate < today or (eventDate == today and eventTime <= now) then
			return true
		end
	end
end

local function _DeleteCalendarEvent(character, index)
	local v = table.remove(character.Calendar, index)
    table.insert(character.expiredCalendar, v)
end

local function _GetNumExpiredCalendarEvents(character)
	return #character.expiredCalendar
end

local function _GetExpiredCalendarEventInfo(character, index)
	local event = character.expiredCalendar[index]
	if event then
		return strsplit("|", event)		-- eventDate, eventTime, title, eventType, inviteStatus
	end
end

local function _DeleteExpiredCalendarEvent(character, index)
	local v = table.remove(character.expiredCalendar, index)
end

-- * Item Cooldowns *
local function _GetNumItemCooldowns(character)
	return character.ItemCooldowns and #character.ItemCooldowns or 0
end

local function _GetItemCooldownInfo(character, index)
	local item = character.ItemCooldowns[index]
	if item then
		local name, lastCheck, duration = strsplit("|", item)
		return name, tonumber(lastCheck), tonumber(duration)
	end
end

local function _HasItemCooldownExpired(character, index)
	local _, lastCheck, duration = _GetItemCooldownInfo(character, index)

	local expires = duration + lastCheck + _GetClientServerTimeGap()
	if (expires - time()) <= 0 then
		return true
	end
end

local function _DeleteItemCooldown(character, index)
	table.remove(character.ItemCooldowns, index)
end

local timerHandle
local lastServerMinute

local function SetClientServerTimeGap()
	-- this function is called every second until the server time changes (track minutes only)
    --local serverTime = GetServerTime()
	--local ServerHour, ServerMinute = date("%H", serverTime), date("%M", serverTime)
    local ServerHour, ServerMinute = GetGameTime()

	if not lastServerMinute then		-- ServerMinute not set ? this is the first pass, save it
		lastServerMinute = ServerMinute
		return
	end

	if lastServerMinute == ServerMinute then return end	-- minute hasn't changed yet, exit

	-- next minute ? do our stuff and stop
	addon:CancelTimer(timerHandle)

	lastServerMinute = nil	-- won't be needed anymore
	timerHandle = nil

	local DateInfo = C_DateAndTime.GetCurrentCalendarTime()
	local ServerMonth, ServerDay, ServerYear = DateInfo.month, DateInfo.monthDay, DateInfo.year
    local timeTable = {}	-- to pass as an argument to time()	see http://lua-users.org/wiki/OsLibraryTutorial for details
	timeTable.year = ServerYear
	timeTable.month = ServerMonth
	timeTable.day = ServerDay
	timeTable.hour = ServerHour
	timeTable.min = ServerMinute
	timeTable.sec = 0					-- minute just changed, so second is 0

	-- our goal is achieved, we can calculate the difference between server time and local time, in seconds.
	clientServerTimeGap = difftime(time(timeTable), time())

	addon:SendMessage("DATASTORE_CS_TIMEGAP_FOUND", clientServerTimeGap)
end

local function ClearExpiredDungeons()
	for key, character in pairs(addon.db.global.Characters) do
        for dungeonID, dungeon in pairs(character.DungeonIDs) do
            if (type(dungeon) ~= "table") or (dungeon.resetTime < time()) then
                character.DungeonIDs[dungeonID] = nil
            end
        end
        
        for dungeonID, dungeon in pairs(character.LFGDungeons) do
            if (type(dungeon) ~= "table") or (dungeon.resetTime < time()) then
                character.LFGDungeons[dungeonID] = nil
            end
        end
        
        for bossID, resetTime in pairs(character.WorldBosses) do
            if (type(resetTime) ~= "number") or (resetTime < time()) then
                character.WorldBosses[bossID] = nil
            end
        end
	end
end

local PublicMethods = {
	GetClientServerTimeGap = _GetClientServerTimeGap,
	GetContactInfo = _GetContactInfo,

	GetSavedInstances = _GetSavedInstances,
	GetSavedInstanceInfo = _GetSavedInstanceInfo,
	HasSavedInstanceExpired = _HasSavedInstanceExpired,
	DeleteSavedInstance = _DeleteSavedInstance,
    GetSavedWorldBosses = _GetSavedWorldBosses,

	IsBossAlreadyLooted = _IsBossAlreadyLooted,
	GetLFGDungeonKillCount = _GetLFGDungeonKillCount,
	
	GetNumCalendarEvents = _GetNumCalendarEvents,
	GetCalendarEventInfo = _GetCalendarEventInfo,
	HasCalendarEventExpired = _HasCalendarEventExpired,
	DeleteCalendarEvent = _DeleteCalendarEvent,
    
    GetNumExpiredCalendarEvents = _GetNumExpiredCalendarEvents,
    GetExpiredCalendarEventInfo = _GetExpiredCalendarEventInfo,
    DeleteExpiredCalendarEvent = _DeleteExpiredCalendarEvent,

	GetNumItemCooldowns = _GetNumItemCooldowns,
	GetItemCooldownInfo = _GetItemCooldownInfo,
	HasItemCooldownExpired = _HasItemCooldownExpired,
	DeleteItemCooldown = _DeleteItemCooldown,
}

function addon:OnInitialize()
	addon.db = LibStub("AceDB-3.0"):New(addonName .. "DB", AddonDB_Defaults)

	DataStore:RegisterModule(addonName, addon, PublicMethods)
	DataStore:SetCharacterBasedMethod("GetContactInfo")

	DataStore:SetCharacterBasedMethod("GetSavedInstances")
	DataStore:SetCharacterBasedMethod("GetSavedInstanceInfo")
	DataStore:SetCharacterBasedMethod("HasSavedInstanceExpired")
	DataStore:SetCharacterBasedMethod("DeleteSavedInstance")
	DataStore:SetCharacterBasedMethod("IsBossAlreadyLooted")
	DataStore:SetCharacterBasedMethod("GetLFGDungeonKillCount")
    DataStore:SetCharacterBasedMethod("GetSavedWorldBosses")

	DataStore:SetCharacterBasedMethod("GetNumCalendarEvents")
	DataStore:SetCharacterBasedMethod("GetCalendarEventInfo")
	DataStore:SetCharacterBasedMethod("HasCalendarEventExpired")
	DataStore:SetCharacterBasedMethod("DeleteCalendarEvent")
    
    DataStore:SetCharacterBasedMethod("GetNumExpiredCalendarEvents")
    DataStore:SetCharacterBasedMethod("GetExpiredCalendarEventInfo")
    DataStore:SetCharacterBasedMethod("DeleteExpiredCalendarEvent")

	DataStore:SetCharacterBasedMethod("GetNumItemCooldowns")
	DataStore:SetCharacterBasedMethod("GetItemCooldownInfo")
	DataStore:SetCharacterBasedMethod("HasItemCooldownExpired")
	DataStore:SetCharacterBasedMethod("DeleteItemCooldown")
    
    -- temp code for patch released 21/nov/2020
    -- can remove this after a couple of months
    -- then if any users report an error with Events.lua just tell them to /reload
	for key, character in pairs(addon.db.global.Characters) do
        for dungeonID, dungeon in pairs(character.DungeonIDs) do
            if (type(dungeon) ~= "table") then
                character.DungeonIDs[dungeonID] = nil
            end
        end
        
        for dungeonID, dungeon in pairs(character.LFGDungeons) do
            if (type(dungeon) ~= "table") then
                character.LFGDungeons[dungeonID] = nil
            end
        end
        
        for bossID, resetTime in pairs(character.WorldBosses) do
            if (type(resetTime) ~= "number") then
                character.WorldBosses[bossID] = nil
            end
        end
	end
end

function addon:OnEnable()
	-- Contacts
	addon:RegisterEvent("PLAYER_ALIVE", OnPlayerAlive)
	addon:RegisterEvent("FRIENDLIST_UPDATE", OnFriendListUpdate)

	-- Dungeon IDs
	addon:RegisterEvent("UPDATE_INSTANCE_INFO", OnUpdateInstanceInfo)
    addon:RegisterEvent("BOSS_KILL", OnBossKill)
	addon:RegisterEvent("RAID_INSTANCE_WELCOME", OnRaidInstanceWelcome)
	addon:RegisterEvent("LFG_UPDATE_RANDOM_INFO", OnLFGUpdateRandomInfo)
	addon:RegisterEvent("ENCOUNTER_END", OnEncounterEnd)
		
	addon:RegisterEvent("CHAT_MSG_SYSTEM", OnChatMsgSystem)  

	ClearExpiredDungeons()
	
	-- Calendar (only register after setting the current month)
	local DateInfo = C_DateAndTime.GetCurrentCalendarTime()
	local thisMonth,thisYear = DateInfo.month, DateInfo.year

	C_Calendar.SetAbsMonth(thisMonth, thisYear)
	addon:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST", OnCalendarUpdateEventList)

	-- Item Cooldowns
	addon:RegisterEvent("CHAT_MSG_LOOT", OnChatMsgLoot)

	timerHandle = addon:ScheduleRepeatingTimer(SetClientServerTimeGap, 1)
end

function addon:OnDisable()
	addon:UnregisterEvent("PLAYER_ALIVE")
	addon:UnregisterEvent("FRIENDLIST_UPDATE")
	addon:UnregisterEvent("UPDATE_INSTANCE_INFO")
    addon:UnregisterEvent("BOSS_KILL")
	addon:UnregisterEvent("RAID_INSTANCE_WELCOME")
	addon:UnregisterEvent("CHAT_MSG_SYSTEM")
	addon:UnregisterEvent("CALENDAR_UPDATE_EVENT_LIST")
end
