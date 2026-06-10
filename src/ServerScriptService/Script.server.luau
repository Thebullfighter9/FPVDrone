-- Connected Discord-GitHub
--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The client only sends key intent like WASD/QE. The server owns the drone physics, hiding, blade motors, and pilot validation.
local CONFIG = table.freeze({
	ModelNames = { "Drone", "DJI FVP" },
	BaseModelNames = { "DroneBase", "BaseDrone" },
	BladesModelName = "Blades",
	CameraPartNames = { "CameraPart", "CameraBall" },

	PromptName = "DronePilotPrompt",
	RootName = "DronePhysicsRoot",
	SeatName = "DroneHiddenSeat",
	RemoteName = "DroneInputRemote",
	AttachmentName = "DroneDriveAttachment",
	LinearVelocityName = "DroneDriveLinearVelocity",
	AlignOrientationName = "DroneDriveAlignOrientation",
	LiftForceName = "DronePilotLiftAssist",
	GeneratedAttribute = "GeneratedBySimpleDroneDriver",
	OldGeneratedAttribute = "GeneratedByDJIFVPDroneController",
	CollisionGroup = "SimpleDroneDriver",

	PromptDistance = 14,
	ForwardSpeed = 260, -- W target speed, fast on purpose so it feels like an FPV drone.
	ReverseSpeed = 105, -- S is slower than forward so backing up stays controllable.
	VerticalSpeed = 58, -- E goes up and Q goes down; no fake hover climb is added.
	TurnSpeed = math.rad(155), -- yaw rate for A/D after input smoothing.
	Acceleration = 7.5,
	InputSmoothing = 10, -- keeps key presses from snapping the drone around.
	CoastDrag = 0.32, -- low drag so letting go still glides instead of hard stopping.
	ParkDrag = 0.68,

	PitchDegrees = 16,
	BankDegrees = 28,
	CameraPitchDegrees = 8,
	CameraYawDegrees = 10,

	LiftAssist = 0.92, -- cancels most gravity, while Q/E still decide climb or drop.
	MaxLinearForcePerMass = 22000,
	MaxTorquePerMass = 11000,
	OrientationResponsiveness = 22,
	RootDensity = 0.85,

	BladeIdleSpin = 35,
	BladeDriveSpin = 65, -- extra blade spin from movement input so the props feel alive.
	BladeSpinSmoothing = 16,

	SeatCameraOffset = CFrame.new(0, -1.45, 0.15),
	FallbackSeatOffset = CFrame.new(0, 1.4, -0.75),
	ExitOffset = CFrame.new(0, 3, 8),
	InputTimeout = 0.45, -- if client packets stop, the drone eases back to neutral.
	SpeedGuiName = "DroneSpeedHud",
	SpeedLabelName = "SpeedText",
	SpeedHudUpdateRate = 0.1,
	StudsPerSecondToMph = 0.626,
})

type Controller = any

local Controller = {} :: any
Controller.__index = Controller

local OLD_GENERATED_NAMES: { [string]: boolean } = {
	DroneStatusGui = true,
	DronePulse = true,
	RaisePrompt = true,
	LowerPrompt = true,
	AltitudePrompt = true,
	PilotPrompt = true,
	DrivePrompt = true,
	DronePilotPrompt = true,
	DronePhysicsRoot = true,
	DroneDriveRoot = true,
	DroneHiddenDriveSeat = true,
	DroneHiddenVehicleSeat = true,
	DroneHiddenSeat = true,
	DronePilotSeat = true,
	DroneDriveAttachment = true,
	DroneLinearVelocity = true,
	DroneDriveLinearVelocity = true,
	DroneAlignOrientation = true,
	DroneDriveAlignOrientation = true,
	DroneLiftAssist = true,
	DronePilotLiftAssist = true,
	DroneSpeedHud = true,
}

