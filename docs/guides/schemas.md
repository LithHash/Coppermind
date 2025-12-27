---
sidebar_position: 1
---

# 📋 Schemas

Schemas define the structure, default values, and migrations for your data. This guide covers everything you need to know about schemas in Coppermind.

---

## Creating a Schema

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

:::info Unique Names
Each schema must have a unique `name` — this is used as the DataStore name.
:::

---

## 📝 Data Templates

The `dataTemplate` defines the default structure for new data:

```lua
local dataTemplate = {
    -- Primitives
    coins = 0,
    playerName = "",
    isPremium = false,
    
    -- Nested tables
    stats = {
        level = 1,
        xp = 0,
        playTime = 0,
    },
    
    -- Arrays
    inventory = {},
    completedQuests = {},
    
    -- Complex nested structures
    settings = {
        audio = {
            musicVolume = 1,
            sfxVolume = 1,
        },
        display = {
            showDamageNumbers = true,
        },
    },
}
```

### 🔄 Data Reconciliation

When loading existing data, Coppermind automatically reconciles it with the template:

| Scenario | Behavior |
|:---------|:---------|
| Missing fields | Added with default values |
| Extra fields | Preserved (not removed) |
| Nested structures | Recursively reconciled |

```lua
-- If saved data is:
{ coins = 500 }

-- And template is:
{ coins = 0, gems = 0, stats = { level = 1 } }

-- ✅ Loaded data becomes:
{ coins = 500, gems = 0, stats = { level = 1 } }
```

---

## 🔍 Retrieving Schemas

Get a registered schema by name:

```lua
local schema = Coppermind.getSchema("PlayerData")

if schema then
    print("Found schema:", schema.name)
end
```

---

## 🔒 Type Safety

For better type inference, define your schema with type annotations:

```lua
type PlayerData = {
    coins: number,
    gems: number,
    inventory: { string },
    stats: {
        level: number,
        xp: number,
    },
}

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
    } :: PlayerData,
    migrations = {},
})
```

:::tip Type Benefits
Type annotations provide:
- Better autocomplete in your IDE
- Compile-time error checking
- Self-documenting code
:::

---

## ✅ Best Practices

### 1. Use Descriptive Names

```lua
-- ✅ Good
local PlayerSchema = Coppermind.registerSchema({
    name = "PlayerData_v1",
    -- ...
})

-- ❌ Avoid
local schema = Coppermind.registerSchema({
    name = "Data",
    -- ...
})
```

### 2. Initialize All Fields

:::warning No Nil Values
Always provide default values for every field — never use `nil`.
:::

```lua
-- ✅ Good
dataTemplate = {
    coins = 0,
    lastLogin = 0,
    settings = {
        musicEnabled = true,
    },
}

-- ❌ Avoid leaving fields undefined
dataTemplate = {
    coins = nil,  -- Don't do this
}
```

### 3. Keep Templates Flat When Possible

Deeply nested structures are harder to work with:

```lua
-- ✅ Prefer flat structures
dataTemplate = {
    audioMusicVolume = 1,
    audioSfxVolume = 1,
    displayShowDamage = true,
}

-- ⚠️ Use nesting sparingly
dataTemplate = {
    settings = {
        audio = {
            volumes = {
                music = 1,  -- Very deep!
            },
        },
    },
}
```

### 4. Version Your Schema Names

If you need to make breaking changes, version your schema:

```lua
-- Original
local PlayerSchemaV1 = Coppermind.registerSchema({
    name = "PlayerData_v1",
    -- ...
})

-- New version with breaking changes
local PlayerSchemaV2 = Coppermind.registerSchema({
    name = "PlayerData_v2",
    -- ...
})
```

:::caution Breaking Changes
Changing the schema name creates a new DataStore. Use migrations for non-breaking changes instead.
:::
