--[=[
	@class Coppermind
	
	A robust, feature-rich data persistence library for Roblox.
	
	## Features
	- 💾 Schema-based data management with templates
	- 🔒 Session locking to prevent data corruption
	- ⏱️ Configurable auto-save intervals
	- 🔄 Data migrations for schema evolution
	- 💱 Atomic transactions between stores
	- 🧪 Mock mode for testing
	- 📡 Event-driven architecture
	- 🧊 Immutable data with deep freeze
	
	```lua
	local Coppermind = require(path.to.Coppermind)
	
	local PlayerSchema = Coppermind.registerSchema({
		name = "PlayerData",
		dataTemplate = {
			coins = 0,
			gems = 0,
		},
		migrations = {},
	})
	
	local store = Coppermind.loadStore(PlayerSchema, tostring(player.UserId), {
		sessionLocked = true,
		autoSave = 60,
	})
	```
]=]

local HttpService = game:GetService("HttpService")

local Signal = require(script.Signal)
local CommandQueue = require(script.CommandQueue)
local Transaction = require(script.Transaction)

--[=[
	@type MigrationFn (data: {[string]: any}) -> ()
	@within Coppermind
	
	A function that transforms data from one version to the next.
]=]
export type MigrationFn = (data: { [string]: any }) -> ()

--[=[
	@interface Schema
	@within Coppermind
	.name string -- Unique identifier for the schema (used as DataStore name)
	.dataTemplate T -- Default values for new data entries
	.migrations {MigrationFn} -- Array of migration functions for schema evolution
]=]
export type Schema<T = { [string]: any }> = {
	name: string,
	dataTemplate: T,
	migrations: { MigrationFn },
}

--[=[
	@interface StoreConfig
	@within Coppermind
	.sessionLocked boolean? -- Whether to lock this data to the current server session
	.autoSave number? -- Auto-save interval in seconds (nil to disable)
]=]
export type StoreConfig<T = { [string]: any }> = {
	sessionLocked: boolean?,
	autoSave: number?,
}

--[=[
	@type StoreState "LOADING" | "READY" | "SAVING" | "UNLOADING" | "UNLOADED" | "ERROR" | "SESSION_LOCKED"
	@within Coppermind
	
	The current state of a store.
	- `LOADING`: Data is being loaded from DataStore
	- `READY`: Data is loaded and available
	- `SAVING`: Data is being saved to DataStore
	- `UNLOADING`: Store is being saved and released
	- `UNLOADED`: Store has been released
	- `ERROR`: An error occurred during load/save
	- `SESSION_LOCKED`: Another server has locked this data
]=]
export type StoreState = "LOADING" | "READY" | "SAVING" | "UNLOADING" | "UNLOADED" | "ERROR" | "SESSION_LOCKED"

--[=[
	@interface Store
	@within Coppermind
	.key string -- The unique key for this store
	.data T? -- The current data (nil while loading)
	.state StoreState -- Current state of the store
	.sessionId string? -- Session lock ID (if session locked)
	.version number -- Data version (for migrations)
	.lastSaved number? -- Timestamp of last successful save
	.onReady Signal -- Fires when store is ready
	.onSaved Signal -- Fires after each successful save
	.onError Signal -- Fires on any error
	.onTransaction Signal -- Fires when a transaction completes
]=]
export type Store<T = { [string]: any }> = {
	key: string,
	data: T?,
	state: StoreState,
	sessionId: string?,
	version: number,
	lastSaved: number?,

	onReady: Signal.Signal<Store<T>>,
	onSaved: Signal.Signal<Store<T>>,
	onError: Signal.Signal<Store<T>, string>,
	onTransaction: Signal.Signal<Store<T>, string>,
}

type InternalStore<T> = Store<T> & {
	schema: Schema<T>,
	config: StoreConfig<T>,
	pendingTxIds: { string },
}