local function createInstance(className: string, props: any, parent: Instance?): Instance
	local instance = Instance.new(className)
	for key, value in pairs(props) do
		(instance :: any)[key] = value
	end
	instance:SetAttribute(CONFIG.GeneratedAttribute, true)
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function findFirstChildByNames(parent: Instance, names: { string }): Instance?
	for _, name in ipairs(names) do
		local found = parent:FindFirstChild(name)
		if found then
			return found
		end
	end
	return nil
end

local function findDescendantByNames(parent: Instance, names: { string }): Instance?
	for _, name in ipairs(names) do
		local found = parent:FindFirstChild(name, true)
		if found then
			return found
		end
	end
	return nil
end

local function requireModel(instance: Instance?, label: string): Model
	if not instance or not instance:IsA("Model") then
		error(`Missing model "{label}" in the drone hierarchy.`)
	end
	return instance
end

local function getDroneModel(): Model
	if script.Parent:IsA("Model") then
		for _, name in ipairs(CONFIG.ModelNames) do
			if script.Parent.Name == name then
				return script.Parent
			end
		end
	end
	local found = findFirstChildByNames(workspace, CONFIG.ModelNames)
	if not found then
		error("Could not find Workspace.Drone or Workspace.DJI FVP.")
	end
	return requireModel(found, found.Name)
end

local function getFirstBasePart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

local function getBaseParts(instance: Instance): { BasePart }
	local parts = table.create(16)
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function getPivot(instance: Instance): CFrame
	if instance:IsA("Model") then
		return instance:GetPivot()
	elseif instance:IsA("BasePart") then
		return instance.CFrame
	end
	return CFrame.identity
end

local function pivotTo(instance: Instance, cframe: CFrame): ()
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function getYawFromCFrame(cframe: CFrame): number
	local _, yaw = cframe:ToOrientation()
	return yaw
end

local function yawToForward(yaw: number): Vector3
	return CFrame.Angles(0, yaw, 0).LookVector
end

local function expAlpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

local function registerCollisionGroup(): ()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(CONFIG.CollisionGroup)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CONFIG.CollisionGroup, CONFIG.CollisionGroup, false)
	end)
end

local function safeSetNetworkOwner(root: BasePart, player: Player?): ()
	pcall(function()
		root:SetNetworkOwner(player)
	end)
end

local function getOrCreateRemote(): RemoteEvent
	local remote = ReplicatedStorage:FindFirstChild(CONFIG.RemoteName)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	if remote then
		remote:Destroy()
	end
	return createInstance("RemoteEvent", {
		Name = CONFIG.RemoteName,
	}, ReplicatedStorage) :: RemoteEvent
end

local function cleanupOldGenerated(model: Model): ()
	for _, item in ipairs(model:GetDescendants()) do
		local taggedOld = item:GetAttribute(CONFIG.OldGeneratedAttribute) == true
		local taggedCurrent = item:GetAttribute(CONFIG.GeneratedAttribute) == true
		local namedOld = OLD_GENERATED_NAMES[item.Name] == true
		local generatedUi = item:IsA("BillboardGui") or item:IsA("ScreenGui") or item:IsA("TextLabel")
		if taggedOld or taggedCurrent or namedOld or generatedUi then
			item:Destroy()
		end
	end
end

local function prepPhysicalPart(part: BasePart, root: BasePart): ()
	part.Anchored = false
	part.Massless = part ~= root
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true
	part.CollisionGroup = CONFIG.CollisionGroup
	if part == root then
		part.CanCollide = true
		part.Transparency = 1
		part.CustomPhysicalProperties = PhysicalProperties.new(CONFIG.RootDensity, 0.5, 0.02, 1, 1)
	end
end

local function prepVisualOnlyPart(part: BasePart): ()
	part.Anchored = true
	part.Massless = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CollisionGroup = CONFIG.CollisionGroup
end

local function prepBladePart(part: BasePart): ()
	part.Anchored = false
	part.Massless = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CollisionGroup = CONFIG.CollisionGroup
end

