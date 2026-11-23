#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <multicolors>

// Every dependency is optional: without GunGame nobody earns XP (cosmetics still work),
// without VIP-Core there is no VIP multiplier
#undef REQUIRE_PLUGIN
#include <gungame>
#tryinclude <vip_core>
#include <gungame_progression>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION      "1.0.0"

#define CONFIG_FILE         "configs/gungame_progression.cfg"
#define CHAT_PREFIX         "{green}[GG]{default} "
#define SAVE_INTERVAL       60.0
#define ITEM_KEY_SIZE       32
#define RANK_NAME_SIZE      48
#define TAG_TEXT_SIZE       32
#define CHAT_TEXT_SIZE      256
// Source user messages carry at most 255 bytes
#define MAX_USERMSG_BYTES   255
#define XP_BAR_SIZE         20
#define TOP_COUNT           10
#define MAX_UNLOCK_LIST     160

#define TEAM_SPECTATOR      1
#define TEAM_T              2
#define TEAM_CT             3

// Stock CS:S materials (hl2/hl2_misc_dir.vpk + hl2_textures_dir.vpk), nothing to download
#define MAT_BEAM            "materials/sprites/laserbeam.vmt"
#define MAT_HALO            "materials/sprites/halo01.vmt"
#define MAT_LIGHTNING       "materials/sprites/lgtning.vmt"
#define MAT_GLOW            "materials/sprites/glow01.vmt"

enum
{
	Cat_Tags = 0,
	Cat_Trails,
	Cat_HEColors,
	Cat_KillEffects,
	Cat_Count
};

// Config sections and menu phrases, in the order of the categories above
static const char g_sCatSections[Cat_Count][] = { "tags", "trails", "he_colors", "kill_effects" };
static const char g_sCatPhrases[Cat_Count][] = { "Category Tags", "Category Trails", "Category HE", "Category Kill Effects" };

enum
{
	KillFx_Sparks = 0,
	KillFx_Energy,
	KillFx_Ring,
	KillFx_Lightning,
	KillFx_Confetti,
	KillFx_Glow,
	KillFx_Count
};

static const char g_sKillFxTypes[KillFx_Count][] = { "sparks", "energy", "ring", "lightning", "confetti", "glow" };

enum struct RankInfo
{
	char name[RANK_NAME_SIZE];
	int xp;
	char hex[8];
}

enum struct ItemInfo
{
	char key[ITEM_KEY_SIZE];
	char name[64];
	int rank;
	char text[TAG_TEXT_SIZE];       // tags
	char hex[8];                    // tags
	char material[PLATFORM_MAX_PATH]; // trails
	float startWidth;               // trails
	float endWidth;                 // trails
	float lifetime;                 // trails
	int fx;                         // kill_effects
	bool randomColor;               // kill_effects
	int color[4];
}

// One chat line waiting to be sent again with the tag (see Hook_SayText2)
enum struct PendingChat
{
	int author;
	bool chat;
	char msgName[64];
	char name[MAX_NAME_LENGTH + TAG_TEXT_SIZE + 16];
	char text[CHAT_TEXT_SIZE];
	char param3[64];
	char param4[64];
	int count;
	int recipients[MAXPLAYERS + 1];
}

ConVar g_cvEnable;
ConVar g_cvDatabase;
ConVar g_cvXPKill;
ConVar g_cvXPHeadshot;
ConVar g_cvXPKnifeSteal;
ConVar g_cvXPLevelUp;
ConVar g_cvXPWin;
ConVar g_cvXPPlace[3];
ConVar g_cvXPPlaytime;
ConVar g_cvXPParticipation;
ConVar g_cvParticipationTime;
ConVar g_cvVIPMultiplier;
ConVar g_cvChatTags;
ConVar g_cvTrails;
ConVar g_cvHEColors;
ConVar g_cvKillFx;
ConVar g_cvKillFxCooldown;
ConVar g_cvKillFxMax;
ConVar g_cvRankUpSound;
ConVar g_cvGGEnabled;

ArrayList g_aRanks;
ArrayList g_aItems[Cat_Count];
ArrayList g_aChatQueue;
bool g_bChatFlushQueued;

Database g_hDB;
bool g_bDBConnecting;
bool g_bDBErrorLogged;
bool g_bSaveErrorLogged;
bool g_bSQLite;
Handle g_hReconnectTimer;

GlobalForward g_fwdRankUp;

bool g_bLate;
bool g_bGunGame;
bool g_bCCC;
bool g_bVIP;

bool g_bMatchOver;
int g_iMatchOverTick;
bool g_bSummaryPending;

int g_iBeamModel;
int g_iHaloModel;
int g_iLightningModel;
int g_iGlowModel;

float g_fKillFxWindow;
int g_iKillFxCount;

// Per player
int g_iAccountId[MAXPLAYERS + 1];
int g_iXP[MAXPLAYERS + 1];
int g_iMatchXP[MAXPLAYERS + 1];
int g_iRank[MAXPLAYERS + 1];
bool g_bLoaded[MAXPLAYERS + 1];
bool g_bDirty[MAXPLAYERS + 1];
char g_sEquip[MAXPLAYERS + 1][Cat_Count][ITEM_KEY_SIZE];
int g_iTeamSeconds[MAXPLAYERS + 1];
int g_iMatchSeconds[MAXPLAYERS + 1];
float g_fNextKillFx[MAXPLAYERS + 1];
int g_iTrailRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
bool g_bMenuOpen[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "GunGame Progression",
	author = "Rushaway",
	description = "GunGame XP, ranks and cosmetic unlocks: chat tags, trails, HE grenade colors and kill effects",
	version = PLUGIN_VERSION,
	url = "https://github.com/srcdslab/sm-plugin-GunGameProgression"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("GGP_GetClientXP", Native_GetClientXP);
	CreateNative("GGP_GetClientRank", Native_GetClientRank);
	CreateNative("GGP_IsClientLoaded", Native_IsClientLoaded);
	CreateNative("GGP_GetRankCount", Native_GetRankCount);
	CreateNative("GGP_GetRankName", Native_GetRankName);

	RegPluginLibrary("gungame_progression");

	g_bLate = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("gungame_progression.phrases");

	g_cvEnable            = CreateConVar("sm_ggp_enable", "1", "Enable XP gains (cosmetics keep working when disabled).", _, true, 0.0, true, 1.0);
	g_cvDatabase          = CreateConVar("sm_ggp_database", "gungame", "databases.cfg entry used to store the progression (tables ggp_*).");
	g_cvXPKill            = CreateConVar("sm_ggp_xp_kill", "10", "XP for a kill (bots included).", _, true, 0.0);
	g_cvXPHeadshot        = CreateConVar("sm_ggp_xp_headshot", "5", "Extra XP when the kill is a headshot.", _, true, 0.0);
	g_cvXPKnifeSteal      = CreateConVar("sm_ggp_xp_knifesteal", "15", "Extra XP for a GunGame knife steal.", _, true, 0.0);
	g_cvXPLevelUp         = CreateConVar("sm_ggp_xp_levelup", "5", "XP per GunGame level gained by a kill or a knife steal (handicap levels give nothing).", _, true, 0.0);
	g_cvXPWin             = CreateConVar("sm_ggp_xp_win", "200", "XP for winning the match.", _, true, 0.0);
	g_cvXPPlace[0]        = CreateConVar("sm_ggp_xp_place1", "75", "XP for the 1st place at the end of the match (GunGame ranking, on top of the win XP).", _, true, 0.0);
	g_cvXPPlace[1]        = CreateConVar("sm_ggp_xp_place2", "50", "XP for the 2nd place at the end of the match.", _, true, 0.0);
	g_cvXPPlace[2]        = CreateConVar("sm_ggp_xp_place3", "25", "XP for the 3rd place at the end of the match.", _, true, 0.0);
	g_cvXPPlaytime        = CreateConVar("sm_ggp_xp_playtime", "5", "XP per full minute spent on T or CT during the match.", _, true, 0.0);
	g_cvXPParticipation   = CreateConVar("sm_ggp_xp_participation", "20", "XP at the end of the match for players on a team who played long enough.", _, true, 0.0);
	g_cvParticipationTime = CreateConVar("sm_ggp_participation_time", "180", "Seconds on T or CT during the match needed for the participation XP.", _, true, 0.0);
	g_cvVIPMultiplier     = CreateConVar("sm_ggp_vip_multiplier", "1.25", "XP multiplier for VIP players (VIP-Core), 1.0 = none.", _, true, 1.0, true, 5.0);
	g_cvChatTags          = CreateConVar("sm_ggp_chat_tags", "1", "Show the chosen tag before the name in chat (with CustomChatColors: needs CCC 8.2.0 or newer, see README).", _, true, 0.0, true, 1.0);
	g_cvTrails            = CreateConVar("sm_ggp_trails", "1", "Enable player trails.", _, true, 0.0, true, 1.0);
	g_cvHEColors          = CreateConVar("sm_ggp_he_colors", "1", "Enable HE grenade colors.", _, true, 0.0, true, 1.0);
	g_cvKillFx            = CreateConVar("sm_ggp_kill_effects", "1", "Enable kill effects.", _, true, 0.0, true, 1.0);
	g_cvKillFxCooldown    = CreateConVar("sm_ggp_kill_effects_cooldown", "2.0", "Seconds before the kill effect of the same player can play again.", _, true, 0.0, true, 60.0);
	g_cvKillFxMax         = CreateConVar("sm_ggp_kill_effects_max", "4", "Most kill effects played per second on the whole server.", _, true, 0.0, true, 32.0);
	g_cvRankUpSound       = CreateConVar("sm_ggp_rankup_sound", "items/gift_pickup.wav", "Sound played to a player who ranks up (stock sound, empty = none).");
	CreateConVar("sm_ggp_version", PLUGIN_VERSION, "GunGame Progression version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	AutoExecConfig(true);

	g_cvTrails.AddChangeHook(OnTrailsChanged);

	RegConsoleCmd("sm_xp", Command_Menu, "Show your GunGame rank, XP and cosmetics.");
	RegConsoleCmd("sm_progress", Command_Menu, "Show your GunGame rank, XP and cosmetics.");
	RegConsoleCmd("sm_cosmetics", Command_Menu, "Show your GunGame rank, XP and cosmetics.");
	RegConsoleCmd("sm_ggp_toprank", Command_TopRank, "Show the 10 players with the most XP.");
	RegAdminCmd("sm_ggp_givexp", Command_GiveXP, ADMFLAG_ROOT, "sm_ggp_givexp <target> <amount> - give (or remove) XP, for tests.");
	RegAdminCmd("sm_ggp_reload", Command_Reload, ADMFLAG_CONFIG, "Reload configs/gungame_progression.cfg.");

	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_team", Event_PlayerTeam);
	// Time limit end of match without a GunGame winner; not fatal if the game lacks it
	HookEventEx("cs_win_panel_match", Event_WinPanelMatch, EventHookMode_PostNoCopy);

	UserMsg msgSayText2 = GetUserMessageId("SayText2");
	if (msgSayText2 != INVALID_MESSAGE_ID && GetUserMessageType() == UM_BitBuf)
		HookUserMessage(msgSayText2, Hook_SayText2, true);

	g_fwdRankUp = new GlobalForward("GGP_OnClientRankUp", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	g_aChatQueue = new ArrayList(sizeof(PendingChat));

	LoadConfig();

	CreateTimer(1.0, Timer_Second, _, TIMER_REPEAT);
	CreateTimer(SAVE_INTERVAL, Timer_Save, _, TIMER_REPEAT);

	for (int client = 1; client <= MaxClients; client++)
		ResetClient(client);

	if (g_bLate)
	{
		PrecacheAssets();

		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsClientInGame(client) && IsClientAuthorized(client))
				OnClientPostAdminCheck(client);
		}
	}
}

