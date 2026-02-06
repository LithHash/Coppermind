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
	loadSession: (store: StoreObject<T>, player: Player, entityId: EntityId?, callback: ((EntityId?) -> ())?) -> EntityId?,
	closeSession: (store: StoreObject<T>, player: Player, callback: ((boolean) -> ())?) -> boolean,

	set: <K>(store: StoreObject<T>, player: Player, key: keyof<T>, value: GetPropertyType<T, K>) -> (),
	get: <K>(store: StoreObject<T>, player: Player, key: keyof<T>) -> GetPropertyType<T, K>?,

	update: (store: StoreObject<T>, player: Player, fn: (data: T) -> T) -> (),
}

local AUTO_SAVE_INTERVAL = 2 * 60
local LOCK_TIMEOUT = 5 * 60

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

local function _acquireLock<T>(store: StoreObject<T>, dataKey: string): (boolean, T?)
	if not _meetsBudget(Enum.DataStoreRequestType.UpdateAsync) then
		warn(`[Coppermind] Failed to acquire lock for {dataKey} - budget exhausted`)
		return false, nil
	end

	local serverId = game.JobId
	local data: T? = nil

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
		warn(`[Coppermind] Failed to acquire lock for {dataKey}`)
		return false, nil
	end

	data = result :: T
	return true, data
end

local function _releaseLock<T>(store: StoreObject<T>, dataKey: string, sessionData: T): boolean
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
		warn(`[Coppermind] Failed to release lock for {dataKey}`)
	end

	return success
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
	providedEntityId: EntityId?,
	callback: ((EntityId?) -> ())?
): EntityId?
	local dataKey = `Player_{player.UserId}`

	local function process(data: T): EntityId
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

		return entityId
	end

	if callback then
		task.spawn(function()
			local lockSuccess, data = _acquireLock(store:: any, dataKey)
			if not lockSuccess or not data then
				callback(nil)
				return
			end

			callback(process(data))
		end)

		return nil
	end

	local lockSuccess, data = _acquireLock(store:: any, dataKey)
	if not lockSuccess or not data then
		return nil
	end

	return process(data)
end

local function closeSession<T>(store: StoreObject<T>, player: Player, callback: ((boolean) -> ())?): boolean
	local session = store.sessions[player]
	if not session then
		if callback then
			callback(false)
		end

		return false
	end

	local function release()
		local success = _releaseLock(store:: any, session.dataKey, session.data)
		store.world:destroy(session.entityId)
		store.sessions[player] = nil
		return success
	end

	if callback then
		task.spawn(function()
			callback(release())
		end)

		return true
	end

	return release()
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

	task.spawn(function()
		while true do
			task.wait(AUTO_SAVE_INTERVAL)

			for player, session in self.sessions do
				task.spawn(function()
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
				end)
			end
		end
	end)

	game:BindToClose(function()
		for player, session in self.sessions do
			_releaseLock(self:: any, session.dataKey, session.data)
			self.world:destroy(session.entityId)
		end
	end)

	return self
end

return {
	new = new,
}
