local TMGCore = exports['tmg-core']:GetCoreObject()



local function showWarning(msg)
	print(('^3%s: %s^0'):format(Lang:t("general.warning"), msg))
end

local function removeItem(Player, item)
	if Config.Consumables[item.name] then
		Player.Functions.RemoveItem(item.name, item.amount >= Config.Consumables[item.name] and Config.Consumables[item.name] or 1)
	end
end

local function checkAndRemoveItem(Player, item, shouldRemove)
	if not item then return false end
	if shouldRemove then
		removeItem(Player, item)
	end
	return true
end

local function checkItems(Player, items, needsAll, shouldRemove)
	if needsAll == nil then needsAll = true end
	local isTable = type(items) == 'table'
	local isArray = isTable and table.type(items) == 'array' or false
	local totalItems = 0
	local count = 0
	if isTable then for _ in pairs(items) do totalItems += 1 end else totalItems = #items end
	local kvIndex
	if isArray then kvIndex = 2 else kvIndex = 1 end
	if isTable then
		for k, v in pairs(items) do
			local itemKV = {k, v}
			local item = Player.Functions.GetItemByName(itemKV[kvIndex])
			if needsAll then
				if checkAndRemoveItem(Player, item, false) then
					count += 1
				end
			else
				if checkAndRemoveItem(Player, item, shouldRemove) then
					return true
				end
			end
		end
		if count == totalItems then
			for k, v in pairs(items) do
				local itemKV = {k, v}
				local item = Player.Functions.GetItemByName(itemKV[kvIndex])
				checkAndRemoveItem(Player, item, shouldRemove)
			end
			return true
		end
	else 
		local item = Player.Functions.GetItemByName(items)
		return checkAndRemoveItem(Player, item, shouldRemove)
	end
	return false
end

local function isAuthorized(Player, door, usedLockpick)
	if door.allAuthorized then return true end

	if Config.AdminAccess and TMGCore.Functions.HasPermission(Player.PlayerData.source, Config.AdminPermission) then
		if Config.Warnings then
			showWarning(Lang:t("general.warn_admin_privilege_used", {player = Player.PlayerData.name, license = Player.PlayerData.license}))
		end
		return true
	end

	if (door.pickable or door.lockpick) and usedLockpick then return true end

	if door.authorizedJobs then
		if door.authorizedJobs[Player.PlayerData.job.name] and Player.PlayerData.job.grade.level >= door.authorizedJobs[Player.PlayerData.job.name] then
			return true
		elseif type(door.authorizedJobs[1]) == 'string' then
			for _, job in pairs(door.authorizedJobs) do 
				if job == Player.PlayerData.job.name then return true end
			end
		end
	end

	if door.authorizedGangs then
		if door.authorizedGangs[Player.PlayerData.gang.name] and Player.PlayerData.gang.grade.level >= door.authorizedGangs[Player.PlayerData.gang.name] then
			return true
		elseif type(door.authorizedGangs[1]) == 'string' then
			for _, gang in pairs(door.authorizedGangs) do 
				if gang == Player.PlayerData.gang.name then return true end
			end
		end
	end

	if door.authorizedCitizenIDs then
		if door.authorizedCitizenIDs[Player.PlayerData.citizenid] then
			return true
		elseif type(door.authorizedCitizenIDs[1]) == 'string' then
			for _, id in pairs(door.authorizedCitizenIDs) do 
				if id == Player.PlayerData.citizenid then return true end
			end
		end
	end

	if door.items then return checkItems(Player, door.items, door.needsAllItems, true) end

	return false
end

local function SaveDoorStates()
    local payload = {
        ["states"] = Config.DoorStates,
        ["last_sync"] = os.time()
    }

    local success = exports['tmgnosql']:UpdateOne('world_states', 
        { ["id"] = "door_lock_states" }, 
        { ["$set"] = payload }, 
        { ["upsert"] = true }
    )

    if success then
        print("^5[TMG]^7 Mainframe: Door security matrices anchored to world_states.")
    else
        print("^1[TMG]^7 Mainframe Error: Failed to synchronize door lock states.")
    end