local registeredSchemas: { [string]: Schema<any> } = {}
local trackedStores: { [string]: { [string]: InternalStore<any> } } = {}
local autoSaveThreads: { [string]: thread } = {}

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

local EVENTS = {
	onLoaded = Signal.new() :: Signal.Signal<Store<any>>,
	onSaved = Signal.new() :: Signal.Signal<Store<any>>,
	onError = Signal.new() :: Signal.Signal<Store<any>, string>,
	onUnloaded = Signal.new() :: Signal.Signal<Store<any>>,
}

local saveStore: (schema: Schema<any>, key: string) -> boolean
local processPendingTransactions: (store: InternalStore<any>) -> ()

local function getStoreKey(schemaName: string, key: string): string
	return `{schemaName}:{key}`
end

local function cancelAutoSave(storeKey: string)
	local thread = autoSaveThreads[storeKey]
	if thread then
		pcall(task.cancel, thread)
		autoSaveThreads[storeKey] = nil
	end
end

local function startAutoSave(store: InternalStore<any>, interval: number)
	local storeKey = getStoreKey(store.schema.name, store.key)
	cancelAutoSave(storeKey)

	autoSaveThreads[storeKey] = task.spawn(function()
		while store.state == "READY" do
			task.wait(interval)

			if store.state ~= "READY" then
				break
			end

			saveStore(store.schema, store.key)
		end
	end)
end

local function buildSavedData(store: InternalStore<any>): CommandQueue.SavedData
	return {
		keyData = deepCopy(store.data) :: any,
		version = store.version,
		lockId = store.sessionId,
		lockTime = if store.sessionId then os.time() else nil,
	}
end

--[=[
	Registers a new schema for data storage.
	
	@within Coppermind
	@param schema Schema<T> -- The schema definition
	@return Schema<T> -- The registered schema
	
	```lua
	local PlayerSchema = Coppermind.registerSchema({
		name = "PlayerData",
		dataTemplate = {
			coins = 0,
			gems = 0,
			inventory = {},
		},
		migrations = {},
	})
	```
]=]
local function registerSchema<T>(schema: Schema<T>): Schema<T>
	assert(schema.name, "Schema must have a name")
	assert(schema.dataTemplate, "Schema must have a dataTemplate")

	schema.migrations = schema.migrations or {}
	registeredSchemas[schema.name] = schema
	trackedStores[schema.name] = {}

	return schema
end

--[=[
	Retrieves a registered schema by name.
	
	@within Coppermind
	@param name string -- The schema name
	@return Schema? -- The schema, or nil if not found
]=]
local function getSchema(name: string): Schema<any>?
	return registeredSchemas[name]
end

--[=[
	Gets a reference to a loaded store.
	
	@within Coppermind
	@param schema Schema<T> -- The schema
	@param key string -- The store key
	@return Store<T>? -- The store, or nil if not loaded
]=]
local function getStore<T>(schema: Schema<T>, key: string): Store<T>?
	if not trackedStores[schema.name] then
		return nil
	end
	return trackedStores[schema.name][key] :: any
end