public void OnPluginEnd()
{
	SaveClients(0, true);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;

		// SM 1.13 crashes when a plugin is unloaded with one of its menus open
		if (g_bMenuOpen[client])
			CancelClientMenu(client, true);

		RemoveTrail(client);
	}
}

public void OnAllPluginsLoaded()
{
	UpdateLibraries();
}

public void OnLibraryAdded(const char[] name)
{
	UpdateLibraries();
}

public void OnLibraryRemoved(const char[] name)
{
	UpdateLibraries();
}

void UpdateLibraries()
{
	// GG_IsMatchStarted is the newest native used here (srcdslab fork 2.0.x)
	g_bGunGame = LibraryExists("gungame") && GetFeatureStatus(FeatureType_Native, "GG_IsMatchStarted") == FeatureStatus_Available;
	g_bCCC = LibraryExists("ccc");
	g_bVIP = LibraryExists("vip_core") && GetFeatureStatus(FeatureType_Native, "VIP_IsClientVIP") == FeatureStatus_Available;
	g_cvGGEnabled = g_bGunGame ? FindConVar("gungame_enabled") : null;
}

public void OnConfigsExecuted()
{
	if (g_hDB == null)
		ConnectDatabase();
}

public void OnMapStart()
{
	PrecacheAssets();

	g_bMatchOver = false;
	g_bSummaryPending = false;

	for (int client = 1; client <= MaxClients; client++)
	{
		g_iMatchXP[client] = 0;
		g_iMatchSeconds[client] = 0;
		g_iTrailRef[client] = INVALID_ENT_REFERENCE;
	}

	delete g_aChatQueue;
	g_aChatQueue = new ArrayList(sizeof(PendingChat));
	g_bChatFlushQueued = false;
}

public void OnMapEnd()
{
	SaveClients(0, false);
}

void PrecacheAssets()
{
	g_iBeamModel = PrecacheModel(MAT_BEAM, true);
	g_iHaloModel = PrecacheModel(MAT_HALO, true);
	g_iLightningModel = PrecacheModel(MAT_LIGHTNING, true);
	g_iGlowModel = PrecacheModel(MAT_GLOW, true);

	ItemInfo item;
	for (int i = 0; i < g_aItems[Cat_Trails].Length; i++)
	{
		g_aItems[Cat_Trails].GetArray(i, item);
		PrecacheModel(item.material, true);
	}

	char sound[PLATFORM_MAX_PATH];
	g_cvRankUpSound.GetString(sound, sizeof(sound));
	if (sound[0])
		PrecacheSound(sound, true);
}

// ---------------------------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------------------------

void LoadConfig()
{
	delete g_aRanks;
	g_aRanks = new ArrayList(sizeof(RankInfo));
	for (int cat = 0; cat < Cat_Count; cat++)
	{
		delete g_aItems[cat];
		g_aItems[cat] = new ArrayList(sizeof(ItemInfo));
	}

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);

	KeyValues kv = new KeyValues("GunGameProgression");
	if (!kv.ImportFromFile(path))
	{
		LogError("Cannot read %s, only the default rank is available.", path);
		delete kv;
		AddFallbackRank();
		return;
	}

	if (kv.JumpToKey("ranks") && kv.GotoFirstSubKey())
	{
		do
		{
			RankInfo rank;
			char section[16];
			kv.GetSectionName(section, sizeof(section));
			kv.GetString("name", rank.name, sizeof(rank.name));
			rank.xp = kv.GetNum("xp", -1);
			if (!rank.name[0] || rank.xp < 0)
			{
				LogError("Rank \"%s\" skipped: \"name\" and \"xp\" (>= 0) are required.", section);
				continue;
			}

			int color[4] = { 255, 255, 255, 255 };
			ReadColor(kv, color);
			FormatEx(rank.hex, sizeof(rank.hex), "%02X%02X%02X", color[0], color[1], color[2]);
			g_aRanks.PushArray(rank);
		} while (kv.GotoNextKey());
	}
	kv.Rewind();

	if (g_aRanks.Length == 0)
		AddFallbackRank();

	g_aRanks.SortCustom(SortRanks);

	RankInfo first;
	g_aRanks.GetArray(0, first);
	if (first.xp != 0)
	{
		LogError("The lowest rank (\"%s\") needs %d XP, it is set to 0.", first.name, first.xp);
		first.xp = 0;
		g_aRanks.SetArray(0, first);
	}

	for (int cat = 0; cat < Cat_Count; cat++)
	{
		if (!kv.JumpToKey(g_sCatSections[cat]) || !kv.GotoFirstSubKey())
		{
			kv.Rewind();
			continue;
		}

		do
		{
			ItemInfo item;
			if (ReadItem(kv, cat, item))
				g_aItems[cat].PushArray(item);
		} while (kv.GotoNextKey());

		kv.Rewind();
	}

	delete kv;
}

void AddFallbackRank()
{
	RankInfo rank;
	strcopy(rank.name, sizeof(rank.name), "Recruit");
	strcopy(rank.hex, sizeof(rank.hex), "FFFFFF");
	g_aRanks.PushArray(rank);
}

int SortRanks(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList list = view_as<ArrayList>(array);
	RankInfo a, b;
	list.GetArray(index1, a);
	list.GetArray(index2, b);
	return a.xp - b.xp;
}

