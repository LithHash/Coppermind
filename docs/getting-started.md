---
sidebar_position: 2
---

# Getting Started

This guide will walk you through the basics of Coppermind.

---

## 📦 Installation

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

<Tabs>
<TabItem value="manual" label="Manual">

1. Download the latest release from GitHub
2. Add the `src` folder to your project
3. Require the module in your code

</TabItem>
</Tabs>

---

## 📋 Defining a Schema

Schemas define the structure and default values for your data. Start by registering one:

```lua
local Coppermind = require(path.to.Coppermind)

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
```

### Schema Properties

| Property | Type | Description |
|:---------|:-----|:------------|
| `name` | `string` | Unique identifier for the schema (used as DataStore name) |
| `dataTemplate` | `table` | Default values for new data |
| `migrations` | `{function}` | Array of migration functions for schema evolution |

---

## 📂 Loading a Store

A store represents a single data entry (e.g., one player's data):

```lua
local store = Coppermind.loadStore(PlayerSchema, tostring(player.UserId), {
    sessionLocked = true,  -- Prevent other servers from loading this data
    autoSave = 60,         -- Auto-save every 60 seconds
})
```

### Configuration Options

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `sessionLocked` | `boolean?` | `false` | Lock data to this server session |
| `autoSave` | `number?` | `nil` | Auto-save interval in seconds |

---

## ⏳ Waiting for Data

Stores load asynchronously. Wait for the data to be ready:

```lua
-- Using the onReady event
store.onReady:Connect(function(store)
    print("Data is ready!")
end)

-- Or check the state
if store.state == "READY" then
    -- Data is available
end
```

### Store States

| State | Icon | Description |
|:------|:----:|:------------|
| `LOADING` | 🔄 | Data is being loaded from DataStore |
| `READY` | ✅ | Data is loaded and available |
| `SAVING` | 💾 | Data is being saved |
| `UNLOADING` | 📤 | Store is being unloaded |
| `UNLOADED` | ⬜ | Store has been unloaded |
| `ERROR` | ❌ | An error occurred |
| `SESSION_LOCKED` | 🔒 | Another server has locked this data |

---

## 📖 Reading Data

Use `getData` to read the current data:

```lua
local data = Coppermind.getData(PlayerSchema, tostring(player.UserId))

if data then
    print("Coins:", data.coins)
    print("Level:", data.stats.level)
end
```

:::caution Data is Immutable
The data returned by `getData` is frozen and cannot be modified directly. Use `updateData` to make changes.
:::

---

## ✏️ Updating Data

Use `updateData` to modify data safely:

<Tabs>
<TabItem value="mutation" label="Mutation Style" default>

Modify the data directly and return `nil`:

```lua
Coppermind.updateData(PlayerSchema, tostring(player.UserId), function(data)
    data.coins += 100
    data.stats.xp += 50
    table.insert(data.inventory, "sword")
    return nil  -- Return nil to apply mutations
end)
```

</TabItem>
<TabItem value="replacement" label="Replacement Style">

Return a new data table to replace the entire data:

```lua
Coppermind.updateData(PlayerSchema, tostring(player.UserId), function(data)
    return {
        coins = data.coins + 100,
        gems = data.gems,
        inventory = data.inventory,
        stats = {
            level = data.stats.level,
            xp = data.stats.xp + 50,
        },
    }
end)
```

</TabItem>
</Tabs>

---

## 💾 Saving Data

<Tabs>
<TabItem value="manual" label="Manual Save" default>

```lua
Coppermind.saveStore(PlayerSchema, tostring(player.UserId))
```

</TabItem>
<TabItem value="auto" label="Auto-Save">

Configure auto-save when loading the store:

```lua
local store = Coppermind.loadStore(PlayerSchema, key, {
    autoSave = 60,  -- Save every 60 seconds
})
```

</TabItem>
</Tabs>

---

## 📤 Unloading a Store

:::warning Always Unload
Always unload stores when they're no longer needed to save data and release session locks!
:::

```lua
game.Players.PlayerRemoving:Connect(function(player)
    Coppermind.unloadStore(PlayerSchema, tostring(player.UserId))
end)
```

---

## 📡 Global Events

Coppermind provides global events for monitoring all stores:

```lua
-- Fires when any store is loaded
Coppermind.onLoaded:Connect(function(store)
    print("Store loaded:", store.key)
end)

-- Fires when any store is saved
Coppermind.onSaved:Connect(function(store)
    print("Store saved:", store.key)
end)

-- Fires when any store encounters an error
Coppermind.onError:Connect(function(store, errorMessage)
    warn("Store error:", store.key, errorMessage)
end)

-- Fires when any store is unloaded
Coppermind.onUnloaded:Connect(function(store)
    print("Store unloaded:", store.key)
end)
```

---

## 🎯 Next Steps

<div className="next-steps">

| Guide | Description |
|:------|:------------|
| 📋 [**Schemas**](./guides/schemas) | Data templates and type safety |
| 📂 [**Stores**](./guides/stores) | Session locking and store management |
| ✏️ [**Data Operations**](./guides/data-operations) | Reading and updating data |
| 🔄 [**Migrations**](./guides/migrations) | Evolving your data schema |
| 💱 [**Transactions**](./guides/transactions) | Atomic operations across stores |
| 🧪 [**Testing**](./guides/testing) | Mock mode and testing patterns |

</div>