--[=[
	Saves a store's data to the DataStore.
	
	@within Coppermind
	@param schema Schema -- The schema
	@param key string -- The store key
	@return boolean -- Whether the save was queued successfully
]=]
function saveStore(schema: Schema<any>, key: string): boolean
	assert(registeredSchemas[schema.name], `Schema {schema.name} is not registered`)

	local store = trackedStores[schema.name][key]
	if not store then
		warn("Attempt to save a store that is not loaded:", key)
		return false
	end

	if store.state ~= "READY" then
		warn("Attempt to save a store that is not ready:", key, "Current state:", store.state)
		return false
	end

	local storeKey = getStoreKey(schema.name, key)
	cancelAutoSave(storeKey)

	store.state = "SAVING"

	CommandQueue.enqueue({
		commandType = "SAVE",
		key = key,
		schema = schema :: any,
		data = buildSavedData(store),
		sessionId = store.sessionId,
		retries = 3,
		callback = function(success, result, errorType)
			if success then
				store.lastSaved = os.time()
				store.state = "READY"
				store.onSaved:Fire(store :: any)
				EVENTS.onSaved:Fire(store :: any)

				if store.config.autoSave and store.config.autoSave > 0 then
					startAutoSave(store, store.config.autoSave)
				end
			else
				if errorType == "LOCK_LOST" then
					store.state = "SESSION_LOCKED"
					warn("Lost session lock for store:", key)
				else
					store.state = "READY"
				end
				store.onError:Fire(store :: any, result)
				EVENTS.onError:Fire(store :: any, result)

				if store.state == "READY" and store.config.autoSave and store.config.autoSave > 0 then
					startAutoSave(store, store.config.autoSave)
				end
			end
		end,
	})

	return true
end

--[=[
	Loads a store from the DataStore.
	
	@within Coppermind
	@param schema Schema<T> -- The schema to use
	@param key string -- Unique identifier for this data entry
	@param config StoreConfig? -- Optional configuration
	@return Store<T> -- The store object (data loads asynchronously)
	
	```lua
	local store = Coppermind.loadStore(PlayerSchema, tostring(player.UserId), {
		sessionLocked = true,
		autoSave = 60,
	})
	
	store.onReady:Connect(function()
		print("Data loaded!")
	end)
	```
]=]
local function loadStore<T>(schema: Schema<T>, key: string, config: StoreConfig<T>?): Store<T>
	assert(registeredSchemas[schema.name], `Schema {schema.name} is not registered`)

	local existingStore = trackedStores[schema.name][key]
	if existingStore then
		warn("Attempt to load an already loaded store:", key)
		return existingStore :: any
	end

	local storeConfig: StoreConfig<T> = config or {}
	local sessionId = if storeConfig.sessionLocked then HttpService:GenerateGUID(false) else nil

	local store: InternalStore<T> = {
		key = key,
		data = nil,
		state = "LOADING" :: StoreState,
		sessionId = sessionId,
		version = 0,
		lastSaved = nil,
		schema = schema,
		config = storeConfig,
		pendingTxIds = {},
		onReady = Signal.new(),
		onSaved = Signal.new(),
		onError = Signal.new(),
		onTransaction = Signal.new(),
	}

	trackedStores[schema.name][key] = store :: any

	CommandQueue.enqueue({
		commandType = "LOAD",
		key = key,
		schema = schema :: any,
		sessionId = sessionId,
		retries = 3,
		callback = function(success, result: CommandQueue.SavedData?, errorType)
			if success and result then
				store.data = result.keyData :: any
				store.version = result.version
				store.state = "READY"
				
				processPendingTransactions(store :: any)
				
				store.onReady:Fire(store :: any)
				EVENTS.onLoaded:Fire(store :: any)

				if storeConfig.autoSave and storeConfig.autoSave > 0 then
					startAutoSave(store :: any, storeConfig.autoSave)
				end
			else
				if errorType == "SESSION_LOCKED" then
					store.state = "SESSION_LOCKED"
					warn("Failed to load store - session locked by another server:", key)
				else
					store.state = "ERROR"
				end
				store.onError:Fire(store :: any, result :: any or "Unknown error")
				EVENTS.onError:Fire(store :: any, result :: any or "Unknown error")
			end
		end,
	})

	return store :: any
end

