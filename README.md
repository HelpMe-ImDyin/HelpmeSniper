# Helpme Sniper

A small World of Warcraft **Forever** addon for buying auction house materials fast: cloth, dye, herbs, anything sold by quantity.

You set a max price and how many you want. The addon searches the auction house on its own and shows a big **YES** the moment something is listed at or under your price. Click BUY: the addon gets the exact price and buys straight away if it's still at or under your max. Keep clicking to keep buying; it doesn't wait for a new search between buys. If someone beats you and the price comes back higher, it cancels automatically, so you never pay more than your max.

It doesn't need TSM or any other addon.

## Install (auto-updates)

1. Install **WowUp** (free) from [wowup.io](https://wowup.io), version 2.24.0 or newer.
2. In WowUp, pick **World of Warcraft Forever** at the top.
3. Go to **Get Addons** → **Install from URL** and paste this project's GitHub link.
4. WowUp updates it whenever a new version comes out. Type `/reload` in game after an update.

The first time it opens, a short welcome page explains the basics. The full guide is always one click away: the **?** button at the top of the window, or **How it works** in Settings.

## How to use it

The window opens just right of the auction house window. Drag it anywhere and it remembers the spot. **Start / Stop** turns searching on and off; the small **Live** marker shows it's searching.

### Adding items

In either item box: start typing the name (after 3 letters, matching items for sale drop down, like a search bar; click one or use Up/Down and Enter), drop an item on "Drop item here", shift-click it into the box, or type its item ID.

### Focus: one item, as fast as possible

For racing for a deal. Only that item is searched, every 0.6 seconds.
- **Max price each**, or the 70–100% buttons to set it from the item's normal price.
- **Count down** (on by default): "Total" is a hard limit. Buy 7 of 20 and it only goes for 13 more. It starts over after 5 minutes without buying, or click Reset. Untick it to buy up to your amount on every click.
- A big line says **YES** (buy now) or **NO**, with the 6 cheapest listings underneath.

### Shopping Lists: fill a list at good prices

For shopping without racing, like TSM groups.
- **Several lists** ("Tailoring 75–150", "Dyes"...). Click the list name to switch lists, see completed ones, or rename, copy or delete. Only the open list is searched, which keeps it fast.
- **Deals at X% of normal:** an item is a deal when it's at or under that share of its normal price (80% by default). Click an item to give it its own % or a fixed price.
- **Columns:** On, Deal at, Normal (its usual price), Now (cheapest price and how far from normal, YES when it's a deal), Got.
- **Track totals** (tick box): counts what you buy ("40/180") and never buys past each amount. It remembers until you mark the list complete, even after logging off. Untick it to just buy freely.
- **Mark complete:** the list stops searching and keeps a receipt (what you bought, what you paid, how that compares with normal). **Shop again** reopens it with the same items and the counts at zero, so you never re-add items.
- **Rest of list:** roughly what the rest would cost at today's prices; red when it's more than you can spend.
- Normal prices take about 10 minutes of watching to learn. Until then, % items show "learning" and won't buy; fixed-price items work straight away.

### Buying

Spam-click the big BUY button, or set a key: Esc → Options → Keybindings → AddOns → Helpme Sniper. The button tells you what it will do:
- **Green:** clicking buys, e.g. "BUY 7 Wool Cloth · 9s each (max 10s)".
- **Yellow:** busy getting the price or buying. Keep clicking.
- **Grey:** nothing at your price right now.
- **Red:** your max looks like a typo.

Shift-click the - and + buttons to change an amount by 10.

### Safety, without pop-ups

- Your max price per item: every buy costs no more than the price it showed you, which is at or under your max. If the price changes (someone bought the cheap ones first), it cancels and searches again.
- Typo guard: if a price you typed is more than double the usual price (say 20g instead of 20c), it warns you and won't buy until you click "I meant it".
- "Never spend below": your gold never drops under this amount.
- Count down and Track totals: never buys more than your amount.

### Settings

*Safety:* never spend below, buy in one click, count down reset time. *Other:* search speed, sound, auto-start, lock window, and the full guide.

## Good to know

- The game needs a real click or key press to start each purchase, so the addon never buys without you clicking. If the game ever refuses the automatic last step, the addon switches to "click again to buy" by itself.
- The auction house handles one purchase at a time, so items are bought one after another.
- WoW allows about 100 auction searches per minute across all addons combined. Running TSM's Sniper at the same time slows both down.
- Only works for items sold by quantity, not gear or bags.
- Updating from an older version: your Watch List becomes a shopping list called "My list", with the same items, prices and amounts.

## Feedback

Found a bug or have an idea? Open an issue on this GitHub page or tell HelpMe ImDyin.
