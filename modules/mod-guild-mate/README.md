# mod-guild-mate

Guild Mate is an AzerothCore module for the Bygdok Eternal Android server that automatically logs in designated characters and keeps them operating autonomously using the existing Playerbots AI system.

## Features

- **Automatic Server Startup Login**: Guild Mate characters log in automatically when the server starts, without requiring a real player to be online first.
- **Real Character Progression**: Unlike RandomBots, Guild Mate characters gain real XP, levels, quest progress, loot, equipment, money, and reputation.
- **Existing Identity Preserved**: Characters retain their existing identity, account ownership, guild membership, inventory, quests, gear, and progression.
- **Autonomous AI**: Uses the existing Playerbots autonomous AI (RPG, questing, grinding, combat, travel, etc.) without requiring a master player.
- **Zero-Player Operation**: Bots continue operating even when no real human players are online.
- **Guild-Based Character Selection**: Select all members of specified guilds for autonomous operation.
- **Human Player Priority**: If a human player logs in as a character that's running as a bot, the bot is kicked and the human takes over.

## Requirements

- AzerothCore (Bygdok Eternal pinned version)
- mod-playerbots (Bygdok Eternal pinned version)

## Installation

1. Copy the `mod-guild-mate` folder to your AzerothCore `modules/` directory.
2. Re-run cmake and rebuild the server.
3. Import the SQL file into your characters database: `data/sql/db-characters/base/guildmate_excluded_accounts.sql`
4. Copy `conf/mod_guild_mate.conf.dist` to your server's conf directory and rename to `mod_guild_mate.conf`.
5. Exclude your human account (see Account Exclusion below).
6. Configure the module (see Configuration section).

## Configuration

### Basic Configuration

Edit `mod_guild_mate.conf` in your server's configuration directory:

```conf
# Enable the module
GuildMate.Enable = 1

# Delay in seconds after server startup before logging in bots
GuildMate.StartupDelay = 60

# Number of bots to log in per batch
GuildMate.LoginBatchSize = 5

# Delay in milliseconds between batches
GuildMate.LoginBatchDelay = 1000

# Guild IDs to auto-login (REQUIRED - comma-separated)
GuildMate.GuildIds = "1,2,3"
```

### Guild Selection

Set `GuildMate.GuildIds` to a comma-separated list of guild IDs whose members should be auto-logged:

```conf
GuildMate.GuildIds = "1,2,3"
```

To find a guild's ID:
```sql
SELECT id, name FROM guild;
```

All members of the specified guilds will be eligible for auto-login, except:
- Characters currently online (human players)
- Characters on random bot accounts (if `ExcludeRandomBotAccounts = 1`)
- Characters on excluded accounts (see Account Exclusion below)

### Account Exclusion

To prevent your human player account's characters from being controlled by Guild Mate, use the in-game command:

```
.guildmate exclude
```

This excludes your account from Guild Mate. Your characters will NOT be auto-logged as bots.

**Available Commands:**
| Command | Description |
|---------|-------------|
| `.guildmate exclude` | Exclude your account from Guild Mate |
| `.guildmate include` | Remove your account from the exclusion list |
| `.guildmate status` | Show your exclusion status and bot counts |

**Alternative (SQL):**
```sql
-- Find your account ID (in auth database)
SELECT id, username FROM account WHERE username = 'YourUsername';

-- Exclude your account (in characters database)
INSERT INTO guildmate_excluded_accounts (account_id, notes) VALUES (1, 'Human main account');
```

All characters on excluded accounts will be skipped by Guild Mate, even if they are members of a configured guild.

**Note:** Exclusion changes take effect on next server restart.

### Required Playerbots Configuration

For Guild Mate to function properly, ensure these Playerbots settings:

```conf
# Keep bots active when no players are nearby (100 = 100% activity)
AiPlayerbot.BotActiveAlone = 100

# Keep bots active when in a guild (important for Guild Mate)
AiPlayerbot.BotActiveAloneForceWhenInGuild = 1

# Allow bots to operate without a real player online (CRITICAL)
AiPlayerbot.DisabledWithoutRealPlayer = 0

# Enable autonomous RPG behavior
AiPlayerbot.EnableNewRpgStrategy = 1

# Enable autonomous questing
AiPlayerbot.AutoDoQuests = 1
```

## How It Works

### Login Process

1. On server startup, Guild Mate waits for the configured startup delay to allow Playerbots to initialize.
2. It queries the character database for all members of configured guilds.
3. Characters are logged in progressively in batches to avoid server overload.
4. Each character receives a PlayerbotAI instance with no master (autonomous mode).

