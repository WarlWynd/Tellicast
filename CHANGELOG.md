# Tellicast changelog

(Called TellBot up to version 1.1.0.)

Version numbers are MAJOR.MINOR.PATCH:
- PATCH (1.1.x) for bug fixes
- MINOR (1.x.0) for new features or changes to how something works
- MAJOR (x.0.0) for changes that need settings redone

## 1.3.0 - 2026-11-11

Added
- "Allow say" and "Allow ooc" in "Who can ask" (both off by default): keywords
  sent in `/say` or `/ooc` are taken from anyone the other "Who can ask"
  settings allow. NPCs and pets saying a keyword are ignored.

Changed
- Tellicast never replies in public chat (`/say`, `/ooc`, `/shout` and so on).
  Replies only go by tell, group or guild. Requests heard in public chat just
  get the spell or command, and "help" and "menu" are ignored there.

## 1.2.0 - 2026-11-11

Changed
- Renamed the project from TellBot to Tellicast.
  - The folder is now `lua\Tellicast`. Run it with `/lua run tellicast`.
  - The in-game command is now `/tellicast` (for example `/tellicast show`).
  - Settings files are now `config/Tellicast_*.lua`. Settings saved under the
    old TellBot names are brought over automatically the first time it runs.

## 1.1.0 - 2026-11-10

Added
- "Allow menu" setting: players who send `menu` get one line per active keyword,
  like `[heal] Superior Healing`. Keywords that use assist end with "(Use Assist)".
- "Settings" section in the window, below "Who can ask". It now holds
  "Listen to group chat", "Listen to guild chat", "Send replies" and "Allow menu".
- Version number in the window, in the startup message, and from `/tellbot version`.

Changed
- The "Offensive Spell" column is now called "Use Assist".
- Spells cast without assist now name the target ("Casting Divine Light on Ursa")
  instead of "Incoming: Divine Light".
- The script moved from `lua\tellbot.lua` to `lua\TellBot\init.lua`.
  `/lua run tellbot` works as before.

Fixed
- Beneficial spells with "Use Assist" ticked (heals, buffs) can now be cast on
  players and pets. Before, they replied "You don't have a target".
  Detrimental spells still refuse player targets.

## 1.0.0

The version from before versioning started: keywords per persona, allow lists,
tells plus group and guild chat, "Offensive Spell" (assist) keywords, rez,
/commands, per-keyword Active, No LoS and Send Replies boxes.
