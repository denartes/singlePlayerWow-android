/*
 * Copyright (C) 2016+ AzerothCore <www.azerothcore.org>
 * Released under GNU GPL v2 license
 *
 * Guild Mate Module Implementation
 */

#include "GuildMate.h"

#include "CharacterCache.h"
#include "Group.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "GameTime.h"
#include "GuildMgr.h"
#include "ObjectAccessor.h"
#include "PlayerbotAI.h"
#include "PlayerbotAIConfig.h"
#include "Playerbots.h"
#include "RandomPlayerbotMgr.h"
#include "ScriptMgr.h"
#include "WorldScript.h"
#include "WorldSession.h"
#include "WorldSessionMgr.h"

GuildMateMgr::GuildMateMgr()
    : PlayerbotHolder(),
      enabled(false),
      startupDelay(60),
      loginBatchSize(5),
      loginBatchDelay(1000),
      excludeRandomBotAccounts(true),
      includeOfflineOnly(true),
      teleportOnLogin(true),
      periodicTeleport(true),
      initialized(false),
      loginStarted(false),
      loginStartTime(0),
      lastBatchTime(0),
      loginQueueIndex(0)
{
}

GuildMateMgr::~GuildMateMgr()
{
}

void GuildMateMgr::Initialize()
{
    if (initialized)
        return;

    // Load configuration
    enabled = sConfigMgr->GetOption<bool>("GuildMate.Enable", true);
    startupDelay = sConfigMgr->GetOption<uint32>("GuildMate.StartupDelay", 60);
    loginBatchSize = sConfigMgr->GetOption<uint32>("GuildMate.LoginBatchSize", 5);
    loginBatchDelay = sConfigMgr->GetOption<uint32>("GuildMate.LoginBatchDelay", 1000);
    guildIds = sConfigMgr->GetOption<std::string>("GuildMate.GuildIds", "");
    excludeRandomBotAccounts = sConfigMgr->GetOption<bool>("GuildMate.ExcludeRandomBotAccounts", true);
    includeOfflineOnly = sConfigMgr->GetOption<bool>("GuildMate.IncludeOfflineOnly", true);
    teleportOnLogin = sConfigMgr->GetOption<bool>("GuildMate.TeleportOnLogin", true);
    periodicTeleport = sConfigMgr->GetOption<bool>("GuildMate.PeriodicTeleport", true);

    if (!enabled)
    {
        LOG_INFO("module.guildmate", "Guild Mate: Module is disabled");
        initialized = true;
        return;
    }

    // Check if Playerbots is enabled
    if (!sPlayerbotAIConfig->enabled && !sPlayerbotAIConfig->randomBotAutologin)
    {
        LOG_ERROR("module.guildmate", "Guild Mate: Playerbots module is not enabled. Guild Mate requires Playerbots.");
        enabled = false;
        initialized = true;
        return;
    }

    // Load excluded accounts from database
    LoadExcludedAccounts();

    LOG_INFO("module.guildmate", "Guild Mate: Initialized with startup delay {} seconds", startupDelay);

    initialized = true;
}

void GuildMateMgr::LoadExcludedAccounts()
{
    excludedAccounts.clear();

    QueryResult result = CharacterDatabase.Query("SELECT account_id FROM guildmate_excluded_accounts");
    if (result)
    {
        do
        {
            Field* fields = result->Fetch();
            uint32 accountId = fields[0].Get<uint32>();
            excludedAccounts.insert(accountId);
        } while (result->NextRow());

        LOG_INFO("module.guildmate", "Guild Mate: Loaded {} excluded accounts", excludedAccounts.size());
    }
}

void GuildMateMgr::StartLogin()
{
    if (!enabled || loginStarted)
        return;

    loginStarted = true;
    loginStartTime = time(nullptr);
    lastBatchTime = 0;

    LoadEligibleCharacters();

    if (eligibleCharacters.empty())
    {
        LOG_INFO("module.guildmate", "Guild Mate: No eligible characters found for auto-login");
        return;
    }

    LOG_INFO("module.guildmate", "Guild Mate: Discovered {} eligible characters for autonomous login",
             eligibleCharacters.size());
    LOG_INFO("module.guildmate", "Guild Mate: {} characters queued for autonomous login", eligibleCharacters.size());
}

