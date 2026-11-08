# Helpme Sniper

A small World of Warcraft **Forever** addon for buying auction house materials fast: cloth, dye, herbs, anything sold by quantity.

You set a max price and a quantity. The addon searches the auction house on its own and tells you the moment something is listed at or under your price. Then you buy it with your buy key: one press gets the price, the next press buys. If someone beats you and the price comes back higher, it cancels automatically, so you never pay more than your max.

It doesn't need TSM or any other addon.

## Install (auto-updates)

1. Install **WowUp** (free) from [wowup.io](https://wowup.io), version 2.24.0 or newer.
2. In WowUp, pick **World of Warcraft Forever** at the top.
3. Go to **Get Addons** → **Install from URL** and paste this project's GitHub link.
4. WowUp updates it whenever a new version comes out. Type `/reload` in game after an update.

## How to use it

The window opens when you open the auction house.

- **Focus** (main mode): drop in one item, set your max price and quantity. Only that item is searched, as fast as the game allows (every 0.6s). You see the cheapest listings live.
- **Snipe**: watch several items at once; they take turns being searched.
- **Watch List**: add items, set prices and quantities, tick items on or off.
- **Settings**: gold to always keep, an extra confirm for big buys, search speed, sound.
- **History**: what you bought and how much you spent today.

**Buy key:** Esc → Options → Keybindings → AddOns → Helpme Sniper. You can also use a macro: `/click HelpmeSniperBuyButton`.

## Good to know

- The game needs a real key press or click for each purchase, so the addon never buys on its own.
- WoW allows about 100 auction searches per minute across all addons combined. Running TSM's Sniper at the same time slows both down.
- Only works for items sold by quantity, not gear or bags.

## Feedback

Found a bug or have an idea? Open an issue on this GitHub page or tell HelpMe ImDyin.
