local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui", 8)

local FIREBASE_URL = "https://cacc-c57bf-default-rtdb.firebaseio.com"
local API_KEY = "AIzaSyBquxKffIm2lBtpi90GLLDdrQG_0yvlo4Y"

local POLL_INTERVAL = 0.25
local AUTH_REFRESH_MARGIN = 300
local MAX_LOG_LINES = 120
local CLAIM_TIMEOUT = 60
local OUTFIT_APPLY_TIMEOUT = 8

local CommunityRemote = ReplicatedStorage:WaitForChild("CommunityOutfitsRemote", 8)
local CatalogGuiRemote = ReplicatedStorage:WaitForChild("CatalogGuiRemote", 8)
local UpdateStatusRemote = ReplicatedStorage:WaitForChild("Events"):WaitForChild("UpdatePlayerStatus", 5)

local active = true
local isProcessing = false
local currentIdToken = nil
local tokenExpiresAt = 0

local MY_USER_ID = tostring(Player.UserId)
local usernameCache = {}

local log

local function optimizeGraphics()
    settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    RunService:Set3dRenderingEnabled(false)

    Lighting.GlobalShadows = false
    Lighting.Brightness = 1
    Lighting.Ambient = Color3.new(1, 1, 1)
    Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
    Lighting.EnvironmentDiffuseScale = 0
    Lighting.EnvironmentSpecularScale = 0
    Lighting.Technology = Enum.Technology.Compatibility

    for _, effect in ipairs(Lighting:GetChildren()) do
        if effect:IsA("PostEffect") then
            effect.Enabled = false
        end
    end

    pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false) end)
    pcall(function() StarterGui:SetCore("ChatActive", false) end)

    UserInputService.MouseEnabled = false
    UserInputService.MouseIconEnabled = false

    workspace.StreamingEnabled = true
    workspace.StreamingMinRadius = 1000

    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        terrain.WaterReflectance = 0
        terrain.WaterTransparency = 1
        terrain.WaterWaveSize = 0
        terrain.WaterWaveSpeed = 0
        terrain:Clear()
    end

    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Texture") or obj:IsA("Decal") then
            obj.Texture = ""
        elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") then
            obj.Enabled = false
        end
    end

    log("Graphics optimized for max FPS")
end

local function createCleanLogger()
    local gui = Instance.new("ScreenGui")
    gui.Name = "CACLogger"
    gui.ResetOnSpawn = false
    gui.Parent = PlayerGui

    local frame = Instance.new("Frame", gui)
    frame.Size = UDim2.fromOffset(540, 320)
    frame.Position = UDim2.fromOffset(16, 16)
    frame.BackgroundColor3 = Color3.fromRGB(17, 17, 23)
    frame.BorderSizePixel = 0

    local logBox = Instance.new("TextLabel", frame)
    logBox.Size = UDim2.fromScale(1, 1)
    logBox.BackgroundTransparency = 1
    logBox.TextColor3 = Color3.new(1, 1, 1)
    logBox.Font = Enum.Font.Code
    logBox.TextSize = 13.5
    logBox.TextXAlignment = Enum.TextXAlignment.Left
    logBox.TextYAlignment = Enum.TextYAlignment.Top
    logBox.TextWrapped = true
    logBox.Text = "[CAC] Logger started • " .. os.date("%H:%M:%S") .. " • Worker: " .. MY_USER_ID

    local function addLine(msg)
        print("[CAC] " .. msg)
        if not logBox.Parent then return end
        logBox.Text = logBox.Text .. "\n" .. msg
        local lines = logBox.Text:split("\n")
        if #lines > MAX_LOG_LINES then
            logBox.Text = table.concat(lines, "\n", #lines - MAX_LOG_LINES + 1)
        end
    end

    local kill = Instance.new("TextButton", frame)
    kill.Size = UDim2.fromOffset(86, 26)
    kill.Position = UDim2.new(1, -94, 0, 6)
    kill.BackgroundColor3 = Color3.fromRGB(210, 60, 60)
    kill.TextColor3 = Color3.new(1, 1, 1)
    kill.Font = Enum.Font.Code
    kill.TextSize = 13
    kill.Text = "STOP"
    kill.MouseButton1Click:Connect(function()
        active = false
        gui:Destroy()
        warn("[CAC] Listener manually terminated")
    end)

    return addLine
end

log = createCleanLogger()

local request_impl = (syn and syn.request) or (http and http.request) or (request or game.HttpService.HttpRequestAsync)

local function http_req(method, url, body)
    if not request_impl then return nil end

    local success, response = pcall(request_impl, {
        Url = url,
        Method = method,
        Headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "Roblox/WinInet"
        },
        Body = body and HttpService:JSONEncode(body) or nil
    })

    if not success or not response or response.StatusCode < 200 or response.StatusCode > 299 then
        return nil
    end

    local ok, json = pcall(HttpService.JSONDecode, HttpService, response.Body)
    return ok and json or nil
