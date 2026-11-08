# Helpme Sniper

A small World of Warcraft **Forever** addon for buying auction house materials fast: cloth, dye, herbs, anything sold by quantity.

You set a max price and how many you want. The addon searches the auction house on its own and shows a big **YES** the moment something is listed at or under your price. Click BUY: the addon gets the exact price and buys straight away if it's still at or under your max. Keep clicking to keep buying; it doesn't wait for a new search between buys. If someone beats you and the price comes back higher, it cancels automatically, so you never pay more than your max.

It doesn't need TSM or any other addon.

## Install (auto-updates)

1. Install **WowUp** (free) from [wowup.io](https://wowup.io), version 2.24.0 or newer.
2. In WowUp, pick **World of Warcraft Forever** at the top.
3. Go to **Get Addons** → **Install from URL** and paste this project's GitHub link.
4. WowUp updates it whenever a new version comes out. Type `/reload` in game after an update.

## How to use it

The window opens when you open the auction house.

- **Focus** (main mode): drop in one item, set your max price and how many. Only that item is searched, as fast as the game allows (every 0.6s). A big line tells you YES (buy now) or NO, and the 6 cheapest listings show underneath.
  - **Count down** (on by default): "Total" is a hard limit. Buy 7 of 20 and it only goes for 13 more, then stops however much you click. It starts over after 5 minutes without buying (change that in Settings), or click Reset. Untick it to buy up to your amount on every click, for as long as you keep clicking.
- **Watch List**: several items at once. Add items, set a max price and amount for each, and tick the ones to search; they take turns. The "Now" column shows YES when there's a deal, otherwise the cheapest price. Click a name to see its prices and buy that one first.
- **Settings**: *Safety* (never spend below a gold amount, buy in one click, count down reset time) and *Other* (search speed, sound, auto-start, lock window).
- **History**: what you bought and how much you spent today.

**Buying:** spam-click the big BUY button, or set a key: Esc → Options → Keybindings → AddOns → Helpme Sniper. The button tells you what it will do and changes color:
- **Green:** clicking buys, e.g. "BUY 7 Wool Cloth · 9s each (max 10s)".
- **Yellow:** busy getting the price or buying. Keep clicking.
- **Grey:** nothing at your price right now.

Shift-click the - and + buttons to change the amount by 10.

**Adding items:** drop an item on "Drop item here", shift-click it into the box, or just start typing its name. After 3 letters, matching items for sale drop down (with how many are listed and the cheapest price), like a search bar. Click one, or use the Up/Down keys and Enter.

**Safety, without pop-ups:**
- Your max price per item: it never pays more on average.
- Typo guard: if your max is more than double the usual price (say 20g instead of 20c), it warns you as you type and won't buy until you click "I meant it".
- "Never spend below": your gold never drops under this amount.
- Count down: never buys more than your total.

## Good to know

- The game needs a real click or key press to start each purchase, so the addon never buys without you clicking. If the game ever refuses the automatic last step, the addon switches to "click again to buy" by itself.
- The window opens just right of the auction house so it doesn't cover it. Drag it anywhere and it remembers the spot; tick "Lock window position" in Settings to pin it.
- WoW allows about 100 auction searches per minute across all addons combined. Running TSM's Sniper at the same time slows both down.
- Only works for items sold by quantity, not gear or bags.

## Feedback

Found a bug or have an idea? Open an issue on this GitHub page or tell HelpMe ImDyin.
