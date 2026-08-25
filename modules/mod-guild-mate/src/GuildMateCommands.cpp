/*
 * Copyright (C) 2016+ AzerothCore <www.azerothcore.org>
 * Released under GNU GPL v2 license
 *
 * Guild Mate Module - Chat Commands
 */

#include "Chat.h"
#include "DatabaseEnv.h"
#include "GuildMate.h"
#include "Player.h"
#include "ScriptMgr.h"

// Playerbots includes for inspect command
#include "Playerbots.h"
#include "PlayerbotAI.h"
#include "TravelMgr.h"

using namespace Acore::ChatCommands;

class guildmate_commandscript : public CommandScript
{
public:
    guildmate_commandscript() : CommandScript("guildmate_commandscript") {}

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable guildmateCommandTable = {
            {"exclude", HandleExcludeCommand, SEC_PLAYER, Console::No},
            {"include", HandleIncludeCommand, SEC_PLAYER, Console::No},
            {"status", HandleStatusCommand, SEC_PLAYER, Console::No},
            {"inspect", HandleInspectCommand, SEC_PLAYER, Console::No},
        };

        static ChatCommandTable commandTable = {
            {"guildmate", guildmateCommandTable},
        };

        return commandTable;
    }

    // .guildmate exclude - Exclude your account from Guild Mate auto-login
    static bool HandleExcludeCommand(ChatHandler* handler, char const* /*args*/)
    {
        Player* player = handler->GetSession()->GetPlayer();
        if (!player)
            return false;

        uint32 accountId = handler->GetSession()->GetAccountId();

        // Check if already excluded
        QueryResult result = CharacterDatabase.Query(
            "SELECT 1 FROM guildmate_excluded_accounts WHERE account_id = {}", accountId);

        if (result)
        {
            handler->PSendSysMessage("Your account is already excluded from Guild Mate.");
            return true;
        }

        // Add to exclusion list
        CharacterDatabase.Execute(
            "INSERT INTO guildmate_excluded_accounts (account_id, notes) VALUES ({}, 'Excluded via .guildmate exclude')",
            accountId);

        handler->PSendSysMessage("Your account (ID: {}) has been excluded from Guild Mate.", accountId);
        handler->PSendSysMessage("Your characters will NOT be auto-logged as bots.");
        handler->PSendSysMessage("Note: Takes effect on next server restart.");

        return true;
    }

    // .guildmate include - Remove your account from exclusion list
    static bool HandleIncludeCommand(ChatHandler* handler, char const* /*args*/)
    {
        Player* player = handler->GetSession()->GetPlayer();
        if (!player)
            return false;

        uint32 accountId = handler->GetSession()->GetAccountId();

        // Check if excluded
        QueryResult result = CharacterDatabase.Query(
            "SELECT 1 FROM guildmate_excluded_accounts WHERE account_id = {}", accountId);

        if (!result)
        {
            handler->PSendSysMessage("Your account is not in the exclusion list.");
            return true;
        }

        // Remove from exclusion list
        CharacterDatabase.Execute(
            "DELETE FROM guildmate_excluded_accounts WHERE account_id = {}", accountId);

        handler->PSendSysMessage("Your account (ID: {}) has been removed from the exclusion list.", accountId);
        handler->PSendSysMessage("Your guild characters WILL be auto-logged as bots.");
        handler->PSendSysMessage("Note: Takes effect on next server restart.");

        return true;
    }

    // .guildmate status - Show Guild Mate status for your account
    static bool HandleStatusCommand(ChatHandler* handler, char const* /*args*/)
    {
        Player* player = handler->GetSession()->GetPlayer();
        if (!player)
            return false;

        uint32 accountId = handler->GetSession()->GetAccountId();

        // Check module status
        if (!sGuildMateMgr->IsEnabled())
        {
            handler->PSendSysMessage("Guild Mate module is disabled.");
            return true;
        }

        // Check exclusion status
        QueryResult result = CharacterDatabase.Query(
            "SELECT 1 FROM guildmate_excluded_accounts WHERE account_id = {}", accountId);

        if (result)
        {
            handler->PSendSysMessage("Your account (ID: {}) is EXCLUDED from Guild Mate.", accountId);
            handler->PSendSysMessage("Your characters will NOT be auto-logged as bots.");
        }
        else
        {
            handler->PSendSysMessage("Your account (ID: {}) is NOT excluded from Guild Mate.", accountId);
            handler->PSendSysMessage("Your guild characters WILL be auto-logged as bots (if in a configured guild).");
        }

        handler->PSendSysMessage("Guild Mate bots online: {}/{}", 
            sGuildMateMgr->GetOnlineCount(), sGuildMateMgr->GetEligibleCount());

        return true;
    }

    // Helper to get BotState name
    static const char* GetBotStateName(BotState state)
    {
        switch (state)
        {
            case BOT_STATE_COMBAT:     return "COMBAT";
            case BOT_STATE_NON_COMBAT: return "NON_COMBAT";
            case BOT_STATE_DEAD:       return "DEAD";
            default:                   return "UNKNOWN";
        }
    }

    // .guildmate inspect <character> - Read-only diagnostic for bot AI state
    static bool HandleInspectCommand(ChatHandler* handler, char const* args)
    {
        if (!args || !*args)
        {
            handler->PSendSysMessage("Usage: .guildmate inspect <character>");
            return true;
        }

        std::string charName = args;

        // Normalize character name
        if (!normalizePlayerName(charName))
        {
            handler->PSendSysMessage("Invalid character name.");
            return false;
        }

        // Find the player (must be online)
        Player* target = ObjectAccessor::FindPlayerByName(charName);
        if (!target)
        {
            handler->PSendSysMessage("Character '{}' is not online.", charName);
            return true;
        }

        // Get PlayerbotAI - must be a bot
        PlayerbotAI* ai = GET_PLAYERBOT_AI(target);
        if (!ai)
        {
            handler->PSendSysMessage("'{}' is not a bot (no PlayerbotAI).", target->GetName());
            return true;
        }

        // ========== BASIC INFO ==========
        handler->PSendSysMessage("=== Inspect: {} ===", target->GetName());
        handler->PSendSysMessage("Level: {} | Class: {}", 
            target->GetLevel(),
            target->getClass());

        // Mode: Autonomous vs Player-controlled
        bool hasRealMaster = ai->HasRealPlayerMaster();
        Player* master = ai->GetMaster();
        if (hasRealMaster && master && master != target)
        {
            handler->PSendSysMessage("Mode: PLAYER-CONTROLLED (master: {})", master->GetName());
        }
        else
        {
            handler->PSendSysMessage("Mode: AUTONOMOUS");
        }

        // ========== AI STATE ==========
        BotState currentState = ai->GetState();
        handler->PSendSysMessage("AI State: {}", GetBotStateName(currentState));

        // ========== ACTIVE STRATEGIES ==========
        // Show strategies for all states
        for (int s = 0; s < BOT_STATE_MAX; ++s)
        {
            BotState state = static_cast<BotState>(s);
            std::vector<std::string> strategies = ai->GetStrategies(state);
            
            if (!strategies.empty())
            {
                std::string stratList;
                for (size_t i = 0; i < strategies.size(); ++i)
                {
                    if (i > 0) stratList += ", ";
                    stratList += strategies[i];
                }
                handler->PSendSysMessage("Strategies [{}]: {}", GetBotStateName(state), stratList);
            }
            else
            {
                handler->PSendSysMessage("Strategies [{}]: (none)", GetBotStateName(state));
            }
        }

        // ========== RPG STATE ==========
        // Read rpgInfo directly from the AI
        std::string rpgStatusStr = ai->rpgInfo.ToString();
        handler->PSendSysMessage("RPG State: {}", rpgStatusStr);

        // RPG Target (if applicable)
        AiObjectContext* context = ai->GetAiObjectContext();
        if (context)
        {
            // Get "rpg target" value
            Value<GuidPosition>* rpgTargetValue = context->GetValue<GuidPosition>("rpg target");
            if (rpgTargetValue)
            {
                GuidPosition rpgTarget = rpgTargetValue->Get();
                if (rpgTarget)
                {
                    WorldObject* obj = rpgTarget.GetWorldObject();
                    if (obj)
                    {
                        handler->PSendSysMessage("RPG Target: {} ({})", 
                            obj->GetName(), rpgTarget.ToString());
                    }
                    else
                    {
                        handler->PSendSysMessage("RPG Target GUID: {}", rpgTarget.ToString());
                    }
                }
            }

            // ========== TRAVEL TARGET ==========
            Value<TravelTarget*>* travelValue = context->GetValue<TravelTarget*>("travel target");
            if (travelValue)
            {
                TravelTarget* travelTarget = travelValue->Get();
                if (travelTarget && travelTarget->isActive())
                {
                    TravelDestination* dest = travelTarget->getDestination();
                    if (dest)
                    {
                        handler->PSendSysMessage("Travel Target: {} (entry: {})", 
                            dest->getTitle(), dest->getEntry());
                    }
                    else
                    {
                        handler->PSendSysMessage("Travel Target: (active, no destination)");
                    }
                }
                else
                {
                    handler->PSendSysMessage("Travel Target: (inactive)");
                }
            }
        }

        // ========== QUEST COUNTS ==========
        std::vector<const Quest*> allQuests = ai->GetAllCurrentQuests();
        std::vector<const Quest*> incompleteQuests = ai->GetCurrentIncompleteQuests();
        handler->PSendSysMessage("Quests: {} total, {} incomplete", 
            allQuests.size(), incompleteQuests.size());

        return true;
    }
};

void AddGuildMateCommandScripts()
{
    new guildmate_commandscript();
}
