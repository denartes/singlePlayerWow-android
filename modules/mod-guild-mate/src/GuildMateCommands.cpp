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
};

void AddGuildMateCommandScripts()
{
    new guildmate_commandscript();
}
