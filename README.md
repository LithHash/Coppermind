# Coppermind

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

## Installation

### Manual

Download the latest release and add the `src` folder to your project.

## Quick Start

```lua
local Coppermind = require(path.to.Coppermind)

-- Define a schema
local PlayerSchema = Coppermind.registerSchema({
    name = "PlayerData",
    dataTemplate = {
        coins = 0,
        gems = 0,
        inventory = {},
        stats = {
            level = 1,
            xp = 0,
        },
    },
    migrations = {},
})

-- Load a player's data
local store = Coppermind.loadStore(PlayerSchema, tostring(player.UserId), {
    sessionLocked = true,
    autoSave = 60,
})

-- Wait for data to be ready
store.onReady:Connect(function()
    local data = Coppermind.getData(PlayerSchema, tostring(player.UserId))
    print("Player has", data.coins, "coins")
end)

-- Update data
Coppermind.updateData(PlayerSchema, tostring(player.UserId), function(data)
    data.coins += 100
    return nil
end)

-- Unload when player leaves
Coppermind.unloadStore(PlayerSchema, tostring(player.UserId))
```

## API Overview

### Schema

| Function | Description |
|----------|-------------|
| `registerSchema(schema)` | Register a new data schema |
| `getSchema(name)` | Retrieve a registered schema |

### Store Management

| Function | Description |
|----------|-------------|
| `loadStore(schema, key, config?)` | Load a data store |
| `saveStore(schema, key)` | Save a store to DataStore |
| `unloadStore(schema, key)` | Save and unload a store |
| `getStore(schema, key)` | Get a store reference |
| `isLoaded(schema, key)` | Check if a store is loaded |

### Data Operations

| Function | Description |
|----------|-------------|
| `getData(schema, key)` | Read current data (immutable) |
| `updateData(schema, key, callback)` | Update data safely |
| `transaction(schema, keyA, keyB, callback)` | Atomic two-store transaction |

### Testing

| Function | Description |
|----------|-------------|
| `setMockMode(enabled)` | Enable/disable mock mode |
| `isMockMode()` | Check if mock mode is enabled |
| `clearMockData()` | Clear all mock data |

### Events

| Event | Description |
|-------|-------------|
| `onLoaded` | Fires when any store loads |
| `onSaved` | Fires when any store saves |
| `onError` | Fires on any store error |
| `onUnloaded` | Fires when any store unloads |

## License

MIT