local function weldToRoot(root: BasePart, part: BasePart): ()
	if part == root then
		return
	end
	local weld = createInstance("WeldConstraint", {
		Name = "DroneWeld_" .. part.Name,
		Part0 = root,
		Part1 = part,
	}, root) :: WeldConstraint
	weld.Enabled = true
end

local function createRoot(model: Model, baseModel: Model): BasePart
	local boundsCFrame, boundsSize = baseModel:GetBoundingBox()
	local root = createInstance("Part", {
		Name = CONFIG.RootName,
		Size = Vector3.new(math.max(boundsSize.X, 3), math.max(boundsSize.Y, 1.25), math.max(boundsSize.Z, 3)),
		CFrame = boundsCFrame,
		Transparency = 1,
		Anchored = false,
		CanCollide = true,
		CanTouch = false,
		CanQuery = true,
	}, model) :: BasePart
	model.PrimaryPart = root
	prepPhysicalPart(root, root)
	return root
end

local function createSeat(model: Model, root: BasePart, cameraPart: BasePart?): Seat
	local seatCFrame = root.CFrame * CONFIG.FallbackSeatOffset
	if cameraPart then
		-- Seat is only a camera/occupant anchor. Real WASD/QE input comes from the LocalScript.
		seatCFrame = cameraPart.CFrame * CONFIG.SeatCameraOffset
	end
	local seat = createInstance("Seat", {
		Name = CONFIG.SeatName,
		Size = Vector3.new(2, 0.7, 2),
		CFrame = seatCFrame,
		Transparency = 1,
		Anchored = false,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
	}, model) :: Seat
	seat.CollisionGroup = CONFIG.CollisionGroup
	weldToRoot(root, seat)
	return seat
end

local function createPrompt(root: BasePart): ProximityPrompt
	return createInstance("ProximityPrompt", {
		Name = CONFIG.PromptName,
		ActionText = "Fly Drone",
		ObjectText = "Drone",
		KeyboardKeyCode = Enum.KeyCode.F,
		GamepadKeyCode = Enum.KeyCode.ButtonX,
		HoldDuration = 0,
		MaxActivationDistance = CONFIG.PromptDistance,
		RequiresLineOfSight = false,
		Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton,
		Enabled = true,
	}, root) :: ProximityPrompt
end

local function createPhysicsRig(root: BasePart): (Attachment, LinearVelocity, AlignOrientation, VectorForce)
	local attachment = createInstance("Attachment", {
		Name = CONFIG.AttachmentName,
	}, root) :: Attachment
	local linearVelocity = createInstance("LinearVelocity", {
		Name = CONFIG.LinearVelocityName,
		Attachment0 = attachment,
		RelativeTo = Enum.ActuatorRelativeTo.World,
		VelocityConstraintMode = Enum.VelocityConstraintMode.Vector,
		VectorVelocity = Vector3.zero,
		MaxForce = root.AssemblyMass * CONFIG.MaxLinearForcePerMass,
		Enabled = false,
	}, root) :: LinearVelocity
	local alignOrientation = createInstance("AlignOrientation", {
		Name = CONFIG.AlignOrientationName,
		Attachment0 = attachment,
		Mode = Enum.OrientationAlignmentMode.OneAttachment,
		CFrame = root.CFrame.Rotation,
		MaxTorque = root.AssemblyMass * CONFIG.MaxTorquePerMass,
		MaxAngularVelocity = math.rad(320),
		Responsiveness = CONFIG.OrientationResponsiveness,
		RigidityEnabled = false,
		Enabled = true,
	}, root) :: AlignOrientation
	local liftForce = createInstance("VectorForce", {
		Name = CONFIG.LiftForceName,
		Attachment0 = attachment,
		RelativeTo = Enum.ActuatorRelativeTo.World,
		ApplyAtCenterOfMass = true,
		Force = Vector3.zero,
		Enabled = false,
	}, root) :: VectorForce
	return attachment, linearVelocity, alignOrientation, liftForce
end

