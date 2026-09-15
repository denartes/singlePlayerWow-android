#include "Transmog.h"
#include "TransmogAddonProtocol.h"
#include "Chat.h"
#include "ScriptedGossip.h"
#include <algorithm>
#include <vector>

namespace
{
    void AddMoneyPart(std::ostringstream& ss, bool& hasValue, uint32 value, char const* icon)
    {
        if (hasValue)
            ss << " ";

        ss << value << icon;
        hasValue = true;
    }

    std::string FormatMoney(WorldSession* session, uint32 copper)
    {
        if (copper == 0)
            return Tstr(session, LANG_TRANSMOG_FREE);

        uint32 gold = copper / 10000;
        uint32 silver = (copper % 10000) / 100;
        uint32 cop = copper % 100;

        std::ostringstream ss;
        bool hasValue = false;
        if (gold > 0)
            AddMoneyPart(ss, hasValue, gold, "|TInterface/MoneyFrame/UI-GoldIcon:14:14:2:0|t");
        if (silver > 0)
            AddMoneyPart(ss, hasValue, silver, "|TInterface/MoneyFrame/UI-SilverIcon:14:14:2:0|t");
        if (cop > 0 || (gold == 0 && silver == 0))
            AddMoneyPart(ss, hasValue, cop, "|TInterface/MoneyFrame/UI-CopperIcon:14:14:2:0|t");

        return ss.str();
    }
}

class npc_transmogrifier : public CreatureScript
{
public:
    npc_transmogrifier() : CreatureScript("npc_transmogrifier") { }

// Open the slot menu and keep the current selection in the Transmog state cache.
    bool OnGossipHello(Player* player, Creature* creature) override
    {
        WorldSession* session = player->GetSession();
        sTransmog->ClearSelection(player->GetGUID());

        TransmogAddon::SendOpen(player);

        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            std::string const slotName = Transmog::GetSlotName(slot);
            if (slotName.empty())
                continue;

            AddGossipItemFor(player, GOSSIP_ICON_MONEY_BAG, Transmog::GetSlotGossipIcon(player, slot) + slotName, MENU_SELECT_SLOT, slot);
        }

        AddGossipItemFor(player, GOSSIP_ICON_MONEY_BAG, "|TInterface/ICONS/INV_Enchant_Disenchant:30:30:-18:0|t" + Tstr(session, LANG_TRANSMOG_REMOVE_ALL), MENU_REMOVE_ALL, 0, Tstr(session, LANG_TRANSMOG_REMOVE_ALL_ASK), 0, false);
        SendGossipMenuFor(player, 601084, creature->GetGUID());
        return true;
    }

// Route menu actions through the same selection, removal, and apply paths.
    bool OnGossipSelect(Player* player, Creature* creature, uint32 sender, uint32 action) override
    {
        player->PlayerTalkClass->ClearMenus();
        WorldSession* session = player->GetSession();
        ObjectGuid guid = player->GetGUID();

        switch (sender)
        {
            case MENU_SELECT_SLOT:
                sTransmog->SetSelectedSlot(guid, action);
                ShowSourceList(player, creature, 0);
                break;
            case MENU_REMOVE_ALL:
                sTransmog->ClearAllSlots(player);
                sTransmog->RefreshAllSlots(player);
                ChatHandler(session).SendNotification(Tstr(session, LANG_TRANSMOG_ALL_REMOVED));
                OnGossipHello(player, creature);
                break;
            case MENU_HIDE_SLOT:
                ApplyAppearance(player, HIDDEN_ITEM_ID);
                ShowSourceList(player, creature, 0);
                break;
            case MENU_REMOVE_SLOT:
                sTransmog->SetSlotAppearance(player, sTransmog->GetSelectedSlot(guid), 0);
                sTransmog->RefreshSlot(player, sTransmog->GetSelectedSlot(guid));
                ChatHandler(session).SendNotification(Tstr(session, LANG_TRANSMOG_SLOT_REMOVED));
                ShowSourceList(player, creature, 0);
                break;
            case MENU_PAGE:
                ShowSourceList(player, creature, action);
                break;
            case MENU_APPLY:
                ApplyAppearance(player, action);
                ShowSourceList(player, creature, 0);
                break;
            case MENU_MAIN:
            default:
                OnGossipHello(player, creature);
                break;
        }

        return true;
    }

