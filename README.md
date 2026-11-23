<p align="center"><img src="media/banner.png" alt="Padvinder"></p>

# Padvinder

A World of Warcraft addon for **WoW Forever** that records the paths you walk, draws them as a
heatmap on your map and minimap, and routes your TomTom arrow over them, plus flight paths,
boats and zeppelins.

The more you play, the better it knows the roads: instead of pointing in a straight line through
a mountain, the arrow follows the paths you (and the game's NPCs) actually use.

## Features

- **Path recording**: every step you take is stored account-wide, per continent. Paths continue
  across zone borders.
- **Heatmap** on the world map and minimap. Show all paths, only travel, or only grinding
  (walking done in or around combat).
- **Route planner**: when TomTom has a waypoint (set by you, Questie, ...), Padvinder plans a
  route over your recorded paths, the flight points you know, and boats, zeppelins and portals,
  and points the TomTom arrow along it. The route is drawn on the map and minimap.
- Knows about one-way drops, swimming and transports, so you don't get routed up a cliff you
  only ever fell down.
- Minimap button for quick access.

## Requirements

- WoW Forever (`_forever_` client).
- Optional but recommended: [TomTom](https://www.curseforge.com/wow/addons/tomtom), needed for
  the route arrow.
- Optional: Questie (its database helps route through areas you haven't walked yet) and
  ForeverDungeonJournal (for its flight point list).

## Installation

1. Download `Padvinder-<version>.zip` from the
   [latest release](https://github.com/Neil2222/padvinder/releases/latest)
   (the asset, **not** "Source code").
2. Unzip it into your AddOns folder, so you end up with:
   ```
   World of Warcraft\_forever_\Interface\AddOns\Padvinder\Padvinder.toc
   ```
3. Restart the game (or `/reload`) and make sure Padvinder is enabled in the AddOns list on the
   character select screen. If it shows as "out of date", tick **Load out of date AddOns**.

To update: delete the old `Padvinder` folder and unzip the new one. Your recorded paths are kept
(they are stored in `WTF\Account\...\SavedVariables\Padvinder.lua`, not in the addon folder).

## Commands

| Command | What it does |
| --- | --- |
| `/pad` | list of commands |
| `/pad info` | what has been recorded |
| `/pad on`, `/pad off`, `/pad toggle` | recording on/off (toggle is handy in a macro) |
| `/pad map` | show/hide paths on the world map |
| `/pad minimap` | show/hide paths on the minimap |
| `/pad show all` / `travel` / `grind` | which paths to show |
| `/pad route` | route planner on/off |
| `/pad button` | show/hide the minimap button |
| `/pad wipe confirm` | erase **everything** that was recorded |

`/padvinder` works too.

## Credits

- Boat, zeppelin, portal and flight data from ForeverDungeonJournal.
- Bundled libraries: LibStub, CallbackHandler-1.0, HereBeDragons-2.0, LibDataBroker-1.1,
  LibDBIcon-1.0 (each under its own license).

## License

MIT, see [LICENSE](LICENSE).
