local DataStoreService = game:GetService("DataStoreService")

export type CommandType = "LOAD" | "SAVE" | "UNLOAD"

export type Schema = {
	name: string,
	dataTemplate: { [string]: any },
	migrations: { (data: { [string]: any }) -> () },
}

export type SavedData = {
	keyData: { [string]: any },
	version: number,
	lockId: string?,
	lockTime: number?,
}

export type CommandSchema = {
	commandType: CommandType,
	key: string,
	schema: Schema,
	data: SavedData?,
	sessionId: string?,
	retries: number,
	callback: ((success: boolean, result: any, errorType: string?) -> ())?,
}

local SESSION_LOCK_EXPIRE_TIME = 1800

local BUDGET_MAP = {
	LOAD = Enum.DataStoreRequestType.UpdateAsync,
	SAVE = Enum.DataStoreRequestType.UpdateAsync,
	UNLOAD = Enum.DataStoreRequestType.UpdateAsync,
}

local dataStoreCache: { [string]: DataStore } = {}
local mockDataCache: { [string]: { [string]: SavedData } } = {}
local commandQueue: { CommandSchema } = {}
local isProcessing: boolean = false
local mockMode: boolean = false

local CommandQueue = {}

local function getBudget(budgetType: Enum.DataStoreRequestType): boolean
	if mockMode then
		return true
	end

	local budget = DataStoreService:GetRequestBudgetForRequestType(budgetType)
	return budget >= 1
end

local function getDataStore(schema: Schema): DataStore
	if not dataStoreCache[schema.name] then
		dataStoreCache[schema.name] = DataStoreService:GetDataStore(schema.name)
	end
	return dataStoreCache[schema.name]
end

local function getMockStore(schemaName: string): { [string]: SavedData }
	if not mockDataCache[schemaName] then
		mockDataCache[schemaName] = {}
	end
	return mockDataCache[schemaName]
end

local function deepCopy<T>(original: T): T
	if type(original) ~= "table" then
		return original
	end

	local copy = {}
	for key, value in original :: any do
		if type(value) == "table" then
			copy[key] = deepCopy(value)
		else
			copy[key] = value
		end
	end

	return copy :: any
end

local function deepFreeze<T>(tbl: T): T
	if type(tbl) ~= "table" then
		return tbl
	end

	for _, value in tbl :: any do
		if type(value) == "table" then
			deepFreeze(value)
		end
	end

	return table.freeze(tbl :: any) :: any
end

local function reconcileData(data: { [string]: any }?, template: { [string]: any }): { [string]: any }
	local reconciled = deepCopy(template)

	if data then
		for key, value in data do
			if type(value) == "table" and type(reconciled[key]) == "table" then
				reconciled[key] = reconcileData(value, reconciled[key])
			else
				reconciled[key] = value
			end
		end
	end

	return reconciled
end

local function applyMigrations(keyData: { [string]: any }, currentVersion: number, schema: Schema): ({ [string]: any }, number)
	local version = currentVersion

	for i = version + 1, #schema.migrations do
		schema.migrations[i](keyData)
		version = i
	end

	return keyData, version
end

local function isLockExpired(lockTime: number?): boolean
	if not lockTime then
		return true
	end
	return os.time() - lockTime > SESSION_LOCK_EXPIRE_TIME
end

local function isLockOwnedBySession(savedData: SavedData?, sessionId: string?): boolean
	if not savedData or not savedData.lockId then
		return true
	end
	if savedData.lockId == sessionId then
		return true
	end
	return isLockExpired(savedData.lockTime)
end

