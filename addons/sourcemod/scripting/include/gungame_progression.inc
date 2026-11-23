#if defined _gungame_progression_included
  #endinput
#endif
#define _gungame_progression_included

/**
 * GunGame Progression API.
 * To check that the plugin is running, verify that the "gungame_progression" library exists.
 */

/**
 * Retrieves the total XP of a player.
 *
 * @param client        Client index.
 * @return              Total XP, 0 for bots, players without a Steam account ID
 *                      and players whose data is not loaded yet (see GGP_IsClientLoaded).
 * @error               Invalid client index or client not in game.
 */
native int GGP_GetClientXP(int client);

/**
 * Retrieves the rank of a player.
 *
 * @param client        Client index.
 * @return              Rank, from 1 to GGP_GetRankCount().
 * @error               Invalid client index or client not in game.
 */
native int GGP_GetClientRank(int client);

/**
 * Retrieves if the progression of a player is loaded from the database.
 *
 * @param client        Client index.
 * @return              True once the data is loaded, false for bots and players without a Steam account ID.
 * @error               Invalid client index or client not in game.
 */
native bool GGP_IsClientLoaded(int client);

/**
 * Retrieves the number of ranks defined in the config.
 *
 * @return              Number of ranks (at least 1).
 */
native int GGP_GetRankCount();

/**
 * Retrieves the name of a rank.
 *
 * @param rank          Rank, from 1 to GGP_GetRankCount().
 * @param buffer        Buffer to store the name in.
 * @param maxlen        Size of the buffer.
 * @return              True on success, false if the rank does not exist.
 */
native bool GGP_GetRankName(int rank, char[] buffer, int maxlen);

/**
 * Called when a player reaches a higher rank.
 * Not called when the data of a player is loaded.
 *
 * @param client        Client index.
 * @param oldRank       Previous rank.
 * @param newRank       New rank (newRank > oldRank, several ranks can be gained at once).
 */
forward void GGP_OnClientRankUp(int client, int oldRank, int newRank);

/* Do not edit the code below. */
public SharedPlugin __pl_gungame_progression =
{
    name = "gungame_progression",
    file = "GunGameProgression.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_gungame_progression_SetNTVOptional()
{
    MarkNativeAsOptional("GGP_GetClientXP");
    MarkNativeAsOptional("GGP_GetClientRank");
    MarkNativeAsOptional("GGP_IsClientLoaded");
    MarkNativeAsOptional("GGP_GetRankCount");
    MarkNativeAsOptional("GGP_GetRankName");
}
#endif