// "color" "R G B" (0-255 each); keeps the given default when the key is missing or invalid
void ReadColor(KeyValues kv, int color[4])
{
	char value[32];
	kv.GetString("color", value, sizeof(value));
	ParseColor(value, color);
}

bool ParseColor(const char[] value, int color[4])
{
	char parts[3][8];
	if (ExplodeString(value, " ", parts, sizeof(parts), sizeof(parts[])) != 3)
		return false;

	for (int i = 0; i < 3; i++)
	{
		int c = StringToInt(parts[i]);
		color[i] = c < 0 ? 0 : (c > 255 ? 255 : c);
	}
	color[3] = 255;
	return true;
}

bool ReadItem(KeyValues kv, int cat, ItemInfo item)
{
	kv.GetSectionName(item.key, sizeof(item.key));
	kv.GetString("name", item.name, sizeof(item.name));
	item.rank = kv.GetNum("rank", 0);
	for (int i = 0; i < 4; i++)
		item.color[i] = 255;

	// "", "none" and "rank:N" are the built-in choices of the tag menu
	if (!item.key[0] || StrEqual(item.key, "none", false) || StrContains(item.key, ":") != -1)
	{
		LogError("%s: item \"%s\" skipped, \"none\" and keys with ':' are reserved.", g_sCatSections[cat], item.key);
		return false;
	}

	if (item.rank < 1)
	{
		LogError("%s: item \"%s\" skipped, \"rank\" (>= 1) is required.", g_sCatSections[cat], item.key);
		return false;
	}

	if (item.rank > g_aRanks.Length)
		LogError("%s: item \"%s\" needs rank %d but only %d ranks exist.", g_sCatSections[cat], item.key, item.rank, g_aRanks.Length);

	if (!item.name[0])
		strcopy(item.name, sizeof(item.name), item.key);

	char value[32];
	kv.GetString("color", value, sizeof(value));

	switch (cat)
	{
		case Cat_Tags:
		{
			kv.GetString("text", item.text, sizeof(item.text));
			if (!item.text[0])
			{
				LogError("tags: item \"%s\" skipped, \"text\" is required.", item.key);
				return false;
			}
			ParseColor(value, item.color);
			FormatEx(item.hex, sizeof(item.hex), "%02X%02X%02X", item.color[0], item.color[1], item.color[2]);
		}
		case Cat_Trails:
		{
			kv.GetString("material", item.material, sizeof(item.material));
			int len = strlen(item.material);
			if (len < 5 || strcmp(item.material[len - 4], ".vmt", false) != 0)
			{
				LogError("trails: item \"%s\" skipped, \"material\" must be a .vmt path.", item.key);
				return false;
			}
			ParseColor(value, item.color);
			item.startWidth = ClampFloat(kv.GetFloat("width", 6.0), 1.0, 16.0);
			item.endWidth = ClampFloat(kv.GetFloat("end_width", 1.0), 0.0, 16.0);
			item.lifetime = ClampFloat(kv.GetFloat("lifetime", 1.0), 0.1, 3.0);
		}
		case Cat_HEColors:
		{
			if (!ParseColor(value, item.color))
			{
				LogError("he_colors: item \"%s\" skipped, \"color\" \"R G B\" is required.", item.key);
				return false;
			}
		}
		case Cat_KillEffects:
		{
			char type[16];
			kv.GetString("type", type, sizeof(type));
			item.fx = -1;
			for (int i = 0; i < KillFx_Count; i++)
			{
				if (StrEqual(type, g_sKillFxTypes[i], false))
				{
					item.fx = i;
					break;
				}
			}
			if (item.fx == -1)
			{
				LogError("kill_effects: item \"%s\" skipped, unknown \"type\" \"%s\".", item.key, type);
				return false;
			}
			item.randomColor = StrEqual(value, "random", false);
			if (!item.randomColor)
				ParseColor(value, item.color);
		}
	}

	return true;
}

float ClampFloat(float value, float min, float max)
{
	return value < min ? min : (value > max ? max : value);
}

// ---------------------------------------------------------------------------------------------
// Ranks and XP
// ---------------------------------------------------------------------------------------------

int GetRankForXP(int xp)
{
	int rank = 1;
	RankInfo info;
	for (int i = 1; i < g_aRanks.Length; i++)
	{
		g_aRanks.GetArray(i, info);
		if (xp < info.xp)
			break;
		rank = i + 1;
	}
	return rank;
}

void GetRank(int rank, RankInfo info)
{
	g_aRanks.GetArray(rank - 1, info);
}

bool XPAllowed()
{
	if (!g_cvEnable.BoolValue || !g_bGunGame || g_cvGGEnabled == null || !g_cvGGEnabled.BoolValue)
		return false;

	// The winning kill can be handled after GG_OnWinner in the same tick
	if (g_bMatchOver && GetGameTickCount() != g_iMatchOverTick)
		return false;

	return !GG_IsWarmupInProgress() && GG_IsMatchStarted();
}

bool CanEarn(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client) && g_iAccountId[client] != 0;
}

bool IsVIP(int client)
{
#if defined _vip_core_included
	return g_bVIP && VIP_IsClientVIP(client);
#else
	return false;
#endif
}

void GiveXP(int client, int amount)
{
	if (amount <= 0)
		return;

	if (IsVIP(client))
		amount = RoundToNearest(float(amount) * g_cvVIPMultiplier.FloatValue);

	g_iMatchXP[client] += amount;
	AddXP(client, amount);
}

void AddXP(int client, int amount)
{
	g_iXP[client] += amount;
	if (g_iXP[client] < 0)
		g_iXP[client] = 0;

	g_bDirty[client] = true;
	UpdateRank(client, g_bLoaded[client]);
}

void UpdateRank(int client, bool announce)
{
	int oldRank = g_iRank[client];
	int newRank = GetRankForXP(g_iXP[client]);
	g_iRank[client] = newRank;

	if (!announce || newRank <= oldRank)
		return;

	RankInfo info;
	GetRank(newRank, info);

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != client && IsClientInGame(i) && !IsFakeClient(i))
			CPrintToChat(i, "%s%t", CHAT_PREFIX, "Rank Up All", name, info.name);
	}
	CPrintToChat(client, "%s%t", CHAT_PREFIX, "Rank Up Self", info.name, newRank, g_aRanks.Length);

	char unlocks[MAX_UNLOCK_LIST];
	if (BuildUnlockList(oldRank, newRank, unlocks, sizeof(unlocks)))
		CPrintToChat(client, "%s%t", CHAT_PREFIX, "Rank Up Unlocks", unlocks);

	char sound[PLATFORM_MAX_PATH];
	g_cvRankUpSound.GetString(sound, sizeof(sound));
	if (sound[0] && PrecacheSound(sound, true))
		EmitSoundToClient(client, sound);

	Call_StartForward(g_fwdRankUp);
	Call_PushCell(client);
	Call_PushCell(oldRank);
	Call_PushCell(newRank);
	Call_Finish();
}

// Names of the items unlocked by the ranks in ]oldRank, newRank]
bool BuildUnlockList(int oldRank, int newRank, char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	ItemInfo item;
	for (int cat = 0; cat < Cat_Count; cat++)
	{
		for (int i = 0; i < g_aItems[cat].Length; i++)
		{
			g_aItems[cat].GetArray(i, item);
			if (item.rank <= oldRank || item.rank > newRank)
				continue;

			if (buffer[0])
				StrCat(buffer, maxlen, ", ");
			StrCat(buffer, maxlen, item.name);
		}
	}
	return buffer[0] != '\0';
}

// Lowest rank item above the given rank; false when everything is unlocked
bool FindNextUnlock(int rank, int &bestCat, ItemInfo best)
{
	bestCat = -1;
	ItemInfo item;
	for (int cat = 0; cat < Cat_Count; cat++)
	{
		for (int i = 0; i < g_aItems[cat].Length; i++)
		{
			g_aItems[cat].GetArray(i, item);
			if (item.rank > rank && (bestCat == -1 || item.rank < best.rank))
			{
				bestCat = cat;
				best = item;
			}
		}
	}
	return bestCat != -1;
}

// ---------------------------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------------------------

void ResetClient(int client)
{
	g_iAccountId[client] = 0;
	g_iXP[client] = 0;
	g_iMatchXP[client] = 0;
	g_iRank[client] = 1;
	g_bLoaded[client] = false;
	g_bDirty[client] = false;
	for (int cat = 0; cat < Cat_Count; cat++)
		g_sEquip[client][cat][0] = '\0';
	g_iTeamSeconds[client] = 0;
	g_iMatchSeconds[client] = 0;
	g_fNextKillFx[client] = 0.0;
	g_bMenuOpen[client] = false;
}

