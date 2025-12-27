---
sidebar_position: 1
---

# Coppermind

<div className="hero-banner">

**A robust, feature-rich data persistence library for Roblox.**

</div>

---

## ✨ Features

<div className="feature-grid">

| Feature | Description |
|:--------|:------------|
| 💾 **Schema-Based** | Define data structure with templates and automatic reconciliation |
| 🔒 **Session Locking** | Prevent data corruption across multiple servers |
| ⏱️ **Auto-Save** | Configurable automatic saving intervals |
| 🔄 **Migrations** | Evolve your data schema without losing player data |
| 💱 **Transactions** | Atomic operations across two stores with rollback |
| 🧪 **Mock Mode** | Test without hitting real DataStores |
| 📡 **Event-Driven** | React to load, save, error, and unload events |
| 🧊 **Immutable Data** | Deep freeze prevents accidental modifications |

</div>

---

## 🚀 Quick Example

```lua
local Coppermind = require(path.to.Coppermind)

-- 📋 Define a schema
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

-- 📂 Load a player's data
local store = Coppermind.loadStore(PlayerSchema, tostring(player.UserId), {
    sessionLocked = true,
    autoSave = 60,
})

-- ✅ Wait for data to be ready
store.onReady:Connect(function()
    local data = Coppermind.getData(PlayerSchema, tostring(player.UserId))
    print("Player has", data.coins, "coins")
end)

-- ✏️ Update data safely
Coppermind.updateData(PlayerSchema, tostring(player.UserId), function(data)
    data.coins += 100
    return nil
end)
```

---

## 📚 What's Next?

<div className="card-container">

| Guide | Description |
|:------|:------------|
| [**Getting Started**](./getting-started) | Learn the basics and set up your first schema |
| [**Schemas**](./guides/schemas) | Deep dive into data templates and type safety |
| [**Stores**](./guides/stores) | Master store lifecycle and session locking |
| [**Transactions**](./guides/transactions) | Implement safe trading and transfers |

</div>

