local TMGCore = exports['tmg-core']:GetCoreObject()

DoorMatrix = {
    isLoggedIn = LocalPlayer.state['isLoggedIn'],
    playerPed = nil,
    playerCoords = nil,
    nearbyDoors = {},
    closestDoor = { id = nil, distance = 100.0, data = nil },
    isPaused = false,
    canContinue = true,
    lastUpdateCoords = vector3(0, 0, 0),
    doorDataCache = {},
    creationData = {}
}


function Draw3DText(coords, str)
    local onScreen, worldX, worldY = World3dToScreen2d(coords.x, coords.y, coords.z)
    local camCoords = GetGameplayCamCoord()
    local scale = 200 / (GetGameplayCamFov() * #(camCoords - coords))
    if onScreen then
        SetTextScale(1.0, 0.5 * scale)
        SetTextFont(4)
        SetTextColour(255, 255, 255, 255)
        SetTextEdge(2, 0, 0, 0, 150)
        SetTextProportional(1)
        SetTextOutline()
        SetTextCentre(1)
        BeginTextCommandDisplayText("STRING")
        AddTextComponentSubstringPlayerName(str)
        EndTextCommandDisplayText(worldX, worldY)
    end
end

local function RaycastWeapon()
    local offset = GetOffsetFromEntityInWorldCoords(GetCurrentPedWeaponEntityIndex(DoorMatrix.playerPed), 0, 0, -0.01)
    local direction = GetGameplayCamRot()
    direction = vec2(direction.x * math.pi / 180.0, direction.z * math.pi / 180.0)
    local num = math.abs(math.cos(direction.x))
    direction = vec3((-math.sin(direction.y) * num), (math.cos(direction.y) * num), math.sin(direction.x))
    local destination = vec3(offset.x + direction.x * 30, offset.y + direction.y * 30, offset.z + direction.z * 30)
    local hit, entityHit, result
    local rayHandle = StartShapeTestLosProbe(offset, destination, -1, DoorMatrix.playerPed, 0)
    repeat
        result, hit, _, _, entityHit = GetShapeTestResult(rayHandle)
        Wait(0)
    until result ~= 1
    if GetEntityType(entityHit) == 3 then return hit, entityHit else return false, 0 end
end

local function RayCastGameplayCamera(distance)
    local cameraRotation = GetGameplayCamRot()
    local cameraCoord = GetGameplayCamCoord()
    local direction = vec3(-math.sin(math.pi/180 * cameraRotation.z) * math.abs(math.cos(math.pi/180 * cameraRotation.x)), math.cos(math.pi/180 * cameraRotation.z) * math.abs(math.cos(math.pi/180 * cameraRotation.x)), math.sin(math.pi/180 * cameraRotation.x))
    local destination = vec3(cameraCoord.x + direction.x * distance, cameraCoord.y + direction.y * distance, cameraCoord.z + direction.z * distance)
    local _, hit, endCoords = GetShapeTestResult(StartShapeTestRay(cameraCoord.x, cameraCoord.y, cameraCoord.z, destination.x, destination.y, destination.z, -1, DoorMatrix.playerPed, 0))
    return hit == 1, endCoords
end

local function PlayDoorSound(door, src, enableSounds)
    if not Config.EnableSounds or not enableSounds then return end
    local origin = door.textCoords
    if src then 
        local entity = NetworkGetEntityFromNetworkId(src)
        origin = entity ~= 0 and GetEntityCoords(entity) or door.textCoords
    end
    
    local distance = #(DoorMatrix.playerCoords - origin)
    if distance < 10 then
        local sound = door.locked and (door.audioLock or {file = 'door-bolt-4.ogg', volume = 0.1}) or (door.audioUnlock or {file = 'door-bolt-4.ogg', volume = 0.1})
        SendNUIMessage({ type = 'audio', audio = sound, distance = distance, sfx = GetProfileSetting(300) })
    end
end

local function DoorAnim()
    if not Config.EnableAnimation then return end
    RequestAnimDict("anim@heists@keycard@")
    while not HasAnimDictLoaded("anim@heists@keycard@") do Wait(0) end
    TaskPlayAnim(DoorMatrix.playerPed, "anim@heists@keycard@", "exit", 8.0, 1.0, -1, 48, 0, 0, 0, 0)
    SetTimeout(550, function() ClearPedTasks(DoorMatrix.playerPed) end)
end


local function IsAuthorized(door)
    if door.allAuthorized then return true end
    local PlayerData = TMGCore.Functions.GetPlayerData()

    if door.authorizedJobs and door.authorizedJobs[PlayerData.job.name] and PlayerData.job.grade.level >= door.authorizedJobs[PlayerData.job.name] then return true end
    if door.authorizedGangs and door.authorizedGangs[PlayerData.gang.name] and PlayerData.gang.grade.level >= door.authorizedGangs[PlayerData.gang.name] then return true end
    if door.authorizedCitizenIDs and door.authorizedCitizenIDs[PlayerData.citizenid] then return true end

    if door.items then
        local p = promise.new()
        TMGCore.Functions.TriggerCallback('tmg-doorlock:server:checkItems', function(result) p:resolve(result) end, door.items, door.needsAllItems)
        return Citizen.Await(p)
    end
    return false
end

local function SyncDoorSystem(doorID)
    local data = Config.DoorList[doorID]
    if not data then return end

    local function Register(v, id)
        local dist = #(DoorMatrix.playerCoords - v.objCoords)
        if dist < 30.0 then
            local searchDist = (data.doorType == "sliding" or data.doorType == "garage" or data.doorType == "doublesliding") and 5.0 or 1.1
            v.object = GetClosestObjectOfType(v.objCoords.x, v.objCoords.y, v.objCoords.z, searchDist, v.objName or v.objHash, false, false, false)
            
            if v.object and v.object ~= 0 then
                v.doorHash = 'door_'..doorID..(id and '_'..id or '')
                if not IsDoorRegisteredWithSystem(v.doorHash) then
                    AddDoorToSystem(v.doorHash, v.objName or v.objHash, v.objCoords.x, v.objCoords.y, v.objCoords.z, false, false, false)
                    DoorSystemSetDoorState(v.doorHash, data.locked and 4 or 0, false, false)
                    if data.locked then DoorSystemSetDoorState(v.doorHash, 1, false, false) end
                    DoorMatrix.nearbyDoors[doorID] = true
                end
            end
        elseif v.object then
            RemoveDoorFromSystem(v.doorHash)
            v.object = nil
            DoorMatrix.nearbyDoors[doorID] = nil
        end
    end

    if data.doors then for k, v in pairs(data.doors) do Register(v, k) end
    else Register(data) end
end


CreateThread(function()
    while true do
        local sleep = 500
        if DoorMatrix.isLoggedIn and DoorMatrix.canContinue then
            DoorMatrix.playerPed = PlayerPedId()
            DoorMatrix.playerCoords = GetEntityCoords(DoorMatrix.playerPed)

            if #(DoorMatrix.playerCoords - DoorMatrix.lastUpdateCoords) > 10.0 then
                for doorID in pairs(Config.DoorList) do SyncDoorSystem(doorID) end
                DoorMatrix.lastUpdateCoords = DoorMatrix.playerCoords
            end

            local closestID, minContextDist = nil, 15.0
            for k in pairs(DoorMatrix.nearbyDoors) do
                local door = Config.DoorList[k]
                if door.textCoords then
                    local dist = #(DoorMatrix.playerCoords - door.textCoords)
                    if dist < minContextDist then
                        minContextDist = dist
                        closestID = k
                    end
                end
            end

            if closestID then
                DoorMatrix.closestDoor = { id = closestID, distance = minContextDist, data = Config.DoorList[closestID] }
                sleep = 0

                if not DoorMatrix.isPaused and not IsPauseMenuActive() then
                    local authorized = IsAuthorized(DoorMatrix.closestDoor.data)
                    local displayText = ""
                    local door = DoorMatrix.closestDoor.data

                    if not door.hideLabel and Config.UseDoorLabelText and door.doorLabel then
                        displayText = door.doorLabel
                    else
                        if not door.locked then
                            displayText = authorized and Lang:t("general.unlocked_button") or Lang:t("general.unlocked")
                        else
                            displayText = authorized and Lang:t("general.locked_button") or Lang:t("general.locked")
                        end
                    end

                    if displayText ~= "" then
                        local color = Config.ChangeColor and (door.locked and Config.LockedColor or Config.UnlockedColor) or Config.DefaultColor
                        SendNUIMessage({ type = "setDoorText", enable = true, text = displayText, color = color })
                    end
                else
                    SendNUIMessage({ type = "setDoorText", enable = false })
                end
            else
                if DoorMatrix.closestDoor.id then SendNUIMessage({ type = "setDoorText", enable = false }) end
                DoorMatrix.closestDoor = { id = nil, distance = 100.0, data = nil }
            end
        end
        Wait(sleep)
    end
end)


RegisterNetEvent('tmg-doorlock:client:setState', function(serverId, doorID, state, src, enableSounds, enableAnimation)
    if not Config.DoorList[doorID] then return end
    local door = Config.DoorList[doorID]
    if serverId == TMGCore.Functions.GetPlayerData().source and (enableAnimation or true) then DoorAnim() end
    door.locked = state
    SyncDoorSystem(doorID)

    CreateThread(function()
        local function ApplyState(v)
            if not IsDoorRegisteredWithSystem(v.doorHash) then return end
            if door.doorType == "sliding" or door.doorType == "garage" or door.doorType == "doublesliding" then
                DoorSystemSetAutomaticRate(v.doorHash, door.doorRate or 1.0, false, false)
                DoorSystemSetDoorState(v.doorHash, state and 1 or 0, false, false)
                DoorSystemSetAutomaticDistance(v.doorHash, state and 0.0 or 30.0, false, false)
            else
                if state then
                    while GetEntityHeading(v.object) ~= (v.objYaw or v.objHeading) do
                        DoorSystemSetDoorState(v.doorHash, 4, false, false)
                        Wait(10)
                    end
                    DoorSystemSetDoorState(v.doorHash, 1, false, false)
                else
                    DoorSystemSetDoorState(v.doorHash, 0, false, false)
                end
            end
        end
        if door.doors then for _, v in pairs(door.doors) do ApplyState(v) end
        else ApplyState(door) end
        PlayDoorSound(door, src, enableSounds)
    end)
end)

RegisterNetEvent('lockpicks:UseLockpick', function(isAdvanced)
    local door = DoorMatrix.closestDoor
    if not door.id or not door.data.locked or (not door.data.pickable and not door.data.lockpick) then return end
    if TMGCore.Functions.GetPlayerData().metadata['isdead'] or TMGCore.Functions.GetPlayerData().metadata['ishandcuffed'] then return end

    local success = exports['tmg-minigames']:Skillbar(isAdvanced and 'easy' or 'medium')
    if success then
        TMGCore.Functions.Notify(Lang:t("success.lockpick_success"), 'success')
        local face = door.data.doors and door.data.doors[1].objCoords or door.data.objCoords
        TaskTurnPedToFaceCoord(DoorMatrix.playerPed, face.x, face.y, face.z, 0)
        Wait(2000)
        TriggerServerEvent('tmg-doorlock:server:updateState', door.id, false, false, true, false)
    else
        TMGCore.Functions.Notify(Lang:t("error.lockpick_fail"), 'error')
        local item = isAdvanced and "advancedlockpick" or "lockpick"
        if isAdvanced and math.random(1, 100) > 17 then return end
        TriggerServerEvent("tmg-doorlock:server:removeLockpick", item)
    end
end)


RegisterNetEvent('tmg-doorlock:client:addNewDoor', function()
    DoorMatrix.canContinue = false
    SendNUIMessage({ type = "setDoorText", enable = false })
    
    local dialog = exports['tmg-input']:ShowInput({
        header = Lang:t("general.newdoor_menu_title"),
        submitText = Lang:t("general.submit_text"),
        inputs = {
            { text = "Config File Name", name = "configfile", type = "text", isRequired = true },
            { text = "Door Identifier", name = "dooridentifier", type = "text", isRequired = true },
            { text = "Door Label", name = "doorlabel", type = "text", isRequired = false },
            { text = "Type", name = "doortype", type = "select", options = {
                { value = "door", text = "Single Door" }, { value = "double", text = "Double Doors" },
                { value = "sliding", text = "Sliding" }, { value = "doublesliding", text = "Double Sliding" },
                { value = "garage", text = "Garage" }
            }},
            { text = "Job Auth", name = "job", type = "text" },
            { text = "Job Grade", name = "jobGrade", type = "number" },
            { text = "Distance", name = "distance", type = "number", isRequired = true, default = 2 },
            { text = "Locked by Default", name = "locked", type = "checkbox", options = {{ value = "true", text = "Locked" }} }
        }
    })

    if not dialog or not next(dialog) then DoorMatrix.canContinue = true return end
    local doorData = dialog
    doorData.locked = (doorData.locked == 'true')

    local function SelectEntity()
        local entity, model, coords, heading = 0, 0, 0, 0
        SendNUIMessage({ type = "setText", aim = "block" })
        while true do
            if IsPlayerFreeAiming(PlayerId()) then
                local hit, ent = RaycastWeapon()
                if hit and ent ~= entity then
                    SetEntityDrawOutline(entity, false)
                    entity = ent
                    SetEntityDrawOutline(entity, true)
                    coords, model, heading = GetEntityCoords(entity), GetEntityModel(entity), GetEntityHeading(entity)
                    SendNUIMessage({ type = "setText", aim = "none", details = "block", coords = coords, heading = heading, hash = model })
                end
                if entity ~= 0 and IsControlPressed(0, 24) then break end
            end
            Wait(0)
        end
        SetEntityDrawOutline(entity, false)
        SendNUIMessage({ type = "setText", aim = "none", details = "none" })
        return entity, model, coords, heading
    end

    if doorData.doortype == 'door' or doorData.doortype == 'sliding' or doorData.doortype == 'garage' then
        local ent, model, coords, heading = SelectEntity()
        doorData.entity, doorData.model, doorData.coords, doorData.heading = ent, model, coords, heading
        TriggerServerEvent('tmg-doorlock:server:saveNewDoor', doorData, false)
    else
        local ent, model, coords, heading = {}, {}, {}, {}
        for i = 1, 2 do ent[i], model[i], coords[i], heading[i] = SelectEntity() Wait(500) end
        doorData.entity, doorData.model, doorData.coords, doorData.heading = ent, model, coords, heading
        TriggerServerEvent('tmg-doorlock:server:saveNewDoor', doorData, true)
    end
    DoorMatrix.canContinue = true
    print("^5[TMG]^7 New door matrix submitted to server for persistence.")
end)

RegisterNetEvent('tmg-doorlock:client:newDoorAdded', function(data, id, creatorSrc)
    Config.DoorList[id] = data
    TriggerEvent('tmg-doorlock:client:setState', creatorSrc, id, data.locked, false, true, true)
end)

RegisterNetEvent('tmg-doorlock:client:ToggleDoorDebug', function()
    Config.DoorDebug = not Config.DoorDebug
    print("^5[TMG]^7 Visual debug matrix: " .. (Config.DoorDebug and "ENABLED" or "DISABLED"))
end)


RegisterCommand('toggledoorlock', function()
    local door = DoorMatrix.closestDoor
    if not door.id or door.distance > (door.data.distance or 2.0) then return end
    if door.data.cantUnlock and door.data.locked then return end
    if TMGCore.Functions.GetPlayerData().metadata['isdead'] or TMGCore.Functions.GetPlayerData().metadata['ishandcuffed'] then return end
    local src = door.data.audioRemote and NetworkGetNetworkIdFromEntity(DoorMatrix.playerPed) or false
    TriggerServerEvent('tmg-doorlock:server:updateState', door.id, not door.data.locked, src, false, false, true, true)
end)

RegisterKeyMapping('toggledoorlock', Lang:t("general.keymapping_description"), 'keyboard', 'E')

RegisterCommand('remotetriggerdoor', function()
    local hit, coords = RayCastGameplayCamera(Config.RemoteTriggerDistance)
    if not hit then return end
    local nearestID = nil
    local minTriggerDist = Config.RemoteTriggerMinDistance
    for k in pairs(DoorMatrix.nearbyDoors) do
        local door = Config.DoorList[k]
        if door.remoteTrigger then
            local dist = #(coords - door.textCoords)
            if dist < minTriggerDist then minTriggerDist = dist nearestID = k end
        end
    end
    if nearestID then TriggerServerEvent('tmg-doorlock:server:updateState', nearestID, not Config.DoorList[nearestID].locked, NetworkGetNetworkIdFromEntity(DoorMatrix.playerPed), false, false, true, true) end
end)

RegisterKeyMapping('remotetriggerdoor', Lang:t("general.keymapping_remotetriggerdoor"), 'keyboard', 'H')


RegisterNetEvent('TMGCore:Client:OnPlayerLoaded', function()
    TMGCore.Functions.TriggerCallback('tmg-doorlock:server:setupDoors', function(result)
        Config.DoorList = result
        DoorMatrix.isLoggedIn = true
        print("^5[TMG]^7 Security grid synchronized.")
    end)
end)

RegisterNetEvent('TMGCore:Client:OnPlayerUnload', function() DoorMatrix.isLoggedIn = false end)

AddEventHandler('onResourceStart', function(res)
    if GetCurrentResourceName() ~= res then return end
    TMGCore.Functions.TriggerCallback('tmg-doorlock:server:setupDoors', function(result) Config.DoorList = result DoorMatrix.isLoggedIn = true end)
end)

exports('GetClosestDoor', function() return DoorMatrix.closestDoor end)
exports('GetNearbyDoors', function() return DoorMatrix.nearbyDoors end)
exports('GetDoorList', function() return Config.DoorList end)