public void OnClientConnected(int client)
{
	ResetClient(client);
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
		return;

	// Clients without a Steam account ID (some NoSteam clients) have no progression
	g_iAccountId[client] = GetSteamAccountID(client);
	if (g_iAccountId[client] != 0)
		LoadClient(client);
}

public void OnClientDisconnect(int client)
{
	if (g_bLoaded[client])
		SaveClients(client, true);

	RemoveTrail(client);
	ResetClient(client);
}

// ---------------------------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------------------------

void ConnectDatabase()
{
	if (g_bDBConnecting)
		return;

	char name[64];
	g_cvDatabase.GetString(name, sizeof(name));
	if (!SQL_CheckConfig(name))
	{
		if (!g_bDBErrorLogged)
			LogError("databases.cfg has no \"%s\" entry (sm_ggp_database): progression is not saved.", name);
		g_bDBErrorLogged = true;
		return;
	}

	g_bDBConnecting = true;
	Database.Connect(OnDatabaseConnect, name);
}

public void OnDatabaseConnect(Database db, const char[] error, any data)
{
	g_bDBConnecting = false;

	if (db == null)
	{
		// Logged once per outage, retried quietly every minute
		if (!g_bDBErrorLogged)
			LogError("Database connection failed, retrying every minute: %s", error);
		g_bDBErrorLogged = true;

		if (g_hReconnectTimer == null)
			g_hReconnectTimer = CreateTimer(60.0, Timer_Reconnect);
		return;
	}

	if (g_hDB != null)
	{
		delete db;
		return;
	}

	g_hDB = db;
	g_bDBErrorLogged = false;
	g_hDB.SetCharset("utf8mb4");

	char driver[16];
	g_hDB.Driver.GetIdentifier(driver, sizeof(driver));
	g_bSQLite = StrEqual(driver, "sqlite");

	Transaction txn = new Transaction();
	if (g_bSQLite)
	{
		txn.AddQuery("CREATE TABLE IF NOT EXISTS ggp_players (account_id INTEGER PRIMARY KEY, name VARCHAR(128) NOT NULL DEFAULT '', xp INTEGER NOT NULL DEFAULT 0, tag VARCHAR(32) NOT NULL DEFAULT '', trail VARCHAR(32) NOT NULL DEFAULT '', he_color VARCHAR(32) NOT NULL DEFAULT '', kill_effect VARCHAR(32) NOT NULL DEFAULT '', last_seen INTEGER NOT NULL DEFAULT 0)");
		txn.AddQuery("CREATE INDEX IF NOT EXISTS ggp_players_xp ON ggp_players (xp)");
	}
	else
	{
		txn.AddQuery("CREATE TABLE IF NOT EXISTS ggp_players (account_id INT NOT NULL PRIMARY KEY, name VARCHAR(128) NOT NULL DEFAULT '', xp INT NOT NULL DEFAULT 0, tag VARCHAR(32) NOT NULL DEFAULT '', trail VARCHAR(32) NOT NULL DEFAULT '', he_color VARCHAR(32) NOT NULL DEFAULT '', kill_effect VARCHAR(32) NOT NULL DEFAULT '', last_seen INT NOT NULL DEFAULT 0, INDEX ggp_players_xp (xp)) DEFAULT CHARSET=utf8mb4");
	}
	g_hDB.Execute(txn, OnTablesReady, OnTablesFailed);
}

public Action Timer_Reconnect(Handle timer)
{
	g_hReconnectTimer = null;
	if (g_hDB == null)
		ConnectDatabase();
	return Plugin_Stop;
}

public void OnTablesReady(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && g_iAccountId[client] != 0 && !g_bLoaded[client])
			LoadClient(client);
	}
}

public void OnTablesFailed(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("Cannot create the ggp_players table: %s", error);
}

void LoadClient(int client)
{
	if (g_hDB == null || g_bLoaded[client] || g_iAccountId[client] == 0)
		return;

	char query[256];
	FormatEx(query, sizeof(query), "SELECT xp, tag, trail, he_color, kill_effect FROM ggp_players WHERE account_id = %d", g_iAccountId[client]);
	g_hDB.Query(OnClientLoaded, query, GetClientUserId(client));
}

public void OnClientLoaded(Database db, DBResultSet results, const char[] error, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || g_bLoaded[client])
		return;

	if (results == null)
	{
		LogError("Cannot load the progression of %L: %s", client, error);
		return;
	}

	if (results.FetchRow())
	{
		// XP earned while the query was running is kept
		g_iXP[client] += results.FetchInt(0);
		for (int cat = 0; cat < Cat_Count; cat++)
			results.FetchString(cat + 1, g_sEquip[client][cat], sizeof(g_sEquip[][]));
	}
	else
	{
		// New player: the row is created by the next save
		g_bDirty[client] = true;
	}

	g_bLoaded[client] = true;
	UpdateRank(client, false);

	if (IsPlayerAlive(client))
		CreateTrail(client);
}

// target 0 = every loaded player; force also saves players without changes (name, last_seen)
void SaveClients(int target, bool force)
{
	if (g_hDB == null)
		return;

	Transaction txn = new Transaction();
	int queries = 0;
	int now = GetTime();
	char query[1024];
	char name[MAX_NAME_LENGTH];

	for (int client = 1; client <= MaxClients; client++)
	{
		if (target != 0 && client != target)
			continue;
		if (!g_bLoaded[client] || !IsClientInGame(client) || (!force && !g_bDirty[client]))
			continue;

		GetClientName(client, name, sizeof(name));

		FormatEx(query, sizeof(query), "INSERT %s INTO ggp_players (account_id) VALUES (%d)", g_bSQLite ? "OR IGNORE" : "IGNORE", g_iAccountId[client]);
		txn.AddQuery(query);

		g_hDB.Format(query, sizeof(query), "UPDATE ggp_players SET name = '%s', xp = %d, tag = '%s', trail = '%s', he_color = '%s', kill_effect = '%s', last_seen = %d WHERE account_id = %d",
			name, g_iXP[client], g_sEquip[client][Cat_Tags], g_sEquip[client][Cat_Trails], g_sEquip[client][Cat_HEColors], g_sEquip[client][Cat_KillEffects], now, g_iAccountId[client]);
		txn.AddQuery(query);

		g_bDirty[client] = false;
		queries += 2;
	}

	if (queries == 0)
	{
		delete txn;
		return;
	}

	g_hDB.Execute(txn, OnSaveDone, OnSaveFailed);
}

public void OnSaveDone(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	g_bSaveErrorLogged = false;
}

public void OnSaveFailed(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	// Logged once until a save works again
	if (!g_bSaveErrorLogged)
		LogError("Cannot save the progression: %s", error);
	g_bSaveErrorLogged = true;
}

public Action Timer_Save(Handle timer)
{
	SaveClients(0, false);
	return Plugin_Continue;
}

// ---------------------------------------------------------------------------------------------
// XP sources
// ---------------------------------------------------------------------------------------------

public Action Timer_Second(Handle timer)
{
	if (!XPAllowed())
		return Plugin_Continue;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!CanEarn(client))
			continue;

		int team = GetClientTeam(client);
		if (team != TEAM_T && team != TEAM_CT)
			continue;

		g_iMatchSeconds[client]++;
		if (++g_iTeamSeconds[client] >= 60)
		{
			g_iTeamSeconds[client] -= 60;
			GiveXP(client, g_cvXPPlaytime.IntValue);
		}
	}
	return Plugin_Continue;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (victim != 0)
		RemoveTrail(victim);

	if (victim == 0 || attacker == 0 || attacker == victim || !IsClientInGame(attacker) || IsFakeClient(attacker))
		return;

	PlayKillEffect(attacker, victim);

	if (!CanEarn(attacker) || !XPAllowed())
		return;

	// Team kills only count in FFA
	if (GetClientTeam(attacker) == GetClientTeam(victim) && !GG_IsFFA())
		return;

	int xp = g_cvXPKill.IntValue;
	if (event.GetBool("headshot"))
		xp += g_cvXPHeadshot.IntValue;
	GiveXP(attacker, xp);
}

public void GG_OnKnifeSteal(int killer, int victim, int killerLevel, int victimLevel, bool victimLost)
{
	if (CanEarn(killer) && XPAllowed())
		GiveXP(killer, g_cvXPKnifeSteal.IntValue);
}

