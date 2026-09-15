#ifndef DEF_TRANSMOG_ADDON_PROTOCOL_H
#define DEF_TRANSMOG_ADDON_PROTOCOL_H

#include "Player.h"
#include <string>

namespace TransmogAddon
{
    constexpr char const* PREFIX = "transmog";

    void SendOpen(Player* player);

    void Dispatch(Player* player, std::string const& message);
}

#endif