end

local function LoadDoorStates()
    local data = exports['tmgnosql']:FetchOne('world_states', { ["id"] = "door_lock_states" })
    
    if data and data.states then
        local doorCount = 0

        for key, isLocked in pairs(data.states) do
            if Config.DoorList[key] ~= nil then
                Config.DoorList[key].locked = isLocked
                doorCount = doorCount + 1
            end
        end

        Config.DoorStates = data.states
        
        print(string.format("^5[TMG]^7 Mainframe: Security Protocols Restored | %d door states synchronized.", doorCount))
    else
        print("^3[TMG]^7 Mainframe: No persistent door states found. Initializing with defaults.")
    end
end



TMGCore.Functions.CreateCallback('tmg-doorlock:server:setupDoors', function(_, cb)
	cb(Config.DoorList)
end)

TMGCore.Functions.CreateCallback('tmg-doorlock:server:checkItems', function(source, cb, items, needsAll)
	local Player = TMGCore.Functions.GetPlayer(source)
	cb(checkItems(Player, items, needsAll, false))
end)



RegisterNetEvent('tmg-doorlock:server:updateState', function(doorID, locked, src, usedLockpick, unlockAnyway, enableSounds, enableAnimation, sentSource)
    local playerId = sentSource or source
    local Player = TMGCore.Functions.GetPlayer(playerId)
    if not Player then return end

    if type(doorID) ~= 'number' and type(doorID) ~= 'string' then return end
    if type(locked) ~= 'boolean' then return end
    if not Config.DoorList[doorID] then return end

    if not unlockAnyway and not isAuthorized(Player, Config.DoorList[doorID], usedLockpick) then
        if Config.Warnings then
            showWarning(Lang:t("general.warn_no_authorisation", {player = Player.PlayerData.name, license = Player.PlayerData.license, doorID = doorID}))
        end
        return
    end

    Config.DoorList[doorID].locked = locked
    Config.DoorStates[doorID] = locked

    exports['tmgnosql']:UpdateOne('world_states', 
        { ["id"] = "door_lock_states" }, 
        { ["$set"] = { ["states." .. tostring(doorID)] = locked } },
        { ["upsert"] = true }
    )

    exports['tmgnosql']:UpdateMany('door_logs', {
        ["door"] = doorID,
        ["citizenid"] = Player.PlayerData.citizenid,
        ["action"] = locked and "LOCKED" or "UNLOCKED",
        ["coords"] = GetEntityCoords(GetPlayerPed(playerId)),
        ["timestamp"] = os.time()
    })

    TriggerClientEvent('tmg-doorlock:client:setState', -1, playerId, doorID, locked, src or false, enableSounds, enableAnimation)

    if Config.DoorList[doorID].autoLock and not locked then
        SetTimeout(Config.DoorList[doorID].autoLock, function()
            if Config.DoorList[doorID].locked then return end
            
            Config.DoorList[doorID].locked = true
            Config.DoorStates[doorID] = true
            
            exports['tmgnosql']:UpdateOne('world_states', 
                { ["id"] = "door_lock_states" }, 
                { ["$set"] = { ["states." .. tostring(doorID)] = true } }
            )
            
            TriggerClientEvent('tmg-doorlock:client:setState', -1, playerId, doorID, true, src or false, enableSounds, enableAnimation)
            print(string.format("^5[TMG]^7 Mainframe: Auto-lock engaged for door node '%s'", doorID))
        end)
    end
end)