local function prepareBaseAssembly(baseModel: Model, root: BasePart): ()
	local parts = getBaseParts(baseModel)
	if #parts == 0 then
		error("DroneBase needs at least one BasePart or MeshPart.")
	end
	for _, part in ipairs(parts) do
		prepPhysicalPart(part, root)
		weldToRoot(root, part)
	end
end

local function makeBladeVisuals(model: Model, root: BasePart): { any }
	local bladeNames = {
		"FrontLeftDrone", "FrontRightDrone", "BackRightDrone", "BackLeftDrone",
		"FrontLeftBlade", "FrontRightBlade", "BackRightBlade", "BackLeftBlade",
	}
	local spinDirections: { [string]: number } = {
		FrontLeftDrone = 1, BackRightDrone = 1, FrontLeftBlade = 1, BackRightBlade = 1,
		FrontRightDrone = -1, BackLeftDrone = -1, FrontRightBlade = -1, BackLeftBlade = -1,
	}
	local blades = table.create(4)
	for index, bladeName in ipairs(bladeNames) do
		local blade = model:FindFirstChild(bladeName)
		if blade then
			local bladePart = getFirstBasePart(blade)
			if bladePart then
				for _, part in ipairs(getBaseParts(blade)) do
					prepBladePart(part)
					if part ~= bladePart then
						local weld = createInstance("WeldConstraint", { Name = "DroneBladePartWeld_" .. part.Name, Part0 = bladePart, Part1 = part }, bladePart) :: WeldConstraint
						weld.Enabled = true
					end
				end
				local baseC0 = root.CFrame:ToObjectSpace(bladePart.CFrame)
				local joint = createInstance("Motor6D", {
					Name = "DroneBladeMotor_" .. bladeName,
					Part0 = root,
					Part1 = bladePart,
					C0 = baseC0,
					C1 = CFrame.identity,
				}, root) :: Motor6D
				table.insert(blades, {
					Joint = joint,
					BaseC0 = baseC0,
					Direction = spinDirections[bladeName] or 1,
					Phase = (index - 1) * math.pi * 0.5,
				})
			end
		end
	end
	return blades
end

local function makeCameraVisual(root: BasePart, cameraPart: BasePart?): any
	if not cameraPart then
		return nil
	end
	prepVisualOnlyPart(cameraPart)
	return {
		Pivot = cameraPart,
		LocalOffset = root.CFrame:ToObjectSpace(cameraPart.CFrame),
	}
end

local function makeRayParams(model: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	params.IgnoreWater = true
	return params
end

local function getPlayerHumanoid(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function getSeatPlayer(seat: Seat): Player?
	local humanoid = seat.Occupant
	if not humanoid or not humanoid.Parent then
		return nil
	end
	return Players:GetPlayerFromCharacter(humanoid.Parent)
end

local function clearConnections(connections: { RBXScriptConnection }): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function ensureSpeedHud(player: Player): TextLabel?
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 3)
	if not playerGui or not playerGui:IsA("PlayerGui") then
		return nil
	end
	local gui = playerGui:FindFirstChild(CONFIG.SpeedGuiName)
	if not gui then
		gui = createInstance("ScreenGui", { Name = CONFIG.SpeedGuiName, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 25, Enabled = false }, playerGui) :: ScreenGui
	end
	local label = gui:FindFirstChild(CONFIG.SpeedLabelName)
	if not label then
		label = createInstance("TextLabel", {
			Name = CONFIG.SpeedLabelName,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -18, 1, -18),
			Size = UDim2.fromOffset(118, 34),
			BackgroundColor3 = Color3.fromRGB(0, 0, 0),
			BackgroundTransparency = 0.32,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			Text = "0 MPH",
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			TextStrokeTransparency = 0.55,
		}, gui) :: TextLabel
	end
	return if label:IsA("TextLabel") then label else nil
end

local function setSpeedHudVisible(self: Controller, player: Player, visible: boolean): ()
	local label = self.HudLabels[player] or ensureSpeedHud(player)
	if not label then
		return
	end
	self.HudLabels[player] = label
	local gui = label.Parent
	if gui and gui:IsA("ScreenGui") then
		gui.Enabled = visible
	end
	if not visible then
		label.Text = "0 MPH"
	end
