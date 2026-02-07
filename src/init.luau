--!strict
local DataStoreService = game:GetService("DataStoreService")

type function GetPropertyType(tbl, key)
	local actualKey = key
	if key:is("intersection") then
		for _, comp in key:components() do
			if comp:is("singleton") then
				actualKey = comp
				break
			end
		end
	end

	if not tbl:is("table") then
		return types.any
	end

	if not actualKey:is("singleton") then
		return types.any
	end

	local property = tbl:readproperty(actualKey)
	if not property then
		return types.any
	end

	return property
end

type World = any
type EntityId = number
type ComponentId = number

export type Promise<T> = {
	andThen: (self: Promise<T>, onResolved: (value: T) -> (), onRejected: ((error: string) -> ())?) -> Promise<T>,
	catch: (self: Promise<T>, onRejected: (error: string) -> ()) -> Promise<T>,
	await: (self: Promise<T>) -> (boolean, T | string),
}

export type Session<T> = {
	entityId: EntityId,
	data: T,
	lastSyncTime: number,
	dataKey: string,
}

export type StoreObject<T> = {
	world: World,
	sessions: {[Player]: Session<T>},
	dataTemplate: T,
	dataStore: DataStore,
	componentMap: {[ComponentId]: string},

	mapComponents: (store: StoreObject<T>, components: {[string]: ComponentId}) -> (),
	loadSession: (store: StoreObject<T>, player: Player, entityId: EntityId?) -> Promise<EntityId>,
	closeSession: (store: StoreObject<T>, player: Player) -> Promise<boolean>,

	set: <K>(store: StoreObject<T>, player: Player, key: keyof<T>, value: GetPropertyType<T, K>) -> (),
	get: <K>(store: StoreObject<T>, player: Player, key: keyof<T>) -> GetPropertyType<T, K>?,

	update: (store: StoreObject<T>, player: Player, fn: (data: T) -> T) -> (),
}

local AUTO_SAVE_INTERVAL = 2 * 60
local LOCK_TIMEOUT = 5 * 60

local function promise<T>(executor: (resolve: (value: T) -> (), reject: (error: string) -> ()) -> ()): Promise<T>
	local status = "pending"
	local value: T | string
	local callbacks: {{onResolved: ((T) -> ())?, onRejected: ((string) -> ())?}} = {}

	local function resolve(val: T)
		if status ~= "pending" then return end
		status = "resolved"
		value = val

		for _, callback in callbacks do
			if callback.onResolved then
				coroutine.wrap(callback.onResolved)(val)
			end
		end
		table.clear(callbacks)
	end

	local function reject(err: string)
		if status ~= "pending" then return end
		status = "rejected"
		value = err

		for _, callback in callbacks do
			if callback.onRejected then
				coroutine.wrap(callback.onRejected)(err)
			end
		end
		table.clear(callbacks)
	end

	local self = {} :: Promise<T>

	function self:andThen(onResolved: (value: T) -> (), onRejected: ((error: string) -> ())?)
		if status == "resolved" then
			coroutine.wrap(onResolved)(value :: T)
		elseif status == "rejected" and onRejected then
			coroutine.wrap(onRejected)(value :: string)
		elseif status == "pending" then
			table.insert(callbacks, {onResolved = onResolved, onRejected = onRejected})
		end
		return self
	end

	function self:catch(onRejected: (error: string) -> ())
		if status == "rejected" then
			coroutine.wrap(onRejected)(value :: string)
		elseif status == "pending" then
			table.insert(callbacks:: any, {onRejected = onRejected})
		end
		return self
	end

	function self:await(): (boolean, T | string)
		if status == "resolved" then
			return true, value :: T
		elseif status == "rejected" then
			return false, value :: string
		end

		local thread = coroutine.running()
		self:andThen(
			function(val)
				coroutine.resume(thread, true, val)
			end,
			function(err)
				coroutine.resume(thread, false, err)
			end
		)
		return coroutine.yield()
	end

	coroutine.wrap(function()
		local success, err = pcall(executor, resolve, reject)
		if not success then
			reject(tostring(err))
		end
	end)()

	return self
end

local function _meetsBudget(requestType: Enum.DataStoreRequestType): boolean
	return DataStoreService:GetRequestBudgetForRequestType(requestType) >= 1
end

local function _syncComponentToData<T>(store: StoreObject<T>, session: Session<T>, key: string)
	for componentId, saveKey in store.componentMap do
		if saveKey ~= key then
			continue
		end

		store.world:assign(session.entityId, componentId, (session.data :: any)[key])
		break
	end
end

local function _acquireLock<T>(store: StoreObject<T>, dataKey: string): Promise<T>
	return promise(function(resolve, reject)
		if not _meetsBudget(Enum.DataStoreRequestType.UpdateAsync) then
			reject(`Failed to acquire lock for {dataKey} - budget exhausted`)
			return
		end

		local serverId = game.JobId

		local success, result = pcall(function()
			return store.dataStore:UpdateAsync(dataKey, function(old: any): any
				local current = old or table.clone(store.dataTemplate :: any)

				local lock = current._lock
				if lock and lock.server ~= serverId and os.time() - lock.time < LOCK_TIMEOUT then
					return nil
				end

				current._lock = {server = serverId, time = os.time()}
				return current
			end)
		end)

		if not success or not result then
			reject(`Failed to acquire lock for {dataKey}`)
			return
		end

		resolve(result :: T)
	end)