void GuildMateMgr::LoadEligibleCharacters()
{
    eligibleCharacters.clear();
    guildMateGuids.clear();

    // First try to load from guild IDs if specified
    if (!guildIds.empty())
    {
        std::vector<uint32> parsedGuildIds;
        std::stringstream ss(guildIds);
        std::string item;
        while (std::getline(ss, item, ','))
        {
            try
            {
                uint32 guildId = std::stoul(item);
                if (guildId > 0)
                    parsedGuildIds.push_back(guildId);
            }
            catch (...)
            {
                LOG_WARN("module.guildmate", "Guild Mate: Invalid guild ID in configuration: {}", item);
            }
        }

        for (uint32 guildId : parsedGuildIds)
        {
            Guild* guild = sGuildMgr->GetGuildById(guildId);
            if (!guild)
            {
                LOG_WARN("module.guildmate", "Guild Mate: Guild {} not found", guildId);
                continue;
            }

            LOG_INFO("module.guildmate", "Guild Mate: Loading members from guild '{}' (ID: {})",
                     guild->GetName(), guildId);

            // Get all characters in this guild
            QueryResult result = CharacterDatabase.Query(
                "SELECT gm.guid, c.account FROM guild_member gm "
                "JOIN characters c ON gm.guid = c.guid "
                "WHERE gm.guildId = {}",
                guildId);

            if (result)
            {
                do
                {
                    Field* fields = result->Fetch();
                    ObjectGuid::LowType guid = fields[0].Get<uint32>();
                    uint32 accountId = fields[1].Get<uint32>();

                    // Skip random bot accounts if configured
                    if (excludeRandomBotAccounts && sPlayerbotAIConfig->IsInRandomAccountList(accountId))
                    {
                        continue;
                    }

                    // Skip excluded accounts (human player accounts)
                    if (excludedAccounts.find(accountId) != excludedAccounts.end())
                    {
                        continue;
                    }

                    // Skip if already online (human player currently playing)
                    if (includeOfflineOnly && IsCharacterOnline(guid))
                    {
                        continue;
                    }

                    eligibleCharacters.push_back(guid);
                    guildMateGuids.insert(guid);
                } while (result->NextRow());
            }
        }
    }
    else
    {
        LOG_ERROR("module.guildmate", "Guild Mate: GuildMate.GuildIds is not configured. "
                  "Set GuildMate.GuildIds in mod_guild_mate.conf to specify which guilds to use.");
    }

    loginQueueIndex = 0;
}

bool GuildMateMgr::IsCharacterOnline(ObjectGuid::LowType guid)
{
    ObjectGuid fullGuid = ObjectGuid::Create<HighGuid::Player>(guid);
    Player* player = ObjectAccessor::FindConnectedPlayer(fullGuid);
    return player && player->IsInWorld();
}

void GuildMateMgr::UpdateAIInternal(uint32 /*elapsed*/, bool /*minimal*/)
{
    if (!enabled || !initialized)
        return;

    // Wait for startup delay
    time_t uptime = GameTime::GetUptime().count();
    if (uptime < startupDelay)
    {
        SetNextCheckDelay(1000);
        return;
    }

    // Start login process after startup delay
    if (!loginStarted)
    {
        StartLogin();
    }

    // Process login queue
    if (!eligibleCharacters.empty() && loginQueueIndex < eligibleCharacters.size())
    {
        uint32 nowMs = GameTime::GetGameTimeMS().count();

        // Check if enough time has passed since last batch
        if (lastBatchTime == 0 || nowMs - lastBatchTime >= loginBatchDelay)
        {
            ProcessLoginBatch();
            lastBatchTime = nowMs;
        }

        // Check more frequently while logging in
        SetNextCheckDelay(loginBatchDelay / 2);
    }
    else
    {
        // All logins complete, check less frequently
        SetNextCheckDelay(5000);

        // Periodically reconcile autonomy for all online Guild Mates
        ReconcileAutonomy();
    }

    // Update bot sessions
    UpdateSessions();
}