public void GG_OnClientLevelChanged(int client, int oldLevel, int newLevel, const char[] weapon, GGLevelReason reason)
{
	// Handicap, reconnect, admin and native levels give nothing
	if (newLevel <= oldLevel || (reason != GGLevelReason_Kill && reason != GGLevelReason_KnifeSteal))
		return;

	if (CanEarn(client) && XPAllowed())
		GiveXP(client, g_cvXPLevelUp.IntValue * (newLevel - oldLevel));
}

public void GG_OnMatchStart()
{
	g_bMatchOver = false;
	g_bSummaryPending = false;

	for (int client = 1; client <= MaxClients; client++)
	{
		g_iMatchXP[client] = 0;
		g_iMatchSeconds[client] = 0;
	}
}

public void GG_OnWinner(int client, const char[] weapon, int victim)
{
	FinishMatch(client);
}

public void Event_WinPanelMatch(Event event, const char[] name, bool dontBroadcast)
{
	// Time limit: the match ends without a GunGame winner (bots cannot win on our server)
	FinishMatch(0);
}

void FinishMatch(int winner)
{
	if (g_bMatchOver)
		return;

	bool allowed = XPAllowed();
	g_bMatchOver = true;
	g_iMatchOverTick = GetGameTickCount();

	if (!allowed)
		return;

	if (winner != 0 && CanEarn(winner))
		GiveXP(winner, g_cvXPWin.IntValue);

	// Placement by GunGame level among everyone, bots included
	int[] ranking = new int[MaxClients];
	int count = GG_GetRanking(ranking, MaxClients);
	for (int i = 0; i < count && i < sizeof(g_cvXPPlace); i++)
	{
		if (CanEarn(ranking[i]))
			GiveXP(ranking[i], g_cvXPPlace[i].IntValue);
	}

	int minSeconds = g_cvParticipationTime.IntValue;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!CanEarn(client))
			continue;

		int team = GetClientTeam(client);
		if ((team == TEAM_T || team == TEAM_CT) && g_iMatchSeconds[client] >= minSeconds)
			GiveXP(client, g_cvXPParticipation.IntValue);
	}

	SaveClients(0, false);

	g_bSummaryPending = true;
	CreateTimer(2.0, Timer_MatchSummary, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_MatchSummary(Handle timer)
{
	if (!g_bSummaryPending)
		return Plugin_Stop;
	g_bSummaryPending = false;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!g_bLoaded[client] || !IsClientInGame(client))
			continue;

		RankInfo rank;
		GetRank(g_iRank[client], rank);

		if (g_iRank[client] < g_aRanks.Length)
		{
			RankInfo next;
			GetRank(g_iRank[client] + 1, next);
			CPrintToChat(client, "%s%t", CHAT_PREFIX, "Match Summary", g_iMatchXP[client], rank.name, next.xp - g_iXP[client]);
		}
		else
		{
			CPrintToChat(client, "%s%t", CHAT_PREFIX, "Match Summary Max", g_iMatchXP[client], rank.name);
		}

		int cat;
		ItemInfo item;
		if (FindNextUnlock(g_iRank[client], cat, item))
		{
			RankInfo needed;
			GetRank(item.rank <= g_aRanks.Length ? item.rank : g_aRanks.Length, needed);
			char category[64];
			FormatEx(category, sizeof(category), "%T", g_sCatPhrases[cat], client);
			CPrintToChat(client, "%s%t", CHAT_PREFIX, "Next Unlock", item.name, category, needed.name);
		}
	}
	return Plugin_Stop;
}

// ---------------------------------------------------------------------------------------------
// Equipped items
// ---------------------------------------------------------------------------------------------

int FindItem(int cat, const char[] key)
{
	if (!key[0])
		return -1;

	ItemInfo item;
	for (int i = 0; i < g_aItems[cat].Length; i++)
	{
		g_aItems[cat].GetArray(i, item);
		if (StrEqual(item.key, key))
			return i;
	}
	return -1;
}

// Equipped and still unlocked item of a category, -1 if none
int GetEquippedItem(int client, int cat, ItemInfo item)
{
	if (!g_bLoaded[client])
		return -1;

	int index = FindItem(cat, g_sEquip[client][cat]);
	if (index == -1)
		return -1;

	g_aItems[cat].GetArray(index, item);
	return item.rank <= g_iRank[client] ? index : -1;
}

// Chat tag of a player: "" = current rank, "none", "rank:N" = an older rank, or a tag item
bool GetChatTag(int client, char[] text, int textLen, char[] hex, int hexLen)
{
	if (!g_bLoaded[client] || StrEqual(g_sEquip[client][Cat_Tags], "none"))
		return false;

	int rankNum = g_iRank[client];
	if (!strncmp(g_sEquip[client][Cat_Tags], "rank:", 5))
	{
		int wanted = StringToInt(g_sEquip[client][Cat_Tags][5]);
		if (wanted >= 1 && wanted <= g_iRank[client])
			rankNum = wanted;
	}
	else if (g_sEquip[client][Cat_Tags][0])
	{
		ItemInfo item;
		if (GetEquippedItem(client, Cat_Tags, item) != -1)
		{
			strcopy(text, textLen, item.text);
			strcopy(hex, hexLen, item.hex);
			return true;
		}
	}

	RankInfo rank;
	GetRank(rankNum, rank);
	strcopy(text, textLen, rank.name);
	strcopy(hex, hexLen, rank.hex);
	return true;
}

void GetEquippedName(int client, int cat, char[] buffer, int maxlen)
{
	if (cat == Cat_Tags)
	{
		if (!g_sEquip[client][cat][0])
		{
			FormatEx(buffer, maxlen, "%T", "Item Auto Rank", client);
			return;
		}
		if (StrEqual(g_sEquip[client][cat], "none"))
		{
			FormatEx(buffer, maxlen, "%T", "Item None", client);
			return;
		}
		if (!strncmp(g_sEquip[client][cat], "rank:", 5))
		{
			int wanted = StringToInt(g_sEquip[client][cat][5]);
			RankInfo rank;
			GetRank(wanted >= 1 && wanted <= g_iRank[client] ? wanted : g_iRank[client], rank);
			strcopy(buffer, maxlen, rank.name);
			return;
		}
	}

	ItemInfo item;
	if (GetEquippedItem(client, cat, item) != -1)
		strcopy(buffer, maxlen, item.name);
	else if (cat == Cat_Tags)
		FormatEx(buffer, maxlen, "%T", "Item Auto Rank", client);
	else
		FormatEx(buffer, maxlen, "%T", "Item None", client);
}

// ---------------------------------------------------------------------------------------------
// Chat tags
// ---------------------------------------------------------------------------------------------

// With CustomChatColors 8.2.0 or newer, CCC asks for a prefix while it builds the sender name of
// every chat line (any author, CCC flags or not): the tag goes there, before the CCC tag.
public void CCC_OnSenderPrefix(int client, char[] prefix, int maxlen)
{
	if (!g_cvChatTags.BoolValue || client < 1 || client > MaxClients || IsFakeClient(client))
		return;

	char tag[TAG_TEXT_SIZE], hex[8];
	if (!GetChatTag(client, tag, sizeof(tag), hex, sizeof(hex)))
		return;

	// Raw color byte: CCC colors the rest of the line itself
	FormatEx(prefix, maxlen, "\x07%s[%s] ", hex, tag);
}