end

local function refreshAuthToken()
    log("Refreshing Firebase token...")
    local data = http_req("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=" .. API_KEY, {
        returnSecureToken = true
    })

    if not data or not data.idToken then
        log("Firebase auth failed")
        return false
    end

    currentIdToken = data.idToken
    tokenExpiresAt = tick() + (data.expiresIn or 3600) - AUTH_REFRESH_MARGIN
    log("Token refreshed")
    return true
end

local function getRequests()
    if tick() > tokenExpiresAt then
        if not refreshAuthToken() then
            return {}
        end
    end
    return http_req("GET", FIREBASE_URL .. "/requests.json?auth=" .. currentIdToken) or {}
end

local function patch(requestId, data)
    local url = FIREBASE_URL .. ("/requests/%s.json?auth=%s"):format(requestId, currentIdToken)
    local success, resp = pcall(request_impl, {
        Url = url,
        Method = "PATCH",
        Headers = {
            ["Content-Type"] = "application/json"
        },
        Body = HttpService:JSONEncode(data)
    })
    return success and resp and resp.StatusCode >= 200 and resp.StatusCode < 300
end

local function tryClaim(requestId)
    local url = FIREBASE_URL .. ("/requests/%s.json?auth=%s"):format(requestId, currentIdToken)

    local current = http_req("GET", url)
    if not current or current.result then
        return false
    end

    local timedOut = current.claimedBy and current.claimedAt and (os.time() - current.claimedAt > CLAIM_TIMEOUT)
    if not timedOut and (current.claimedBy or current.processing) then
        return false
    end

    local claimData = {
        claimedBy = MY_USER_ID,
        claimedAt = os.time(),
        processing = true
    }

    if not patch(requestId, claimData) then
        return false
    end

    task.wait(0.05 + math.random(0, 50) / 1000)

    local after = http_req("GET", url)
    if not after or after.claimedBy ~= MY_USER_ID then
        log("Claim lost race → " .. requestId)
        return false
    end

    if timedOut then
        log("Reclaimed timed out → " .. requestId)
    else
        log("Claimed → " .. requestId)
    end

    return true
end

local function sendResult(id, payload)
    if patch(id, { result = payload }) then
        log("Result sent for " .. id)
    else
        log("Failed to send result for " .. id)
    end
end

local function forceResetCharacter()
    pcall(function()
        CatalogGuiRemote:InvokeServer({
            Action = "MorphIntoPlayer",
            UserId = Player.UserId,
            RigType = Enum.HumanoidRigType.R15
        })
        UpdateStatusRemote:FireServer("None")
    end)
    log("Character reset")
end

local function getUsername(userIdStr)
    if usernameCache[userIdStr] then
        return usernameCache[userIdStr]
    end

    local success, data = pcall(function()
        return Players:GetNameFromUserIdAsync(tonumber(userIdStr))
    end)

    if success and data then
        usernameCache[userIdStr] = data
        return data
    else
        usernameCache[userIdStr] = userIdStr
        return userIdStr
    end
end

