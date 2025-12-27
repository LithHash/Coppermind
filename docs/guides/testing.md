---
sidebar_position: 6
---

# 🧪 Testing

Coppermind provides a mock mode for testing your data logic without hitting real DataStores.

---

## ⚡ Enabling Mock Mode

```lua
-- Enable mock mode
Coppermind.setMockMode(true)

-- Check if mock mode is enabled
if Coppermind.isMockMode() then
    print("Running in mock mode")
end

-- Disable mock mode
Coppermind.setMockMode(false)
```

---

## 🔮 Mock Mode Behavior

:::info What Mock Mode Does
In mock mode, all data operations are simulated in memory!
:::

| Feature | Behavior |
|:--------|:---------|
| 💾 Storage | Data stored in memory |
| ⚡ Speed | Operations complete nearly instantly |
| 📊 Rate Limits | No rate limiting or budget concerns |
| 🔒 Session Locking | Still works (simulated) |
| 🎯 Use Cases | Unit tests & local development |

---

## 🗑️ Clearing Mock Data

Reset all mock data between tests:

```lua
Coppermind.clearMockData()
```

This clears:
- ✅ All stored mock data
- ✅ All mock escrow/transaction data

---

## 🧪 Testing Patterns

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

### 🏗️ Basic Test Setup

```lua
local function runTests()
    -- Enable mock mode
    Coppermind.setMockMode(true)
    Coppermind.clearMockData()
    
    -- Run tests...
    testDataOperations()
    testTransactions()
    testMigrations()
    
    -- Cleanup
    Coppermind.setMockMode(false)
end
```

---

<Tabs>
<TabItem value="data-ops" label="📝 Data Operations" default>

```lua
local function testDataOperations()
    local testKey = "test_player"
    
    -- Load store
    local store = Coppermind.loadStore(PlayerSchema, testKey, {})
    task.wait(0.2)  -- Wait for async load
    
    -- Verify initial data
    local data = Coppermind.getData(PlayerSchema, testKey)
    assert(data.coins == 0, "Initial coins should be 0")
    
    -- Test update
    Coppermind.updateData(PlayerSchema, testKey, function(d)
        d.coins = 100
        return nil
    end)
    
    data = Coppermind.getData(PlayerSchema, testKey)
    assert(data.coins == 100, "Coins should be 100 after update")
    
    -- Cleanup
    Coppermind.unloadStore(PlayerSchema, testKey)
    task.wait(0.1)
    
    print("✓ Data operations test passed")
end
```

</TabItem>
<TabItem value="persistence" label="💾 Persistence">

```lua
local function testPersistence()
    local testKey = "persistence_test"
    
    -- First session: save data
    local store1 = Coppermind.loadStore(PlayerSchema, testKey, {})
    task.wait(0.2)
    
    Coppermind.updateData(PlayerSchema, testKey, function(data)
        data.coins = 500
        return nil
    end)
    
    Coppermind.saveStore(PlayerSchema, testKey)
    task.wait(0.2)
    Coppermind.unloadStore(PlayerSchema, testKey)
    task.wait(0.2)
    
    -- Second session: verify data persisted
    local store2 = Coppermind.loadStore(PlayerSchema, testKey, {})
    task.wait(0.2)
    
    local data = Coppermind.getData(PlayerSchema, testKey)
    assert(data.coins == 500, "Coins should persist after reload")
    
    Coppermind.unloadStore(PlayerSchema, testKey)
    task.wait(0.1)
    
    print("✓ Persistence test passed")
end
```

</TabItem>
<TabItem value="transactions" label="🔐 Transactions">

```lua
local function testTransactions()
    local keyA = "player_a"
    local keyB = "player_b"
    
    -- Setup both stores
    Coppermind.loadStore(PlayerSchema, keyA, {})
    Coppermind.loadStore(PlayerSchema, keyB, {})
    task.wait(0.2)
    
    -- Give player A some coins
    Coppermind.updateData(PlayerSchema, keyA, function(data)
        data.coins = 1000
        return nil
    end)
    
    -- Execute transaction
    local success, result = Coppermind.transaction(
        PlayerSchema,
        keyA,
        keyB,
        function(dataA, dataB)
            dataA.coins -= 500
            dataB.coins += 500
            return true
        end
    )
    
    assert(success, "Transaction should succeed")
    
    local dataA = Coppermind.getData(PlayerSchema, keyA)
    local dataB = Coppermind.getData(PlayerSchema, keyB)
    
    assert(dataA.coins == 500, "Player A should have 500 coins")
    assert(dataB.coins == 500, "Player B should have 500 coins")
    
    -- Cleanup
    Coppermind.unloadStore(PlayerSchema, keyA)
    Coppermind.unloadStore(PlayerSchema, keyB)
    task.wait(0.1)
    
    print("✓ Transaction test passed")
end
```