end

local function _releaseLock<T>(store: StoreObject<T>, dataKey: string, sessionData: T): Promise<boolean>
	return promise(function(resolve, reject)
		local success = pcall(function()
			store.dataStore:UpdateAsync(dataKey, function(old: any): any
				old = old or {}

				for k, v in sessionData :: any do
					old[k] = v
				end

				old._lock = nil
				return old
			end)
		end)

		if not success then
			reject(`Failed to release lock for {dataKey}`)
			return
		end

		resolve(true)
	end)
end

local function mapComponents<T>(store: StoreObject<T>, components: {[string]: ComponentId})
	for name, componentId in components do
		if (store.dataTemplate :: any)[name] ~= nil then
			store.componentMap[componentId] = name
		end
	end
end

local function set<T, K>(store: StoreObject<T>, player: Player, key: K, value: any)
	local session = store.sessions[player]
	if not session then
		return
	end

	(session.data :: any)[key] = value
	_syncComponentToData(store:: any, session, tostring(key))
end

local function get<T, K>(store: StoreObject<T>, player: Player, key: K): any?
	local session = store.sessions[player]
	if not session then
		return nil
	end

	return (session.data :: any)[key]
end

local function update<T>(store: StoreObject<T>, player: Player, fn: (data: T) -> T)
	local session = store.sessions[player]
	if not session then
		return
	end

	local oldData = table.clone(session.data :: any)
	session.data = fn(session.data)

	for componentId, saveKey in store.componentMap do
		local oldValue = oldData[saveKey]
		local newValue = (session.data :: any)[saveKey]

		if oldValue ~= newValue then
			store.world:assign(session.entityId, componentId, newValue)
		end
	end
end

local function loadSession<T>(
	store: StoreObject<T>,
	player: Player,
	providedEntityId: EntityId?
): Promise<EntityId>
	return promise(function(resolve, reject)
		local dataKey = `Player_{player.UserId}`

		_acquireLock(store:: any, dataKey):andThen(function(data: T)
			local sessionData: T = table.clone(data :: any);
			(sessionData :: any)._lock = nil

			local entityId = providedEntityId
			if not entityId then
				local entity = store.world:entity()
				entityId = entity.id
			end

			for componentId, saveKey in store.componentMap do
				if (sessionData :: any)[saveKey] ~= nil then
					store.world:assign(entityId, componentId, (sessionData :: any)[saveKey])
				end
			end

			store.sessions[player] = {
				entityId = entityId,
				data = sessionData,
				lastSyncTime = os.time(),
				dataKey = dataKey,
			}

			resolve(entityId)
		end, reject)
	end)
end

local function closeSession<T>(store: StoreObject<T>, player: Player): Promise<boolean>
	return promise(function(resolve, reject)
		local session = store.sessions[player]
		if not session then
			reject("No session found for player")
			return
		end

		_releaseLock(store:: any, session.dataKey, session.data):andThen(function()
			store.world:destroy(session.entityId)
			store.sessions[player] = nil
			resolve(true)
		end, reject)
	end)
end

local function new<T>(world: World, storeName: string, dataTemplate: T): StoreObject<T>
	local self = {
		world = world,
		sessions = {},
		dataTemplate = dataTemplate,
		dataStore = DataStoreService:GetDataStore(storeName),
		componentMap = {},
		mapComponents = mapComponents,
		loadSession = loadSession,
		closeSession = closeSession,
		set = set :: any,
		get = get :: any,
		update = update,
	}:: StoreObject<T>

	coroutine.wrap(function()
		while true do
			task.wait(AUTO_SAVE_INTERVAL)

			for player, session in self.sessions do
				coroutine.wrap(function()
					if not self.sessions[player] then
						return
					end

					pcall(function()
						self.dataStore:UpdateAsync(session.dataKey, function(old: any): any
							old = old or {}
							for k, v in session.data :: any do
								old[k] = v
							end
							old._lock = {server = game.JobId, time = os.time()}
							return old
						end)

						session.lastSyncTime = os.time()
					end)
				end)()
			end
		end
	end)()

	game:BindToClose(function()
		local threads = {}

		for player, session in self.sessions do
			local thread = coroutine.create(function()
				local success = _releaseLock(self:: any, session.dataKey, session.data):await()
				if success then
					self.world:destroy(session.entityId)
				end
			end)

			table.insert(threads, thread)
			coroutine.resume(thread)
		end

		for _, thread in threads do
			while coroutine.status(thread) ~= "dead" do
				task.wait()
			end
		end
	end)

	return self
end

return {
	new = new,
	Promise = promise,
}