// CS:S sends one SayText2 per recipient while the say command runs. Without CustomChatColors,
// the messages of players with a tag are blocked here and sent again on the next frame with the
// same recipients, message name and parameters, only the name parameter gets the tag. CustomChatColors
// already blocks and rebuilds every chat line (with USERMSG_BLOCKHOOKS), so doing it too would
// print each line twice: with CCC loaded the plugin leaves chat alone (see README).
public Action Hook_SayText2(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	if (init || g_bCCC || !g_cvChatTags.BoolValue)
		return Plugin_Continue;

	int author = msg.ReadByte();
	if (author < 1 || author > MaxClients || !IsClientInGame(author) || IsFakeClient(author))
		return Plugin_Continue;

	bool chat = view_as<bool>(msg.ReadByte());

	char msgName[64];
	msg.ReadString(msgName, sizeof(msgName), false);
	if (strncmp(msgName, "#Cstrike_Chat_", 14) != 0)
		return Plugin_Continue;

	char tag[TAG_TEXT_SIZE], hex[8];
	if (!GetChatTag(author, tag, sizeof(tag), hex, sizeof(hex)))
		return Plugin_Continue;

	char name[MAX_NAME_LENGTH], text[CHAT_TEXT_SIZE];
	msg.ReadString(name, sizeof(name), false);
	msg.ReadString(text, sizeof(text), false);
	// %s3 is the place name in some team chat messages
	char param3[64], param4[64];
	msg.ReadString(param3, sizeof(param3), false);
	msg.ReadString(param4, sizeof(param4), false);

	// The client message starts with \x03 (team color) before the name parameter
	char taggedName[MAX_NAME_LENGTH + TAG_TEXT_SIZE + 16];
	FormatEx(taggedName, sizeof(taggedName), "\x07%s[%s]\x03 %s", hex, tag, name);

	// Bytes: author, chat, 4 strings and their terminators. The tag makes the message longer
	// than the one of the game, so cut the text (at a UTF-8 boundary) if it would not fit.
	int room = MAX_USERMSG_BYTES - 2 - (strlen(msgName) + 1) - (strlen(taggedName) + 1) - (strlen(param3) + 1) - (strlen(param4) + 1) - 1;
	if (room < 0)
		return Plugin_Continue;
	int len = strlen(text);
	if (len > room)
	{
		len = room;
		while (len > 0 && (text[len] & 0xC0) == 0x80)
			len--;
		text[len] = '\0';
	}

	// Same line as a queued one (the next recipient of the same message): add the recipients
	PendingChat pending;
	int index = -1;
	for (int i = g_aChatQueue.Length - 1; i >= 0; i--)
	{
		g_aChatQueue.GetArray(i, pending);
		if (pending.author == author && pending.chat == chat && StrEqual(pending.msgName, msgName) && StrEqual(pending.text, text))
		{
			index = i;
			break;
		}
	}

	if (index == -1)
	{
		pending.author = author;
		pending.chat = chat;
		strcopy(pending.msgName, sizeof(pending.msgName), msgName);
		strcopy(pending.name, sizeof(pending.name), taggedName);
		strcopy(pending.text, sizeof(pending.text), text);
		strcopy(pending.param3, sizeof(pending.param3), param3);
		strcopy(pending.param4, sizeof(pending.param4), param4);
		pending.count = 0;
	}

	for (int i = 0; i < playersNum && pending.count < sizeof(pending.recipients); i++)
		pending.recipients[pending.count++] = players[i];

	if (index == -1)
		g_aChatQueue.PushArray(pending);
	else
		g_aChatQueue.SetArray(index, pending);

	// A user message cannot be started from a user message hook
	if (!g_bChatFlushQueued)
	{
		g_bChatFlushQueued = true;
		RequestFrame(Frame_FlushChat);
	}
	return Plugin_Handled;
}

public void Frame_FlushChat(any data)
{
	g_bChatFlushQueued = false;

	PendingChat pending;
	int[] clients = new int[MaxClients];
	for (int i = 0; i < g_aChatQueue.Length; i++)
	{
		g_aChatQueue.GetArray(i, pending);

		int count = 0;
		for (int j = 0; j < pending.count; j++)
		{
			int client = pending.recipients[j];
			if (client >= 1 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client) && count < MaxClients)
				clients[count++] = client;
		}
		if (count == 0)
			continue;

		BfWrite bf = UserMessageToBfWrite(StartMessage("SayText2", clients, count, USERMSG_RELIABLE | USERMSG_BLOCKHOOKS));
		bf.WriteByte(pending.author);
		bf.WriteByte(pending.chat ? 1 : 0);
		bf.WriteString(pending.msgName);
		bf.WriteString(pending.name);
		bf.WriteString(pending.text);
		bf.WriteString(pending.param3);
		bf.WriteString(pending.param4);
		EndMessage();
	}

	delete g_aChatQueue;
	g_aChatQueue = new ArrayList(sizeof(PendingChat));
}

// ---------------------------------------------------------------------------------------------
// Trails
// ---------------------------------------------------------------------------------------------

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client != 0 && !IsFakeClient(client))
		CreateTimer(0.1, Timer_SpawnTrail, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SpawnTrail(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0)
		CreateTrail(client);
	return Plugin_Stop;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client != 0)
		RemoveTrail(client);
}

void OnTrailsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client))
			CreateTrail(client);
	}
}

// (Re)creates the trail of a player, or only removes it when he should not have one
void CreateTrail(int client)
{
	RemoveTrail(client);

	// Living players on a team only: never for spectators or dead players
	if (!g_cvTrails.BoolValue || !IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) < TEAM_T)
		return;

	ItemInfo item;
	if (GetEquippedItem(client, Cat_Trails, item) == -1)
		return;

	int entity = CreateEntityByName("env_spritetrail");
	if (entity == -1)
		return;

	char color[16];
	FormatEx(color, sizeof(color), "%d %d %d", item.color[0], item.color[1], item.color[2]);

	PrecacheModel(item.material, true);
	DispatchKeyValue(entity, "spritename", item.material);
	DispatchKeyValueFloat(entity, "lifetime", item.lifetime);
	DispatchKeyValueFloat(entity, "startwidth", item.startWidth);
	DispatchKeyValueFloat(entity, "endwidth", item.endWidth);
	DispatchKeyValue(entity, "rendermode", "5");
	DispatchKeyValue(entity, "renderamt", "255");
	DispatchKeyValue(entity, "rendercolor", color);
	DispatchSpawn(entity);

	float origin[3];
	GetClientAbsOrigin(client, origin);
	origin[2] += 10.0;
	TeleportEntity(entity, origin, NULL_VECTOR, NULL_VECTOR);

	SetVariantString("!activator");
	AcceptEntityInput(entity, "SetParent", client);

	if (HasEntProp(entity, Prop_Send, "m_flTextureRes"))
		SetEntPropFloat(entity, Prop_Send, "m_flTextureRes", 0.05);

	g_iTrailRef[client] = EntIndexToEntRef(entity);
}

void RemoveTrail(int client)
{
	int entity = EntRefToEntIndex(g_iTrailRef[client]);
	if (entity != INVALID_ENT_REFERENCE)
		RemoveEntity(entity);
	g_iTrailRef[client] = INVALID_ENT_REFERENCE;
}

// ---------------------------------------------------------------------------------------------
// HE grenade colors
// ---------------------------------------------------------------------------------------------

public void OnEntityCreated(int entity, const char[] classname)
{
	if (g_cvHEColors.BoolValue && StrEqual(classname, "hegrenade_projectile"))
		RequestFrame(Frame_ColorGrenade, EntIndexToEntRef(entity));
}

// Next frame: the thrower is set after the projectile spawned
public void Frame_ColorGrenade(any ref)
{
	int entity = EntRefToEntIndex(ref);
	if (entity == INVALID_ENT_REFERENCE)
		return;

	int thrower = -1;
	if (HasEntProp(entity, Prop_Send, "m_hThrower"))
		thrower = GetEntPropEnt(entity, Prop_Send, "m_hThrower");
	if (thrower <= 0)
		thrower = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	if (thrower < 1 || thrower > MaxClients || !IsClientInGame(thrower) || IsFakeClient(thrower))
		return;

	ItemInfo item;
	if (GetEquippedItem(thrower, Cat_HEColors, item) == -1)
		return;

	SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
	SetEntityRenderColor(entity, item.color[0], item.color[1], item.color[2], 255);

	TE_SetupBeamFollow(entity, g_iBeamModel, 0, 1.0, 3.0, 1.0, 1, item.color);
	TE_SendToAll();
}

// ---------------------------------------------------------------------------------------------
// Kill effects
// ---------------------------------------------------------------------------------------------

