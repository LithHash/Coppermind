local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

export type TransactionStatus = "pending" | "deposited" | "complete" | "refunded" | "expired"

export type PartyData = {
	key: string,
	beforeData: { [string]: any },
	afterData: { [string]: any },
	deposited: boolean,
	claimed: boolean,
}

export type EscrowData = {
	id: string,
	schemaName: string,
	status: TransactionStatus,
	createdAt: number,
	expiresAt: number,
	parties: { [string]: PartyData },
}

local ESCROW_STORE_NAME = "Coppermind_Escrow"
local ESCROW_TIMEOUT = 300
local MAX_PENDING_PER_PLAYER = 50

local escrowDataStore: DataStore? = nil
local mockEscrowCache: { [string]: EscrowData } = {}
local mockMode = false

local Transaction = {}

local function getEscrowStore(): DataStore
	if not escrowDataStore then
		escrowDataStore = DataStoreService:GetDataStore(ESCROW_STORE_NAME)
	end
	return escrowDataStore :: DataStore
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

local function _computeDelta(before: { [string]: any }, after: { [string]: any }): { [string]: any }
	local delta = {}

	local function compareTable(b: any, a: any, path: { string })
		if type(b) ~= "table" or type(a) ~= "table" then
			if b ~= a then
				local key = table.concat(path, ".")
				delta[key] = { from = b, to = a }
			end
			return
		end

		for k, v in a do
			local newPath = table.clone(path)
			table.insert(newPath, tostring(k))
			compareTable(b[k], v, newPath)
		end

		for k, v in b do
			if a[k] == nil then
				local newPath = table.clone(path)
				table.insert(newPath, tostring(k))
				delta[table.concat(newPath, ".")] = { from = v, to = nil }
			end
		end
	end

	compareTable(before, after, {})
	return delta
end

local function _applyDelta(data: { [string]: any }, party: PartyData): { [string]: any }
	return deepCopy(party.afterData)
end

local function _revertDelta(data: { [string]: any }, party: PartyData): { [string]: any }
	return deepCopy(party.beforeData)
end

local function generateTransactionId(): string
	return HttpService:GenerateGUID(false)
end

function Transaction.createEscrow(
	schemaName: string,
	keyA: string,
	keyB: string,
	beforeA: { [string]: any },
	afterA: { [string]: any },
	beforeB: { [string]: any },
	afterB: { [string]: any }
): (boolean, string?, EscrowData?)
	local txId = generateTransactionId()
	local now = os.time()

	local escrow: EscrowData = {
		id = txId,
		schemaName = schemaName,
		status = "pending",
		createdAt = now,
		expiresAt = now + ESCROW_TIMEOUT,
		parties = {
			[keyA] = {
				key = keyA,
				beforeData = deepCopy(beforeA),
				afterData = deepCopy(afterA),
				deposited = false,
				claimed = false,
			},
			[keyB] = {
				key = keyB,
				beforeData = deepCopy(beforeB),
				afterData = deepCopy(afterB),
				deposited = false,
				claimed = false,
			},
		},
	}

	if mockMode then
		mockEscrowCache[txId] = escrow
		return true, txId, escrow
	end

	local success, result = pcall(function()
		return getEscrowStore():UpdateAsync(txId, function(oldData)
			if oldData then
				return nil
			end

			return escrow
		end)
	end)

	if success and result then
		return true, txId, result :: EscrowData
	else
		warn("[Coppermind] Failed to create escrow:", result)
		return false, nil, nil
	end
end

function Transaction.deposit(txId: string, playerKey: string): (boolean, EscrowData?)
	if mockMode then
		local escrow = mockEscrowCache[txId]
		if not escrow then
			return false, nil
		end

		local party = escrow.parties[playerKey]
		if not party then
			return false, nil
		end

		party.deposited = true

		local allDeposited = true
		for _, p in escrow.parties do
			if not p.deposited then
				allDeposited = false
				break
			end
		end

		if allDeposited then
			escrow.status = "complete"
		else
			escrow.status = "deposited"
		end

		return true, escrow
	end

	local maxRetries = 3
	local retryDelay = 0.5
	
	for attempt = 1, maxRetries do
		local success, result = pcall(function()
			return getEscrowStore():UpdateAsync(txId, function(oldData: EscrowData?)
				if not oldData then
					return nil
				end

				local party = oldData.parties[playerKey]
				if not party then
					return nil
				end

				party.deposited = true

				local allDeposited = true
				for _, p in oldData.parties do
					if not p.deposited then
						allDeposited = false
						break
					end
				end

				if allDeposited then
					oldData.status = "complete"
				else
					oldData.status = "deposited"
				end

				return oldData
			end)
		end)

		if success and result then
			return true, result :: EscrowData
		end
		
		if attempt < maxRetries then
			task.wait(retryDelay)
			retryDelay *= 2
		end
	end
	
	warn("[Coppermind] Failed to deposit after", maxRetries, "attempts for tx:", txId)
	return false, nil
end

function Transaction.getEscrow(txId: string): EscrowData?
	if mockMode then
		return mockEscrowCache[txId]
	end

	local success, result = pcall(function()
		return getEscrowStore():GetAsync(txId)
	end)

	if success then
		return result :: EscrowData?
	end

	return nil
end

function Transaction.markClaimed(txId: string, playerKey: string): boolean
	if mockMode then
		local escrow = mockEscrowCache[txId]
		if escrow and escrow.parties[playerKey] then
			escrow.parties[playerKey].claimed = true

			local allClaimed = true
			for _, p in escrow.parties do
				if not p.claimed then
					allClaimed = false
					break
				end
			end

			if allClaimed then
				mockEscrowCache[txId] = nil
			end
			return true
		end

		return false
	end

	local success = pcall(function()
		getEscrowStore():UpdateAsync(txId, function(oldData: EscrowData?)
			if not oldData then
				return nil
			end

			if oldData.parties[playerKey] then
				oldData.parties[playerKey].claimed = true
			end

			local allClaimed = true
			for _, p in oldData.parties do
				if not p.claimed then
					allClaimed = false
					break
				end
			end

			if allClaimed then
				return nil
			end

			return oldData
		end)
	end)

	return success
end

function Transaction.refund(txId: string): boolean
	if mockMode then
		local escrow = mockEscrowCache[txId]
		if escrow then
			escrow.status = "refunded"
			return true
		end

		return false
	end

	local success = pcall(function()
		getEscrowStore():UpdateAsync(txId, function(oldData: EscrowData?)
			if oldData then
				oldData.status = "refunded"
			end

			return oldData
		end)
	end)

	return success
end

function Transaction.isExpired(escrow: EscrowData): boolean
	return os.time() > escrow.expiresAt
end

function Transaction.addPendingTx(
	pendingList: { string }?,
	txId: string
): { string }
	local list = pendingList or {}

	while #list >= MAX_PENDING_PER_PLAYER do
		table.remove(list, 1)
	end

	table.insert(list, txId)
	return list
end

function Transaction.removePendingTx(
	pendingList: { string }?,
	txId: string
): { string }
	if not pendingList then
		return {}
	end

	local newList = {}
	for _, id in pendingList do
		if id ~= txId then
			table.insert(newList, id)
		end
	end

	return newList
end

function Transaction.setMockMode(enabled: boolean)
	mockMode = enabled
end

function Transaction.isMockMode(): boolean
	return mockMode
end

function Transaction.clearMockData()
	mockEscrowCache = {}
end

function Transaction.getMockEscrows(): { [string]: EscrowData }
	return mockEscrowCache
end

return Transaction