void GuildMateMgr::ProcessLoginBatch()
{
    uint32 loggedIn = 0;

    while (loginQueueIndex < eligibleCharacters.size() && loggedIn < loginBatchSize)
    {
        ObjectGuid::LowType guid = eligibleCharacters[loginQueueIndex];
        loginQueueIndex++;

        // Skip if already online (could have logged in manually)
        if (IsCharacterOnline(guid))
        {
            LOG_DEBUG("module.guildmate", "Guild Mate: Skipping {} (now online)", guid);
            continue;
        }

        // Skip if already a playerbot
        ObjectGuid fullGuid = ObjectGuid::Create<HighGuid::Player>(guid);
        if (GetPlayerBot(fullGuid))
        {
            LOG_DEBUG("module.guildmate", "Guild Mate: Skipping {} (already a bot)", guid);
            continue;
        }

        // Log in the character with no master (0 = autonomous)
        AddPlayerBot(fullGuid, 0);
        loggedIn++;

        LOG_DEBUG("module.guildmate", "Guild Mate: Queued character {} for login", guid);
    }

    if (loggedIn > 0)
    {
        LOG_INFO("module.guildmate", "Guild Mate: Batch login {}/{} ({} this batch)",
                 loginQueueIndex, eligibleCharacters.size(), loggedIn);
    }

    // Check if login complete
    if (loginQueueIndex >= eligibleCharacters.size())
    {
        LOG_INFO("module.guildmate", "Guild Mate: {}/{} autonomous bots online",
                 playerBots.size(), eligibleCharacters.size());
    }
}

void GuildMateMgr::OnBotLoginInternal(Player* const bot)
{
    if (!bot)
        return;

    LOG_INFO("module.guildmate", "Guild Mate: {} logged in ({}/{})",
             bot->GetName(), playerBots.size(), eligibleCharacters.size());

    // Mark as Guild Mate
    guildMateGuids.insert(bot->GetGUID().GetCounter());

    // Ensure the bot can gain XP (unlike fixed-level RandomBots)
    bot->RemovePlayerFlag(PLAYER_FLAGS_NO_XP_GAIN);

    // Get the PlayerbotAI for this bot (created by PlayerbotHolder::OnBotLogin())
    PlayerbotAI* ai = GET_PLAYERBOT_AI(bot);
    if (ai)
    {
        // Add autonomous non-combat strategies since we're not RandomBots
        // (RandomBots get these in AiFactory::AddDefaultNonCombatStrategies via IsRandomBot check)
        ai->ChangeStrategy("+grind", BOT_STATE_NON_COMBAT);

        // Add RPG strategy based on configuration
        if (sPlayerbotAIConfig->enableNewRpgStrategy)
        {
            ai->ChangeStrategy("+new rpg", BOT_STATE_NON_COMBAT);
            LOG_DEBUG("module.guildmate", "Guild Mate: {} enabled with grind + new rpg strategies", bot->GetName());
        }
        else if (sPlayerbotAIConfig->autoDoQuests)
        {
            ai->ChangeStrategy("+rpg", BOT_STATE_NON_COMBAT);
            LOG_DEBUG("module.guildmate", "Guild Mate: {} enabled with grind + rpg strategies", bot->GetName());
        }
        else
        {
            ai->ChangeStrategy("+move random", BOT_STATE_NON_COMBAT);
            LOG_DEBUG("module.guildmate", "Guild Mate: {} enabled with grind + move random strategies", bot->GetName());
        }

        // Remove follow strategy since we're autonomous (no master)
        ai->ChangeStrategy("-follow", BOT_STATE_NON_COMBAT);
    }

    // Teleport to level-appropriate zone (like RandomBots do)
    // This ensures the RPG system has valid grind/camp locations nearby
    if (teleportOnLogin)
    {
        sRandomPlayerbotMgr->RandomTeleportForLevel(bot);
        lastTeleportTime[bot->GetGUID().GetCounter()] = time(nullptr);
        LOG_INFO("module.guildmate", "Guild Mate: {} teleported to level-appropriate zone", bot->GetName());
    }
}

bool GuildMateMgr::IsUnderPlayerControl(Player* bot)
{
    PlayerbotAI* ai = GET_PLAYERBOT_AI(bot);
    if (!ai)
        return false;

    Player* master = ai->GetMaster();
    if (!master || !master->IsInWorld() || GET_PLAYERBOT_AI(master))
        return false;

    // Bot must be in the same group as the real player master
    Group* group = bot->GetGroup();
    if (!group)
        return false;

    return group->IsMember(master->GetGUID());
}