void PlayKillEffect(int attacker, int victim)
{
	if (!g_cvKillFx.BoolValue)
		return;

	ItemInfo item;
	if (GetEquippedItem(attacker, Cat_KillEffects, item) == -1)
		return;

	// GetEngineTime keeps running across map changes, unlike GetGameTime
	float now = GetEngineTime();
	if (now < g_fNextKillFx[attacker])
		return;

	if (now - g_fKillFxWindow >= 1.0)
	{
		g_fKillFxWindow = now;
		g_iKillFxCount = 0;
	}
	if (g_iKillFxCount >= g_cvKillFxMax.IntValue)
		return;

	g_iKillFxCount++;
	g_fNextKillFx[attacker] = now + g_cvKillFxCooldown.FloatValue;

	float pos[3];
	GetClientAbsOrigin(victim, pos);

	int color[4];
	color = item.color;
	if (item.randomColor)
		RandomColor(color);

	float up[3] = { 0.0, 0.0, 1.0 };
	float center[3];
	center = pos;
	center[2] += 40.0;

	switch (item.fx)
	{
		case KillFx_Sparks:
		{
			TE_SetupSparks(center, up, 8, 3);
			TE_SendToAllInRange(center, RangeType_Visibility);
			TE_SetupMetalSparks(center, up);
			TE_SendToAllInRange(center, RangeType_Visibility);
		}
		case KillFx_Energy:
		{
			TE_SetupEnergySplash(center, up, false);
			TE_SendToAllInRange(center, RangeType_Visibility);
		}
		case KillFx_Ring:
		{
			float ground[3];
			ground = pos;
			ground[2] += 8.0;
			TE_SetupBeamRingPoint(ground, 10.0, 150.0, g_iBeamModel, g_iHaloModel, 0, 15, 0.6, 6.0, 0.0, color, 10, 0);
			TE_SendToAllInRange(ground, RangeType_Visibility);
		}
		case KillFx_Lightning:
		{
			// From the ceiling or 400 units above, whichever is lower
			float top[3];
			top = pos;
			top[2] += 400.0;
			TR_TraceRay(center, top, MASK_SOLID_BRUSHONLY, RayType_EndPoint);
			TR_GetEndPosition(top);

			TE_SetupBeamPoints(top, pos, g_iLightningModel, g_iHaloModel, 0, 15, 0.3, 8.0, 4.0, 0, 6.0, color, 3);
			TE_SendToAllInRange(pos, RangeType_Visibility);
			TE_SetupSparks(pos, up, 4, 2);
			TE_SendToAllInRange(pos, RangeType_Visibility);
		}
		case KillFx_Confetti:
		{
			// Five short tracers bursting out of the body
			float end[3];
			for (int i = 0; i < 5; i++)
			{
				end[0] = center[0] + GetRandomFloat(-70.0, 70.0);
				end[1] = center[1] + GetRandomFloat(-70.0, 70.0);
				end[2] = center[2] + GetRandomFloat(10.0, 70.0);
				if (item.randomColor)
					RandomColor(color);

				TE_SetupBeamPoints(center, end, g_iBeamModel, 0, 0, 0, 0.5, 2.0, 0.5, 0, 0.0, color, 0);
				TE_SendToAllInRange(center, RangeType_Visibility);
			}
		}
		case KillFx_Glow:
		{
			TE_SetupGlowSprite(center, g_iGlowModel, 0.6, 1.2, 220);
			TE_SendToAllInRange(center, RangeType_Visibility);
		}
	}
}

void RandomColor(int color[4])
{
	// One bright channel, so random colors never come out dark or grey
	color[0] = GetRandomInt(40, 255);
	color[1] = GetRandomInt(40, 255);
	color[2] = GetRandomInt(40, 255);
	color[GetRandomInt(0, 2)] = 255;
	color[3] = 255;
}

// ---------------------------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------------------------

bool CheckProgressionAvailable(int client)
{
	if (g_iAccountId[client] == 0)
	{
		CReplyToCommand(client, "%s%t", CHAT_PREFIX, "No Account");
		return false;
	}
	if (g_hDB == null)
	{
		CReplyToCommand(client, "%s%t", CHAT_PREFIX, "Database Unavailable");
		return false;
	}
	if (!g_bLoaded[client])
	{
		CReplyToCommand(client, "%s%t", CHAT_PREFIX, "Not Loaded");
		return false;
	}
	return true;
}

public Action Command_Menu(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[GG] %t", "Command is in-game only");
		return Plugin_Handled;
	}

	if (CheckProgressionAvailable(client))
		ShowMainMenu(client);
	return Plugin_Handled;
}

public Action Command_TopRank(int client, int args)
{
	if (g_hDB == null)
		CReplyToCommand(client, "%s%t", CHAT_PREFIX, "Database Unavailable");
	else
		QueryTop(client);
	return Plugin_Handled;
}

void QueryTop(int client)
{
	if (g_hDB == null)
		return;

	// Pending saves run first on the same connection, so the list is up to date
	SaveClients(0, false);

	char query[128];
	FormatEx(query, sizeof(query), "SELECT name, xp FROM ggp_players ORDER BY xp DESC LIMIT %d", TOP_COUNT);
	g_hDB.Query(OnTopLoaded, query, client == 0 ? 0 : GetClientUserId(client));
}

public Action Command_GiveXP(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[GG] Usage: sm_ggp_givexp <target> <amount>");
		return Plugin_Handled;
	}

	char pattern[MAX_TARGET_LENGTH], amountArg[16];
	GetCmdArg(1, pattern, sizeof(pattern));
	GetCmdArg(2, amountArg, sizeof(amountArg));
	int amount = StringToInt(amountArg);

	char targetName[MAX_TARGET_LENGTH];
	int targets[MAXPLAYERS];
	bool tnIsMl;
	int count = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_NO_BOTS, targetName, sizeof(targetName), tnIsMl);
	if (count <= 0)
	{
		ReplyToTargetError(client, count);
		return Plugin_Handled;
	}

	for (int i = 0; i < count; i++)
	{
		int target = targets[i];
		if (!g_bLoaded[target])
		{
			ReplyToCommand(client, "[GG] %N: %t", target, "Not Loaded");
			continue;
		}

		AddXP(target, amount);
		ReplyToCommand(client, "[GG] %t", "Give XP", amount, target, g_iXP[target]);
		LogAction(client, target, "\"%L\" gave %d XP to \"%L\" (now %d XP)", client, amount, target, g_iXP[target]);
	}
	return Plugin_Handled;
}

public Action Command_Reload(int client, int args)
{
	LoadConfig();
	PrecacheAssets();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		UpdateRank(i, false);
		CreateTrail(i);
	}

	ReplyToCommand(client, "[GG] %t", "Config Reloaded");
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------------------------
// Menus
// ---------------------------------------------------------------------------------------------

void ShowMainMenu(int client)
{
	RankInfo rank;
	GetRank(g_iRank[client], rank);

	char title[512], line[192];
	FormatEx(title, sizeof(title), "%T\n \n", "Menu Title", client);

	FormatEx(line, sizeof(line), "%T\n", "Menu Rank", client, rank.name, g_iRank[client], g_aRanks.Length);
	StrCat(title, sizeof(title), line);
	FormatEx(line, sizeof(line), "%T\n", "Menu XP", client, g_iXP[client]);
	StrCat(title, sizeof(title), line);

	if (g_iRank[client] < g_aRanks.Length)
	{
		RankInfo next;
		GetRank(g_iRank[client] + 1, next);

		// [||||||||............] 40%
		int span = next.xp - rank.xp;
		int done = g_iXP[client] - rank.xp;
		int filled = span > 0 ? (done * XP_BAR_SIZE) / span : XP_BAR_SIZE;
		char bar[XP_BAR_SIZE + 1];
		for (int i = 0; i < XP_BAR_SIZE; i++)
			bar[i] = i < filled ? '|' : '.';
		bar[XP_BAR_SIZE] = '\0';
		FormatEx(line, sizeof(line), "[%s] %d%%\n", bar, span > 0 ? (done * 100) / span : 100);
		StrCat(title, sizeof(title), line);

		FormatEx(line, sizeof(line), "%T\n", "Menu Next Rank", client, next.name, next.xp - g_iXP[client]);
		StrCat(title, sizeof(title), line);
	}
	else
	{
		FormatEx(line, sizeof(line), "%T\n", "Menu Max Rank", client);
		StrCat(title, sizeof(title), line);
	}

	int cat;
	ItemInfo item;
	if (FindNextUnlock(g_iRank[client], cat, item))
		FormatEx(line, sizeof(line), "%T\n ", "Menu Next Unlock", client, item.name, item.rank);
	else
		FormatEx(line, sizeof(line), "%T\n ", "Menu All Unlocked", client);
	StrCat(title, sizeof(title), line);

	Menu menu = new Menu(MenuHandler_Main);
	menu.SetTitle("%s", title);

	char info[8], display[128], equipped[64];
	for (int i = 0; i < Cat_Count; i++)
	{
		GetEquippedName(client, i, equipped, sizeof(equipped));
		FormatEx(info, sizeof(info), "%d", i);
		FormatEx(display, sizeof(display), "%T: %s", g_sCatPhrases[i], client, equipped);
		menu.AddItem(info, display);
	}

	FormatEx(display, sizeof(display), "%T", "Menu Top", client);
	menu.AddItem("top", display);

	menu.Display(client, MENU_TIME_FOREVER);
	g_bMenuOpen[client] = true;
}

