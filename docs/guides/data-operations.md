---
sidebar_position: 3
---

# ✏️ Data Operations

This guide covers reading and updating data in Coppermind stores.

---

## 📖 Reading Data

Use `getData` to access the current data:

```lua
local data = Coppermind.getData(PlayerSchema, key)

if data then
    print("Coins:", data.coins)
    print("Level:", data.stats.level)
    print("Inventory:", #data.inventory, "items")
end
```

### Return Values

| Scenario | Returns | Notes |
|:---------|:--------|:------|
| Store is ready | ✅ Frozen data table | |
| Store is loading | ⚠️ `nil` | Warning logged |
| Store is session locked | 🔒 `nil` | Warning logged |
| Store doesn't exist | ❌ `nil` | |

### 🧊 Data Immutability

:::danger Frozen Data
Data returned by `getData` is **frozen** and cannot be modified!
:::

```lua
local data = Coppermind.getData(PlayerSchema, key)

-- ❌ This will error!
data.coins = 100  -- Cannot modify frozen table

-- ✅ Use updateData instead
Coppermind.updateData(PlayerSchema, key, function(data)
    data.coins = 100
    return nil
end)
```

This immutability ensures data integrity and prevents accidental modifications.

---

## ✏️ Updating Data

Use `updateData` to safely modify data:

```lua
local success = Coppermind.updateData(PlayerSchema, key, function(data)
    -- Modify the mutable copy
    data.coins += 100
    return nil
end)

if success then
    print("Data updated!")
end
```

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

<Tabs>
<TabItem value="mutation" label="🔄 Mutation Style" default>

Modify the data directly and return `nil`:

```lua
Coppermind.updateData(PlayerSchema, key, function(data)
    data.coins += 100
    data.gems += 50
    data.stats.xp += 25
    table.insert(data.inventory, "new_item")
    return nil  -- Apply mutations
end)
```

</TabItem>
<TabItem value="replacement" label="🔁 Replacement Style">

Return a new table to replace the entire data:

```lua
Coppermind.updateData(PlayerSchema, key, function(data)
    return {
        coins = data.coins + 100,
        gems = data.gems,
        inventory = data.inventory,
        stats = {
            level = data.stats.level,
            xp = data.stats.xp + 25,
        },
    }
end)
```

</TabItem>
</Tabs>

### ❌ When Updates Fail

`updateData` returns `false` when:

| Reason | Description |
|:-------|:------------|
| Store doesn't exist | Key was never loaded |
| Store is loading | Data not ready yet |
| Store is session locked | Another server owns it |
| Invalid state | Store is unloading/unloaded |
| No data | Store has nil data |

```lua
local success = Coppermind.updateData(PlayerSchema, key, function(data)
    data.coins += 100
    return nil
end)

if not success then
    warn("Failed to update data for", key)
end
```

---

## 🔗 Working with Nested Data

### Reading Nested Values

```lua
local data = Coppermind.getData(PlayerSchema, key)

-- Access nested tables
local level = data.stats.level
local musicVolume = data.settings.audio.musicVolume

-- Safely access potentially nil nested values
local achievementProgress = data.achievements and data.achievements.progress
```

### Updating Nested Values

```lua
Coppermind.updateData(PlayerSchema, key, function(data)
    -- Update nested values
    data.stats.level += 1
    data.stats.xp = 0
    
    -- Modify nested arrays
    table.insert(data.inventory, "reward_item")
    
    -- Update deeply nested values
    data.settings.audio.musicVolume = 0.5
    
    return nil
end)
```

---

## 📦 Working with Arrays

<Tabs>
<TabItem value="add" label="➕ Adding Items" default>

```lua
Coppermind.updateData(PlayerSchema, key, function(data)
    table.insert(data.inventory, "sword")
    table.insert(data.inventory, "shield")
    return nil
end)
```

</TabItem>
<TabItem value="remove" label="➖ Removing Items">

```lua
Coppermind.updateData(PlayerSchema, key, function(data)
    -- Remove by value
    local index = table.find(data.inventory, "old_item")
    if index then
        table.remove(data.inventory, index)
    end
    return nil
end)
```

</TabItem>
<TabItem value="filter" label="🔍 Filtering">

```lua
Coppermind.updateData(PlayerSchema, key, function(data)
    -- Keep only items that aren't expired
    local filtered = {}
    for _, item in data.inventory do
        if not item.expired then
            table.insert(filtered, item)
        end
    end
    data.inventory = filtered
    return nil
end)
```

</TabItem>
</Tabs>

---

## 🎯 Common Patterns

### 💰 Increment/Decrement

```lua
local function addCoins(key: string, amount: number)
    return Coppermind.updateData(PlayerSchema, key, function(data)
        data.coins += amount
        return nil
    end)
end

local function spendCoins(key: string, amount: number): boolean
    local success = false
    
    Coppermind.updateData(PlayerSchema, key, function(data)
        if data.coins >= amount then
            data.coins -= amount
            success = true
        end
        return nil
    end)
    
    return success
end
```

### 🔀 Toggle Values

```lua
local function toggleSetting(key: string, setting: string)
    Coppermind.updateData(PlayerSchema, key, function(data)
        data.settings[setting] = not data.settings[setting]
        return nil
    end)
end
```

### ⬆️ Conditional Updates

```lua
local function levelUp(key: string): boolean
    local leveled = false
    
    Coppermind.updateData(PlayerSchema, key, function(data)
        local xpNeeded = data.stats.level * 100
        
        if data.stats.xp >= xpNeeded then
            data.stats.level += 1
            data.stats.xp -= xpNeeded
            leveled = true
        end
        
        return nil
    end)
    
    return leveled
end
```

### 🎁 Batch Updates

```lua
local function claimRewards(key: string, rewards: { coins: number, items: { string } })
    Coppermind.updateData(PlayerSchema, key, function(data)
        data.coins += rewards.coins
        
        for _, item in rewards.items do
            table.insert(data.inventory, item)
        end
        
        return nil
    end)
end
```

---

## ✅ Best Practices

### 1. Keep Updates Atomic

:::tip Single Update
Do all related changes in a single `updateData` call!
:::

```lua
-- ✅ Good - single atomic update
Coppermind.updateData(PlayerSchema, key, function(data)
    data.coins -= 100
    table.insert(data.inventory, "purchased_item")
    return nil
end)

-- ❌ Avoid - multiple separate updates
Coppermind.updateData(PlayerSchema, key, function(data)
    data.coins -= 100
    return nil
end)
Coppermind.updateData(PlayerSchema, key, function(data)
    table.insert(data.inventory, "purchased_item")
    return nil
end)
```

### 2. Validate Before Writing

```lua
local function purchaseItem(key: string, itemId: string, cost: number): (boolean, string?)
    local result = { success = false, error = nil }
    
    Coppermind.updateData(PlayerSchema, key, function(data)
        if data.coins < cost then
            result.error = "Not enough coins"
            return nil
        end
        
        if table.find(data.inventory, itemId) then
            result.error = "Already owned"
            return nil
        end
        
        data.coins -= cost
        table.insert(data.inventory, itemId)
        result.success = true
        return nil
    end)
    
    return result.success, result.error
end
```

### 3. Handle Missing Data Gracefully

```lua
local function safeGetCoins(key: string): number?
    local data = Coppermind.getData(PlayerSchema, key)
    
    if not data then
        return nil
    end
    
    return data.coins
end
```