void GuildMateMgr::RestoreAutonomy(Player* bot)
{
    if (bot->IsInCombat())
        return;

    PlayerbotAI* ai = GET_PLAYERBOT_AI(bot);
    if (!ai)
        return;

    ai->SetMaster(nullptr);
    ai->ResetStrategies();

    ai->ChangeStrategy("+grind", BOT_STATE_NON_COMBAT);

    if (sPlayerbotAIConfig->enableNewRpgStrategy)
        ai->ChangeStrategy("+new rpg", BOT_STATE_NON_COMBAT);
    else if (sPlayerbotAIConfig->autoDoQuests)
        ai->ChangeStrategy("+rpg", BOT_STATE_NON_COMBAT);
    else
        ai->ChangeStrategy("+move random", BOT_STATE_NON_COMBAT);

    ai->ChangeStrategy("-follow", BOT_STATE_NON_COMBAT);

    LOG_INFO("module.guildmate", "Guild Mate: {} restored to autonomous state from current position", bot->GetName());
}

void GuildMateMgr::ReconcileAutonomy()
{
    time_t now = time(nullptr);

    for (auto& [accountId, bot] : playerBots)
    {
        if (!bot || !bot->IsInWorld())
            continue;

        ObjectGuid::LowType lowGuid = bot->GetGUID().GetCounter();
        if (!IsGuildMate(lowGuid))
            continue;

        bool underControl = IsUnderPlayerControl(bot);
        bool wasControlled = playerControlledBots.count(lowGuid) > 0;

        if (underControl && !wasControlled)
        {
            playerControlledBots.insert(lowGuid);
            LOG_INFO("module.guildmate", "Guild Mate: {} is now under player control", bot->GetName());
        }
        else if (!underControl && wasControlled)
        {
            playerControlledBots.erase(lowGuid);
            RestoreAutonomy(bot);
        }

        // Periodic teleportation for autonomous bots (like RandomBots)
        if (periodicTeleport && !underControl && !bot->InBattleground() && !bot->GetGroup())
        {
            // Check if enough time has passed since last teleport
            time_t lastTele = lastTeleportTime.count(lowGuid) ? lastTeleportTime[lowGuid] : 0;
            uint32 teleportInterval = urand(
                sPlayerbotAIConfig->minRandomBotTeleportInterval,
                sPlayerbotAIConfig->maxRandomBotTeleportInterval);

            if (now - lastTele >= teleportInterval)
            {
                // Check if bot is idle (not actively doing something useful)
                PlayerbotAI* ai = GET_PLAYERBOT_AI(bot);
                if (ai && !bot->IsInCombat() && !bot->isDead())
                {
                    sRandomPlayerbotMgr->RandomTeleportForLevel(bot);
                    lastTeleportTime[lowGuid] = now;
                    LOG_DEBUG("module.guildmate", "Guild Mate: {} periodic teleport to level-appropriate zone",
                              bot->GetName());
                }
            }
        }
    }
}

bool GuildMateMgr::IsGuildMate(ObjectGuid::LowType guid)
{
    return guildMateGuids.find(guid) != guildMateGuids.end();
}

bool GuildMateMgr::IsGuildMate(Player* player)
{
    if (!player)
        return false;
    return IsGuildMate(player->GetGUID().GetCounter());
}

// World Script to hook into server startup
class GuildMateWorldScript : public WorldScript
{
public:
    GuildMateWorldScript() : WorldScript("GuildMateWorldScript", {
        WORLDHOOK_ON_STARTUP,
        WORLDHOOK_ON_UPDATE
    }) {}

    void OnStartup() override
    {
        sGuildMateMgr->Initialize();
    }

    void OnUpdate(uint32 diff) override
    {
        sGuildMateMgr->UpdateAI(diff);
    }
};

// Forward declaration for command scripts
void AddGuildMateCommandScripts();

void AddGuildMateScripts()
{
    new GuildMateWorldScript();
    AddGuildMateCommandScripts();
}