public int MenuHandler_Main(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			g_bMenuOpen[param1] = false;

			char info[8];
			menu.GetItem(param2, info, sizeof(info));
			if (StrEqual(info, "top"))
				QueryTop(param1);
			else if (g_bLoaded[param1])
				ShowCategoryMenu(param1, StringToInt(info), 0);
		}
		case MenuAction_Cancel:
		{
			g_bMenuOpen[param1] = false;
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

bool IsCategoryEnabled(int cat)
{
	switch (cat)
	{
		case Cat_Tags:        return g_cvChatTags.BoolValue;
		case Cat_Trails:      return g_cvTrails.BoolValue;
		case Cat_HEColors:    return g_cvHEColors.BoolValue;
		case Cat_KillEffects: return g_cvKillFx.BoolValue;
	}
	return false;
}

void AddChoice(Menu menu, int client, int cat, const char[] value, const char[] name, int rank)
{
	char info[ITEM_KEY_SIZE + 8], display[128];
	FormatEx(info, sizeof(info), "%d|%s", cat, value);

	if (rank > g_iRank[client])
	{
		FormatEx(display, sizeof(display), "%T", "Item Locked", client, name, rank);
		menu.AddItem(info, display, ITEMDRAW_DISABLED);
	}
	else if (StrEqual(g_sEquip[client][cat], value))
	{
		FormatEx(display, sizeof(display), "%T", "Item Equipped", client, name);
		menu.AddItem(info, display, ITEMDRAW_DISABLED);
	}
	else
	{
		menu.AddItem(info, name);
	}
}

void ShowCategoryMenu(int client, int cat, int firstItem)
{
	if (cat < 0 || cat >= Cat_Count)
		return;

	Menu menu = new Menu(MenuHandler_Category);

	char title[256], equipped[64];
	GetEquippedName(client, cat, equipped, sizeof(equipped));
	FormatEx(title, sizeof(title), "%T\n%T", g_sCatPhrases[cat], client, "Equipped", client, equipped);
	if (!IsCategoryEnabled(cat))
		Format(title, sizeof(title), "%s\n%T", title, "Feature Disabled", client);
	menu.SetTitle("%s", title);

	char name[64];
	if (cat == Cat_Tags)
	{
		FormatEx(name, sizeof(name), "%T", "Item Auto Rank", client);
		AddChoice(menu, client, cat, "", name, 1);
		FormatEx(name, sizeof(name), "%T", "Item None", client);
		AddChoice(menu, client, cat, "none", name, 1);
	}
	else
	{
		FormatEx(name, sizeof(name), "%T", "Item None", client);
		AddChoice(menu, client, cat, "", name, 1);
	}

	ItemInfo item;
	for (int i = 0; i < g_aItems[cat].Length; i++)
	{
		g_aItems[cat].GetArray(i, item);
		AddChoice(menu, client, cat, item.key, item.name, item.rank);
	}

	// The names of the ranks already reached can be used as tags
	if (cat == Cat_Tags)
	{
		RankInfo rank;
		char value[16];
		for (int r = g_iRank[client]; r >= 1; r--)
		{
			GetRank(r, rank);
			FormatEx(value, sizeof(value), "rank:%d", r);
			AddChoice(menu, client, cat, value, rank.name, r);
		}
	}

	menu.ExitBackButton = true;
	menu.DisplayAt(client, firstItem, MENU_TIME_FOREVER);
	g_bMenuOpen[client] = true;
}

public int MenuHandler_Category(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			g_bMenuOpen[param1] = false;

			char info[ITEM_KEY_SIZE + 8];
			menu.GetItem(param2, info, sizeof(info));

			int split = FindCharInString(info, '|');
			if (split == -1 || !g_bLoaded[param1])
				return 0;

			info[split] = '\0';
			int cat = StringToInt(info);
			if (cat < 0 || cat >= Cat_Count)
				return 0;

			if (Equip(param1, cat, info[split + 1]))
			{
				char category[64], equipped[64];
				FormatEx(category, sizeof(category), "%T", g_sCatPhrases[cat], param1);
				GetEquippedName(param1, cat, equipped, sizeof(equipped));
				CPrintToChat(param1, "%s%t", CHAT_PREFIX, "Equipped Chat", category, equipped);
			}

			// A new menu each time: redisplaying this one from its own Select crashes SM 1.13 once it is deleted in End
			ShowCategoryMenu(param1, cat, menu.Selection);
		}
		case MenuAction_Cancel:
		{
			g_bMenuOpen[param1] = false;
			if (param2 == MenuCancel_ExitBack && IsClientInGame(param1) && g_bLoaded[param1])
				ShowMainMenu(param1);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

bool Equip(int client, int cat, const char[] value)
{
	bool valid = !value[0];
	if (cat == Cat_Tags && StrEqual(value, "none"))
	{
		valid = true;
	}
	else if (cat == Cat_Tags && !strncmp(value, "rank:", 5))
	{
		int wanted = StringToInt(value[5]);
		valid = wanted >= 1 && wanted <= g_iRank[client];
	}
	else if (value[0])
	{
		int index = FindItem(cat, value);
		if (index != -1)
		{
			ItemInfo item;
			g_aItems[cat].GetArray(index, item);
			valid = item.rank <= g_iRank[client];
		}
	}

	if (!valid)
		return false;

	strcopy(g_sEquip[client][cat], sizeof(g_sEquip[][]), value);
	g_bDirty[client] = true;

	if (cat == Cat_Trails)
		CreateTrail(client);
	return true;
}

public void OnTopLoaded(Database db, DBResultSet results, const char[] error, any userid)
{
	int client = userid == 0 ? 0 : GetClientOfUserId(userid);
	if (userid != 0 && client == 0)
		return;

	if (results == null)
	{
		LogError("Cannot read the top %d: %s", TOP_COUNT, error);
		return;
	}

	char name[MAX_NAME_LENGTH], line[192];
	RankInfo rank;
	int position = 0;

	if (client == 0)
	{
		while (results.FetchRow())
		{
			results.FetchString(0, name, sizeof(name));
			int xp = results.FetchInt(1);
			GetRank(GetRankForXP(xp), rank);
			PrintToServer("%d. %s - %d XP (%s)", ++position, name, xp, rank.name);
		}
		return;
	}

	Menu menu = new Menu(MenuHandler_Top);
	menu.SetTitle("%T\n ", "Top Title", client);

	while (results.FetchRow())
	{
		results.FetchString(0, name, sizeof(name));
		int xp = results.FetchInt(1);
		GetRank(GetRankForXP(xp), rank);
		FormatEx(line, sizeof(line), "%T", "Top Line", client, ++position, name, xp, rank.name);
		menu.AddItem("", line, ITEMDRAW_DISABLED);
	}

	if (position == 0)
	{
		FormatEx(line, sizeof(line), "%T", "Top Empty", client);
		menu.AddItem("", line, ITEMDRAW_DISABLED);
	}

	menu.ExitBackButton = g_bLoaded[client];
	menu.Display(client, MENU_TIME_FOREVER);
	g_bMenuOpen[client] = true;
}

public int MenuHandler_Top(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			g_bMenuOpen[param1] = false;
		}
		case MenuAction_Cancel:
		{
			g_bMenuOpen[param1] = false;
			if (param2 == MenuCancel_ExitBack && IsClientInGame(param1) && g_bLoaded[param1])
				ShowMainMenu(param1);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

// ---------------------------------------------------------------------------------------------
// Natives
// ---------------------------------------------------------------------------------------------

int GetNativeClient()
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d or client not in game", client);
		return 0;
	}
	return client;
}

public int Native_GetClientXP(Handle plugin, int numParams)
{
	int client = GetNativeClient();
	return client != 0 && g_bLoaded[client] ? g_iXP[client] : 0;
}

public int Native_GetClientRank(Handle plugin, int numParams)
{
	int client = GetNativeClient();
	return client != 0 ? g_iRank[client] : 1;
}

public int Native_IsClientLoaded(Handle plugin, int numParams)
{
	int client = GetNativeClient();
	return client != 0 && g_bLoaded[client];
}

public int Native_GetRankCount(Handle plugin, int numParams)
{
	return g_aRanks.Length;
}

public int Native_GetRankName(Handle plugin, int numParams)
{
	int rankNum = GetNativeCell(1);
	if (rankNum < 1 || rankNum > g_aRanks.Length)
		return false;

	RankInfo rank;
	GetRank(rankNum, rank);
	SetNativeString(2, rank.name, GetNativeCell(3));
	return true;
}
