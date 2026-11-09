# Helpme Sniper

A small World of Warcraft **Forever** addon for buying auction house materials fast: cloth, dye, herbs, anything sold by quantity.

You set a max price and how many you want. The addon searches the auction house on its own and shows a big **YES** the moment something is listed at or under your price. Click BUY: the addon gets the exact price and buys straight away if it's still at or under your max. Keep clicking to keep buying; it doesn't wait for a new search between buys. If someone beats you and the price comes back higher, it cancels automatically, so you never pay more than your max.

It works on its own; you don't need any other addon.

## Install (auto-updates)

1. Install **WowUp** (free) from [wowup.io](https://wowup.io), version 2.24.0 or newer.
2. In WowUp, pick **World of Warcraft Forever** at the top.
3. Go to **Get Addons** → **Install from URL** and paste this project's GitHub link.
4. WowUp updates it whenever a new version comes out. Type `/reload` in game after an update.

The first time it opens, a short welcome page explains the basics. The full guide is always one click away: the **?** button at the top of the window, or **How it works** in Settings.

## How to use it

The window opens just right of the auction house window. Drag it anywhere and it remembers the spot. **Start / Stop** turns searching on and off; the small **Live** marker shows it's searching.

### Adding items

In either item box: start typing the name (after 2 letters, matching items drop down straight away, like a search bar; click one or use Up/Down and Enter), drop an item on "Drop item here", shift-click it into the box, or type its item ID.

The names come from the addon's own saved list of everything sold by quantity on the auction house. When you open the auction house, and every 15 minutes while it's open, the addon copies the whole auction house in one go (the game allows one copy every 15 minutes). It isn't a search, so nothing changes in the auction house window. If an item isn't in the list yet, type its name and press Enter to search the auction house for it.

### Prices

Each copy also saves prices: the cheapest price, how many are listed, and a market price worked out from the cheaper listings (ignoring a few silly ones). The **normal price** combines the last 14 days, with recent days counting most. Hover any item (in your bags, a chat link or the search list) to see its normal price and the cheapest price from the last copy.

### Focus: one item, as fast as possible

For racing for a deal. Only that item is searched, every 0.6 seconds.
- **Max price each**, or the 70–100% buttons to set it from the item's normal price.
- **Count down** (on by default): "Total" is a hard limit. Buy 7 of 20 and it only goes for 13 more. It starts over after 5 minutes without buying, or click Reset. Untick it to buy up to your amount on every click.
- A big line says **YES** (buy now) or **NO**, with the 6 cheapest listings underneath.

### Shopping Lists: fill a list at good prices

For filling a list of materials at good prices, without racing.
- **Several lists** ("Tailoring 75–150", "Dyes"...). Click the list name to switch lists, see completed ones, or rename, copy or delete. Only the open list is searched: its items take turns, one search every 0.6 seconds, so with 10 items each is checked about every 6 seconds. BUY always checks the exact live price before paying.
- **Deals at X% of normal:** an item is a deal when it's at or under that share of its normal price (80% by default). Click an item to give it its own % or a fixed price.
- **Columns:** On, Deal at, Normal (its usual price), Now (cheapest price and how far from normal, YES when it's a deal), Got.
- **Track totals** (tick box): counts what you buy ("40/180") and never buys past each amount. It remembers until you mark the list complete, even after logging off. Untick it to just buy freely.
- **Mark complete:** the list stops searching and keeps a receipt (what you bought, what you paid, how that compares with normal). **Shop again** reopens it with the same items and the counts at zero, so you never re-add items.
- **Rest of list:** roughly what the rest would cost at today's prices; red when it's more than you can spend.
- Items get a normal price a few seconds after you first open the auction house. An item nobody had listed shows "learning" and won't buy until it's been watched for a while; fixed-price items work straight away.

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
- WoW allows about 100 auction searches per minute, shared by everything you run. If another addon or app is scanning the auction house at the same time, both slow down.
- Selling: the auction house handles one request at a time and greys out its Create Auction button while one is waiting. So while you're selling, the shopping list pauses by itself (the marker says "Paused: selling") and carries on about 30 seconds after you post. If anything else is using the auction house (its own window, another addon), it waits about 10 seconds ("Waiting: AH busy"). Focus never pauses, because it's for racing.
- Mouse on the auction house: while your mouse is over the auction house window, searching eases off to one search every 2 seconds, so its buttons (like Create Auction) stay usable. The marker says "easy: mouse on AH". With your mouse on Helpme Sniper (or anywhere else) it runs at full speed. To post with nothing searching at all, click Stop.
- Only works for items sold by quantity, not gear or bags.
- Updating from an older version: your Watch List becomes a shopping list called "My list", with the same items, prices and amounts.

## Feedback

Found a bug or have an idea? Open an issue on this GitHub page or tell HelpMe ImDyin.