RegisterNetEvent('tmg-doorlock:server:saveNewDoor', function(data, doubleDoor)
    local src = source
    if not TMGCore.Functions.HasPermission(src, Config.CommandPermission) and not IsPlayerAceAllowed(src, 'command') then
        return
    end

    local Player = TMGCore.Functions.GetPlayer(src)
    if not Player then return end

    local identifier = data.configfile..'-'..data.dooridentifier
    local configData = {
        ["identifier"] = identifier,
        ["creator"] = Player.PlayerData.name,
        ["doorLabel"] = data.doorlabel,
        ["doorType"] = data.doortype,
        ["locked"] = data.locked,
        ["pickable"] = data.pickable,
        ["distance"] = data.distance,
        ["authorizedJobs"] = data.job and { [data.job] = tonumber(data.jobGrade) or 0 } or nil,
        ["authorizedGangs"] = data.gang and { [data.gang] = tonumber(data.gangGrade) or 0 } or nil,
        ["authorizedCitizenIDs"] = data.cid and { [data.cid] = true } or nil,
        ["items"] = data.item and { [data.item] = 1 } or nil,
        ["createdAt"] = os.time()
    }

    if doubleDoor then
        configData.doors = {
            {objName = data.model[1], objYaw = data.heading[1], objCoords = data.coords[1]},
            {objName = data.model[2], objYaw = data.heading[2], objCoords = data.coords[2]}
        }
    else
        configData.objName = data.model
        configData.objYaw = data.heading
        configData.objCoords = data.coords
    end

    local success = exports['tmgnosql']:UpdateMany('custom_doors', configData)

    if success then
        Config.DoorList[identifier] = configData
        
        TriggerClientEvent('tmg-doorlock:client:newDoorAdded', -1, configData, identifier, src)
        TriggerClientEvent('TMGCore:Notify', src, "Security matrix anchored successfully!", "success")
        
        print(string.format("^5[TMG]^7 Mainframe: New door asset '%s' registered by %s", identifier, Player.PlayerData.name))
    else
        TriggerClientEvent('TMGCore:Notify', src, "Mainframe Error: Failed to anchor door asset.", "error")
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if GetCurrentResourceName() ~= resource then return end

    CreateThread(function()
        local customDoors = exports['tmgnosql']:FetchAll('custom_doors', {})
        local customCount = 0
        
        if customDoors then
            for _, door in ipairs(customDoors) do
                Config.DoorList[door.identifier] = door
                customCount = customCount + 1
            end
        end

        LoadDoorStates()

        local totalDoors = 0
        for _ in pairs(Config.DoorList) do totalDoors = totalDoors + 1 end
        
        print(string.format("^5[TMG]^7 Mainframe: Security Matrix Initialized."))
        print(string.format("^5[TMG]^7 Registry: %d static and %d custom door nodes synchronized.", (totalDoors - customCount), customCount))
    end)
end)

AddEventHandler('onResourceStop', function(resource)
    if GetCurrentResourceName() == resource and Config.PersistentDoorStates then
		SaveDoorStates()
    end
end)

RegisterNetEvent('txAdmin:events:scheduledRestart', function(eventData)
    if eventData.secondsRemaining == 60 then
        CreateThread(function()
            Wait(45000)
			SaveDoorStates()
        end)
	else
		SaveDoorStates()
    end
end)

RegisterNetEvent('tmg-doorlock:server:removeLockpick', function(type)
	local Player = TMGCore.Functions.GetPlayer(source)

	if not Player then return end

	if type == "advancedlockpick" or type == "lockpick" then
		Player.Functions.RemoveItem(type, 1)
	end
end)



TMGCore.Commands.Add('newdoor', Lang:t("general.newdoor_command_description"), {}, false, function(source)
	TriggerClientEvent('tmg-doorlock:client:addNewDoor', source)
end, Config.CommandPermission)

TMGCore.Commands.Add('doordebug', Lang:t("general.doordebug_command_description"), {}, false, function(source)
	TriggerClientEvent('tmg-doorlock:client:ToggleDoorDebug', source)
end, Config.CommandPermission)