local function snapshotDescription(desc)
    if not desc then return nil end

    local snap = {
        Shirt = desc.Shirt or 0,
        Pants = desc.Pants or 0,
        GraphicTShirt = desc.GraphicTShirt or 0,

        Head = desc.Head or 0,
        Torso = desc.Torso or 0,
        LeftArm = desc.LeftArm or 0,
        RightArm = desc.RightArm or 0,
        LeftLeg = desc.LeftLeg or 0,
        RightLeg = desc.RightLeg or 0,
        Face = desc.Face or 0,

        HeadColor = desc.HeadColor and desc.HeadColor:ToHex() or "",
        TorsoColor = desc.TorsoColor and desc.TorsoColor:ToHex() or "",
        LeftArmColor = desc.LeftArmColor and desc.LeftArmColor:ToHex() or "",
        RightArmColor = desc.RightArmColor and desc.RightArmColor:ToHex() or "",
        LeftLegColor = desc.LeftLegColor and desc.LeftLegColor:ToHex() or "",
        RightLegColor = desc.RightLegColor and desc.RightLegColor:ToHex() or "",

        HeightScale = desc.HeightScale or 0,
        WidthScale = desc.WidthScale or 0,
        HeadScale = desc.HeadScale or 0,
        DepthScale = desc.DepthScale or 0,
        ProportionScale = desc.ProportionScale or 0,
        BodyTypeScale = desc.BodyTypeScale or 0,

        WalkAnimation = desc.WalkAnimation or 0,
        RunAnimation = desc.RunAnimation or 0,
        JumpAnimation = desc.JumpAnimation or 0,
        IdleAnimation = desc.IdleAnimation or 0,
        FallAnimation = desc.FallAnimation or 0,
        SwimAnimation = desc.SwimAnimation or 0,
        ClimbAnimation = desc.ClimbAnimation or 0,
    }

    local accessories = {}
    for _, acc in desc:GetAccessories(true) do
        table.insert(accessories, table.concat({
            tostring(acc.AssetId or 0),
            tostring(acc.AccessoryType and acc.AccessoryType.Name or "Unknown"),
            tostring(acc.IsLayered and true or false),
            tostring(acc.Order or 0)
        }, ":"))
    end
    table.sort(accessories)
    snap.Accessories = accessories

    return snap
end

local function descriptionsEqual(a, b)
    if a == nil or b == nil then
        return false
    end

    for key, value in pairs(a) do
        local other = b[key]

        if type(value) == "table" then
            if type(other) ~= "table" or #value ~= #other then
                return false
            end
            for i = 1, #value do
                if value[i] ~= other[i] then
                    return false
                end
            end
        else
            if value ~= other then
                return false
            end
        end
    end

    return true
end

local function waitForOutfitApply(humanoid, previousSnapshot, timeout)
    local started = tick()
    local desc = humanoid:FindFirstChildOfClass("HumanoidDescription")

    while tick() - started < timeout do
        desc = humanoid:FindFirstChildOfClass("HumanoidDescription")
        if desc then
            local currentSnapshot = snapshotDescription(desc)
            if currentSnapshot and not descriptionsEqual(previousSnapshot, currentSnapshot) then
                task.wait(0.2)
                return desc
            end
        end
        task.wait(0.1)
    end

    return humanoid:FindFirstChildOfClass("HumanoidDescription")
end