end

local function updateSpeedHud(self: Controller, dt: number): ()
	if not self.Pilot then
		return
	end
	self.SpeedHudTimer += dt
	if self.SpeedHudTimer < CONFIG.SpeedHudUpdateRate then
		return
	end
	self.SpeedHudTimer = 0
	local label = self.HudLabels[self.Pilot] or ensureSpeedHud(self.Pilot)
	if not label then
		return
	end
	self.HudLabels[self.Pilot] = label
	local gui = label.Parent
	if gui and gui:IsA("ScreenGui") then
		gui.Enabled = true
	end
	local flatVelocity = Vector3.new(self.Root.AssemblyLinearVelocity.X, 0, self.Root.AssemblyLinearVelocity.Z)
	local mph = math.max(0, math.floor(flatVelocity.Magnitude * CONFIG.StudsPerSecondToMph + 0.5))
	label.Text = `{mph} MPH`
end

local function hideCharacter(self: Controller, player: Player): ()
	if self.HiddenCharacters[player] then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character then
		return
	end
	local record: any = {
		PartStates = {},
		VisualStates = {},
		Humanoid = humanoid,
		AutoRotate = humanoid and humanoid.AutoRotate or nil,
		WalkSpeed = humanoid and humanoid.WalkSpeed or nil,
		JumpPower = humanoid and humanoid.JumpPower or nil,
		JumpHeight = humanoid and humanoid.JumpHeight or nil,
		UseJumpPower = humanoid and humanoid.UseJumpPower or nil,
		CameraOffset = humanoid and humanoid.CameraOffset or nil,
		CameraMode = player.CameraMode,
		CameraMinZoomDistance = player.CameraMinZoomDistance,
		CameraMaxZoomDistance = player.CameraMaxZoomDistance,
	}
	if humanoid then
		humanoid.AutoRotate = false
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
		humanoid.CameraOffset = Vector3.zero
	end
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 0.5
	for _, item in ipairs(character:GetDescendants()) do
		if item:IsA("BasePart") then
			record.PartStates[item] = { Transparency = item.Transparency, CanCollide = item.CanCollide, CanTouch = item.CanTouch, CanQuery = item.CanQuery }
			item.Transparency = 1
			item.CanCollide = false
			item.CanTouch = false
			item.CanQuery = false
		elseif item:IsA("Decal") or item:IsA("Texture") then
			record.VisualStates[item] = { Transparency = item.Transparency }
			item.Transparency = 1
		end
	end
	self.HiddenCharacters[player] = record
end

local function restoreCharacter(self: Controller, player: Player): ()
	local record = self.HiddenCharacters[player]
	if not record then
		return
	end
	for part, state in pairs(record.PartStates) do
		if part.Parent then
			part.Transparency = state.Transparency
			part.CanCollide = state.CanCollide
			part.CanTouch = state.CanTouch
			part.CanQuery = state.CanQuery
		end
	end
	for visual, state in pairs(record.VisualStates) do
		if visual.Parent then
			(visual :: any).Transparency = state.Transparency
		end
	end
	local humanoid = record.Humanoid
	if humanoid and humanoid.Parent then
		if record.AutoRotate ~= nil then humanoid.AutoRotate = record.AutoRotate end
		if record.WalkSpeed ~= nil then humanoid.WalkSpeed = record.WalkSpeed end
		if record.UseJumpPower ~= nil then humanoid.UseJumpPower = record.UseJumpPower end
		if record.JumpPower ~= nil then humanoid.JumpPower = record.JumpPower end
		if record.JumpHeight ~= nil then humanoid.JumpHeight = record.JumpHeight end
		if record.CameraOffset ~= nil then humanoid.CameraOffset = record.CameraOffset end
	end
	player.CameraMode = record.CameraMode
	player.CameraMinZoomDistance = record.CameraMinZoomDistance
	player.CameraMaxZoomDistance = record.CameraMaxZoomDistance
	self.HiddenCharacters[player] = nil