private:
// Display only compatible collected appearances for the selected equipped slot.
    void ShowSourceList(Player* player, Creature* creature, uint32 page)
    {
        WorldSession* session = player->GetSession();
        ObjectGuid guid = player->GetGUID();
        uint8 slot = sTransmog->GetSelectedSlot(guid);

        if (slot >= EQUIPMENT_SLOT_END)
        {
            OnGossipHello(player, creature);
            return;
        }

        Item* targetItem = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (!targetItem)
        {
            AddGossipItemFor(player, GOSSIP_ICON_CHAT, Tstr(session, LANG_TRANSMOG_EMPTY_SLOT), MENU_MAIN, 0);
            AddGossipItemFor(player, GOSSIP_ICON_MONEY_BAG, "|TInterface/ICONS/Ability_Spy:30:30:-18:0|t" + Tstr(session, LANG_TRANSMOG_BACK), MENU_MAIN, 0);
            SendGossipMenuFor(player, 601084, creature->GetGUID());
            return;
        }

        ItemTemplate const* targetTemplate = targetItem->GetTemplate();
        std::vector<ItemTemplate const*> appearances = Transmog::GetValidAppearances(player, targetTemplate);
        uint32 currentFake = sTransmog->GetSlotAppearance(guid, slot);

        uint32 totalPages = (appearances.size() + MAX_ITEMS_PER_PAGE - 1) / MAX_ITEMS_PER_PAGE;
        if (page >= totalPages && totalPages > 0)
            page = totalPages - 1;

        uint32 start = page * MAX_ITEMS_PER_PAGE;
        uint32 end = std::min(start + MAX_ITEMS_PER_PAGE, static_cast<uint32>(appearances.size()));
        uint32 cost = sTransmog->GetAppearanceCost(0);

        std::string headerIcon;
        if (currentFake == HIDDEN_ITEM_ID && TransmogRules_IsArmorSlot(slot))
            headerIcon = "|TInterface/ICONS/inv_misc_enggizmos_27:30:30:-18:0|t";
        else if (currentFake)
            headerIcon = Transmog::GetItemIcon(currentFake, 30, 30, -18, 0);
        else
            headerIcon = Transmog::GetItemIcon(targetItem->GetEntry(), 30, 30, -18, 0);

        AddGossipItemFor(player, GOSSIP_ICON_MONEY_BAG, headerIcon + Transmog::GetSlotName(slot), MENU_MAIN, 0);

        if (TransmogRules_IsArmorSlot(slot))
        {
            uint32 hideCost = sTransmog->GetAppearanceCost(HIDDEN_ITEM_ID);
            AddGossipItemFor(player, GOSSIP_ICON_MONEY_BAG, "|TInterface/ICONS/inv_misc_enggizmos_27:30:30:-18:0|t" + Tstr(session, LANG_TRANSMOG_HIDE_SLOT) + " |cff7f7f7f(" + FormatMoney(session, hideCost) + ")|r", MENU_HIDE_SLOT, 0, "", 0, false);
        }

        if (currentFake != 0)
            AddGossipItemFor(player, GOSSIP_ICON_MONEY_BAG, "|TInterface/ICONS/INV_Enchant_Disenchant:30:30:-18:0|t" + Tstr(session, LANG_TRANSMOG_REMOVE_SLOT), MENU_REMOVE_SLOT, 0, "", 0, false);

        if (appearances.empty())
        {
            AddGossipItemFor(player, GOSSIP_ICON_CHAT, Tstr(session, LANG_TRANSMOG_NO_APPEARANCES), MENU_MAIN, 0);
        }
        else
        {
            for (uint32 i = start; i < end; ++i)
            {
                ItemTemplate const* source = appearances[i];
                if (source->ItemId == currentFake)
                    continue;

                std::string text = Transmog::GetItemIcon(source->ItemId, 30, 30, -18, 0) + Transmog::GetItemLink(source->ItemId, session) + " |cff7f7f7f(" + FormatMoney(session, cost) + ")|r";
                AddGossipItemFor(player, GOSSIP_ICON_MONEY_BAG, text, MENU_APPLY, source->ItemId, "", cost, false);
            }
        }

        if (page > 0)
            AddGossipItemFor(player, GOSSIP_ICON_CHAT, Tstr(session, LANG_TRANSMOG_PREVIOUS_PAGE), MENU_PAGE, page - 1);

        if (end < appearances.size())
            AddGossipItemFor(player, GOSSIP_ICON_CHAT, Tstr(session, LANG_TRANSMOG_NEXT_PAGE), MENU_PAGE, page + 1);

        AddGossipItemFor(player, GOSSIP_ICON_MONEY_BAG, "|TInterface/ICONS/Ability_Spy:30:30:-18:0|t" + Tstr(session, LANG_TRANSMOG_BACK), MENU_MAIN, 0);
        SendGossipMenuFor(player, 601084, creature->GetGUID());
    }

// Translate the shared result into the notification expected by the gossip UI.
    void ApplyAppearance(Player* player, uint32 itemEntry)
    {
        WorldSession* session = player->GetSession();
        uint8 slot = sTransmog->GetSelectedSlot(player->GetGUID());
        TransmogApplyResult result = sTransmog->ApplyAppearance(player, slot, itemEntry);

        switch (result)
        {
            case TransmogApplyResult::Success:
                ChatHandler(session).SendNotification(itemEntry == HIDDEN_ITEM_ID ? Tstr(session, LANG_TRANSMOG_HIDDEN) : Tstr(session, LANG_TRANSMOG_OK));
                return;
            case TransmogApplyResult::EmptySlot:
                ChatHandler(session).SendNotification(Tstr(session, LANG_TRANSMOG_EMPTY_SLOT));
                return;
            case TransmogApplyResult::NotEnoughMoney:
                ChatHandler(session).SendNotification(Tstr(session, LANG_TRANSMOG_NO_MONEY));
                return;
            case TransmogApplyResult::InvalidAppearance:
                ChatHandler(session).SendNotification(Tstr(session, LANG_TRANSMOG_INVALID_SRC));
                return;
            case TransmogApplyResult::AlreadyApplied:
            case TransmogApplyResult::InvalidSlot:
                return;
        }
    }
};

void AddSC_TransmogGossip()
{
    new npc_transmogrifier();
}
