# Helpme Sniper

A small World of Warcraft **Forever** addon for buying auction house materials fast: cloth, dye, herbs, anything sold by quantity.

You set a max price and a quantity. The addon searches the auction house on its own and tells you the moment something is listed at or under your price. Then you press BUY once: the addon gets the exact price and buys straight away if it's still at or under your max. If someone beats you and the price comes back higher, it cancels automatically, so you never pay more than your max. Spamming the button is safe.

It doesn't need TSM or any other addon.

## Install (auto-updates)

1. Install **WowUp** (free) from [wowup.io](https://wowup.io), version 2.24.0 or newer.
2. In WowUp, pick **World of Warcraft Forever** at the top.
3. Go to **Get Addons** → **Install from URL** and paste this project's GitHub link.
4. WowUp updates it whenever a new version comes out. Type `/reload` in game after an update.

## How to use it

The window opens when you open the auction house.

- **Focus** (main mode): drop in one item, set your max price and quantity. Only that item is searched, as fast as the game allows (every 0.6s). You see the cheapest listings live.
  - **Count down** (optional): tick it and your quantity becomes a hard limit. Buy 7 of 20 and it only goes for 13 more, then stops. It starts over after 5 minutes without buying (change that in Settings), or click Reset. Leave it off to buy up to your quantity every time, for as long as you keep pressing.
- **Snipe**: watch several items at once; they take turns being searched.
- **Watch List**: add items, set prices and quantities, tick items on or off.
- **Settings**: gold to always keep, an extra confirm for big buys, search speed, sound, one-press buying.
- **History**: what you bought and how much you spent today.

**Buying:** click the big BUY button, or set a key: Esc → Options → Keybindings → AddOns → Helpme Sniper. Buys over your "extra confirm" amount (2g by default) need **Shift + click**, so spamming can't confirm a big buy by accident.

## Good to know

- The game needs a real key press or click to start each purchase, so the addon never buys without you pressing. If the game ever refuses the automatic last step, the addon switches to "press again to buy" by itself.
- WoW allows about 100 auction searches per minute across all addons combined. Running TSM's Sniper at the same time slows both down.
- Only works for items sold by quantity, not gear or bags.

## Feedback

Found a bug or have an idea? Open an issue on this GitHub page or tell HelpMe ImDyin.
