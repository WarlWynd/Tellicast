# TellBot changelog

Version numbers are MAJOR.MINOR.PATCH:
- PATCH (1.1.x) for bug fixes
- MINOR (1.x.0) for new features or changes to how something works
- MAJOR (x.0.0) for changes that need settings redone

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