local function executeCommand(command: CommandSchema)
	local success: boolean, result: any = false, nil
	local errorType: string? = nil

	if mockMode then
		local mockStore = getMockStore(command.schema.name)

		if command.commandType == "LOAD" then
			local existingData = mockStore[command.key]
			
			if command.sessionId and not isLockOwnedBySession(existingData, command.sessionId) then
				success, result, errorType = false, "Session is locked by another server", "SESSION_LOCKED"
			else
				local keyData = reconcileData(existingData and existingData.keyData, command.schema.dataTemplate)
				local version = existingData and existingData.version or 0
				keyData, version = applyMigrations(keyData, version, command.schema)

				local savedData: SavedData = {
					keyData = keyData,
					version = version,
					lockId = command.sessionId,
					lockTime = if command.sessionId then os.time() else nil,
				}

				mockStore[command.key] = deepCopy(savedData)
				savedData.keyData = deepFreeze(savedData.keyData)
				success, result = true, savedData
			end
		elseif command.commandType == "SAVE" then
			if command.data then
				mockStore[command.key] = deepCopy(command.data)
			end
			success, result = true, nil
		elseif command.commandType == "UNLOAD" then
			if command.data then
				local dataToSave = deepCopy(command.data)
				dataToSave.lockId = nil
				dataToSave.lockTime = nil
				mockStore[command.key] = dataToSave
			end
			success, result = true, nil
		end
	else
		local dataStore = getDataStore(command.schema)

		if command.commandType == "LOAD" then
			success, result = pcall(function()
				return dataStore:UpdateAsync(command.key, function(oldData: SavedData?)
					if command.sessionId and not isLockOwnedBySession(oldData, command.sessionId) then
						return nil
					end

					local keyData = reconcileData(oldData and oldData.keyData, command.schema.dataTemplate)
					local version = oldData and oldData.version or 0
					keyData, version = applyMigrations(keyData, version, command.schema)

					local newData: SavedData = {
						keyData = keyData,
						version = version,
						lockId = command.sessionId,
						lockTime = if command.sessionId then os.time() else nil,
					}

					return newData
				end)
			end)

			if success then
				if result == nil and command.sessionId then
					success, result, errorType = false, "Session is locked by another server", "SESSION_LOCKED"
				else
					(result :: SavedData).keyData = deepFreeze((result :: SavedData).keyData)
				end
			end
		elseif command.commandType == "SAVE" then
			success, result = pcall(function()
				return dataStore:UpdateAsync(command.key, function(oldData: SavedData?)
					if command.sessionId and oldData and oldData.lockId ~= command.sessionId then
						return nil
					end

					if command.data then
						local dataToSave = deepCopy(command.data)
						if command.sessionId then
							dataToSave.lockTime = os.time()
						end

						return dataToSave
					end
					return oldData
				end)
			end)

			if success and result == nil and command.sessionId then
				success, result, errorType = false, "Lost session lock", "LOCK_LOST"
			end
		elseif command.commandType == "UNLOAD" then
			success, result = pcall(function()
				return dataStore:UpdateAsync(command.key, function(oldData: SavedData?)
					if command.data then
						local dataToSave = deepCopy(command.data)
						dataToSave.lockId = nil
						dataToSave.lockTime = nil

						return dataToSave
					end

					if oldData then
						oldData.lockId = nil
						oldData.lockTime = nil
					end

					return oldData
				end)
			end)
		end
	end

	if not success and errorType ~= "SESSION_LOCKED" and errorType ~= "LOCK_LOST" and command.retries > 0 then
		command.retries -= 1
		table.insert(commandQueue, command)
		return
	end

	if command.callback then
		command.callback(success, result, errorType)
	end
end

local function processQueue()
	if isProcessing then
		return
	end

	isProcessing = true

	task.spawn(function()
		while #commandQueue > 0 do
			local command = commandQueue[1]
			local budgetType = BUDGET_MAP[command.commandType]

			if budgetType and not getBudget(budgetType) then
				task.wait(0.5)
				continue
			end

			table.remove(commandQueue, 1)
			executeCommand(command)
		end

		isProcessing = false
	end)
end

function CommandQueue.enqueue(command: CommandSchema)
	table.insert(commandQueue, command)
	processQueue()
end

function CommandQueue.getQueueLength(): number
	return #commandQueue
end

function CommandQueue.isProcessing(): boolean
	return isProcessing
end

function CommandQueue.setMockMode(enabled: boolean)
	mockMode = enabled
end

function CommandQueue.isMockMode(): boolean
	return mockMode
end

function CommandQueue.clearMockData()
	mockDataCache = {}
end

return CommandQueue