end

local function moveCharacterToExit(self: Controller, player: Player): ()
	local character = player.Character
	if character then
		character:PivotTo(self.Root.CFrame * CONFIG.ExitOffset)
	end
end

function Controller.new(model: Model): Controller
	registerCollisionGroup()
	cleanupOldGenerated(model)
	local baseModel = requireModel(findFirstChildByNames(model, CONFIG.BaseModelNames), "DroneBase")
	local cameraPartCandidate = findDescendantByNames(model, CONFIG.CameraPartNames)
	local cameraPart = if cameraPartCandidate and cameraPartCandidate:IsA("BasePart") then cameraPartCandidate else nil
	local bladesModel = model:FindFirstChild(CONFIG.BladesModelName)
	local root = createRoot(model, baseModel)
	local seat = createSeat(model, root, cameraPart)
	local attachment, linearVelocity, alignOrientation, liftForce = createPhysicsRig(root)
	local prompt = createPrompt(root)
	prepareBaseAssembly(baseModel, root)
	local controller = setmetatable({
		Model = model,
		BaseModel = baseModel,
		Root = root,
		Seat = seat,
		Prompt = prompt,
		Remote = getOrCreateRemote(),
		Attachment = attachment,
		LinearVelocity = linearVelocity,
		AlignOrientation = alignOrientation,
		LiftForce = liftForce,
		RayParams = makeRayParams(model),
		Blades = if bladesModel and bladesModel:IsA("Model") then makeBladeVisuals(bladesModel, root) else {},
		CameraVisual = makeCameraVisual(root, cameraPart),
		Pilot = nil :: Player?,
		PilotHumanoid = nil :: Humanoid?,
		HiddenCharacters = {},
		HudLabels = {},
		Connections = {},
		PilotConnections = {},
		InputThrottle = 0,
		InputSteer = 0,
		InputVertical = 0,
		LastInputAt = 0,
		SmoothedThrottle = 0,
		SmoothedSteer = 0,
		SmoothedVertical = 0,
		HorizontalVelocity = Vector3.zero,
		TargetYaw = getYawFromCFrame(root.CFrame),
		BladeSpin = 0,
		BladeSpinSpeed = 0,
		SpeedHudTimer = 0,
		Destroyed = false,
	}, Controller) :: any
	return controller :: Controller
end

function Controller:ReceiveInput(player: Player, payload: any): ()
	if self.Pilot ~= player or typeof(payload) ~= "table" then
		return
	end
	local throttle = if typeof(payload.Throttle) == "number" then payload.Throttle else 0
	local steer = if typeof(payload.Steer) == "number" then payload.Steer else 0
	local vertical = if typeof(payload.Vertical) == "number" then payload.Vertical else 0
	self.InputThrottle = math.clamp(throttle, -1, 1)
	self.InputSteer = math.clamp(steer, -1, 1)
	self.InputVertical = math.clamp(vertical, -1, 1)
	self.LastInputAt = os.clock()
end

function Controller:EnterPilot(player: Player): ()
	if self.Pilot then
		return
	end
	local humanoid = getPlayerHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	hideCharacter(self, player)
	setSpeedHudVisible(self, player, true)
	self.Pilot = player
	self.PilotHumanoid = humanoid
	self.Prompt.Enabled = false
	self.InputThrottle = 0
	self.InputSteer = 0
	self.InputVertical = 0
	self.LastInputAt = os.clock()
	self.SmoothedThrottle = 0
	self.SmoothedSteer = 0
	self.SmoothedVertical = 0
	self.HorizontalVelocity = Vector3.zero
	self.TargetYaw = getYawFromCFrame(self.Root.CFrame)
	self.LinearVelocity.Enabled = true
	self.LiftForce.Enabled = true
	safeSetNetworkOwner(self.Root, player)
	self.Seat:Sit(humanoid)
	self.Remote:FireClient(player, "Start")
	clearConnections(self.PilotConnections)
	table.insert(self.PilotConnections, humanoid.Died:Connect(function()
		self:ExitPilot()
	end))
	table.insert(self.PilotConnections, humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
		if humanoid.Jump then
			self:ExitPilot()
		end
	end))
	table.insert(self.PilotConnections, player.CharacterRemoving:Connect(function()
		self:ExitPilot()
	end))
	task.delay(0.25, function()
		if self.Pilot == player and self.Seat.Occupant ~= humanoid then
			self:ExitPilot()
		end
	end)
