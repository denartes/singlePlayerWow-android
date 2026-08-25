/*
 * Copyright (C) 2016+ AzerothCore <www.azerothcore.org>
 * Released under GNU GPL v2 license
 *
 * Guild Mate Module
 * Automatically logs in designated characters and keeps them operating
 * autonomously using the existing Playerbots AI system.
 */

#ifndef _GUILDMATE_H
#define _GUILDMATE_H

#include "Common.h"
#include "ObjectGuid.h"
#include "Player.h"
#include "PlayerbotMgr.h"

#include <vector>
#include <unordered_set>

class GuildMateMgr : public PlayerbotHolder
{
public:
    GuildMateMgr();
    virtual ~GuildMateMgr();

    static GuildMateMgr* instance()
    {
        static GuildMateMgr instance;
        return &instance;
    }

    // Initialize the manager and load configuration
    void Initialize();

    // Begin the login process for Guild Mate characters
    void StartLogin();

    // Called periodically to process login queue and maintain bots
    void UpdateAIInternal(uint32 elapsed, bool minimal = false) override;

    // Check if a character is a Guild Mate
    bool IsGuildMate(ObjectGuid::LowType guid);
    bool IsGuildMate(Player* player);

    // Get statistics
    uint32 GetOnlineCount() const { return playerBots.size(); }
    uint32 GetEligibleCount() const { return eligibleCharacters.size(); }

    // Configuration getters
    bool IsEnabled() const { return enabled; }
    uint32 GetStartupDelay() const { return startupDelay; }
    uint32 GetLoginBatchSize() const { return loginBatchSize; }
    uint32 GetLoginBatchDelay() const { return loginBatchDelay; }

protected:
    void OnBotLoginInternal(Player* const bot) override;

private:
    // Load eligible characters from database/guilds
    void LoadEligibleCharacters();

    // Load excluded accounts from database
    void LoadExcludedAccounts();

    // Process the next batch of logins
    void ProcessLoginBatch();

    // Check if character is already online
    bool IsCharacterOnline(ObjectGuid::LowType guid);

    // Autonomy lifecycle
    bool IsUnderPlayerControl(Player* bot);
    void RestoreAutonomy(Player* bot);
    void ReconcileAutonomy();

    // Configuration
    bool enabled;
    uint32 startupDelay;
    uint32 loginBatchSize;
    uint32 loginBatchDelay;
    std::string guildIds;
    bool excludeRandomBotAccounts;
    bool includeOfflineOnly;

    // State
    bool initialized;
    bool loginStarted;
    time_t loginStartTime;
    time_t lastBatchTime;

    // Character lists
    std::vector<ObjectGuid::LowType> eligibleCharacters;
    std::unordered_set<ObjectGuid::LowType> guildMateGuids;
    std::unordered_set<uint32> excludedAccounts;
    uint32 loginQueueIndex;

    // Tracks bots currently under legitimate player control
    std::unordered_set<ObjectGuid::LowType> playerControlledBots;
};

#define sGuildMateMgr GuildMateMgr::instance()

#endif