</TabItem>
<TabItem value="failed-tx" label="❌ Failed Transactions">

```lua
local function testFailedTransaction()
    local keyA = "player_a"
    local keyB = "player_b"
    
    Coppermind.loadStore(PlayerSchema, keyA, {})
    Coppermind.loadStore(PlayerSchema, keyB, {})
    task.wait(0.2)
    
    -- Player A has 0 coins (default)
    local success, errorMsg = Coppermind.transaction(
        PlayerSchema,
        keyA,
        keyB,
        function(dataA, dataB)
            if dataA.coins < 100 then
                return false, "Not enough coins"
            end
            dataA.coins -= 100
            dataB.coins += 100
            return true
        end
    )
    
    assert(not success, "Transaction should fail")
    assert(errorMsg == "Not enough coins", "Error message should match")
    
    -- Verify no changes were made
    local dataA = Coppermind.getData(PlayerSchema, keyA)
    local dataB = Coppermind.getData(PlayerSchema, keyB)
    
    assert(dataA.coins == 0, "Player A coins should be unchanged")
    assert(dataB.coins == 0, "Player B coins should be unchanged")
    
    Coppermind.unloadStore(PlayerSchema, keyA)
    Coppermind.unloadStore(PlayerSchema, keyB)
    task.wait(0.1)
    
    print("✓ Failed transaction test passed")
end
```

</TabItem>
<TabItem value="events" label="📢 Events">

```lua
local function testEvents()
    local testKey = "event_test"
    local events = {
        ready = false,
        saved = false,
    }
    
    local store = Coppermind.loadStore(PlayerSchema, testKey, {})
    
    store.onReady:Connect(function()
        events.ready = true
    end)
    
    store.onSaved:Connect(function()
        events.saved = true
    end)
    
    task.wait(0.2)
    assert(events.ready, "onReady should fire")
    
    Coppermind.saveStore(PlayerSchema, testKey)
    task.wait(0.2)
    assert(events.saved, "onSaved should fire")
    
    Coppermind.unloadStore(PlayerSchema, testKey)
    task.wait(0.1)
    
    print("✓ Events test passed")
end
```

</TabItem>
</Tabs>

---

## ⏳ Waiting for Async Operations

:::warning Async Operations
Mock mode operations are still asynchronous. Always wait properly!
:::

<Tabs>
<TabItem value="timeout" label="⏱️ Wait with Timeout" default>

```lua
local store = Coppermind.loadStore(schema, key, {})
task.wait(0.2)
```

</TabItem>
<TabItem value="events" label="📢 Use Events">

```lua
local store = Coppermind.loadStore(schema, key, {})
store.onReady:Wait()  -- Blocks until ready
```

</TabItem>
<TabItem value="polling" label="🔄 Poll State">

```lua
local store = Coppermind.loadStore(schema, key, {})
while store.state == "LOADING" do
    task.wait(0.05)
end
```

</TabItem>
</Tabs>

---

## 📋 Complete Test Suite Example

```lua
local function runTestSuite()
    print("Starting Coppermind test suite...")
    
    Coppermind.setMockMode(true)
    
    local tests = {
        { name = "Data Operations", fn = testDataOperations },
        { name = "Persistence", fn = testPersistence },
        { name = "Transactions", fn = testTransactions },
        { name = "Failed Transactions", fn = testFailedTransaction },
        { name = "Events", fn = testEvents },
    }
    
    local passed = 0
    local failed = 0
    
    for _, test in tests do
        Coppermind.clearMockData()
        
        local success, err = pcall(test.fn)
        
        if success then
            passed += 1
        else
            failed += 1
            warn(`✗ {test.name}: {err}`)
        end
    end
    
    Coppermind.setMockMode(false)
    
    print(`\nResults: {passed}/{passed + failed} tests passed`)
end
```

---

## ✅ Testing Checklist

| Test Type | What to Verify |
|:----------|:---------------|
| 📝 **Data Operations** | Read, write, update cycles work correctly |
| 💾 **Persistence** | Data survives save/load cycles |
| 🔐 **Transactions** | Atomic operations commit/rollback properly |
| ❌ **Failure Cases** | Errors are handled gracefully |
| 📢 **Events** | All lifecycle events fire correctly |
| 🔄 **Migrations** | Old data formats upgrade properly |
