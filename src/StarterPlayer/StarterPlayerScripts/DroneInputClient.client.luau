--!strict

-- Client-side keys for the drone. It only sends intent; the server still owns the real movement.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local remoteObject = ReplicatedStorage:WaitForChild("DroneInputRemote", 10)
if not remoteObject or not remoteObject:IsA("RemoteEvent") then
	warn("DroneInputRemote was not found, so drone keyboard controls are off.")
	return
end

local remote = remoteObject :: RemoteEvent
local active = false
local heldKeys: {[Enum.KeyCode]: boolean} = {}
local sendTimer = 0 -- extra heartbeat send keeps controls alive if a key event is missed.

local watchedKeys: {[Enum.KeyCode]: boolean} = {
	[Enum.KeyCode.W] = true,
	[Enum.KeyCode.A] = true,
	[Enum.KeyCode.S] = true,
	[Enum.KeyCode.D] = true,
	[Enum.KeyCode.Q] = true, -- down
	[Enum.KeyCode.E] = true, -- up
}

local function axis(positiveKey: Enum.KeyCode, negativeKey: Enum.KeyCode): number
	return (if heldKeys[positiveKey] then 1 else 0) + (if heldKeys[negativeKey] then -1 else 0)
end

local function clearKeys(): ()
	table.clear(heldKeys)
end

local function sendInput(): ()
	if not active then
		return
	end
	remote:FireServer({
		Throttle = axis(Enum.KeyCode.W, Enum.KeyCode.S),
		Steer = axis(Enum.KeyCode.D, Enum.KeyCode.A), -- D right, A left.
		Vertical = axis(Enum.KeyCode.E, Enum.KeyCode.Q), -- E up, Q down.
	})
end

local function setKey(keyCode: Enum.KeyCode, isDown: boolean): ()
	if not watchedKeys[keyCode] then
		return
	end
	heldKeys[keyCode] = if isDown then true else nil
	sendInput()
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if active and not gameProcessed then
		setKey(input.KeyCode, true)
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if active then
		setKey(input.KeyCode, false)
	end
end)

UserInputService.WindowFocusReleased:Connect(function()
	clearKeys()
	sendInput()
end)

remote.OnClientEvent:Connect(function(action: unknown)
	if action == "Start" then
		active = true
		clearKeys()
		sendInput()
	elseif action == "Stop" then
		clearKeys()
		sendInput()
		active = false
	end
end)

RunService.Heartbeat:Connect(function(dt: number)
	if not active then
		return
	end
	sendTimer += dt
	if sendTimer >= 0.05 then
		sendTimer = 0
		sendInput()
	end
end)