### Strategy Initialization

When a Guild Mate character logs in, the following strategies are automatically enabled:

- **grind**: Enables autonomous grinding/combat behavior
- **new rpg** (if `EnableNewRpgStrategy=1`): Advanced RPG behavior including questing, exploration, and world interaction
- **rpg** (fallback if `new rpg` disabled but `AutoDoQuests=1`): Basic RPG/questing behavior
- **move random** (fallback): Random movement if questing disabled

The `follow` strategy is explicitly disabled since Guild Mate bots have no master to follow.

**Technical Note**: These strategies are added in `OnBotLoginInternal()` because the standard `AiFactory::AddDefaultNonCombatStrategies()` only adds them for RandomBots (via the `IsRandomBot()` check). Guild Mate characters are not RandomBots, so we must add these strategies explicitly.

### Human Player Handling

Guild Mate respects human player priority:

1. **At startup**: Characters already online are skipped
2. **During operation**: If a human logs in as a character running as a bot, the bot session is kicked by the core server's session management, and the human takes control
3. **After logout**: If a human logs out, the character may be picked up by Guild Mate on the next server restart

### Zero-Player Operation

With proper Playerbots configuration (`BotActiveAlone=100`, `DisabledWithoutRealPlayer=0`), Guild Mate bots continue operating indefinitely even when no human players are online. They will:

- Quest and grind for XP
- Travel between zones
- Interact with NPCs
- Gain real progression (XP, loot, reputation, etc.)

## Logging

Guild Mate logs to the `module.guildmate` logger. Example output:

```
Guild Mate: Initialized with startup delay 60 seconds
Guild Mate: Loading members from guild 'My Guild' (ID: 1)
Guild Mate: Discovered 12 eligible characters for autonomous login
Guild Mate: 12 characters queued for autonomous login
Guild Mate: Batch login 5/12 (5 this batch)
Guild Mate: MyWarrior logged in (5/12)
Guild Mate: MyWarrior enabled with grind + new rpg strategies
...
Guild Mate: 12/12 autonomous bots online
```

## Troubleshooting

### Bots don't log in
- Check that `GuildMate.Enable = 1`
- Check that `GuildMate.GuildIds` is set to valid guild ID(s)
- Check that Playerbots is enabled
- Check server logs for error messages

### Bots don't quest/grind (just stand around)
- Ensure `AiPlayerbot.BotActiveAlone = 100`
- Ensure `AiPlayerbot.DisabledWithoutRealPlayer = 0`
- Ensure `AiPlayerbot.EnableNewRpgStrategy = 1` or `AiPlayerbot.AutoDoQuests = 1`
- Check server logs for "enabled with grind + new rpg strategies" message

### Bots disappear when I log out
- Ensure `AiPlayerbot.DisabledWithoutRealPlayer = 0`
- This is the most common misconfiguration

### Bot took over my character
- Guild Mate only logs in characters that are offline
- If your character is online, it won't be affected
- If you log in while a bot has your character, you'll automatically kick the bot

## Technical Details

Guild Mate works by:

1. **Extending `PlayerbotHolder`**: Reuses the existing Playerbots bot login infrastructure
2. **Calling `AddPlayerBot(guid, 0)`**: The `0` means no master account (autonomous operation)
3. **Hooking `WorldScript::OnStartup`**: Initializes the module after server start
4. **Hooking `WorldScript::OnUpdate`**: Processes login batches and maintains bot sessions
5. **Explicit strategy injection**: Adds `grind`, `new rpg` strategies after login since `AddDefaultNonCombatStrategies()` only adds them for RandomBots

### Key Differences from RandomBots

| Feature | RandomBots | Guild Mate |
|---------|-----------|------------|
| Character ownership | Dedicated bot accounts | Real player accounts |
| XP gain | Blocked (`NO_XP_GAIN` flag) | Real XP gain |
| Identity | Generated characters | Existing characters |
| Selection | Random from bot accounts | Explicit guild membership |
| Account type | Bot accounts | Player accounts |

### Code Path for Strategy Initialization

```
AddPlayerBot(guid, 0)
  -> PlayerbotHolder::AddPlayerBot()
     -> HandlePlayerBotLoginCallback()
        -> OnBotLogin(bot)
           -> GuildMateMgr::OnBotLoginInternal(bot)
              -> ai->ChangeStrategy("+grind", BOT_STATE_NON_COMBAT)
              -> ai->ChangeStrategy("+new rpg", BOT_STATE_NON_COMBAT)
              -> ai->ChangeStrategy("-follow", BOT_STATE_NON_COMBAT)
```

## License

GNU GPL v2