end

function Controller:ExitPilot(): ()
	local player = self.Pilot
	local humanoid = self.PilotHumanoid
	if not player then
		return
	end
	self.Remote:FireClient(player, "Stop")
	self.Pilot = nil
	self.PilotHumanoid = nil
	self.Prompt.Enabled = true
	self.InputThrottle = 0
	self.InputSteer = 0
	self.InputVertical = 0
	self.SmoothedThrottle = 0
	self.SmoothedSteer = 0
	self.SmoothedVertical = 0
	self.HorizontalVelocity = Vector3.zero
	self.LinearVelocity.VectorVelocity = Vector3.zero
	self.LinearVelocity.Enabled = false
	self.LiftForce.Force = Vector3.zero
	self.LiftForce.Enabled = false
	clearConnections(self.PilotConnections)
	if humanoid and humanoid.Parent and humanoid.SeatPart == self.Seat then
		humanoid.Sit = false
		humanoid.Jump = true
	end
	moveCharacterToExit(self, player)
	setSpeedHudVisible(self, player, false)
	restoreCharacter(self, player)
	safeSetNetworkOwner(self.Root, nil)
end

function Controller:Start(): ()
	safeSetNetworkOwner(self.Root, nil)
	table.insert(self.Connections, self.Prompt.Triggered:Connect(function(player: Player)
		self:EnterPilot(player)
	end))
	table.insert(self.Connections, self.Remote.OnServerEvent:Connect(function(player: Player, payload: any)
		self:ReceiveInput(player, payload)
	end))
	table.insert(self.Connections, self.Seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local seatedPlayer = getSeatPlayer(self.Seat)
		if self.Pilot and seatedPlayer ~= self.Pilot then
			self:ExitPilot()
		end
	end))
	table.insert(self.Connections, Players.PlayerRemoving:Connect(function(player: Player)
		if self.Pilot == player then
			self:ExitPilot()
		else
			setSpeedHudVisible(self, player, false)
			restoreCharacter(self, player)
		end
	end))
	table.insert(self.Connections, self.Model.AncestryChanged:Connect(function(_, parent: Instance?)
		if parent == nil then
			self:Destroy()
		end
	end))
	table.insert(self.Connections, RunService.Heartbeat:Connect(function(dt: number)
		self:Update(math.min(dt, 1 / 20))
	end))
end

