# GunGame Progression

SourceMod plugin for Counter-Strike: Source GunGame servers that adds long-term progression:
players earn XP by playing GunGame, climb 50 ranks and unlock cosmetics as they rank up: a chat
tag, a trail, a color for their HE grenades and a kill effect.

There is no currency and nothing to buy: every unlock comes from playing, and no unlock changes
the gameplay (no damage, health, speed, weapon or visibility advantage). The optional VIP
multiplier only speeds up the progression.

Written for the [srcdslab GunGame:SM fork](https://github.com/srcdslab/sm-plugin-GunGame) (2.0.x),
whose forwards and natives it uses. Pure SourcePawn, no extension, no gamedata. Every material
and sound comes with the game: clients download nothing.

## How it works

### XP

| Source | Default | Cvar |
| - | - | - |
| Kill (bots count as victims) | 10 | `sm_ggp_xp_kill` |
| Headshot kill, on top of the kill | +5 | `sm_ggp_xp_headshot` |
| GunGame knife steal, on top of the kill | +15 | `sm_ggp_xp_knifesteal` |
| GunGame level gained by a kill or a knife steal, per level | 5 | `sm_ggp_xp_levelup` |
| Match win | 200 | `sm_ggp_xp_win` |
| End of match placement 1st / 2nd / 3rd (GunGame ranking by level, bots included) | 75 / 50 / 25 | `sm_ggp_xp_place1..3` |
| Each full minute on T or CT during the match | 5 | `sm_ggp_xp_playtime` |
| Participation: on T or CT at the end of the match, after 3 minutes on a team | 20 | `sm_ggp_xp_participation`, `sm_ggp_participation_time` |

- Bots never earn XP, but killing a bot gives XP (the server is mostly bots).
- No XP while the GunGame warmup runs, before the match starts, after it ended, or when GunGame
  is not loaded or disabled (`gungame_enabled 0`). Cosmetics keep working at all times.
- Handicap, reconnect, admin and native GunGame levels give no level XP. Team kills give nothing,
  except in GunGame FFA mode.
- The match ends with the GunGame winner (`GG_OnWinner`), or with the time limit
  (`cs_win_panel_match`) when nobody won: there is no win XP then, but placement and
  participation XP are still given.
- VIP players (VIP-Core, optional) get `sm_ggp_vip_multiplier` times the XP (1.25 by default).
- At the end of the match, every player gets a summary: XP earned in the match, rank, XP left to
  the next rank and the next unlock.

### Ranks

50 ranks with generic military names (Recruit, Private I-III, ..., General, Field Marshal, Hero,
Champion, Legend), defined in the config with the total XP each one needs. The default curve is
`xp(rank) = 100 * (rank - 1) ^ 2.1`: with about 350 XP per 10 minutes of play, a regular player
reaches rank 10 after about 5 hours and rank 50 after about 170 hours (150 to 200 hours between
400 and 300 XP per 10 minutes). The details are in the config file.

A rank up is announced in chat to everyone, with a sound and the list of new unlocks for the player.

### Cosmetics

| Category | What it does |
| - | - |
| Chat tag | `[Tag]` before the name in chat, in the tag color. By default the current rank name, or the name of any rank already reached, a special tag of the config, or no tag. See [Chat tags and CustomChatColors](#chat-tags-and-customchatcolors). |
| Trail | `env_spritetrail` parented to the player. Created on spawn, removed on death, team change and disconnect: never on spectators or dead players. |
| HE grenade color | The thrown `hegrenade_projectile` gets the item color, plus a beam that follows it in the same color. |
| Kill effect | A small temp entity effect where the victim dies: sparks, energy splash, colored shockwave ring, lightning strike from the ceiling (or 400 units above), confetti (5 short colored tracers) or a glow. |

Kill effects are limited to `sm_ggp_kill_effects_cooldown` seconds per player and
`sm_ggp_kill_effects_max` effects per second on the whole server, and are only sent to the players
who can see the spot. The heaviest effect is 5 temp entities.

Trail materials are stock CS:S sprites. The default config uses `sprites/laserbeam`, `bluelaser1`,
`physbeam`, `purplelaser1`, `crystal_beam1`, `xbeam2`, `plasmabeam` and `lgtning`, all listed in
`hl2/hl2_misc_dir.vpk` (vmt) and `hl2/hl2_textures_dir.vpk` (vtf) of the current CS:S install. Only use
materials that ship with the game, or clients see missing textures.

### Persistence

Data is saved in the `databases.cfg` entry of `sm_ggp_database` (`gungame` by default, the
SQLite entry GunGame stats already uses), in its own `ggp_players` table, keyed by the Steam
account ID. MySQL works too. Clients without a Steam account ID (some NoSteam clients) have no
progression. Players are loaded after the admin check, and saved every 60 seconds (only if
something changed), on disconnect, at map end and at match end. Every query is threaded. If the
database cannot be reached, the error is logged once and the connection is retried every minute.

| Column | Content |
| - | - |
| `account_id` | Steam account ID (primary key) |
| `name` | Last name seen |
| `xp` | Total XP |
| `tag`, `trail`, `he_color`, `kill_effect` | Equipped item keys (`tag`: empty = current rank, `none`, `rank:N` or a tag key) |
| `last_seen` | Unix time of the last save |

## Chat tags and CustomChatColors

Without [CustomChatColors](https://github.com/srcdslab/sm-plugin-CustomChatColors) (CCC), the
plugin adds the tag itself: CS:S sends the chat line as one `SayText2` user message per recipient.
For a player with a tag, these messages are blocked and sent again on the next frame to the same
recipients, with the same message name and parameters (so the dead / team / location prefixes and
the language of each client stay right); only the name parameter becomes `[Tag] Name`.

With CCC loaded (`ccc` library), the plugin does not touch chat at all, and the chat tag category
shows "Disabled on this server". The reasons, from the CCC source (8.1.x):

- CCC already blocks every chat `SayText2` and sends its own line from `player_say`, with
  `USERMSG_BLOCKHOOKS`. A second plugin rebuilding chat lines would print each line twice, and
  CCC's own line cannot be hooked.
- CCC only shows a tag for players with the Generic or Custom1 admin flag, so `CCC_SetTag` cannot
  show a rank tag to regular players.
- `CCC_SetTag` only changes the tag in memory, but the next tag or color change of the player saves
  every current value to the CCC database: a rank tag prepended to a VIP tag would end up saved as
  the VIP tag.

Showing rank tags next to CCC tags needs a small CCC addition, for example a forward called while
CCC builds the sender name, letting another plugin add a prefix for any player. This plugin does
not depend on it.

## Requirements

- SourceMod 1.12 or newer (built for 1.12 and 1.13).
- [srcdslab/sm-plugin-GunGame](https://github.com/srcdslab/sm-plugin-GunGame) 2.0.x. Without
  GunGame the plugin loads, but nobody earns XP.
- Optional: [srcdslab/sm-plugin-VIP-Core](https://github.com/srcdslab/sm-plugin-VIP-Core) for the
  VIP multiplier.
- A `databases.cfg` entry (SQLite or MySQL).

## Installation

Extract the release archive matching your SourceMod version (`-sm1.12` or `-sm1.13`) into `cstrike/`:

- `addons/sourcemod/plugins/GunGameProgression.smx`
- `addons/sourcemod/configs/gungame_progression.cfg`
- `addons/sourcemod/translations/gungame_progression.phrases.txt`
- `addons/sourcemod/scripting/include/gungame_progression.inc` (only to build other plugins)

The config `cfg/sourcemod/plugin.GunGameProgression.cfg` is created on first load.

## Cvars

| Cvar | Default | Description |
| - | - | - |
| `sm_ggp_enable` | `1` | Enable XP gains (cosmetics keep working when disabled) |
| `sm_ggp_database` | `gungame` | `databases.cfg` entry used to store the progression (tables `ggp_*`) |
| `sm_ggp_xp_kill` | `10` | XP for a kill (bots included) |
| `sm_ggp_xp_headshot` | `5` | Extra XP when the kill is a headshot |
| `sm_ggp_xp_knifesteal` | `15` | Extra XP for a GunGame knife steal |
| `sm_ggp_xp_levelup` | `5` | XP per GunGame level gained by a kill or a knife steal |
| `sm_ggp_xp_win` | `200` | XP for winning the match |
| `sm_ggp_xp_place1` | `75` | XP for the 1st place at the end of the match (on top of the win XP) |
| `sm_ggp_xp_place2` | `50` | XP for the 2nd place |
| `sm_ggp_xp_place3` | `25` | XP for the 3rd place |
| `sm_ggp_xp_playtime` | `5` | XP per full minute spent on T or CT during the match |
| `sm_ggp_xp_participation` | `20` | XP at the end of the match for players on a team who played long enough |
| `sm_ggp_participation_time` | `180` | Seconds on T or CT during the match needed for the participation XP |
| `sm_ggp_vip_multiplier` | `1.25` | XP multiplier for VIP players (VIP-Core), `1.0` = none |
| `sm_ggp_chat_tags` | `1` | Show the chosen tag before the name in chat (only without CCC) |
| `sm_ggp_trails` | `1` | Enable player trails |
| `sm_ggp_he_colors` | `1` | Enable HE grenade colors |
| `sm_ggp_kill_effects` | `1` | Enable kill effects |
| `sm_ggp_kill_effects_cooldown` | `2.0` | Seconds before the kill effect of the same player can play again |
| `sm_ggp_kill_effects_max` | `4` | Most kill effects played per second on the whole server |
| `sm_ggp_rankup_sound` | `items/gift_pickup.wav` | Sound played to a player who ranks up (stock sound, empty = none) |

## Commands

| Command | Access | Description |
| - | - | - |
| `sm_xp`, `sm_progress`, `sm_cosmetics` | Everyone | Menu with the rank, XP, progress bar to the next rank, next unlock, and one submenu per cosmetic category (locked items are shown with the rank they need) |
| `sm_ggp_toprank` | Everyone | The 10 players with the most XP |
| `sm_ggp_givexp <target> <amount>` | Root | Give (or remove, with a negative amount) XP, for tests |
| `sm_ggp_reload` | Config | Reload `configs/gungame_progression.cfg` |

The GunGame commands (`rank`, `top`, `top10` from GunGame stats, `level`, `score`, `leader`...)
are left alone.

## Config

`addons/sourcemod/configs/gungame_progression.cfg`:

```
"GunGameProgression"
{
    "ranks"
    {
        "1" { "name" "Recruit" "xp" "0" "color" "200 200 200" }
        "2" { "name" "Private I" "xp" "100" "color" "200 200 200" }
    }
    "tags"
    {
        "veteran" { "name" "Veteran" "rank" "12" "text" "Veteran" "color" "139 195 74" }
    }
    "trails"
    {
        "laser_red" { "name" "Red laser" "rank" "5" "material" "materials/sprites/laserbeam.vmt" "color" "255 60 60" }
    }
    "he_colors"
    {
        "red" { "name" "Red" "rank" "4" "color" "255 40 40" }
    }
    "kill_effects"
    {
        "confetti" { "name" "Confetti" "rank" "23" "type" "confetti" "color" "random" }
    }
}
```

- Ranks: `name`, `xp` (total XP needed, the lowest rank must need 0) and `color` (`R G B`, rank
  tag color). Rank names are not translated.
- Every item needs `rank` (unlocked from that rank on) and a `name` (shown in menus, not
  translated). The section name is the key saved in the database: renaming it unequips the item.
  `none` and keys containing `:` are reserved.
- `tags`: `text` and `color`.
- `trails`: `material` (stock `.vmt`), `color`, `width` (1-16, default 6), `end_width` (0-16,
  default 1), `lifetime` (0.1-3 seconds, default 1).
- `he_colors`: `color`.
- `kill_effects`: `type` (`sparks`, `energy`, `ring`, `lightning`, `confetti`, `glow`) and `color`
  (`R G B` or `random`; sparks, energy and glow are not colored).

## API

`addons/sourcemod/scripting/include/gungame_progression.inc` (library `gungame_progression`):

```sourcepawn
native int GGP_GetClientXP(int client);
native int GGP_GetClientRank(int client);
native bool GGP_IsClientLoaded(int client);
native int GGP_GetRankCount();
native bool GGP_GetRankName(int rank, char[] buffer, int maxlen);
forward void GGP_OnClientRankUp(int client, int oldRank, int newRank);
```

## License

GPL-3.0, see [LICENSE](LICENSE).
