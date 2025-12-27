export type Connection = () -> ()

export type Signal<T...> = {
	Fire: (self: Signal<T...>, T...) -> (),
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
}

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({ _connections = {} }, Signal)
	return self :: any
end

function Signal:Fire(...)
	for _, callback in self._connections do
		task.spawn(callback, ...)
	end
end

function Signal:Connect(callback): Connection
	table.insert(self._connections, callback)

	return function()
		local index = table.find(self._connections, callback)
		if index then
			table.remove(self._connections, index)
		end
	end
end

return Signal