function Controller:Update(dt: number): ()
	if self.Destroyed then
		return
	end
	local mass = self.Root.AssemblyMass
	self.LinearVelocity.MaxForce = mass * CONFIG.MaxLinearForcePerMass
	self.AlignOrientation.MaxTorque = mass * CONFIG.MaxTorquePerMass
	if self.Pilot then
		local humanoid = self.PilotHumanoid
		if not humanoid or not humanoid.Parent or humanoid.Health <= 0 or getSeatPlayer(self.Seat) ~= self.Pilot then
			self:ExitPilot()
			return
		end
		local now = os.clock()
		local throttle = self.InputThrottle
		local steer = self.InputSteer
		local vertical = self.InputVertical
		if now - self.LastInputAt > CONFIG.InputTimeout then
			throttle = 0
			steer = 0
			vertical = 0
		end
		local inputAlpha = expAlpha(CONFIG.InputSmoothing, dt)
		self.SmoothedThrottle += (throttle - self.SmoothedThrottle) * inputAlpha
		self.SmoothedSteer += (steer - self.SmoothedSteer) * inputAlpha
		self.SmoothedVertical += (vertical - self.SmoothedVertical) * inputAlpha
		self.TargetYaw += -self.SmoothedSteer * CONFIG.TurnSpeed * dt
		local forward = yawToForward(self.TargetYaw)
		local driveAlpha = expAlpha(CONFIG.Acceleration, dt)
		if math.abs(self.SmoothedThrottle) > 0.03 then
			local speed = if self.SmoothedThrottle >= 0 then CONFIG.ForwardSpeed else CONFIG.ReverseSpeed
			local targetHorizontal = forward * self.SmoothedThrottle * speed
			self.HorizontalVelocity = self.HorizontalVelocity:Lerp(targetHorizontal, driveAlpha)
		else
			local drag = math.exp(-CONFIG.CoastDrag * dt)
			self.HorizontalVelocity *= drag
			if self.HorizontalVelocity.Magnitude < 0.05 then
				self.HorizontalVelocity = Vector3.zero
			end
		end
		local verticalSpeed = self.SmoothedVertical * CONFIG.VerticalSpeed
		self.LinearVelocity.VectorVelocity = Vector3.new(self.HorizontalVelocity.X, verticalSpeed, self.HorizontalVelocity.Z)
		self.LiftForce.Force = Vector3.new(0, mass * workspace.Gravity * CONFIG.LiftAssist, 0)
		self.AlignOrientation.CFrame = CFrame.Angles(0, self.TargetYaw, 0)
			* CFrame.Angles(math.rad(-CONFIG.PitchDegrees) * self.SmoothedThrottle, 0, math.rad(-CONFIG.BankDegrees) * self.SmoothedSteer)
	else
		local velocity = self.Root.AssemblyLinearVelocity
		self.Root.AssemblyLinearVelocity = Vector3.new(velocity.X * CONFIG.ParkDrag, velocity.Y, velocity.Z * CONFIG.ParkDrag)
		self.Root.AssemblyAngularVelocity *= CONFIG.ParkDrag
		self.TargetYaw = getYawFromCFrame(self.Root.CFrame)
		self.AlignOrientation.CFrame = CFrame.Angles(0, self.TargetYaw, 0)
	end
	updateSpeedHud(self, dt)
	self:UpdateVisuals(dt)
end

function Controller:UpdateVisuals(dt: number): ()
	local speedAmount = math.clamp(self.HorizontalVelocity.Magnitude / CONFIG.ForwardSpeed, 0, 1)
	local inputAmount = math.max(math.abs(self.SmoothedThrottle), math.abs(self.SmoothedVertical), speedAmount)
	local targetBladeSpeed = if self.Pilot then CONFIG.BladeIdleSpin + inputAmount * CONFIG.BladeDriveSpin else 0
	local spinAlpha = expAlpha(CONFIG.BladeSpinSmoothing, dt)
	self.BladeSpinSpeed += (targetBladeSpeed - self.BladeSpinSpeed) * spinAlpha
	self.BladeSpin += self.BladeSpinSpeed * dt
	for _, blade in ipairs(self.Blades) do
		local spin = CFrame.Angles(0, self.BladeSpin * blade.Direction + blade.Phase, 0)
		blade.Joint.C0 = blade.BaseC0 * spin
	end
	if self.CameraVisual then
		local yaw = math.rad(CONFIG.CameraYawDegrees) * -self.SmoothedSteer
		local pitch = math.rad(CONFIG.CameraPitchDegrees) * -self.SmoothedThrottle
		pivotTo(self.CameraVisual.Pivot, self.Root.CFrame * self.CameraVisual.LocalOffset * CFrame.Angles(pitch, yaw, 0))
	end
end

function Controller:Destroy(): ()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	if self.Pilot then
		self:ExitPilot()
	end
	for player in pairs(self.HiddenCharacters) do
		setSpeedHudVisible(self, player, false)
		restoreCharacter(self, player)
	end
	clearConnections(self.PilotConnections)
	clearConnections(self.Connections)
end

local droneModel = getDroneModel()
local controller = Controller.new(droneModel)
controller:Start()