--[=[
	Unloads a store, saving its data and releasing any session lock.
	
	@within Coppermind
	@param schema Schema<T> -- The schema
	@param key string -- The store key
	@return boolean -- Whether the unload was queued successfully
	
	```lua
	game.Players.PlayerRemoving:Connect(function(player)
		Coppermind.unloadStore(PlayerSchema, tostring(player.UserId))
	end)
	```
]=]
local function unloadStore<T>(schema: Schema<T>, key: string): boolean
	assert(registeredSchemas[schema.name], `Schema {schema.name} is not registered`)

	local store = trackedStores[schema.name][key]
	if not store then
		warn("Attempt to unload a store that is not loaded:", key)
		return false
	end

	if store.state == "UNLOADING" or store.state == "UNLOADED" then
		warn("Store is already unloading or unloaded:", key)
		return false
	end

	local storeKey = getStoreKey(schema.name, key)
	cancelAutoSave(storeKey)

	store.state = "UNLOADING"

	CommandQueue.enqueue({
		commandType = "UNLOAD",
		key = key,
		schema = schema :: any,
		data = buildSavedData(store),
		sessionId = store.sessionId,
		retries = 3,
		callback = function(success, result, _errorType)
			if success then
				store.state = "UNLOADED"
				trackedStores[schema.name][key] = nil
				EVENTS.onUnloaded:Fire(store :: any)
			else
				store.state = "ERROR"
				store.onError:Fire(store :: any, result)
				EVENTS.onError:Fire(store :: any, result)
			end
		end,
	})

	return true
end

--[=[
	Checks if a store is currently loaded.
	
	@within Coppermind
	@param schema Schema<T> -- The schema
	@param key string -- The store key
	@return boolean -- Whether the store is loaded
]=]
local function isLoaded<T>(schema: Schema<T>, key: string): boolean
	local store = trackedStores[schema.name] and trackedStores[schema.name][key]
	return store ~= nil and store.state ~= "UNLOADED"
end

--[=[
	Gets the current data for a store.
	
	:::caution Data is Immutable
	The returned data is frozen and cannot be modified directly.
	Use `updateData` to make changes.
	:::
	
	@within Coppermind
	@param schema Schema<T> -- The schema
	@param key string -- The store key
	@return T? -- The data, or nil if not available
]=]
local function getData<T>(schema: Schema<T>, key: string): T?
	local store = trackedStores[schema.name] and trackedStores[schema.name][key]

	if not store then
		return nil
	end

	if store.state == "LOADING" then
		warn("getData called while store is still loading:", key)
		return nil
	end

	if store.state == "SESSION_LOCKED" then
		warn("getData called on session-locked store:", key)
		return nil
	end

	if store.state == "READY" or store.state == "SAVING" then
		return store.data :: any
	end

	return nil
end

--[=[
	Updates a store's data safely.
	
	The callback receives a mutable copy of the data. Either mutate it directly
	and return nil, or return a new table to replace the data entirely.
	
	@within Coppermind
	@param schema Schema<T> -- The schema
	@param key string -- The store key
	@param callback (data: T) -> T? -- The update function
	@return boolean -- Whether the update was successful
	
	```lua
	-- Mutation style
	Coppermind.updateData(PlayerSchema, key, function(data)
		data.coins += 100
		return nil
	end)
	
	-- Replacement style
	Coppermind.updateData(PlayerSchema, key, function(data)
		return { coins = data.coins + 100, gems = data.gems }
	end)
	```
]=]
local function updateData<T>(schema: Schema<T>, key: string, callback: (data: T) -> T?): boolean
	local store = trackedStores[schema.name] and trackedStores[schema.name][key]

	if not store then
		warn("Attempt to update data for a store that is not loaded:", key)
		return false
	end

	if store.state == "LOADING" then
		warn("Attempt to update data before store is ready:", key, "- state is LOADING")
		return false
	end

	if store.state == "SESSION_LOCKED" then
		warn("Attempt to update data on session-locked store:", key)
		return false
	end

	if store.state ~= "READY" and store.state ~= "SAVING" then
		warn("Attempt to update data for store in invalid state:", key, "- state is", store.state)
		return false
	end

	if not store.data then
		warn("Attempt to update data but store has no data:", key)
		return false
	end

	local mutableCopy = deepCopy(store.data)
	local result = callback(mutableCopy :: any)

	if result ~= nil then
		store.data = deepFreeze(result) :: any
	else
		store.data = deepFreeze(mutableCopy) :: any
	end

	return true