local function processSingleOutfit(hexCode, requesterName)
    local code = tonumber(hexCode, 16)
    if not code then
        return { error = "Invalid outfit code" }
    end

    local char = Player.Character or Player.CharacterAdded:Wait()
    local humanoid = char:WaitForChild("Humanoid", 3)
    if not humanoid then
        return { error = "Humanoid not found" }
    end

    local beforeDesc = humanoid:FindFirstChildOfClass("HumanoidDescription")
    local beforeSnapshot = snapshotDescription(beforeDesc)

    log("Processing • " .. requesterName .. " • code: " .. code)

    local success, outfit = pcall(CommunityRemote.InvokeServer, CommunityRemote, {
        Action = "GetFromOutfitCode",
        OutfitCode = code
    })
    if not success or not outfit then
        return { error = "Failed to fetch outfit" }
    end

    local wearSuccess = pcall(CommunityRemote.InvokeServer, CommunityRemote, {
        Action = "WearCommunityOutfit",
        OutfitInfo = outfit
    })
    if not wearSuccess then
        return { error = "Failed to wear outfit" }
    end

    local desc = waitForOutfitApply(humanoid, beforeSnapshot, OUTFIT_APPLY_TIMEOUT)
    if not desc then
        return { error = "Outfit apply timed out" }
    end

    task.wait(0.35)

    local otherAcc = {}
    for _, acc in desc:GetAccessories(true) do
        local entry = {
            assetId = acc.AssetId,
            isLayered = acc.IsLayered,
            type = acc.AccessoryType.Name
        }
        if acc.Order then
            entry.order = acc.Order
        end
        table.insert(otherAcc, entry)
    end

    local animations = {
        walk = desc.WalkAnimation or 0,
        run = desc.RunAnimation or 0,
        jump = desc.JumpAnimation or 0,
        idle = desc.IdleAnimation or 0,
        fall = desc.FallAnimation or 0,
        swim = desc.SwimAnimation or 0,
        climb = desc.ClimbAnimation or 0,
    }

    local result = {
        RigType = humanoid.RigType.Name,
        Colors = {
            Head = desc.HeadColor:ToHex(),
            Torso = desc.TorsoColor:ToHex(),
            LeftArm = desc.LeftArmColor:ToHex(),
            RightArm = desc.RightArmColor:ToHex(),
            LeftLeg = desc.LeftLegColor:ToHex(),
            RightLeg = desc.RightLegColor:ToHex(),
        },
        Clothing = {
            Shirt = desc.Shirt,
            Pants = desc.Pants
        },
        Accessories = {
            Other = otherAcc
        },
        Scales = {
            Height = desc.HeightScale,
            Width = desc.WidthScale,
            Head = desc.HeadScale,
            Depth = desc.DepthScale,
            Proportion = desc.ProportionScale,
            BodyType = desc.BodyTypeScale,
        },
        Body = {
            Head = desc.Head,
            Torso = desc.Torso,
            LeftArm = desc.LeftArm,
            RightArm = desc.RightArm,
            LeftLeg = desc.LeftLeg,
            RightLeg = desc.RightLeg,
            Face = desc.Face,
        },
        Animations = animations
    }

    log("Done • " .. #otherAcc .. " accessories")
    return result
end

local function processRequest(requestId, data)
    isProcessing = true

    local requesterName = data.username or getUsername(data.userId or "unknown")
    log("Processing request from • " .. requesterName .. " • " .. requestId)

    local success, err = pcall(function()
        local result = {}
        local codes = data.codes or (data.code and { data.code }) or {}

        for i, hexCode in ipairs(codes) do
            local single = processSingleOutfit(hexCode, requesterName)
            result["outfit" .. i] = single
            task.wait(0.5 + math.random(0, 50) / 1000)
        end

        task.wait(0.3)
        forceResetCharacter()
        sendResult(requestId, result)
    end)

    if not success then
        log("Error in processing: " .. tostring(err))
        sendResult(requestId, { error = tostring(err) })
    end

    isProcessing = false
end

task.spawn(optimizeGraphics)

task.spawn(function()
    if not refreshAuthToken() then
        log("Initial auth failed → stopping")
        return
    end

    log("Listener active • poll: " .. POLL_INTERVAL .. "s • multi-worker safe")

    while active do
        if isProcessing then
            RunService.Heartbeat:Wait()
            continue
        end

        local t = tick()
        local requests = getRequests() or {}

        for id, data in pairs(requests) do
            local codes = data.codes or (data.code and { data.code }) or {}

            if #codes > 0 and not data.result then
                if tryClaim(id) then
                    task.spawn(processRequest, id, data)
                    break
                end
            end
        end

        local elapsed = tick() - t
        if elapsed < POLL_INTERVAL then
            task.wait(POLL_INTERVAL - elapsed)
        end
    end
end)

task.spawn(function()
    while active do
        Player.Idled:Wait()
        if not active then break end

        log("Anti-AFK triggered")
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)

        task.wait(285 + math.random(0, 30))
    end
end)

log("CAC ready • optimized • white logs • usernames • 2026")