end

--[=[
	Enables or disables mock mode for testing.
	
	In mock mode, data is stored in memory instead of DataStores.
	
	@within Coppermind
	@param enabled boolean -- Whether to enable mock mode
]=]
local function setMockMode(enabled: boolean)
	CommandQueue.setMockMode(enabled)
	Transaction.setMockMode(enabled)
end

--[=[
	Checks if mock mode is currently enabled.
	
	@within Coppermind
	@return boolean -- Whether mock mode is enabled
]=]
local function isMockMode(): boolean
	return CommandQueue.isMockMode()
end

--[=[
	Clears all mock data. Use between tests.
	
	@within Coppermind
]=]
local function clearMockData()
	CommandQueue.clearMockData()
	Transaction.clearMockData()
end

function processPendingTransactions(store: InternalStore<any>)
	if not store.pendingTxIds or #store.pendingTxIds == 0 then
		return
	end

	local toRemove: { string } = {}

	for _, txId in store.pendingTxIds do
		local escrow = Transaction.getEscrow(txId)

		if not escrow then
			table.insert(toRemove, txId)
			continue
		end

		local party = escrow.parties[store.key]
		if not party then
			table.insert(toRemove, txId)
			continue
		end

		if escrow.status == "complete" and not party.claimed then
			store.data = deepFreeze(deepCopy(party.afterData)) :: any
			Transaction.markClaimed(txId, store.key)
			store.onTransaction:Fire(store :: any, txId)
			table.insert(toRemove, txId)
		elseif escrow.status == "refunded" or Transaction.isExpired(escrow) then
			if party.deposited and not party.claimed then
				store.data = deepFreeze(deepCopy(party.beforeData)) :: any
				Transaction.markClaimed(txId, store.key)
			end
			table.insert(toRemove, txId)
		end
	end

	for _, txId in toRemove do
		store.pendingTxIds = Transaction.removePendingTx(store.pendingTxIds, txId)
	end
end

--[=[
	Executes an atomic transaction between two stores.
	
	Either both stores are updated, or neither is (rollback on failure).
	
	@within Coppermind
	@param schema Schema<T> -- The schema (both stores must use the same schema)
	@param keyA string -- First store key
	@param keyB string -- Second store key
	@param callback (dataA: T, dataB: T) -> (boolean?, string?) -- Transaction function
	@return boolean -- Whether the transaction succeeded
	@return string? -- Transaction ID on success, or error message on failure
	
	```lua
	local success, result = Coppermind.transaction(
		PlayerSchema,
		sellerKey,
		buyerKey,
		function(sellerData, buyerData)
			if buyerData.coins < 100 then
				return false, "Not enough coins"
			end
			
			sellerData.coins += 100
			buyerData.coins -= 100
			return true
		end
	)
	```
]=]
local function transaction<T>(
	schema: Schema<T>,
	keyA: string,
	keyB: string,
	callback: (dataA: T, dataB: T) -> (boolean?, string?)
): (boolean, string?)
	assert(registeredSchemas[schema.name], `Schema {schema.name} is not registered`)

	local storeA = trackedStores[schema.name] and trackedStores[schema.name][keyA]
	local storeB = trackedStores[schema.name] and trackedStores[schema.name][keyB]

	if not storeA then
		return false, `Store not loaded: {keyA}`
	end

	if not storeB then
		return false, `Store not loaded: {keyB}`
	end

	if storeA.state ~= "READY" and storeA.state ~= "SAVING" then
		return false, `Store {keyA} is not ready (state: {storeA.state})`
	end

	if storeB.state ~= "READY" and storeB.state ~= "SAVING" then
		return false, `Store {keyB} is not ready (state: {storeB.state})`
	end

	if not storeA.data or not storeB.data then
		return false, "One or both stores have no data"
	end

	local beforeA = deepCopy(storeA.data)
	local beforeB = deepCopy(storeB.data)
	local afterA = deepCopy(storeA.data)
	local afterB = deepCopy(storeB.data)

	local success, errorMsg = callback(afterA :: any, afterB :: any)

	if success == false then
		return false, errorMsg or "Transaction aborted by callback"
	end

	local aChanged = HttpService:JSONEncode(beforeA) ~= HttpService:JSONEncode(afterA)
	local bChanged = HttpService:JSONEncode(beforeB) ~= HttpService:JSONEncode(afterB)

	if not aChanged and not bChanged then
		return true, nil
	end

	storeA.data = deepFreeze(afterA) :: any
	storeB.data = deepFreeze(afterB) :: any

	local escrowSuccess, txId, _escrow = Transaction.createEscrow(
		schema.name,
		keyA,
		keyB,
		beforeA :: any,
		afterA :: any,
		beforeB :: any,
		afterB :: any
	)

	if not escrowSuccess or not txId then
		storeA.data = deepFreeze(beforeA) :: any
		storeB.data = deepFreeze(beforeB) :: any
		return false, "Failed to create transaction escrow"
	end

	storeA.pendingTxIds = Transaction.addPendingTx(storeA.pendingTxIds, txId)
	storeB.pendingTxIds = Transaction.addPendingTx(storeB.pendingTxIds, txId)

	local depositA = Transaction.deposit(txId, keyA)
	local depositB = Transaction.deposit(txId, keyB)

	if not depositA or not depositB then
		storeA.data = deepFreeze(beforeA) :: any
		storeB.data = deepFreeze(beforeB) :: any
		Transaction.refund(txId)
		return false, "Failed to complete transaction deposit"
	end

	Transaction.markClaimed(txId, keyA)
	Transaction.markClaimed(txId, keyB)

	storeA.pendingTxIds = Transaction.removePendingTx(storeA.pendingTxIds, txId)
	storeB.pendingTxIds = Transaction.removePendingTx(storeB.pendingTxIds, txId)

	storeA.onTransaction:Fire(storeA :: any, txId)
	storeB.onTransaction:Fire(storeB :: any, txId)

	return true, txId
end

--[=[
	Gets the number of pending transactions for a store.
	
	@within Coppermind
	@param schema Schema<T> -- The schema
	@param key string -- The store key
	@return number -- Number of pending transactions
]=]
local function getPendingTransactionCount<T>(schema: Schema<T>, key: string): number
	local store = trackedStores[schema.name] and trackedStores[schema.name][key]
	if not store then
		return 0
	end

	return #store.pendingTxIds
end

--[=[
	@prop onLoaded Signal<Store>
	@within Coppermind
	
	Fires when any store finishes loading.
]=]

--[=[
	@prop onSaved Signal<Store>
	@within Coppermind
	
	Fires when any store is saved.
]=]

--[=[
	@prop onError Signal<Store, string>
	@within Coppermind
	
	Fires when any store encounters an error.
]=]

--[=[
	@prop onUnloaded Signal<Store>
	@within Coppermind
	
	Fires when any store is unloaded.
]=]

return {
	registerSchema = registerSchema,
	getSchema = getSchema,

	loadStore = loadStore,
	saveStore = saveStore,
	unloadStore = unloadStore,
	getStore = getStore,
	isLoaded = isLoaded,

	getData = getData,
	updateData = updateData,
	transaction = transaction,
	getPendingTransactionCount = getPendingTransactionCount,

	setMockMode = setMockMode,
	isMockMode = isMockMode,
	clearMockData = clearMockData,

	onLoaded = EVENTS.onLoaded,
	onSaved = EVENTS.onSaved,
	onError = EVENTS.onError,
	onUnloaded = EVENTS.onUnloaded,
}