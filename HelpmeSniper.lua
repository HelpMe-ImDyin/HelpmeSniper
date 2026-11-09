-- Helpme Sniper v0.7
-- Personal quick-buy sniper for stackable auction house items (cloth, dye, herbs).
-- Standalone: scans the auction house itself, no other addons needed.
--
-- Tabs:
--   Focus          one item, searched as fast as the game allows, live listings
--   Shopping List  named lists of items you need; deals are a % of the normal price (or a
--                  fixed price); "Track totals" counts what you buy until you mark the list
--                  complete; completed lists keep a receipt and can be shopped again
--   Settings       Safety (never spend below, one-click buying, count down reset) and Other
--   History        what you bought and how much you spent today
--
-- Buying: one press of the buy key asks the auction house for the exact price (the game
-- requires a real key press for that). When the price comes back at or under your max, the
-- addon buys straight away. If the game ever refuses the automatic buy, it falls back to
-- "press again to buy". Spamming the key is safe: extra presses are ignored while a buy is
-- in progress. A typo guard refuses to buy when your max is over double the usual price.
-- Works only for items sold by quantity (cloth, herbs, dye, ...), not gear or bags.

local ADDON_NAME = ...
local HS = {}
_G.HelpmeSniper = HS

BINDING_HEADER_HELPMESNIPER = "Helpme Sniper"
BINDING_NAME_HELPMESNIPER_BUY = "Buy (one press; safe to spam)"

-- Prices are stored in copper (100 copper = 1 silver, 10000 copper = 1 gold).
local DEFAULTS = {
	version = 8,
	interval = 0.6,
	autoStart = true,
	sound = true,
	locked = false, -- drag the window anywhere; tick "Lock window position" in Settings to pin it
	autoBuy = true, -- buy as soon as the price comes back (one-press buying)
	countdown = true, -- Focus: quantity is a hard total (untick to buy up to the quantity on every click)
	resetMinutes = 5, -- Focus count down starts over after this many minutes without buying that item
	reserve = 5000, -- keep 50s
	tab = "focus",
	mode = "all", -- "focus" = only the Focus tab's item is searched, "all" = the open shopping list
	items = {}, -- the Focus item's settings
	lists = { { name = "My list", pct = 80, track = true, items = {}, order = {}, log = {} } },
	activeList = 1,
	prices = {},
	history = {},
	names = {}, -- [itemID] = name of everything sold by quantity on the auction house
	notSold = {}, -- [itemID] = true: on the auction house but not sold by quantity (never checked again)
	market = {}, -- [itemID] = { min, qty, at, d = { [day] = { sum, count } } } from the full copies
}

local MAX_ITEMS = 8 -- items per shopping list
local MAX_LISTS = 15
local PCT_MIN, PCT_MAX, PCT_STEP = 10, 150, 5
local LISTING_ROWS = 6 -- cheapest listings shown on the Focus tab
local WINDOW_SECONDS = 60
local MAX_PER_WINDOW = 98 -- the game allows ~100 searches per minute
local MIN_INTERVAL = 0.6
local MAX_INTERVAL = 3.0
local PRICE_KEEP_SECONDS = 3 * 24 * 3600 -- price memory: last 3 days
local MIN_SAMPLES = 10 -- scans needed before "Typical" is trusted
local QUOTE_TIMEOUT, READY_TIMEOUT, BUY_TIMEOUT = 6, 20, 8
-- While a deal is on screen, search less often so the auction house line is free the
-- instant you press buy (a search in flight can delay or swallow the price request).
local DEAL_INTERVAL = 2.0
-- Mouse over the auction house window (you're doing something there, like selling): search
-- only this often, so its own buttons (like Create Auction) stay usable. Anywhere else,
-- including over our window, searching runs at full speed.
local HOVER_INTERVAL = 2.0
-- After every answer, wait until the line has been free this long before asking again, so
-- the auction house's own buttons (like Create Auction) and other addons always get a turn.
local LINE_GAP = 0.3
-- Selling: searching pauses while you put something up for sale, and this long after.
local SELL_PAUSE = 30
-- Someone else (the auction house window, another addon) is using the line: wait this long.
local OTHERS_PAUSE = 10

local db
local ahOpen, scanning = false, false
local lastSend, nextIndex = 0, 1
local sendTimes = {}
local awaiting -- { id = itemID, t = time sent }
local priorityID, focusID
local results = {} -- [itemID] = { avail, total, cheapest }
local pending -- { itemID, qty, expected, quote, stage = quoting|ready|waitline|buying, t, auto }
local selected, editID
local dealMsgID -- the item whose "Deal:" message is on the status line, so it can be cleared
local typingMax -- the Focus max price while it's being typed (for the live typo warning)
local nameSearch -- an item name you typed that's being looked up on the auction house (Enter)
local full -- the full auction house copy in progress (see "Full scan")
local namesDirty, namesRefreshAt = false, 0 -- new names learned: refresh the open list
local keyWaiting = {} -- [itemID] = auction house item whose name the game is still loading
local ui = {}
local sellUntil, othersUntil = 0, 0 -- searching pauses until these times (you're selling / the line is in use)
local lineFreeSince -- when the auction house line last became free (nil while it's busy)
local checkSoon = {} -- shopping list items the last full copy says may be a deal: check live first
local function ClearCheckSoon()
	for k in pairs(checkSoon) do checkSoon[k] = nil end
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function DeepCopy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = DeepCopy(v) end
	return out
end

local function Print(msg)
	print("|cff33ff99Helpme Sniper:|r " .. msg)
end

local function Money(c)
	c = math.floor((c or 0) + 0.5)
	local g = math.floor(c / 10000)
	local s = math.floor((c % 10000) / 100)
	local cp = c % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "|cffffd700g|r" end
	if s > 0 then parts[#parts + 1] = s .. "|cffc7c7cfs|r" end
	if cp > 0 or #parts == 0 then parts[#parts + 1] = cp .. "|cffeda55fc|r" end
	return table.concat(parts, " ")
end

-- Same as Money but without the gold/silver/copper colors, for text that has its own color.
local function MoneyPlain(c)
	c = math.floor((c or 0) + 0.5)
	local g = math.floor(c / 10000)
	local s = math.floor((c % 10000) / 100)
	local cp = c % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "g" end
	if s > 0 then parts[#parts + 1] = s .. "s" end
	if cp > 0 or #parts == 0 then parts[#parts + 1] = cp .. "c" end
	return table.concat(parts, " ")
end

-- Accepts 20c, 27s, 1s50, 1s50c, 2g, 2g50s, 2g50, or a plain number of copper (slash commands).
local function ParseMoney(s)
	if not s then return nil end
	s = s:lower():gsub("%s", "")
	if s:match("^%d+$") then return tonumber(s) end
	local g = tonumber(s:match("(%d+)g")) or 0
	local sv = tonumber(s:match("(%d+)s")) or 0
	local c = tonumber(s:match("(%d+)c")) or 0
	if not s:find("c") then
		if s:find("s") then
			c = tonumber(s:match("s(%d+)$")) or c
		elseif s:find("g") then
			sv = tonumber(s:match("g(%d+)$")) or sv
		end
	end
	local v = g * 10000 + sv * 100 + c
	if v > 0 then return v end
	return nil
end

local function ItemName(id)
	local name
	if C_Item and C_Item.GetItemNameByID then name = C_Item.GetItemNameByID(id) end
	if not name and GetItemInfo then name = GetItemInfo(id) end
	if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
	return name or ("item " .. id)
end

local function SetStatus(msg, r, g, b)
	dealMsgID = nil
	if ui.msg then
		ui.msg:SetText(msg)
		ui.msg:SetTextColor(r or 1, g or 1, b or 1)
	end
end

local function PlayAlert()
	if db.sound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959) end
end

local function CancelQuote()
	if C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
		pcall(C_AuctionHouse.CancelCommoditiesPurchase)
	end
end

-- Right after a buy the game can take a moment to lower your gold total. Until it catches
-- up (or 10 seconds pass), the addon uses its own lower figure so it can't overspend.
local moneyCap, moneyCapAt

local function Money_Now()
	local m = GetMoney()
	if moneyCap then
		if m <= moneyCap or GetTime() - moneyCapAt > 10 then
			moneyCap = nil -- the game has caught up
		else
			m = moneyCap
		end
	end
	return m
end

local function Spendable()
	return math.max(0, Money_Now() - (db.reserve or 0))
end

-- True when the auction house can take a new request right now.
local function LineReady()
	return not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady()
end

-- Count down: starts over once you haven't bought this item for db.resetMinutes.
local function ResetIfStale(cfg)
	if cfg.boughtAt and time() - cfg.boughtAt >= (db.resetMinutes or 5) * 60 then
		cfg.bought, cfg.boughtAt = 0, nil
	end
end

-- The shopping list that's open (only that one is searched).
local function ActiveList()
	return db.lists and db.lists[db.activeList or 1]
end

-- An item's settings for the tab you're on: the Focus item's, or the open shopping list's.
local function Cfg(id)
	if not id then return nil end
	if db.mode == "focus" then return db.items[id] end
	local L = ActiveList()
	return L and not L.done and L.items[id] or nil
end

-- Shopping list item with Track totals on, and all of it bought.
local function ItemDone(L, cfg)
	return L.track and (cfg.got or 0) >= cfg.qty
end

-- How many more of this item you still want right now.
local function Remaining(cfg)
	if cfg.kind == "list" then
		local L = ActiveList()
		if L and L.track then return math.max(0, cfg.qty - (cfg.got or 0)) end
		return cfg.qty
	end
	if not db.countdown then return cfg.qty end
	ResetIfStale(cfg)
	return math.max(0, cfg.qty - (cfg.bought or 0))
end

local function ResetCountdown(cfg)
	cfg.bought, cfg.boughtAt = 0, nil
end

-- "resets in 3:12" for the count down line
local function ResetIn(cfg)
	if not cfg.boughtAt then return nil end
	local left = math.max(0, (db.resetMinutes or 5) * 60 - (time() - cfg.boughtAt))
	return ("%d:%02d"):format(math.floor(left / 60), left % 60)
end

-- Reads an item link, an item ID, or an item name (names only work for items the game has loaded).
local function ItemIDFromText(text)
	if not text then return nil end
	local id = tonumber(text:match("item:(%d+)")) or tonumber(text:match("^%s*(%d+)%s*$"))
	if id then return id end
	local name = text:match("^%s*(.-)%s*$")
	if name and name ~= "" then
		local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
		local ok, _, link = pcall(getInfo, name)
		if ok and type(link) == "string" then return tonumber(link:match("item:(%d+)")) end
	end
	return nil
end

-- ============================================================================
-- Price memory (the addon's own record of the cheapest price it has seen)
-- ============================================================================

local function RecordPrice(id, price)
	if not price then return end
	local list = db.prices[id]
	if not list then
		list = {}
		db.prices[id] = list
	end
	local now = time()
	local last = list[#list]
	if last and now - last[1] < 60 then
		-- one sample per minute: keep the lowest price seen in that minute
		if price < last[2] then last[2] = price end
		return
	end
	list[#list + 1] = { now, price }
	local cutoff = now - PRICE_KEEP_SECONDS
	if list[1] and list[1][1] < cutoff then
		local kept = {}
		for _, s in ipairs(list) do
			if s[1] >= cutoff then kept[#kept + 1] = s end
		end
		db.prices[id] = kept
	end
end

-- ============================================================================
-- Market prices from the full auction house copy (see "Full scan" below).
-- Each copy gives every item one price, worked out from its cheaper listings so a few silly
-- listings don't skew it. Each day's copies are averaged, and the normal price weighs the
-- last 14 days, recent days most (a day's weight halves about every 2 days).
-- ============================================================================

local MARKET_DAYS = 14
local MARKET_RECENT_DAYS = 3 -- a normal price needs a copy from the last 3 days
local MARKET_MIN_QTY = 3 -- copies with fewer listed than this are too thin to judge a price

local function Day()
	return math.floor(time() / 86400)
end

-- One copy's price for one item. flat = { unitPrice, quantity, unitPrice, quantity, ... }
-- 1. cheapest first, and only the cheapest 30% of what's listed
-- 2. after the first 15%, stop at a price jump of 20% or more
-- 3. drop prices far from the rest (more than 1.5 standard deviations)
-- 4. average what's left (by quantity)
-- Returns the price, the cheapest price, and how many are listed.
local function ScanValue(flat)
	local a = {}
	for j = 1, #flat, 2 do a[#a + 1] = { flat[j], flat[j + 1] } end
	table.sort(a, function(x, y) return x[1] < y[1] end)
	local total = 0
	for _, e in ipairs(a) do total = total + e[2] end
	local kept, seen = {}, 0
	for k, e in ipairs(a) do
		if k > 1 then
			if seen >= 0.30 * total then break end
			if seen >= 0.15 * total and e[1] >= 1.2 * a[k - 1][1] then break end
		end
		kept[#kept + 1] = e
		seen = seen + e[2]
	end
	local w, s = 0, 0
	for _, e in ipairs(kept) do
		w = w + e[2]
		s = s + e[1] * e[2]
	end
	local mean = s / w
	local var = 0
	for _, e in ipairs(kept) do var = var + e[2] * (e[1] - mean) ^ 2 end
	local sd = math.sqrt(var / w)
	local w2, s2 = 0, 0
	for _, e in ipairs(kept) do
		if math.abs(e[1] - mean) <= 1.5 * sd then
			w2 = w2 + e[2]
			s2 = s2 + e[1] * e[2]
		end
	end
	return (w2 > 0 and s2 / w2 or mean), a[1][1], total
end

-- Saves one copy's price for an item.
local function SaveScanPrice(id, flat)
	if #flat < 2 then return end
	local value, cheapest, total = ScanValue(flat)
	value = math.floor(value + 0.5)
	local m = db.market[id]
	if not m then
		m = { d = {} }
		db.market[id] = m
	end
	m.min, m.qty, m.at = math.floor(cheapest + 0.5), total, time()
	if total < MARKET_MIN_QTY then return end -- shows in tooltips, but doesn't count toward normal
	local day = Day()
	local v = m.d[day]
	if v then
		v[1], v[2] = v[1] + value, v[2] + 1
	else
		m.d[day] = { value, 1 }
	end
	for d in pairs(m.d) do
		if day - d > MARKET_DAYS then m.d[d] = nil end
	end
end

-- The normal price from the copies of the last 14 days, or nil if it has none.
local function MarketValue(id)
	local m = db.market and db.market[id]
	if not m or not m.d then return nil end
	local today = Day()
	local sumW, sumV, recent = 0, 0, false
	for day, v in pairs(m.d) do
		local age = today - day
		if age >= 0 and age <= MARKET_RECENT_DAYS then recent = true end
		if age >= 0 and age <= MARKET_DAYS and v[2] > 0 then
			local wt = 0.5 ^ (age / 2)
			sumW = sumW + wt
			sumV = sumV + wt * v[1] / v[2]
		end
	end
	if sumW == 0 or not recent then return nil end
	return math.max(1, math.floor(sumV / sumW + 0.5))
end

-- "12 min", "3 h", "2 days"
local function Ago(t)
	local s = math.max(0, time() - (t or 0))
	if s < 3600 then return math.max(1, math.floor(s / 60)) .. " min" end
	if s < 172800 then return math.floor(s / 3600) .. " h" end
	return math.floor(s / 86400) .. " days"
end

-- Normal price: from the full auction house copies when there are any. Otherwise the middle
-- value of the cheapest prices seen over the last 3 days, or nil (still learning).
local function SampleMedian(id)
	local list = db.prices[id]
	if not list then return nil, 0 end
	local cutoff = time() - PRICE_KEEP_SECONDS
	local vals = {}
	for _, s in ipairs(list) do
		if s[1] >= cutoff then vals[#vals + 1] = s[2] end
	end
	if #vals < MIN_SAMPLES then return nil, #vals end
	table.sort(vals)
	local n = #vals
	if n % 2 == 1 then return vals[(n + 1) / 2], n end
	return math.floor((vals[n / 2] + vals[n / 2 + 1]) / 2), n
end

local function Typical(id)
	local mv = MarketValue(id)
	local med, n = SampleMedian(id)
	-- Safety: never more than 1.5x what the fast searching has seen, so one odd copy
	-- (say a few overpriced listings) can't make a high price look normal.
	if mv and med then return math.min(mv, math.floor(med * 1.5)), n end
	if mv then return mv, MIN_SAMPLES end
	return med, n
end

local function LowToday(id)
	local list = db.prices[id]
	if not list then return nil end
	local cutoff = time() - 86400
	local low
	for _, s in ipairs(list) do
		if s[1] >= cutoff and (not low or s[2] < low) then low = s[2] end
	end
	return low
end

-- ============================================================================
-- Deals
-- ============================================================================

local function Target()
	if db.mode == "focus" then
		local r = focusID and results[focusID]
		return (r and r.avail > 0) and focusID or nil
	end
	if selected and results[selected] and results[selected].avail > 0 then return selected end
	local L = ActiveList()
	for _, id in ipairs(L and L.order or {}) do
		local r = results[id]
		if r and r.avail > 0 then return id end
	end
	return nil
end

-- The most you'll pay for one. Shopping list items can be a % of the normal price, which
-- gives nil (don't buy) until the normal price is known. Otherwise it's the price you typed.
local function MaxFor(cfg, id)
	if cfg.kind == "list" and cfg.mode ~= "fixed" then
		local typ = Typical(id)
		local L = ActiveList()
		local pct = cfg.pct or (L and L.pct) or 80
		return typ and math.max(1, math.floor(typ * pct / 100)) or nil
	end
	return (cfg.max or 0) > 0 and cfg.max or nil
end

-- Typo guard: a max more than double the usual price (or, while still learning, double
-- the cheapest listing right now) looks like a mistake, e.g. 20g instead of 20c.
-- Nothing is bought until you click "I meant it" (which only covers that exact max).
-- Returns the usual price when the max looks like a typo, otherwise nil.
local function TypoRef(cfg, itemID, max, cheapestNow)
	local ref = Typical(itemID) or cheapestNow
	if cfg and ref and (max or 0) > 2 * ref and cfg.okMax ~= max then return ref end
	return nil
end

-- Works out how many to buy (and the cost) from the listings at or under your max,
-- cheapest first, up to what you still want and what you can afford.
local function Fill(cfg, under, typo)
	local need = typo and 0 or Remaining(cfg)
	local money = Spendable()
	local avail, total = 0, 0
	for _, l in ipairs(under) do
		if avail >= need then break end
		local want = need - avail
		local afford = math.floor((money - total) / l.price)
		local take = math.min(l.qty, want, afford)
		if take > 0 then
			avail = avail + take
			total = total + take * l.price
		end
		if take < math.min(l.qty, want) then break end -- out of gold
	end
	return avail, total
end

local function Evaluate(itemID)
	local cfg = Cfg(itemID)
	if not cfg then return end
	local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
	local first = n > 0 and C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
	local cheapest = first and first.unitPrice or nil
	RecordPrice(itemID, cheapest) -- first, so a % of normal can use the newest price memory
	local max = MaxFor(cfg, itemID)
	local listings, under = {}, {}
	local active = (cfg.enabled ~= false or itemID == focusID) and max ~= nil
	for i = 1, n do
		local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		if not info then break end
		local price = info.unitPrice
		local q = (info.quantity or 0) - (info.numOwnerItems or 0) -- skip your own auctions
		if i <= LISTING_ROWS then listings[#listings + 1] = { price = price, qty = q } end
		local cheapEnough = active and price <= max
		if cheapEnough and q > 0 then under[#under + 1] = { price = price, qty = q } end
		if i >= LISTING_ROWS and not cheapEnough then break end
	end
	local typoRef = max and TypoRef(cfg, itemID, max, cheapest)
	local avail, total = Fill(cfg, under, typoRef)
	local prev = results[itemID]
	results[itemID] = { avail = avail, total = total, cheapest = cheapest, listings = listings, under = under, time = GetTime(), typo = typoRef, max = max }
	local relevant = db.mode ~= "focus" or itemID == focusID -- don't announce other items while on Focus
	if avail > 0 and (not prev or prev.avail == 0) and relevant then
		PlayAlert()
		if not pending then
			SetStatus(("Deal: %d %s at avg %s. Press BUY!"):format(avail, ItemName(itemID), Money(total / avail)), 0.3, 1, 0.3)
			dealMsgID = itemID
		end
	elseif avail == 0 and dealMsgID == itemID and not pending then
		SetStatus("") -- that deal is gone: don't leave an old message up
	end
	HS.Refresh()
end

-- ============================================================================
-- Buying (bound to a key, a macro, or the BUY button)
-- ============================================================================

-- The final "buy" for the price we were quoted. auto = sent by the addon, not by a key press.
local function SendConfirm(auto)
	pending.stage = "buying"
	pending.auto = auto
	pending.t = GetTime()
	SetStatus(("Buying %d %s for %s..."):format(pending.qty, ItemName(pending.itemID), Money(pending.quote)), 1, 1, 0)
	lineFreeSince = nil
	C_AuctionHouse.ConfirmCommoditiesPurchase(pending.itemID, pending.qty)
end

function HelpmeSniper_BuyStep()
	if not db then return end
	if not ahOpen then
		Print("Open the auction house first.")
		return
	end
	if pending then
		if pending.stage == "ready" then
			if LineReady() then
				SendConfirm(false)
			else
				SetStatus("Auction house busy for a split second. Press again.", 1, 1, 0)
			end
		end
		-- Getting the price or already buying: extra presses do nothing, so spamming is safe.
		HS.Refresh()
		return
	end
	local id = Target()
	if not id then
		SetStatus("No deals right now.", 0.7, 0.7, 0.7)
		return
	end
	if not LineReady() then
		-- The price request needs this exact key press, so it can't be saved for later.
		SetStatus("Auction house busy for a split second. Press again.", 1, 1, 0)
		return
	end
	local r = results[id]
	local cfg = Cfg(id)
	pending = {
		itemID = id, qty = r.avail, expected = r.total, max = r.max, stage = "quoting", t = GetTime(), moneyAtStart = Money_Now(),
		cfg = cfg, list = (cfg and cfg.kind == "list") and ActiveList() or nil, -- where to count the purchase
	}
	lineFreeSince = nil
	C_AuctionHouse.StartCommoditiesPurchase(id, r.avail)
	SetStatus(("Getting price for %d %s..."):format(r.avail, ItemName(id)), 1, 1, 0)
	HS.Refresh()
end

-- ============================================================================
-- Scanning
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Selling: the auction house handles one request at a time, and greys out its own
-- Create Auction button while any request is waiting. So while you're selling, the addon
-- stays off the line. It notices selling from the game's own steps (working out the
-- deposit, posting), which works however the auction house window looks.
-- ----------------------------------------------------------------------------

local function NoteSelling()
	sellUntil = GetTime() + SELL_PAUSE
end

local function SellFrameShown()
	local f = _G.AuctionHouseFrame
	if not f then return false end
	for _, key in ipairs({ "ItemSellFrame", "CommoditiesSellFrame" }) do
		local s = f[key]
		if s and s.IsVisible and s:IsVisible() then return true end
	end
	return false
end

-- Why searching is paused right now: "selling", "busy" (someone else is using the line), or nil.
local function PauseReason(now)
	if now < sellUntil or SellFrameShown() then return "selling" end
	if now < othersUntil then return "busy" end
	return nil
end

do
	local function hookIf(tbl, name)
		if tbl and type(tbl[name]) == "function" then pcall(hooksecurefunc, tbl, name, NoteSelling) end
	end
	for _, name in ipairs({ "CalculateItemDeposit", "CalculateCommodityDeposit", "PostItem", "PostCommodity" }) do
		hookIf(C_AuctionHouse, name)
	end
	-- older-style auction house functions, in case this client's selling page uses them
	for _, name in ipairs({ "CalculateAuctionDeposit", "GetAuctionDeposit", "PostAuction", "StartAuction", "ClickAuctionSellItemButton" }) do
		hookIf(_G, name)
	end
end

-- True once the line has been free for LINE_GAP seconds (Tick keeps lineFreeSince up to date).
local function LineFree(now)
	return lineFreeSince ~= nil and now - lineFreeSince >= LINE_GAP
end


-- True while the mouse is over the auction house window and not over ours (or our name list).
local function MouseOnAH()
	local ah = _G.AuctionHouseFrame or _G.AuctionFrame
	if not (ah and ah:IsVisible() and ah:IsMouseOver()) then return false end
	if ui.frame and ui.frame:IsVisible() and ui.frame:IsMouseOver() then return false end
	if ui.picker and ui.picker:IsVisible() and ui.picker:IsMouseOver() then return false end
	if ui.guide and ui.guide:IsVisible() and ui.guide:IsMouseOver() then return false end
	return true
end

local function CanSend(now)
	while sendTimes[1] and now - sendTimes[1] >= WINDOW_SECONDS do table.remove(sendTimes, 1) end
	if #sendTimes >= MAX_PER_WINDOW then return false end
	local interval = db.interval or MIN_INTERVAL
	if not priorityID and ui.mouseOnAH then interval = math.max(interval, HOVER_INTERVAL) end -- leave the auction house room
	if not priorityID and Target() then interval = math.max(interval, DEAL_INTERVAL) end -- keep the line free for your press
	if now - lastSend < interval then return false end
	if awaiting and now - awaiting.t < 3 then return false end -- wait for the last answer (max 3s)
	return LineFree(now)
end

local function NextItem()
	if priorityID then
		local id = priorityID
		priorityID = nil
		if Cfg(id) then return id end
	end
	if not scanning then return nil end
	while checkSoon[1] do
		local id = table.remove(checkSoon, 1)
		if Cfg(id) and db.mode ~= "focus" then return id end
	end
	if db.mode == "focus" then
		return (focusID and db.items[focusID]) and focusID or nil
	end
	-- Shopping list: ticked items take turns; finished ones (Track totals) are skipped,
	-- so the rest get checked more often.
	local L = ActiveList()
	if not L or L.done then return nil end
	local n = #L.order
	for _ = 1, n do
		if nextIndex > n then nextIndex = 1 end
		local id = L.order[nextIndex]
		nextIndex = nextIndex + 1
		local cfg = L.items[id]
		if cfg and cfg.enabled ~= false and not ItemDone(L, cfg) then return id end
	end
	return nil
end

local function Tick()
	if not db or not ahOpen then return end
	local now = GetTime()
	if LineReady() then
		lineFreeSince = lineFreeSince or now
	else
		lineFreeSince = nil
		-- The line is busy but not with anything of ours: the auction house window or another
		-- addon (say, posting through another addon) is using it. Step aside for a while.
		local ours = pending or (awaiting and now - awaiting.t < 3) or (full and full.stage == "wait")
			or (nameSearch and nameSearch.sent) or now - lastSend < 1.5
		if not ours then othersUntil = now + OTHERS_PAUSE end
	end
	-- Focus never pauses: it's for racing, and a paused Focus would look broken. Only the
	-- shopping list (and the 15-minute copy) step aside while you sell or the line is in use.
	local rawPause = PauseReason(now)
	local pause = db.mode ~= "focus" and rawPause or nil
	-- Selling while Focus races: say once (per auction house visit) why posting may flicker.
	if rawPause == "selling" and db.mode == "focus" and scanning and not ui.focusSellTip and not pending and not dealMsgID then
		ui.focusSellTip = true
		SetStatus("Focus is racing, so Create Auction may flicker. Click Stop to post freely.", 1, 0.82, 0)
	end
	local onAH = MouseOnAH()
	if pause ~= ui.pauseShown or onAH ~= ui.mouseOnAH then
		ui.pauseShown, ui.mouseOnAH = pause, onAH
		HS.Refresh() -- the Live marker says why it's paused or easing off
	end
	if HS.UpdateAge then HS.UpdateAge(now) end
	if namesDirty and now - namesRefreshAt > 0.5 then
		namesRefreshAt = now
		HS.RefreshNames()
	end
	-- A name you pressed Enter on that isn't in the item list: search the auction house once
	-- the line is free (never in the middle of a purchase).
	if nameSearch and not pending then
		if not nameSearch.sent then
			if now >= nameSearch.due and not rawPause and LineFree(now) and (not Target() or now - (nameSearch.made or 0) > 3) then HS.SendNameSearch() end
		elseif not nameSearch.waiting and now - nameSearch.sent > 5 then
			local s = nameSearch
			nameSearch = nil
			if ui.picker and ui.picker:IsShown() and ui.picker.box == s.box then
				ui.picker.title:SetText("No answer from the auction house. Keep typing or press Enter.")
			end
		end
	end
	if pending then
		if pending.stage == "waitline" and LineReady() then
			SendConfirm(true) -- the line just freed up: buy now
			HS.Refresh()
			return
		end
		local limit = (pending.stage == "buying" and BUY_TIMEOUT) or ((pending.stage == "quoting" or pending.stage == "waitline") and QUOTE_TIMEOUT) or READY_TIMEOUT
		if now - pending.t > limit then
			if pending.stage ~= "buying" then CancelQuote() end
			SetStatus("Timed out, cancelled. Nothing was bought.", 1, 0.6, 0.2)
			pending = nil
			HS.Refresh()
		end
		return -- no searching while a purchase is in progress
	end
	if not full and not rawPause then HS.StartFullScan() end
	if full and HS.FullScanStep(now, rawPause) then return end
	if pause then return end -- shopping list: you're selling, or someone else is using the line
	if not scanning and not priorityID then return end
	if not CanSend(now) then return end
	local id = NextItem()
	if not id then return end
	lastSend = now
	lineFreeSince = nil
	sendTimes[#sendTimes + 1] = now
	awaiting = { id = id, t = now }
	C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(id), {}, true)
end

-- ============================================================================
-- Shopping lists
-- ============================================================================

local function NewListTable(name)
	return { name = name, pct = 80, track = true, items = {}, order = {}, log = {} }
end

-- Opens a list: it becomes the one that's searched.
function HS.OpenList(i)
	if not db.lists[i] then return end
	db.activeList = i
	ClearCheckSoon()
	results = {}
	selected, editID = nil, nil
	nextIndex = 1
	if dealMsgID then SetStatus("") end
	HS.Refresh()
end

function HS.NewList(name)
	if #db.lists >= MAX_LISTS then
		Print("You have " .. MAX_LISTS .. " lists already. Delete one first.")
		return
	end
	name = (name or ""):match("^%s*(.-)%s*$")
	if name == "" then name = "List " .. (#db.lists + 1) end
	table.insert(db.lists, NewListTable(name))
	HS.OpenList(#db.lists)
end

function HS.RenameList(L, name)
	name = (name or ""):match("^%s*(.-)%s*$")
	if L and name ~= "" then L.name = name end
	HS.Refresh()
end

-- Same items, prices and amounts, nothing bought yet.
function HS.CopyList(i)
	local src = db.lists[i]
	if not src then return end
	if #db.lists >= MAX_LISTS then
		Print("You have " .. MAX_LISTS .. " lists already. Delete one first.")
		return
	end
	local L = NewListTable(src.name .. " (copy)")
	L.pct, L.track = src.pct, src.track
	for _, id in ipairs(src.order) do
		local c = DeepCopy(src.items[id])
		c.got = 0
		L.items[id] = c
		L.order[#L.order + 1] = id
	end
	table.insert(db.lists, L)
	HS.OpenList(#db.lists)
end

function HS.DeleteList(L)
	local i
	for k, v in ipairs(db.lists) do
		if v == L then i = k end
	end
	if not i then return end
	local wasOpen = i == db.activeList
	table.remove(db.lists, i)
	if #db.lists == 0 then db.lists[1] = NewListTable("My list") end
	if wasOpen then
		HS.OpenList(math.min(i, #db.lists))
	else
		if i < db.activeList then db.activeList = db.activeList - 1 end
		HS.Refresh()
	end
end

-- Finishing a list: it stops being searched and keeps a receipt of what you bought.
function HS.MarkComplete(L)
	L = L or ActiveList()
	if not L or L.done then return end
	L.done = true
	L.doneAt = time()
	if L == ActiveList() then
		results = {}
		selected, editID = nil, nil
	end
	SetStatus(('List "%s" complete.'):format(L.name), 0.3, 1, 0.3)
	HS.Refresh()
end

-- Reopens a completed list with the same items, prices and amounts, and the counts at zero.
function HS.ShopAgain()
	local L = ActiveList()
	if not L then return end
	L.done, L.doneAt = nil, nil
	L.log = {}
	for _, cfg in pairs(L.items) do cfg.got = 0 end
	results = {}
	nextIndex = 1
	SetStatus(('Shopping "%s" again.'):format(L.name), 0.8, 0.8, 0.8)
	HS.Refresh()
end

-- True when every ticked item on a tracked list is fully bought.
local function ListAllBought(L)
	if not L.track or #L.order == 0 then return false end
	for _, id in ipairs(L.order) do
		local cfg = L.items[id]
		if cfg and cfg.enabled ~= false and not ItemDone(L, cfg) then return false end
	end
	return true
end

function HS.AddItem(id)
	if not id or not db then return end
	local L = ActiveList()
	if not L then
		db.lists[1] = NewListTable("My list")
		db.activeList = 1
		L = db.lists[1]
	end
	if L.done then
		Print('"' .. L.name .. '" is completed. Click Shop again first, or make a new list.')
		return
	end
	if L.items[id] then
		Print(ItemName(id) .. " is already on this list.")
	elseif #L.order >= MAX_ITEMS then
		Print("This list is full (" .. MAX_ITEMS .. " items). Remove one, or make a new list.")
		return
	else
		L.items[id] = { kind = "list", mode = "pct", qty = 20, enabled = true, got = 0 }
		table.insert(L.order, id)
		Print(('Added %s to "%s". It counts as a deal at %d%% of its normal price or less.'):format(ItemName(id), L.name, L.pct))
	end
	editID = id
	priorityID = id -- look up its price right away
	HS.Refresh()
end

function HS.RemoveItem(id, L)
	L = L or ActiveList()
	if not L or not L.items[id] then return end
	L.items[id] = nil
	results[id] = nil
	for i = #L.order, 1, -1 do
		if L.order[i] == id then table.remove(L.order, i) end
	end
	if editID == id then editID = nil end
	if selected == id then selected = nil end
	HS.Refresh()
end

function HS.UpdateMode()
	local id = db.focusItem
	focusID = (db.mode == "focus" and id and db.items[id]) and id or nil
end

function HS.SetFocusItem(id)
	if not id or not db then return end
	if not db.items[id] then db.items[id] = { max = 0, qty = 20, enabled = true } end
	db.focusItem = id
	HS.UpdateMode()
	priorityID = id -- look up its price right away
	HS.Refresh()
end

function HS.FocusQty(delta)
	local cfg = db.focusItem and db.items[db.focusItem]
	if cfg then
		cfg.qty = math.max(1, cfg.qty + delta)
		results[db.focusItem] = nil -- the old result was worked out for the old amount
		priorityID = db.focusItem
		HS.Refresh()
	end
end

-- Pop-ups (the game's own dialog boxes)
local function PopupEditBox(self)
	return self.editBox or self.EditBox or (self.GetName and self:GetName() and _G[self:GetName() .. "EditBox"])
end

local function PopupText(self)
	local eb = PopupEditBox(self)
	return eb and eb:GetText() or ""
end

local function NamePopup(text, onAccept, onShow)
	return {
		text = text,
		button1 = OKAY,
		button2 = CANCEL,
		hasEditBox = true,
		maxLetters = 40,
		OnShow = function(self, data)
			local eb = PopupEditBox(self)
			if eb then
				eb:SetText(onShow and onShow(data) or "")
				eb:SetFocus()
				eb:HighlightText()
			end
		end,
		OnAccept = function(self, data) onAccept(PopupText(self), data) end,
		EditBoxOnEnterPressed = function(self)
			local p = self:GetParent()
			onAccept(PopupText(p), p.data)
			p:Hide()
		end,
		EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
end

StaticPopupDialogs["HELPMESNIPER_NEWLIST"] = NamePopup("Name your new shopping list:", function(name) HS.NewList(name) end)
StaticPopupDialogs["HELPMESNIPER_RENAMELIST"] = NamePopup("Rename this list:",
	function(name, L) HS.RenameList(L, name) end,
	function(L) return L and L.name or "" end)

local function YesNo(text, onAccept)
	return {
		text = text,
		button1 = YES,
		button2 = NO,
		OnAccept = function(_, data) onAccept(data) end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
end

StaticPopupDialogs["HELPMESNIPER_REMOVE"] = YesNo("Remove %s from this list?", function(d) HS.RemoveItem(d.id, d.list) end)
StaticPopupDialogs["HELPMESNIPER_DELETELIST"] = YesNo('Delete the list "%s"? This can\'t be undone.', function(L) HS.DeleteList(L) end)
StaticPopupDialogs["HELPMESNIPER_COMPLETE"] = YesNo('Some items aren\'t fully bought yet. Mark "%s" complete anyway?', function(L) HS.MarkComplete(L) end)

-- ============================================================================
-- UI building blocks
-- ============================================================================

local function Text(parent, template, x, y, width, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", x, y)
	if width then fs:SetWidth(width) end
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(false)
	return fs
end

local function Button(parent, label, x, y, w, h, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(w, h or 20)
	b:SetPoint("TOPLEFT", x, y)
	b:SetText(label)
	b:SetNormalFontObject("GameFontNormalSmall")
	b:SetHighlightFontObject("GameFontHighlightSmall")
	if onClick then b:SetScript("OnClick", onClick) end
	return b
end

local function Check(parent, label, x, y, onClick)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(22, 22)
	cb:SetPoint("TOPLEFT", x, y)
	if label then
		local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
		fs:SetText(label)
	end
	cb:SetScript("OnClick", onClick)
	return cb
end

-- A small hover tip.
local function Tip(frame, text)
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(text, 1, 1, 1)
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- The small "Live" / "Paused" marker: a colored square plus a word.
local function LiveText()
	if ui.pauseShown == "selling" then
		return "|TInterface\\Buttons\\WHITE8X8:8:8:0:0:8:8:0:8:0:8:255:209:0|t |cffffd100Paused: selling|r"
	elseif ui.pauseShown == "busy" then
		return "|TInterface\\Buttons\\WHITE8X8:8:8:0:0:8:8:0:8:0:8:255:209:0|t |cffffd100Waiting: AH busy|r"
	end
	if scanning and ui.mouseOnAH then
		return "|TInterface\\Buttons\\WHITE8X8:8:8:0:0:8:8:0:8:0:8:51:255:51|t |cff33ff33Live|r |cffaaaaaa(easy: mouse on AH)|r"
	elseif scanning then
		return "|TInterface\\Buttons\\WHITE8X8:8:8:0:0:8:8:0:8:0:8:51:255:51|t |cff33ff33Live|r"
	end
	return "|TInterface\\Buttons\\WHITE8X8:8:8:0:0:8:8:0:8:0:8:255:136:51|t |cffff8833Paused - click Start|r"
end

local function NumberBox(parent, x, y, w, maxLetters)
	local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	eb:SetSize(w, 18)
	eb:SetPoint("TOPLEFT", x + 6, y)
	eb:SetAutoFocus(false)
	eb:SetNumeric(true)
	eb:SetMaxLetters(maxLetters)
	eb:SetJustifyH("RIGHT")
	eb:SetFontObject("GameFontHighlightSmall")
	return eb
end

-- Three boxes for gold / silver / copper. onCommit(copper) runs when you press Enter or click away.
-- onChange(copper), if given, runs on every keystroke.
local function MoneyBoxes(parent, x, y, onCommit, onChange)
	local boxes = {}
	local specs = { { w = 34, max = 5, suffix = "|cffffd700g|r" }, { w = 22, max = 2, suffix = "|cffc7c7cfs|r" }, { w = 22, max = 2, suffix = "|cffeda55fc|r" } }
	local cx = x
	for i, sp in ipairs(specs) do
		local eb = NumberBox(parent, cx, y, sp.w, sp.max)
		local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		lbl:SetPoint("LEFT", eb, "RIGHT", 2, 0)
		lbl:SetText(sp.suffix)
		eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		eb:SetScript("OnEscapePressed", function(self)
			boxes.cancel = true
			self:ClearFocus()
		end)
		eb:SetScript("OnTabPressed", function() boxes[i % 3 + 1]:SetFocus() end)
		if onChange then
			eb:SetScript("OnTextChanged", function(_, userInput)
				if userInput then onChange(boxes.Get()) end
			end)
		end
		eb:SetScript("OnEditFocusLost", function()
			if boxes.cancel then
				boxes.cancel = nil
				if onChange then onChange(nil) end -- Escape: drop the half-typed number
				HS.Refresh()
				return
			end
			onCommit(boxes.Get())
		end)
		boxes[i] = eb
		cx = cx + sp.w + 20
	end
	function boxes.Get()
		return (tonumber(boxes[1]:GetText()) or 0) * 10000 + (tonumber(boxes[2]:GetText()) or 0) * 100 + (tonumber(boxes[3]:GetText()) or 0)
	end
	function boxes.Set(v)
		if boxes[1]:HasFocus() or boxes[2]:HasFocus() or boxes[3]:HasFocus() then return end
		v = math.floor(v or 0)
		boxes[1]:SetText(tostring(math.floor(v / 10000)))
		boxes[2]:SetText(tostring(math.floor((v % 10000) / 100)))
		boxes[3]:SetText(tostring(v % 100))
	end
	function boxes.Show(show)
		for j = 1, 3 do boxes[j]:SetShown(show) end
	end
	return boxes
end

-- ============================================================================
-- Full scan: one request copies the whole auction house (every item, how many, the price).
-- It isn't a search, so nothing changes in the auction house window. The game allows one
-- copy every 15 minutes per account. Each copy updates the item name list (everything sold
-- by quantity; gear and bags are skipped) and the market prices.
-- ============================================================================

local FULL_SCAN_EVERY = 15 * 60 + 10 -- the game's limit is one copy per 15 minutes
local SCAN_WAIT = 90 -- no copy after this many seconds: give up until the next turn
local SCAN_RETRY = 60 -- the request itself errored: try again after this many seconds
local READ_BATCH = 500 -- auctions read per tick (spread out so the game doesn't stutter)
local CALC_BATCH = 150 -- items worked out per tick
local GEAR_CLASSES = { [1] = true, [2] = true, [4] = true, [17] = true } -- bags, weapons, armor, pets
local scanRetryAt = 0
local gearCache = {} -- [itemID] = true/false for this session
local lowerNames = {} -- [itemID] = lowercase name for this session (fast typing search)
local nameWait = {} -- [itemID] = true while the game loads an item's name

local function IsGearID(id)
	local cached = gearCache[id]
	if cached ~= nil then return cached end
	local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if not instant then return false end
	local classID = select(6, instant(id))
	if classID == nil then return false end -- unknown yet: check again next time
	cached = GEAR_CLASSES[classID] == true
	gearCache[id] = cached
	return cached
end

-- The item's name if it's sold by quantity, false if it isn't, nil if the game hasn't loaded it.
local function NameIfStackable(id)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local name, _, _, _, _, _, _, stack = getInfo(id)
	if not name or not stack then return nil end
	if stack > 1 then return name end
	return false
end

local function SetName(id, name)
	if name == false then db.notSold[id] = true end
	if name then db.notSold[id] = nil end
	if name ~= nil then lowerNames[id] = nil end
	if name and db.names[id] ~= name then
		db.names[id] = name
		namesDirty = true
	elseif name == false and db.names[id] then
		db.names[id] = nil
		namesDirty = true
	end
end

-- True for things sold by quantity (cloth, herbs, dye...), false for gear, bags and pets.
local function IsCommodityInfo(info)
	if info.isCommodity ~= nil then return info.isCommodity end
	return not info.isEquipment and not info.isPet
end

-- Remembers a name from an auction house search (the Enter search, or your own searches).
local function LearnKey(key)
	local id = key and key.itemID
	if not id or id == 0 then return end
	if IsGearID(id) then
		keyWaiting[id] = nil
		return
	end
	local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(key)
	if not info or not info.itemName or info.itemName == "" then
		keyWaiting[id] = key -- the game is still loading it: ITEM_KEY_ITEM_INFO_RECEIVED tries again
		return
	end
	keyWaiting[id] = nil
	SetName(id, IsCommodityInfo(info) and info.itemName or false)
end

local function LearnBrowse(list)
	if type(list) ~= "table" then return end
	for _, res in ipairs(list) do LearnKey(res.itemKey) end
end

-- Items the addon already knows (your lists, your Focus item, items it has priced).
local function SeedNames()
	local function add(id)
		if type(id) ~= "number" or db.names[id] then return end
		local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
		if name and name ~= "" then
			db.names[id] = name
		elseif C_Item and C_Item.RequestLoadItemDataByID then
			C_Item.RequestLoadItemDataByID(id) -- there next time
		end
	end
	for id in pairs(db.prices) do add(id) end
	for id in pairs(db.items) do add(id) end
	for _, L in ipairs(db.lists) do
		for id in pairs(L.items) do add(id) end
	end
end

-- Starts a copy if the last one was over 15 minutes ago (checked often while the AH is open).
function HS.StartFullScan()
	if full or not ahOpen or not C_AuctionHouse.ReplicateItems then return end
	if db.scanAt and time() - db.scanAt < FULL_SCAN_EVERY then return end
	-- One request per 15 minutes, even if the last one never arrived (the game allows no more).
	if db.scanAskedAt and time() - db.scanAskedAt < FULL_SCAN_EVERY then return end
	if GetTime() < scanRetryAt then return end
	full = { stage = "ask", t = GetTime() + 2 } -- 2s: let the auction house window settle first
end

local function FailScan(retrySoon)
	full = nil
	if retrySoon then scanRetryAt = GetTime() + SCAN_RETRY end
	namesDirty = true
end

local function FinishScan()
	local count = full.count or 0
	local since = full.arrivedAt or 0
	full = nil
	if scanning and db.mode ~= "focus" then
		local L = ActiveList()
		for _, id in ipairs(L and not L.done and L.order or {}) do
			local cfg, m = L.items[id], db.market[id]
			local max = cfg and MaxFor(cfg, id)
			local queued = false
			for _, q in ipairs(checkSoon) do
				if q == id then queued = true end
			end
			if not queued and cfg and cfg.enabled ~= false and not ItemDone(L, cfg) and m and m.min and m.at
				and m.at >= since and max and m.min <= max then
				checkSoon[#checkSoon + 1] = id
			end
		end
	end
	db.scanAt = time()
	namesDirty = true
	if not pending and not dealMsgID then
		SetStatus(("Auction house copied: %d items priced."):format(count), 0.6, 0.8, 1)
	end
	HS.Refresh()
end

-- The copy arrived (REPLICATE_ITEM_LIST_UPDATE).
function HS.FullScanArrived()
	if not full and ahOpen and db.scanAskedAt and time() - db.scanAskedAt < 180
		and (not db.scanAt or db.scanAt < db.scanAskedAt) then
		full = { stage = "wait", t = GetTime() } -- it came late, but it's still good
	end
	if not full or full.stage ~= "wait" then return end
	local n = C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
	if n <= 0 then
		FailScan()
		return
	end
	full.stage, full.i, full.n, full.auctions = "read", 0, n, {}
	full.arrivedAt = time()
end

-- Called by Tick. Returns true when it used the auction house line this time.
function HS.FullScanStep(now, selling)
	if full.stage == "ask" then
		if selling or now < full.t or not LineFree(now) or Target() then return false end
		if not pcall(C_AuctionHouse.ReplicateItems) then
			FailScan(true)
			return false
		end
		db.scanAskedAt = time()
		full.stage, full.t = "wait", now
		lineFreeSince = nil
		lastSend = now
		return true
	elseif full.stage == "wait" then
		if now - full.t > SCAN_WAIT then FailScan() end
	elseif full.stage == "read" then
		local stop = math.min(full.n, full.i + READ_BATCH)
		for i = full.i, stop - 1 do
			local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, id = C_AuctionHouse.GetReplicateItemInfo(i)
			if id and count and count > 0 and buyout and buyout > 0 and not IsGearID(id) then
				local flat = full.auctions[id]
				if not flat then
					flat = {}
					full.auctions[id] = flat
				end
				flat[#flat + 1] = buyout / count
				flat[#flat + 1] = count
			end
		end
		full.i = stop
		if stop >= full.n then
			full.ids = {}
			for id in pairs(full.auctions) do full.ids[#full.ids + 1] = id end
			full.stage, full.k, full.count = "calc", 0, 0
		end
	elseif full.stage == "calc" then
		for _ = 1, CALC_BATCH do
			full.k = full.k + 1
			local id = full.ids[full.k]
			if not id then
				FinishScan()
				return false
			end
			-- Names it already knows (or knows aren't sold by quantity) are never looked up again.
			---@type string|false|nil
			local name = db.names[id]
			if name ~= nil and not db.market[id] then
				local check = NameIfStackable(id) -- first price for it: make sure it's sold by quantity
				if check ~= nil then name = check end
			end
			if name == nil and db.notSold[id] then name = false end
			if name == nil then name = NameIfStackable(id) end
			if name == nil then
				nameWait[id] = true -- asking for it loads it; GET_ITEM_INFO_RECEIVED fills it in
			end
			SetName(id, name)
			if name ~= false then
				SaveScanPrice(id, full.auctions[id])
				full.count = full.count + 1
			elseif db.market[id] then
				db.market[id] = nil -- not sold by quantity
			end
		end
	end
	return false
end

-- An item's details finished loading (GET_ITEM_INFO_RECEIVED).
function HS.ItemLoaded(id)
	if not nameWait[id] then return end
	local name = NameIfStackable(id)
	if name == nil then return end
	nameWait[id] = nil
	SetName(id, name)
	if name == false then db.market[id] = nil end
end

-- Item tooltips (bags, chat links, the search list): one line with the normal price and
-- the cheapest price from the last copy.
local function AddPriceLine(tooltip, id)
	if not db or not id or not tooltip or not tooltip.AddLine then return end
	if tooltip.IsForbidden and tooltip:IsForbidden() then return end
	local typ = MarketValue(id)
	local m = db.market[id]
	if not typ and not (m and m.min) then return end
	local parts = {}
	if typ then parts[#parts + 1] = "normal " .. Money(typ) end
	if m and m.min then parts[#parts + 1] = ("cheapest %s, %d listed (%s ago)"):format(Money(m.min), m.qty or 0, Ago(m.at)) end
	tooltip:AddLine("|cff33ff99Helpme Sniper:|r |cffffffff" .. table.concat(parts, " · ") .. "|r")
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		AddPriceLine(tooltip, data and data.id)
	end)
elseif GameTooltip and GameTooltip.HookScript then
	local function OnItem(tooltip)
		local _, link = tooltip:GetItem()
		AddPriceLine(tooltip, link and tonumber(link:match("item:(%d+)")))
	end
	GameTooltip:HookScript("OnTooltipSetItem", OnItem)
	if ItemRefTooltip then ItemRefTooltip:HookScript("OnTooltipSetItem", OnItem) end
end

-- Names containing what you typed: names that start with it first, then a word that starts
-- with it ("cloth" finds "Wool Cloth"), then the rest; shorter names first.
local function LocalMatches(q)
	local lower = q:lower()
	local matches = {}
	for id, name in pairs(db.names) do
		local ln = lowerNames[id]
		if not ln then
			ln = name:lower()
			lowerNames[id] = ln
		end
		local at = ln:find(lower, 1, true)
		if at then
			local rank = 2
			if at == 1 then
				rank = 0
			elseif ln:sub(at - 1, at - 1) == " " then
				rank = 1
			end
			local m = db.market[id]
			matches[#matches + 1] = { id = id, name = name, rank = rank, qty = m and m.qty, price = m and m.min }
		end
	end
	table.sort(matches, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		if #a.name ~= #b.name then return #a.name < #b.name end
		return a.name < b.name
	end)
	return matches
end

-- ============================================================================
-- Find an item by typing its name, like a search bar: after 2 letters a list of matching
-- items drops down straight away and updates as you type. Click one, or use Up/Down + Enter.
-- ============================================================================

local SUGGEST_ROWS = 8

local function Picker()
	if ui.picker then return ui.picker end
	local pk = CreateFrame("Frame", nil, ui.frame, "BackdropTemplate")
	pk:SetFrameStrata("DIALOG")
	pk:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	pk:SetBackdropColor(0.08, 0.09, 0.1, 0.98)
	pk:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	pk:SetWidth(290)
	pk.title = Text(pk, "GameFontDisableSmall", 6, -6, 250)
	Button(pk, "X", 266, -3, 20, 18, function() HS.ClosePicker() end)
	pk.rows = {}
	for i = 1, SUGGEST_ROWS do
		local b = CreateFrame("Button", nil, pk)
		b:SetSize(282, 18)
		b:SetPoint("TOPLEFT", 4, -22 - (i - 1) * 18)
		local hl = b:CreateTexture(nil, "HIGHLIGHT") -- mouse over
		hl:SetAllPoints()
		hl:SetColorTexture(0.3, 0.5, 0.8, 0.35)
		b.sel = b:CreateTexture(nil, "BACKGROUND") -- chosen with the arrow keys
		b.sel:SetAllPoints()
		b.sel:SetColorTexture(0.3, 0.5, 0.8, 0.35)
		b.sel:Hide()
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetSize(16, 16)
		b.icon:SetPoint("LEFT", 2, 0)
		b.name = Text(b, "GameFontHighlightSmall", 22, -3, 150)
		b.qty = Text(b, "GameFontDisableSmall", 172, -3, 44, "RIGHT")
		b.price = Text(b, "GameFontHighlightSmall", 218, -3, 62, "RIGHT")
		b:SetScript("OnClick", function(self)
			if self.itemID then HS.PickSuggestion(self.itemID) end
		end)
		b:SetScript("OnEnter", function(self)
			if self.itemID and GameTooltip.SetItemByID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.itemID)
				GameTooltip:Show()
			end
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		pk.rows[i] = b
	end
	pk:Hide()
	ui.picker = pk
	return pk
end

function HS.ClosePicker()
	nameSearch = nil
	if ui.picker then ui.picker:Hide() end
end

-- Highlights suggestion number i (for the arrow keys).
local function SelectSuggestion(i)
	local pk = ui.picker
	if not pk then return end
	local n = pk.count or 0
	if n == 0 then
		pk.selected = nil
	else
		pk.selected = ((i - 1) % n) + 1
	end
	for j, b in ipairs(pk.rows) do b.sel:SetShown(j == pk.selected) end
end

-- Opens or updates the list under the box. matches = nil keeps the rows already shown.
local function ShowSuggestions(box, onPick, title, matches)
	local pk = Picker()
	if pk.box ~= box then matches = matches or {} end -- switched to the other box: start clean
	pk.box, pk.onPick = box, onPick
	pk.title:SetText(title or "")
	if matches then
		local n = math.min(#matches, SUGGEST_ROWS)
		for i, b in ipairs(pk.rows) do
			local m = matches[i]
			b.itemID = m and m.id
			if m then
				local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(m.id)) or (GetItemIcon and GetItemIcon(m.id))
				b.icon:SetTexture(icon or 134400)
				b.name:SetText(m.name)
				b.qty:SetText(m.qty and m.qty > 0 and tostring(m.qty) or "")
				b.price:SetText(m.price and Money(m.price) or "")
			end
			b:SetShown(i <= n)
		end
		pk.count = n
		SelectSuggestion(1)
	end
	pk:SetHeight(26 + (pk.count or 0) * 18)
	pk:ClearAllPoints()
	pk:SetPoint("TOP", box, "BOTTOM", 0, -2)
	pk:SetPoint("RIGHT", ui.frame, "RIGHT", -8, 0)
	pk:Show()
end

function HS.PickSuggestion(id)
	local pk = ui.picker
	local box, onPick = pk and pk.box, pk and pk.onPick
	if box then
		box:SetText("")
		box:ClearFocus()
	end
	HS.ClosePicker()
	if onPick and id then onPick(id) end
end

-- Runs on every letter typed into an item box: matching names drop down straight away from
-- the addon's own item list (no auction house search, so nothing changes in its window).
function HS.NameTyped(box, onPick)
	local q = (box:GetText() or ""):match("^%s*(.-)%s*$")
	if #q < 2 or q:find("item:") or q:match("^%d+$") then
		HS.ClosePicker()
		return
	end
	nameSearch = nil -- you kept typing: forget any auction house search for the old text
	local matches = LocalMatches(q)
	local title
	if #matches > 0 then
		title = "Click one, or use Up/Down and Enter"
	elseif full then
		title = "Copying the auction house, one moment..."
	else
		title = "Not in the list yet. Press Enter to search."
	end
	ShowSuggestions(box, onPick, title, matches)
	ui.picker.fromAH = nil
end

-- Refreshes the open list when new names have been learned (Tick calls this).
function HS.RefreshNames()
	namesDirty = false
	local pk = ui.picker
	if not (pk and pk:IsShown() and pk.box and pk.box:HasFocus()) then return end
	if nameSearch or pk.fromAH or (pk.count or 0) >= SUGGEST_ROWS then return end
	if (pk.selected or 1) > 1 or pk:IsMouseOver() then return end -- you're choosing: don't move the rows
	HS.NameTyped(pk.box, pk.onPick)
end

-- Enter in an item box: an ID or link is used straight away; otherwise the highlighted
-- suggestion; with nothing in the list, it searches the auction house and takes a clear match.
function HS.NameEnter(box, onPick)
	local text = box:GetText() or ""
	local id = ItemIDFromText(text)
	local pk = ui.picker
	if not id and pk and pk:IsShown() and pk.box == box and not nameSearch and (pk.count or 0) > 0 and pk.selected then
		id = pk.rows[pk.selected].itemID
	end
	if id then
		box:SetText("")
		box:ClearFocus()
		HS.ClosePicker()
		onPick(id)
		return
	end
	local q = text:match("^%s*(.-)%s*$")
	if #q < 2 or not ahOpen then return end
	nameSearch = { text = q, lower = q:lower(), box = box, onPick = onPick, due = 0, enter = true, made = GetTime() }
	ShowSuggestions(box, onPick, "Searching the auction house...", {})
end

-- Up/Down arrows move through the suggestions.
function HS.NameArrow(box, key)
	local pk = ui.picker
	if not (pk and pk:IsShown() and pk.box == box and (pk.count or 0) > 0) then return end
	if key == "DOWN" then
		SelectSuggestion((pk.selected or 0) + 1)
	elseif key == "UP" then
		SelectSuggestion((pk.selected or 2) - 1)
	end
end

-- Sends the search (Tick calls this once the pause is over and the auction house line is free).
function HS.SendNameSearch()
	local s = nameSearch
	if not s or s.sent then return end
	local sorts = {}
	if Enum and Enum.AuctionHouseSortOrder then
		sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } }
	end
	local now = GetTime()
	s.sent = now
	lineFreeSince = nil
	lastSend = now -- the regular searching waits its turn
	sendTimes[#sendTimes + 1] = now
	C_AuctionHouse.SendBrowseQuery({ searchString = s.text, sorts = sorts, filters = {}, itemClassFilters = {} })
end

-- Reads the results into the list.
function HS.FinishNameSearch(s)
	if nameSearch ~= s then return end -- you kept typing: a newer search replaces this one
	nameSearch = nil
	local seen, matches, exact, loading = {}, {}, nil, 0
	for _, res in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
		local id = res.itemKey and res.itemKey.itemID
		if id and not seen[id] then
			seen[id] = true
			-- Learns the name; gear and bags can't be bought by quantity, so they get no name here.
			LearnKey(res.itemKey)
			local name = db.names[id]
			if not name and keyWaiting[id] then loading = loading + 1 end
			local lower = name and name:lower()
			if lower and lower:find(s.lower, 1, true) then
				matches[#matches + 1] = { id = id, name = name, qty = res.totalQuantity, price = res.minPrice, starts = lower:sub(1, #s.lower) == s.lower }
				if lower == s.lower then exact = id end
			end
		end
	end
	table.sort(matches, function(a, b)
		if a.starts ~= b.starts then return a.starts end
		return #a.name < #b.name
	end)
	if s.enter and (exact or #matches == 1) then
		HS.PickSuggestion(exact or matches[1].id)
		return
	end
	local title
	if #matches == 0 and loading > 0 then
		title = "Still loading names. Press Enter again."
	elseif #matches == 0 then
		title = "Nothing for sale called that right now"
	else
		title = "Click one, or use Up/Down and Enter"
	end
	ShowSuggestions(s.box, s.onPick, title, matches)
	ui.picker.fromAH = true -- these came from the auction house: keep them until you type again
end

-- Hooks an item box up to the search bar behavior.
local function MakeSearchBox(box, onPick)
	if box.SetAltArrowKeyMode then box:SetAltArrowKeyMode(false) end -- plain arrow keys reach the box
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput then HS.NameTyped(self, onPick) end
	end)
	box:SetScript("OnEnterPressed", function(self) HS.NameEnter(self, onPick) end)
	box:SetScript("OnArrowPressed", function(self, key) HS.NameArrow(self, key) end)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
		HS.ClosePicker()
	end)
end

-- ============================================================================
-- Window
-- ============================================================================

local TABS = { { key = "focus", label = "Focus" }, { key = "shop", label = "Shopping List" }, { key = "settings", label = "Settings" }, { key = "history", label = "History" } }

function HS.ShowTab(key)
	if not ui.panels[key] then key = "focus" end
	db.tab = key
	local oldMode = db.mode
	if key == "focus" then
		db.mode = "focus"
	elseif key == "shop" then
		db.mode = "all"
	end
	if db.mode ~= oldMode then results = {} end -- Focus and the shopping list have their own settings
	HS.UpdateMode()
	HS.ClosePicker() -- the search list belongs to the tab you were on
	if ui.listMenu then ui.listMenu:Hide() end
	if dealMsgID and Target() ~= dealMsgID then SetStatus("") end -- switching tabs: drop a deal message that no longer applies
	for _, t in ipairs(TABS) do
		ui.panels[t.key]:SetShown(t.key == key)
		if t.key == key then ui.tabs[t.key]:LockHighlight() else ui.tabs[t.key]:UnlockHighlight() end
	end
	HS.Refresh()
end

-- The menu that drops down from the list name: switch lists, completed lists, rename/copy/delete.
local MENU_ROWS = MAX_LISTS + 4

local function ListMenu()
	if ui.listMenu then return ui.listMenu end
	local m = CreateFrame("Frame", nil, ui.frame, "BackdropTemplate")
	m:SetFrameStrata("DIALOG")
	m:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	m:SetBackdropColor(0.08, 0.09, 0.1, 0.98)
	m:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	m:SetWidth(220)
	m.rows = {}
	for i = 1, MENU_ROWS do
		local b = CreateFrame("Button", nil, m)
		b:SetSize(212, 16)
		b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 16)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(0.3, 0.5, 0.8, 0.35)
		b.text = Text(b, "GameFontHighlightSmall", 4, -2, 204)
		b:SetScript("OnClick", function(self)
			m:Hide()
			if self.action then self.action() end
		end)
		m.rows[i] = b
	end
	m:Hide()
	ui.listMenu = m
	return m
end

function HS.ToggleListMenu()
	local m = ListMenu()
	if m:IsShown() then
		m:Hide()
		return
	end
	local entries = {}
	local function add(text, action) entries[#entries + 1] = { text = text, action = action } end
	local function mark(i) return i == db.activeList and "|cff33ff33> |r" or "   " end
	for i, L in ipairs(db.lists) do
		if not L.done then add(mark(i) .. L.name, function() HS.OpenList(i) end) end
	end
	local anyDone = false
	for _, L in ipairs(db.lists) do
		if L.done then anyDone = true end
	end
	if anyDone then
		add("|cff888888Completed:|r", nil)
		for i, L in ipairs(db.lists) do
			if L.done then add(mark(i) .. "|cffaaaaaa" .. L.name .. "|r", function() HS.OpenList(i) end) end
		end
	end
	local cur = db.activeList
	local curList = db.lists[cur]
	add("|cffffd100Rename this list|r", function() StaticPopup_Show("HELPMESNIPER_RENAMELIST", nil, nil, curList) end)
	add("|cffffd100Copy this list|r", function() HS.CopyList(cur) end)
	add("|cffffd100Delete this list|r", function()
		if curList then StaticPopup_Show("HELPMESNIPER_DELETELIST", curList.name, nil, curList) end
	end)
	for i, b in ipairs(m.rows) do
		local e = entries[i]
		b:SetShown(e ~= nil)
		if e then
			b.text:SetText(e.text)
			b.action = e.action
			b:EnableMouse(e.action ~= nil)
		end
	end
	m:SetHeight(8 + #entries * 16)
	m:ClearAllPoints()
	m:SetPoint("TOPLEFT", ui.listBtn, "BOTTOMLEFT", 0, -2)
	m:Show()
end

local function BuildShopPanel(p)
	-- Row 1: which list, new list, Track totals, Live marker
	ui.listBtn = Button(p, "My list", 0, -2, 150, 22, function() HS.ToggleListMenu() end)
	local arrow = ui.listBtn:CreateTexture(nil, "OVERLAY")
	arrow:SetSize(14, 14)
	arrow:SetPoint("RIGHT", -6, 0)
	arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
	Tip(ui.listBtn, "Switch lists, see completed lists,\nor rename, copy or delete this list")
	Tip(Button(p, "New list", 154, -2, 66, 22, function() StaticPopup_Show("HELPMESNIPER_NEWLIST") end), "Start a new shopping list")
	ui.trackCheck = Check(p, "Track totals", 226, 0, function(self)
		local L = ActiveList()
		if L then
			L.track = self:GetChecked() and true or false
			results = {}
			HS.Refresh()
		end
	end)
	Tip(ui.trackCheck, "On: counts what you buy and never buys past each amount.\nIt remembers until you mark the list complete.\nOff: every click buys up to the amount.")
	ui.shopLive = Text(p, "GameFontHighlightSmall", 350, -8, 104, "RIGHT")

	-- A completed list shows its receipt
	local d = CreateFrame("Frame", nil, p)
	d:SetAllPoints()
	ui.doneView = d
	ui.doneTitle = Text(d, "GameFontNormal", 2, -34, 450)
	ui.doneTotal = Text(d, "GameFontHighlightSmall", 2, -54, 450)
	ui.doneLines = {}
	for i = 1, 9 do
		ui.doneLines[i] = Text(d, "GameFontHighlightSmall", 2, -76 - (i - 1) * 17, 450)
	end
	Tip(Button(d, "Shop again", 0, -240, 110, 22, function() HS.ShopAgain() end), "Open this list again with the same items, prices\nand amounts, and the counts back at zero")
	Button(d, "Delete list", 116, -240, 90, 22, function()
		local L = ActiveList()
		if L then StaticPopup_Show("HELPMESNIPER_DELETELIST", L.name, nil, L) end
	end)

	-- An open list
	local b = CreateFrame("Frame", nil, p)
	b:SetAllPoints()
	ui.shopBody = b

	-- Row 2: add items, and roughly what the rest of the list costs
	Text(b, "GameFontNormalSmall", 2, -33, 30):SetText("Add:")
	local function AddFromCursor()
		local kind, id, link = GetCursorInfo()
		if kind == "item" then
			ClearCursor()
			HS.AddItem(tonumber(id) or ItemIDFromText(link))
			return true
		end
	end
	ui.dropBtn = Button(b, "Drop item here", 32, -28, 104, 22, function()
		if not AddFromCursor() then Print("Pick up an item from your bags, then click or drop it on this button.") end
	end)
	ui.dropBtn:SetScript("OnReceiveDrag", AddFromCursor)
	ui.addBox = CreateFrame("EditBox", nil, b, "InputBoxTemplate")
	ui.addBox:SetSize(150, 20)
	ui.addBox:SetPoint("TOPLEFT", 146, -29)
	ui.addBox:SetAutoFocus(false)
	ui.addBox:SetFontObject("GameFontHighlightSmall")
	ui.addHint = ui.addBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.addHint:SetPoint("LEFT", 2, 0)
	ui.addHint:SetText("type a name / shift-click")
	ui.addBox:SetScript("OnEditFocusGained", function() ui.addHint:Hide() end)
	ui.addBox:SetScript("OnEditFocusLost", function(self) ui.addHint:SetShown(self:GetText() == "") end)
	MakeSearchBox(ui.addBox, HS.AddItem)
	ui.addBox:SetScript("OnReceiveDrag", AddFromCursor)
	ui.costText = Text(b, "GameFontHighlightSmall", 300, -33, 156, "RIGHT")

	-- Row 3: the list's deal %, and Mark complete
	Text(b, "GameFontNormalSmall", 2, -58, 52):SetText("Deals at")
	local function ListPct(delta)
		local L = ActiveList()
		if L then
			L.pct = math.min(PCT_MAX, math.max(PCT_MIN, (L.pct or 80) + delta))
			results = {}
			HS.Refresh()
		end
	end
	Button(b, "-", 54, -54, 20, 20, function() ListPct(-PCT_STEP) end)
	ui.pctText = Text(b, "GameFontHighlight", 76, -57, 36, "CENTER")
	Button(b, "+", 114, -54, 20, 20, function() ListPct(PCT_STEP) end)
	Text(b, "GameFontNormalSmall", 140, -58, 200):SetText("of normal price or less")
	ui.markBtn = Button(b, "Mark complete", 356, -54, 100, 20, function()
		local L = ActiveList()
		if not L then return end
		if ListAllBought(L) then
			HS.MarkComplete()
		else
			StaticPopup_Show("HELPMESNIPER_COMPLETE", L.name, nil, L)
		end
	end)
	Tip(ui.markBtn, "Finish this list: it stops searching and keeps a receipt.\nLater, pick it from the list menu and click Shop again to reuse it.")

	-- Column headings
	Text(b, "GameFontNormalSmall", 0, -78, 24):SetText("On")
	Text(b, "GameFontNormalSmall", 24, -78, 118):SetText("Item")
	Text(b, "GameFontNormalSmall", 146, -78, 72):SetText("Deal at")
	Text(b, "GameFontNormalSmall", 222, -78, 70, "RIGHT"):SetText("Normal")
	Text(b, "GameFontNormalSmall", 296, -78, 100, "RIGHT"):SetText("Now")
	ui.gotHeader = Text(b, "GameFontNormalSmall", 400, -78, 54, "RIGHT")

	ui.shopRows = {}
	for i = 1, MAX_ITEMS do
		local row = CreateFrame("Button", nil, b)
		row:SetSize(456, 18)
		row:SetPoint("TOPLEFT", 0, -92 - (i - 1) * 18)
		row.sel = row:CreateTexture(nil, "BACKGROUND") -- the item you clicked (edit strip)
		row.sel:SetAllPoints()
		row.sel:SetColorTexture(0.25, 0.4, 0.7, 0.3)
		row.sel:Hide()
		row.hl = row:CreateTexture(nil, "BACKGROUND") -- the item the BUY button will buy
		row.hl:SetAllPoints()
		row.hl:SetColorTexture(0.2, 0.55, 0.2, 0.35)
		row.hl:Hide()
		local hover = row:CreateTexture(nil, "HIGHLIGHT")
		hover:SetAllPoints()
		hover:SetColorTexture(1, 1, 1, 0.06)
		row.on = Check(row, nil, 0, 2, function(self)
			local L = ActiveList()
			local cfg = L and row.itemID and L.items[row.itemID]
			if cfg then
				cfg.enabled = self:GetChecked() and true or false
				results[row.itemID] = nil
				if cfg.enabled then priorityID = row.itemID end
				HS.Refresh()
			end
		end)
		row.name = Text(row, nil, 24, -3, 118)
		row.deal = Text(row, nil, 146, -3, 72)
		row.normal = Text(row, nil, 222, -3, 70, "RIGHT")
		row.now = Text(row, nil, 296, -3, 100, "RIGHT")
		row.got = Text(row, nil, 400, -3, 54, "RIGHT")
		row:SetScript("OnClick", function(self)
			if self.itemID then
				-- Finish any half-typed price or amount for the item that's open now, first.
				for j = 1, 3 do ui.fixMoney[j]:ClearFocus() end
				ui.itemQty:ClearFocus()
				editID = self.itemID -- open it in the edit strip
				selected = self.itemID -- and buy it first when it's a deal
				HS.Refresh()
			end
		end)
		ui.shopRows[i] = row
	end
	ui.emptyHint = Text(b, "GameFontDisableSmall", 4, -100, 448)
	ui.emptyHint:SetText("Empty list. Add items above: type a name, drop an item, or shift-click it.")

	-- Edit strip: change the clicked item
	local s = CreateFrame("Frame", nil, b)
	s:SetSize(456, 22)
	s:SetPoint("TOPLEFT", 0, -240)
	ui.stripHint = Text(s, "GameFontDisableSmall", 2, -6, 450)
	ui.stripHint:SetText("Click an item to change its deal price or amount, or to remove it.")
	local c = CreateFrame("Frame", nil, s)
	c:SetAllPoints()
	ui.stripCtl = c
	local function EditCfg()
		local L = ActiveList()
		return L, L and editID and L.items[editID]
	end
	local function Changed()
		if editID then
			results[editID] = nil
			priorityID = editID
		end
		HS.Refresh()
	end
	ui.modeBtn = Button(c, "% of normal", 0, 0, 76, 20, function()
		local _, cfg = EditCfg()
		if not cfg then return end
		if cfg.mode == "fixed" then
			cfg.mode = "pct"
		else
			if (cfg.max or 0) <= 0 then cfg.max = MaxFor(cfg, editID) or 0 end -- start from today's % price
			cfg.mode = "fixed"
		end
		Changed()
	end)
	Tip(ui.modeBtn, "Click to switch between a % of the\nnormal price and a fixed price")
	local pf = CreateFrame("Frame", nil, c)
	pf:SetAllPoints()
	ui.pctFrame = pf
	local function ItemPct(delta)
		local L, cfg = EditCfg()
		if cfg then
			cfg.pct = math.min(PCT_MAX, math.max(PCT_MIN, (cfg.pct or L.pct or 80) + delta))
			Changed()
		end
	end
	Button(pf, "-", 80, 0, 20, 20, function() ItemPct(-PCT_STEP) end)
	ui.itemPctText = Text(pf, "GameFontHighlight", 102, -3, 36, "CENTER")
	Button(pf, "+", 140, 0, 20, 20, function() ItemPct(PCT_STEP) end)
	ui.itemMaxText = Text(pf, "GameFontHighlightSmall", 164, -4, 52)
	local ff = CreateFrame("Frame", nil, c)
	ff:SetAllPoints()
	ui.fixFrame = ff
	ui.fixMoney = MoneyBoxes(ff, 78, -1, function(copper)
		local _, cfg = EditCfg()
		if cfg then cfg.max = copper end
		Changed()
	end)
	Text(c, "GameFontNormalSmall", 218, -4, 44):SetText("Amount")
	local function ItemQty(delta)
		local _, cfg = EditCfg()
		if cfg then
			cfg.qty = math.max(1, cfg.qty + delta)
			Changed()
		end
	end
	Tip(Button(c, "-", 262, 0, 20, 20, function() ItemQty(IsShiftKeyDown() and -10 or -1) end), "Shift-click: 10 at a time")
	ui.itemQty = NumberBox(c, 280, -1, 32, 4)
	ui.itemQty:SetJustifyH("CENTER")
	ui.itemQty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	ui.itemQty:SetScript("OnEditFocusLost", function(self)
		local _, cfg = EditCfg()
		local v = tonumber(self:GetText())
		if cfg and v and v >= 1 and math.floor(v) ~= cfg.qty then
			cfg.qty = math.floor(v)
			Changed()
		else
			HS.Refresh()
		end
	end)
	Tip(Button(c, "+", 320, 0, 20, 20, function() ItemQty(IsShiftKeyDown() and 10 or 1) end), "Shift-click: 10 at a time")
	ui.itemOk = Button(c, "I meant it", 344, 0, 62, 20, function()
		local _, cfg = EditCfg()
		if cfg then cfg.okMax = cfg.max end
		Changed()
	end)
	Tip(ui.itemOk, "This fixed price is over double the usual price.\nClick if that's really what you want to pay.")
	ui.itemRemove = Button(c, "Remove", 410, 0, 46, 20, function()
		if editID then StaticPopup_Show("HELPMESNIPER_REMOVE", ItemName(editID), nil, { id = editID, list = ActiveList() }) end
	end)
end

local function BuildSettingsPanel(p)
	-- Safety: what stops you spending more than you mean to
	Text(p, "GameFontNormal", 2, -2, 200):SetText("Safety")
	Text(p, "GameFontNormalSmall", 2, -24, 220):SetText("Never spend below:")
	ui.reserve = MoneyBoxes(p, 230, -20, function(copper)
		db.reserve = copper
		HS.Refresh()
	end)
	ui.autoBuyCheck = Check(p, "Buy in one click (gets the price and buys)", 0, -42, function(self)
		db.autoBuy = self:GetChecked() and true or false
		db.autoBuyBlocked = nil -- ticking it again lets the addon retry
		HS.Refresh()
	end)
	ui.autoBuyNote = Text(p, "GameFontDisableSmall", 296, -47, 160)
	Text(p, "GameFontNormalSmall", 2, -68, 230):SetText("Count down resets after no buys for:")
	Button(p, "-", 236, -64, 22, 20, function()
		db.resetMinutes = math.max(1, (db.resetMinutes or 5) - 1)
		HS.Refresh()
	end)
	ui.resetText = Text(p, "GameFontHighlight", 262, -67, 40, "CENTER")
	Button(p, "+", 306, -64, 22, 20, function()
		db.resetMinutes = math.min(120, (db.resetMinutes or 5) + 1)
		HS.Refresh()
	end)
	Text(p, "GameFontHighlightSmall", 334, -68, 60):SetText("minutes")

	-- Other
	Text(p, "GameFontNormal", 2, -94, 200):SetText("Other")
	Button(p, "How it works (full guide)", 290, -92, 166, 20, function() HS.ShowGuide() end)
	Text(p, "GameFontNormalSmall", 2, -116, 220):SetText("Search every (sec):")
	Button(p, "-", 236, -112, 22, 20, function()
		db.interval = math.max(MIN_INTERVAL, math.floor((db.interval - 0.1) * 10 + 0.5) / 10)
		HS.Refresh()
	end)
	ui.speedText = Text(p, "GameFontHighlight", 262, -115, 40, "CENTER")
	Button(p, "+", 306, -112, 22, 20, function()
		db.interval = math.min(MAX_INTERVAL, math.floor((db.interval + 0.1) * 10 + 0.5) / 10)
		HS.Refresh()
	end)
	ui.speedNote = Text(p, "GameFontDisableSmall", 2, -134, 450)
	ui.soundCheck = Check(p, "Play a sound when a deal appears", 0, -150, function(self) db.sound = self:GetChecked() and true or false end)
	ui.autoCheck = Check(p, "Start searching when the auction house opens", 0, -172, function(self) db.autoStart = self:GetChecked() and true or false end)
	ui.lockCheck = Check(p, "Lock window position", 0, -194, function(self) db.locked = self:GetChecked() and true or false end)

	local help = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	help:SetPoint("TOPLEFT", 2, -222)
	help:SetWidth(450)
	help:SetJustifyH("LEFT")
	help:SetText("Set a buy key: Esc > Options > Keybindings > AddOns > Helpme Sniper.\nOther auction addons searching at the same time slow this down.")
end

local function BuildHistoryPanel(p)
	ui.spentText = Text(p, "GameFontNormal", 2, -6, 450)
	ui.histLines = {}
	for i = 1, 13 do
		ui.histLines[i] = Text(p, "GameFontHighlightSmall", 2, -28 - (i - 1) * 17, 450)
	end
end

local function BuildFocusPanel(p)
	local function AddFromCursor()
		local kind, id, link = GetCursorInfo()
		if kind == "item" then
			ClearCursor()
			HS.SetFocusItem(tonumber(id) or ItemIDFromText(link))
			return true
		end
	end
	Text(p, "GameFontNormalSmall", 2, -7):SetText("Item:")
	local drop = Button(p, "Drop item here", 40, -2, 120, 22, function()
		if not AddFromCursor() then Print("Pick up an item from your bags, then click or drop it on this button.") end
	end)
	drop:SetScript("OnReceiveDrag", AddFromCursor)

	ui.focusBox = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
	ui.focusBox:SetSize(180, 20)
	ui.focusBox:SetPoint("TOPLEFT", 174, -3)
	ui.focusBox:SetAutoFocus(false)
	ui.focusBox:SetFontObject("GameFontHighlightSmall")
	local hint = ui.focusBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", 2, 0)
	hint:SetText("or shift-click / name / ID")
	ui.focusBox:SetScript("OnEditFocusGained", function() hint:Hide() end)
	ui.focusBox:SetScript("OnEditFocusLost", function(self) hint:SetShown(self:GetText() == "") end)
	MakeSearchBox(ui.focusBox, HS.SetFocusItem)
	ui.focusBox:SetScript("OnReceiveDrag", AddFromCursor)

	ui.fEmpty = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	ui.fEmpty:SetPoint("TOPLEFT", 2, -50)
	ui.fEmpty:SetWidth(450)
	ui.fEmpty:SetJustifyH("LEFT")
	ui.fEmpty:SetText("Pick ONE item to snipe.\n\nDrop it on the button above, shift-click it into the box, or type its name and press Enter.\n\nWhile this tab is open, only that item is searched, as fast as the game allows.")

	local b = CreateFrame("Frame", nil, p)
	b:SetAllPoints()
	ui.fBody = b

	ui.fIcon = b:CreateTexture(nil, "ARTWORK")
	ui.fIcon:SetSize(32, 32)
	ui.fIcon:SetPoint("TOPLEFT", 2, -32)
	ui.fName = Text(b, "GameFontNormalLarge", 40, -32, 410)
	ui.fAge = Text(b, "GameFontHighlightSmall", 40, -52, 410)

	Text(b, "GameFontNormalSmall", 2, -78, 94):SetText("Max price each:")
	ui.fMoney = MoneyBoxes(b, 96, -74, function(copper)
		typingMax = nil
		local id = db.focusItem
		local cfg = id and db.items[id]
		if cfg then
			cfg.max = copper
			results[id] = nil
			priorityID = id
		end
		HS.Refresh()
	end, function(copper)
		typingMax = copper -- live typo check while typing
		HS.Refresh()
	end)
	ui.fQtyLabel = Text(b, "GameFontNormalSmall", 244, -78, 56)
	Tip(Button(b, "-", 300, -74, 20, 20, function() HS.FocusQty(IsShiftKeyDown() and -10 or -1) end), "Shift-click: 10 at a time")
	ui.fQty = NumberBox(b, 320, -75, 40, 4)
	Tip(ui.fQty, "Type an amount, or use - and +\nShift-click - or + to change it by 10")
	ui.fQty:SetJustifyH("CENTER")
	ui.fQty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	ui.fQty:SetScript("OnEditFocusLost", function(self)
		local cfg = db.focusItem and db.items[db.focusItem]
		local v = tonumber(self:GetText())
		if cfg and v and v >= 1 and math.floor(v) ~= cfg.qty then
			cfg.qty = math.floor(v)
			results[db.focusItem] = nil
			priorityID = db.focusItem
		end
		HS.Refresh()
	end)
	Tip(Button(b, "+", 372, -74, 20, 20, function() HS.FocusQty(IsShiftKeyDown() and 10 or 1) end), "Shift-click: 10 at a time")
	ui.fReset = Button(b, "Reset", 398, -74, 54, 20, function()
		local cfg = db.focusItem and db.items[db.focusItem]
		if cfg then
			ResetCountdown(cfg)
			results[db.focusItem] = nil
			priorityID = db.focusItem
			HS.Refresh()
		end
	end)
	ui.fCount = Check(b, "Count down", 340, -100, function(self)
		db.countdown = self:GetChecked() and true or false
		if db.focusItem then
			results[db.focusItem] = nil
			priorityID = db.focusItem
		end
		HS.Refresh()
	end)

	Text(b, "GameFontNormalSmall", 2, -104, 120):SetText("Max = % of typical:")
	ui.fPct = {}
	for i, pct in ipairs({ 70, 80, 90, 100 }) do
		ui.fPct[i] = Button(b, pct .. "%", 124 + (i - 1) * 54, -100, 50, 20, function()
			local id = db.focusItem
			local cfg = id and db.items[id]
			local typ = id and Typical(id)
			if cfg and typ then
				cfg.max = math.max(1, math.floor(typ * pct / 100))
				results[id] = nil
				priorityID = id
				HS.Refresh()
			end
		end)
	end

	ui.fDeal = Text(b, "GameFontNormalLarge", 2, -126, 450)
	ui.fPrices = Text(b, "GameFontDisableSmall", 2, -148, 450)
	-- Typo guard override: accepts this exact max for this item (changing the max asks again).
	ui.fOk = Button(b, "I meant it", 372, -124, 80, 20, function()
		local id = db.focusItem
		local cfg = id and db.items[id]
		if cfg then
			if typingMax then -- still typing: take the number in the boxes as your max
				cfg.max = typingMax
				typingMax = nil
				for j = 1, 3 do ui.fMoney[j]:ClearFocus() end
			end
			cfg.okMax = cfg.max
			results[id] = nil
			priorityID = id
			HS.Refresh()
		end
	end)
	ui.fOk:Hide()

	Text(b, "GameFontNormalSmall", 4, -166, 90, "RIGHT"):SetText("Price each")
	Text(b, "GameFontNormalSmall", 100, -166, 70, "RIGHT"):SetText("Available")
	Text(b, "GameFontNormalSmall", 176, -166, 90, "RIGHT"):SetText("Running total")
	ui.fCountText = Text(b, "GameFontHighlightSmall", 280, -166, 172)
	ui.fRows = {}
	for i = 1, LISTING_ROWS do
		local y = -182 - (i - 1) * 14
		ui.fRows[i] = {
			price = Text(b, nil, 4, y, 90, "RIGHT"),
			qty = Text(b, nil, 100, y, 70, "RIGHT"),
			cum = Text(b, nil, 176, y, 90, "RIGHT"),
			note = Text(b, nil, 280, y, 170),
		}
	end
end

-- Where the window opens: where you last dragged it, otherwise just right of the
-- auction house window so it never covers it.
function HS.PlaceWindow()
	local f = ui.frame
	if not f then return end
	f:ClearAllPoints()
	local ah = _G.AuctionHouseFrame or _G.AuctionFrame
	if db.pos then
		f:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
	elseif ah then
		f:SetPoint("TOPLEFT", ah, "TOPRIGHT", 12, 0)
	else
		f:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
	end
end

local function BuildFrame()
	local f = CreateFrame("Frame", "HelpmeSniperFrame", UIParent, "BackdropTemplate")
	ui.frame = f
	f:SetSize(472, 400)
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		-- Remember where you put it, measured from the screen's bottom-left corner.
		local left, top = self:GetLeft(), self:GetTop()
		if left and top then
			db.pos = { "TOPLEFT", "BOTTOMLEFT", left, top }
			self:ClearAllPoints()
			self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
		end
		if self.SetUserPlaced then self:SetUserPlaced(false) end -- the addon saves the spot itself
	end)
	HS.PlaceWindow()
	f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	f:SetBackdropColor(0.05, 0.06, 0.07, 0.95)
	f:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
	f:Hide()
	f:SetScript("OnHide", function()
		scanning = false
		ClearCheckSoon()
	end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 10, -9)
	title:SetText("Helpme Sniper")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)

	Tip(Button(f, "?", 330, -7, 22, 20, function() HS.ShowGuide() end), "How it works (full guide)")
	ui.startBtn = Button(f, "Start", 356, -7, 80, 20, function()
		scanning = not scanning
		if not scanning then ClearCheckSoon() end
		SetStatus(scanning and "Scanning..." or "Paused.", 0.8, 0.8, 0.8)
		HS.Refresh()
	end)

	ui.tabs, ui.panels = {}, {}
	for i, t in ipairs(TABS) do
		ui.tabs[t.key] = Button(f, t.label, 8 + (i - 1) * 115, -32, 110, 22, function() HS.ShowTab(t.key) end)
		local p = CreateFrame("Frame", nil, f)
		p:SetPoint("TOPLEFT", 8, -60)
		p:SetPoint("BOTTOMRIGHT", -8, 76)
		p:Hide()
		ui.panels[t.key] = p
	end
	BuildFocusPanel(ui.panels.focus)
	BuildShopPanel(ui.panels.shop)
	BuildSettingsPanel(ui.panels.settings)
	BuildHistoryPanel(ui.panels.history)

	-- status line and BUY button, shared by every tab
	ui.msg = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.msg:SetPoint("BOTTOMLEFT", 10, 48)
	ui.msg:SetPoint("BOTTOMRIGHT", -10, 48)
	ui.msg:SetJustifyH("LEFT")

	ui.buyBtn = CreateFrame("Button", "HelpmeSniperBuyButton", f, "UIPanelButtonTemplate")
	ui.buyBtn:SetSize(456, 34)
	ui.buyBtn:SetPoint("BOTTOM", 0, 8)
	ui.buyBtn:SetScript("OnClick", function() HelpmeSniper_BuyStep() end)
	-- A see-through color laid over the button: green = will buy, yellow = busy, grey = nothing to buy.
	ui.buyTint = ui.buyBtn:CreateTexture(nil, "ARTWORK")
	ui.buyTint:SetPoint("TOPLEFT", 3, -3)
	ui.buyTint:SetPoint("BOTTOMRIGHT", -3, 3)
end

-- ============================================================================
-- Welcome page (shown once) and the full guide
-- ============================================================================

local H = "|cffffd100" -- heading color
local WELCOME_TEXT = [[Buy auction house materials fast, without overpaying.

]] .. H .. [[1. Focus:|r one item, searched as fast as the game allows. Use this to race for deals.

]] .. H .. [[2. Shopping Lists:|r make lists of what you need. It tells you when each item hits a good price, tracks what you've bought, and you mark the list complete when you're done.

]] .. H .. [[3. Buy:|r when the big button turns |cff33ff33green|r, click it. Keep clicking to keep buying.

]] .. H .. [[4. Safe:|r never over your max price, never below your gold floor, never more than your total.

|cffaaaaaaHover over buttons for tips. Click ? at the top any time for the full guide.|r]]

local GUIDE = {
	{ title = "Getting started", text = H .. [[Getting started|r

Helpme Sniper opens by itself when you open the auction house, just right of the auction house window. Drag it anywhere and it remembers the spot.

]] .. H .. [[Start / Stop|r (top right) turns searching on and off. It starts by itself when the auction house opens, unless you turn that off in Settings.

The small |cff33ff33Live|r marker means it's searching. |cffff8833Paused|r means it isn't.

There are four tabs:
- ]] .. H .. [[Focus:|r one item, searched as fast as the game allows.
- ]] .. H .. [[Shopping List:|r your lists of things to buy at good prices.
- ]] .. H .. [[Settings:|r safety and other options.
- ]] .. H .. [[History:|r what you bought and spent today.

The status line and the big BUY button at the bottom are the same on every tab.]] },

	{ title = "Adding items", text = H .. [[Adding items|r

The Focus tab and the Shopping List both have a box for adding items. You can:

- ]] .. H .. [[Type the name.|r After 2 letters, matching items drop down straight away, like a search bar. Click one, or use the Up/Down keys and Enter. Escape closes the list.
- ]] .. H .. [[Drop it|r from your bags on the "Drop item here" button.
- ]] .. H .. [[Shift-click it|r (in your bags or a chat link) while the box is selected.
- ]] .. H .. [[Type its ID number|r and press Enter.

Only items sold by quantity work: cloth, herbs, ore, dye and so on. Gear and bags can't be bought this way, so the search leaves them out.

]] .. H .. [[Where the names come from:|r the addon keeps its own saved list of every item sold by quantity on the auction house. When you open the auction house, and every 15 minutes while it's open, it copies the whole auction house in one go (the game allows one copy every 15 minutes). The copy isn't a search, so nothing changes in the auction house window. If an item isn't in the list yet (say it was just listed), type its name and press Enter: it searches the auction house for it and remembers it.

The list also shows how many are listed and the cheapest price from the last copy. Hover a name to see its normal price.]] },

	{ title = "Focus", text = H .. [[Focus|r

Focus is for racing: pick one item, and only that item is searched, as fast as the game allows (about every 0.6 seconds).

- ]] .. H .. [[Max price each:|r the most you'll pay for one, in gold, silver and copper.
- ]] .. H .. [[70% to 100% buttons:|r set your max to that share of the item's normal price.
- ]] .. H .. [[Total / Per buy:|r how many you want. With Count down ticked it's a total. Unticked, every click can buy up to that many.
- ]] .. H .. [[Count down:|r counts what you've bought and stops at your total. It starts over after 5 minutes without buying that item (change that in Settings), or when you click Reset.
- ]] .. H .. [[The big line:|r YES means you can buy now, with how many, the price and your max. NO shows the cheapest price against your max. TYPO? means your max looks like a mistake (see Safety).
- ]] .. H .. [[Listings:|r the 6 cheapest listings with a running total. Ones at or under your max are marked green.]] },

	{ title = "Shopping Lists", text = H .. [[Shopping Lists|r

Shopping lists are for filling a list of materials at good prices, without racing.

- ]] .. H .. [[Lists:|r click the list name at the top to switch lists, see completed lists, or rename, copy or delete the open list. "New list" starts another. Only the open list is searched, which keeps it fast.
- ]] .. H .. [[Deals at X% of normal:|r an item counts as a deal when it's at or under that share of its normal price. Click an item to give it its own % or a fixed price instead.
- ]] .. H .. [[Columns:|r On (tick to search it), Deal at, Normal (its usual price), Now (the cheapest price and how far it is from normal, or YES when it's a deal), and Got.
- ]] .. H .. [[Track totals:|r when on, it counts what you buy (like "40/180") and never buys past each amount. It remembers until you mark the list complete, even after logging off. When off, every click buys up to the amount.
- ]] .. H .. [[Mark complete:|r finishes the list. It stops searching and keeps a receipt of what you bought, what you paid, and how that compares with normal.
- ]] .. H .. [[Shop again:|r open a completed list from the list menu and click Shop again. Same items, prices and amounts, with the counts back at zero.
- ]] .. H .. [[Edit strip:|r click an item to switch between % of normal and a fixed price, change its amount, or remove it.
- ]] .. H .. [[Rest of list:|r roughly what the rest of the list would cost at today's prices. It turns red when that's more than you can spend.

]] .. H .. [[Normal price:|r what an item usually sells for. It comes from the auction house copies (see Adding items): each copy looks at the cheaper listings, ignoring a few silly ones, and the last 14 days are combined with recent days counting most. Items get a normal price a few seconds after you first open the auction house. An item nobody had listed in a copy shows "learning" and won't buy until it's been watched for a while. Fixed-price items work straight away.]] },

	{ title = "Buying", text = H .. [[Buying|r

Click the big button, or set a key: Esc > Options > Keybindings > AddOns > Helpme Sniper. A macro works too: /click HelpmeSniperBuyButton

The button shows what a click will do:
- |cff33ff33Green:|r clicking buys, for example "BUY 7 Wool Cloth · 9s each (max 10s)".
- |cffffd100Yellow:|r busy getting the price or buying. Keep clicking.
- Grey: nothing at your price right now.
- |cffff5555Red:|r your max looks like a typo.

- ]] .. H .. [[One click:|r the click asks the auction house for the exact price, and the addon buys straight away if it's still at or under your max. If the game ever refuses that, the addon switches to "click again to buy" by itself.
- ]] .. H .. [[Keep buying:|r spam the button. After each buy, your next click buys more of what's left without waiting for a new search. Every buy is still price-checked first.
- ]] .. H .. [[Someone beat you?|r If the price comes back over your max, it cancels and nothing is bought.]] },

	{ title = "Safety", text = H .. [[Safety|r

There are no pop-ups to click through. These rules protect you instead:

- ]] .. H .. [[Max price:|r every buy costs no more than the price it showed you, which is at or under your max.
- ]] .. H .. [[Never spend below:|r your gold never drops under this amount (set it in Settings).
- ]] .. H .. [[Totals:|r Count down (Focus) and Track totals (Shopping List) never buy more than your amount.
- ]] .. H .. [[Typo guard:|r if a price you typed is more than double the usual price (say 20g instead of 20c), it warns you and won't buy until you click "I meant it". That only covers that exact price.
- ]] .. H .. [[Price check:|r every buy gets the exact price first. If it's higher than what it showed you (say someone bought the cheap ones first), or more than you can spend, it cancels and searches again right away.]] },

	{ title = "Settings", text = H .. [[Settings|r

]] .. H .. [[Safety|r
- Never spend below: the gold the addon always leaves you.
- Buy in one click: gets the price and buys with one click. Untick it to always click twice.
- Count down resets after: how long the Focus count down waits before starting over.

]] .. H .. [[Other|r
- Search every: how often it searches, on both tabs. 0.6 seconds is the fastest the game allows.
- Play a sound when a deal appears.
- Start searching when the auction house opens.
- Lock window position: stops the window from being dragged.]] },

	{ title = "Tips and limits", text = H .. [[Tips and limits|r

- The game allows about 100 auction searches a minute, shared by everything you run. If another addon or app is scanning the auction house at the same time, both slow down.
- Selling: the auction house handles one request at a time and greys out its Create Auction button while one is waiting. So while you're selling, the shopping list pauses by itself (the marker says "Paused: selling") and carries on about 30 seconds after you post. If anything else is using the auction house (its own window, another addon), it waits about 10 seconds ("Waiting: AH busy"). Focus never pauses, because it's for racing.
- Mouse on the auction house: while your mouse is over the auction house window, searching eases off to one search every 2 seconds, so its buttons (like Create Auction) stay usable. The marker says "easy: mouse on AH". Move the mouse back to Helpme Sniper (or anywhere else) and it's full speed again.
- The auction house handles one purchase at a time, so items are bought one after another, not all at once.
- On a shopping list, ticked items take turns. With 4 items, each is checked about every 2.4 seconds. Finished items are skipped, so the rest speed up.
- Normal prices come from the auction house copies over the last 14 days, recent days counting most.
- Hover any item (in your bags, a chat link or the search list) to see its normal price and the cheapest price from the last copy.
- Typing a name searches the auction house, so the auction house window shows those results too. That's harmless.
- Type /hsnipe in chat for a few text commands.]] },
}

function HS.ShowWelcome()
	if not ui.welcome then
		local w = CreateFrame("Frame", nil, ui.frame, "BackdropTemplate")
		w:SetFrameStrata("DIALOG")
		w:SetPoint("TOPLEFT", 8, -30)
		w:SetPoint("BOTTOMRIGHT", -8, 8)
		w:EnableMouse(true) -- nothing underneath can be clicked by accident
		w:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		w:SetBackdropColor(0.06, 0.07, 0.08, 1)
		w:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
		local title = w:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		title:SetPoint("TOP", 0, -14)
		title:SetText("Welcome to Helpme Sniper")
		local fs = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		fs:SetPoint("TOPLEFT", 18, -44)
		fs:SetWidth(420)
		fs:SetJustifyH("LEFT")
		fs:SetJustifyV("TOP")
		fs:SetSpacing(3)
		fs:SetText(WELCOME_TEXT)
		Button(w, "Full guide", 106, -322, 116, 26, function()
			db.seenWelcome = true
			w:Hide()
			HS.ShowGuide()
		end)
		Button(w, "Got it", 234, -322, 116, 26, function()
			db.seenWelcome = true
			w:Hide()
		end)
		ui.welcome = w
	end
	ui.welcome:Show()
end

function HS.GuideTopic(i)
	local g = ui.guide
	if not g or not GUIDE[i] then return end
	g.topic = i
	g.text:SetText(GUIDE[i].text)
	g.content:SetHeight(g.text:GetStringHeight() + 16)
	g.scroll:SetVerticalScroll(0)
	for j, b in ipairs(g.tabs) do
		if j == i then b:LockHighlight() else b:UnlockHighlight() end
	end
end

function HS.ShowGuide()
	if not ui.guide then
		local g = CreateFrame("Frame", "HelpmeSniperGuide", UIParent, "BackdropTemplate")
		g:SetSize(620, 440)
		g:SetPoint("CENTER")
		g:SetFrameStrata("DIALOG")
		g:SetClampedToScreen(true)
		g:SetMovable(true)
		g:EnableMouse(true)
		g:RegisterForDrag("LeftButton")
		g:SetScript("OnDragStart", g.StartMoving)
		g:SetScript("OnDragStop", g.StopMovingOrSizing)
		g:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		g:SetBackdropColor(0.05, 0.06, 0.07, 0.98)
		g:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
		local title = g:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		title:SetPoint("TOPLEFT", 12, -10)
		title:SetText("Helpme Sniper: how it works")
		local close = CreateFrame("Button", nil, g, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", 0, 0)
		g.tabs = {}
		for i, topic in ipairs(GUIDE) do
			g.tabs[i] = Button(g, topic.title, 10, -40 - (i - 1) * 28, 150, 24, function() HS.GuideTopic(i) end)
		end
		local sf = CreateFrame("ScrollFrame", "HelpmeSniperGuideScroll", g, "UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 172, -40)
		sf:SetPoint("BOTTOMRIGHT", -32, 14)
		local content = CreateFrame("Frame", nil, sf)
		content:SetSize(410, 10)
		sf:SetScrollChild(content)
		local fs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		fs:SetPoint("TOPLEFT", 4, -4)
		fs:SetWidth(400)
		fs:SetJustifyH("LEFT")
		fs:SetJustifyV("TOP")
		fs:SetSpacing(3)
		g.scroll, g.content, g.text = sf, content, fs
		table.insert(UISpecialFrames, "HelpmeSniperGuide") -- Escape closes it
		ui.guide = g
	end
	ui.guide:Show()
	HS.GuideTopic(ui.guide.topic or 1)
end

-- ============================================================================
-- Refresh (redraws whatever is on screen)
-- ============================================================================

-- Sets the BUY button's words and color in one go.
local function SetBuy(text, r, g, b, tintAlpha)
	ui.buyBtn:SetText(("|cff%02x%02x%02x%s|r"):format(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), text))
	ui.buyTint:SetColorTexture(r, g, b, tintAlpha or 0.3)
end

local function RefreshBuy()
	ui.startBtn:SetText(scanning and "Stop" or "Start")
	local target = Target()
	if pending and pending.stage == "ready" then
		SetBuy(("CLICK AGAIN: buy %d %s for %s"):format(pending.qty, ItemName(pending.itemID), MoneyPlain(pending.quote)), 0.3, 1, 0.3)
	elseif pending and pending.stage == "buying" then
		SetBuy(("Buying %d %s..."):format(pending.qty, ItemName(pending.itemID)), 1, 0.82, 0)
	elseif pending then
		SetBuy(("Getting price for %d %s..."):format(pending.qty, ItemName(pending.itemID)), 1, 0.82, 0)
	elseif target then
		local r = results[target]
		SetBuy(("BUY %d %s · %s each (max %s)"):format(r.avail, ItemName(target), MoneyPlain(r.total / r.avail), MoneyPlain(r.max or 0)), 0.3, 1, 0.3)
	else
		-- Nothing to buy: on the Focus tab, say why if it's something you can fix.
		local id = db.mode == "focus" and db.focusItem
		local cfg = id and db.items[id]
		local r = id and results[id]
		if cfg and r and r.typo then
			SetBuy("Check your max price (typo?)", 1, 0.35, 0.35)
		elseif cfg and db.countdown and (cfg.max or 0) > 0 and Remaining(cfg) == 0 then
			SetBuy(("Done: bought all %d. Reset to buy more"):format(cfg.qty), 0.6, 0.6, 0.6, 0.12)
		else
			SetBuy("BUY · no deal right now", 0.6, 0.6, 0.6, 0.12)
		end
	end
end

-- "82c -4%": a price and how far it is from normal (green when cheaper).
local function NowText(price, typ)
	if not price then return "" end
	local s = Money(price)
	if typ and typ > 0 then
		local d = math.floor((price / typ - 1) * 100 + 0.5)
		if d < 0 then
			s = s .. (" |cff33ff33%d%%|r"):format(d)
		elseif d > 0 then
			s = s .. (" |cffaaaaaa+%d%%|r"):format(d)
		end
	end
	return s
end

-- A completed list: its receipt.
local function RefreshDone(L)
	ui.doneTitle:SetText(('"%s" completed %s'):format(L.name, L.doneAt and date("%d %b %H:%M", L.doneAt) or ""))
	local lines, spent, seen = {}, 0, {}
	local function line(id)
		local e = L.log and L.log[id]
		if not e or seen[id] or (e.qty or 0) <= 0 then return end
		seen[id] = true
		spent = spent + e.spent
		local s = ("%d %s for %s (avg %s"):format(e.qty, ItemName(id), Money(e.spent), Money(e.spent / e.qty))
		if (e.normal or 0) > 0 then
			local d = math.floor((1 - e.spentN / e.normal) * 100 + 0.5)
			if d >= 0 then
				s = s .. (", |cff33ff33%d%% under normal|r"):format(d)
			else
				s = s .. (", %d%% over normal"):format(-d)
			end
		end
		lines[#lines + 1] = s .. ")"
	end
	for _, id in ipairs(L.order) do line(id) end
	for id in pairs(L.log or {}) do line(id) end
	ui.doneTotal:SetText(#lines > 0 and ("Spent %s in total."):format(Money(spent)) or "Nothing was bought on this list.")
	for i, fs in ipairs(ui.doneLines) do fs:SetText(lines[i] or "") end
end

local function RefreshShop()
	ui.shopLive:SetText(LiveText())
	local L = ActiveList()
	if not L then return end
	ui.listBtn:SetText(L.name)
	ui.trackCheck:SetChecked(L.track)
	ui.shopBody:SetShown(not L.done)
	ui.doneView:SetShown(L.done and true or false)
	if L.done then
		RefreshDone(L)
		return
	end
	ui.pctText:SetText((L.pct or 80) .. "%")
	ui.gotHeader:SetText(L.track and "Got" or "Amount")
	ui.markBtn:SetShown(L.track)
	if ListAllBought(L) then ui.markBtn:LockHighlight() else ui.markBtn:UnlockHighlight() end

	local target = Target()
	local cost, unknown = 0, false
	local i = 1
	for _, id in ipairs(L.order) do
		local cfg = L.items[id]
		local r = results[id]
		local row = ui.shopRows[i]
		row.itemID = id
		row:Show()
		local on = cfg.enabled ~= false
		local done = ItemDone(L, cfg)
		local typ, n = Typical(id)
		local max = MaxFor(cfg, id)
		row.on:SetChecked(on)
		row.name:SetText(ItemName(id))
		if cfg.mode == "fixed" then
			row.deal:SetText((cfg.max or 0) > 0 and Money(cfg.max) or "|cffff5555set price|r")
		else
			row.deal:SetText((cfg.pct or L.pct or 80) .. "%")
		end
		row.normal:SetText(typ and Money(typ) or ("|cff888888learning %d/%d|r"):format(n, MIN_SAMPLES))
		-- "Now": what's happening with this item right now
		local nr, ng, nb = 1, 1, 1
		if not on then
			row.now:SetText("|cff888888off|r")
			nr, ng, nb = 0.5, 0.5, 0.5
		elseif done then
			row.now:SetText("|cffffd100done|r")
		elseif r and r.typo then
			row.now:SetText("|cffff5555typo?|r")
			nr, ng, nb = 1, 0.35, 0.35
		elseif not max then
			if cfg.mode == "fixed" then
				row.now:SetText("|cffff5555set price|r")
			else
				row.now:SetText((r and r.cheapest) and (Money(r.cheapest) .. " |cff888888wait|r") or "|cff888888learning|r")
			end
		elseif r and r.avail > 0 then
			row.now:SetText("|cff33ff33YES|r " .. NowText(r.total / r.avail, typ))
			nr, ng, nb = 0.3, 1, 0.3
		elseif r and r.cheapest then
			row.now:SetText(NowText(r.cheapest, typ))
		elseif r then
			row.now:SetText("|cff888888none listed|r")
		else
			row.now:SetText("|cff888888...|r")
		end
		row.name:SetTextColor(nr, ng, nb)
		if L.track then
			row.got:SetText((done and "|cffffd100%d/%d|r" or "%d/%d"):format(cfg.got or 0, cfg.qty))
		else
			row.got:SetText(tostring(cfg.qty))
		end
		row.hl:SetShown(on and target == id)
		row.sel:SetShown(editID == id and target ~= id)
		if on and not done then
			local price = (r and r.cheapest) or typ
			if price then cost = cost + Remaining(cfg) * price else unknown = true end
		end
		i = i + 1
	end
	for j = i, MAX_ITEMS do
		ui.shopRows[j].itemID = nil
		ui.shopRows[j]:Hide()
	end
	ui.emptyHint:SetShown(#L.order == 0)
	if cost == 0 then
		ui.costText:SetText("")
	else
		local label = cost > Spendable() and "|cffff5555Rest of list|r" or "|cffaaaaaaRest of list|r"
		ui.costText:SetText(("%s ~ %s%s"):format(label, Money(cost), unknown and " +" or ""))
	end

	-- Edit strip
	local cfg = editID and L.items[editID]
	ui.stripHint:SetShown(not cfg)
	ui.stripCtl:SetShown(cfg ~= nil)
	if cfg then
		local fixed = cfg.mode == "fixed"
		ui.modeBtn:SetText(fixed and "Fixed price" or "% of normal")
		ui.pctFrame:SetShown(not fixed)
		ui.fixFrame:SetShown(fixed)
		if fixed then
			ui.fixMoney.Set(cfg.max or 0)
		else
			ui.itemPctText:SetText((cfg.pct or L.pct or 80) .. "%")
			local max = MaxFor(cfg, editID)
			ui.itemMaxText:SetText(max and ("= " .. Money(max)) or "|cff888888learning|r")
		end
		if not ui.itemQty:HasFocus() then ui.itemQty:SetText(tostring(cfg.qty)) end
		local r = results[editID]
		ui.itemOk:SetShown((fixed and r and r.typo) and true or false)
	end
end

local function RefreshSettings()
	ui.reserve.Set(db.reserve)
	ui.speedText:SetText(("%.1f"):format(db.interval))
	local active = 0
	local L = ActiveList()
	for _, id in ipairs(L and L.order or {}) do
		local cfg = L.items[id]
		if cfg and cfg.enabled ~= false and not ItemDone(L, cfg) then active = active + 1 end
	end
	ui.speedNote:SetText(("One search every %.1fs (every %.0fs while your mouse is on the auction house window). Focus: your one item. Shopping list: %d items take turns, each about every %.1fs. The shopping list pauses while you sell; Focus never does."):format(db.interval, HOVER_INTERVAL, active, db.interval * math.max(1, active)))
	ui.soundCheck:SetChecked(db.sound)
	ui.autoCheck:SetChecked(db.autoStart)
	ui.lockCheck:SetChecked(db.locked)
	ui.autoBuyCheck:SetChecked(db.autoBuy)
	ui.autoBuyNote:SetText((db.autoBuy and db.autoBuyBlocked) and "|cffff8833blocked by the game: 2 presses|r" or "")
	ui.resetText:SetText(tostring(db.resetMinutes or 5))
end

local function RefreshHistory()
	local today = date("%Y-%m-%d")
	local spent, count = 0, 0
	for _, h in ipairs(db.history) do
		if date("%Y-%m-%d", h.t) == today then
			spent = spent + h.total
			count = count + 1
		end
	end
	ui.spentText:SetText(("Spent today: %s  (%d purchase%s)"):format(Money(spent), count, count == 1 and "" or "s"))
	for i, fs in ipairs(ui.histLines) do
		local h = db.history[i]
		if h then
			fs:SetText(("%s   %d x %s   %s   (%s each)"):format(date("%m/%d %H:%M", h.t), h.qty, ItemName(h.id), Money(h.total), Money(h.total / h.qty)))
		elseif i == 1 then
			fs:SetText("|cff888888No purchases yet.|r")
		else
			fs:SetText("")
		end
	end
end

local function RefreshFocus()
	local id = db.focusItem
	local cfg = id and db.items[id]
	ui.fEmpty:SetShown(not cfg)
	ui.fBody:SetShown(cfg ~= nil)
	if not cfg then return end

	local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or (GetItemIcon and GetItemIcon(id))
	ui.fIcon:SetTexture(icon or 134400)
	ui.fName:SetText(ItemName(id))
	ui.fMoney.Set(cfg.max)
	if not ui.fQty:HasFocus() then ui.fQty:SetText(tostring(cfg.qty)) end
	ui.fCount:SetChecked(db.countdown)
	ui.fReset:SetShown(db.countdown)
	ui.fQtyLabel:SetText(db.countdown and "Total:" or "Per buy:")
	local left = Remaining(cfg)
	if db.countdown then
		local resets = ResetIn(cfg)
		ui.fCountText:SetText(("|cffffd100Bought %d of %d|r%s"):format(cfg.qty - left, cfg.qty, resets and ("  |cffaaaaaaresets in " .. resets .. "|r") or ""))
	else
		ui.fCountText:SetText("")
	end
	local typ, n = Typical(id)
	for _, btn in ipairs(ui.fPct) do btn:SetEnabled(typ ~= nil) end
	local low = LowToday(id)
	local r = results[id]
	ui.fPrices:SetText(("Typical %s   ·   Low today %s"):format(
		typ and Money(typ) or ("learning " .. n .. "/" .. MIN_SAMPLES),
		low and Money(low) or "-"))

	-- The big YES / NO line: can I buy right now?
	-- While you're typing a max, it warns straight away if the number looks like a typo.
	local typingRef = typingMax and TypoRef(cfg, id, typingMax, r and r.cheapest)
	local typoShown = typingRef or (not typingMax and r and r.typo)
	ui.fOk:SetShown(typoShown and true or false)
	ui.fDeal:SetWidth(typoShown and 365 or 450)
	if typingRef then
		ui.fDeal:SetText(("TYPO? %s is over double the usual %s"):format(Money(typingMax), Money(typingRef)))
		ui.fDeal:SetTextColor(1, 0.35, 0.35)
	elseif (cfg.max or 0) <= 0 then
		ui.fDeal:SetText("Set your max price to start")
		ui.fDeal:SetTextColor(1, 0.35, 0.35)
	elseif r and r.typo then
		ui.fDeal:SetText(("TYPO? max %s is over double the usual %s"):format(Money(cfg.max), Money(r.typo)))
		ui.fDeal:SetTextColor(1, 0.35, 0.35)
	elseif db.countdown and left == 0 then
		ui.fDeal:SetText(("DONE: bought all %d. Reset to buy more"):format(cfg.qty))
		ui.fDeal:SetTextColor(1, 0.82, 0)
	elseif r and r.avail > 0 then
		ui.fDeal:SetText(("YES: %d at %s (your max %s)"):format(r.avail, Money(r.total / r.avail), Money(cfg.max)))
		ui.fDeal:SetTextColor(0.3, 1, 0.3)
	elseif r and r.cheapest then
		ui.fDeal:SetText(("NO: cheapest %s, your max %s"):format(Money(r.cheapest), Money(cfg.max)))
		ui.fDeal:SetTextColor(0.65, 0.65, 0.65)
	elseif r then
		ui.fDeal:SetText("NO: none listed right now")
		ui.fDeal:SetTextColor(0.65, 0.65, 0.65)
	else
		ui.fDeal:SetText("Checking...")
		ui.fDeal:SetTextColor(0.65, 0.65, 0.65)
	end

	local cum = 0
	for i, row in ipairs(ui.fRows) do
		local l = r and r.listings and r.listings[i]
		if l then
			cum = cum + math.max(0, l.qty)
			row.price:SetText(Money(l.price))
			row.qty:SetText(tostring(l.qty))
			row.cum:SetText(tostring(cum))
			row.note:SetText((cfg.max > 0 and l.price <= cfg.max) and "|cff33ff33at or under your max|r" or "")
		else
			row.price:SetText("")
			row.qty:SetText("")
			row.cum:SetText("")
			row.note:SetText("")
		end
	end
end

-- "last update 0.3s ago" line on the Focus tab, refreshed a few times a second
local ageShown = 0
function HS.UpdateAge(now)
	if not ui.fAge or not ui.panels.focus:IsShown() or now - ageShown < 0.2 then return end
	ageShown = now
	local id = db.focusItem
	if not id then return end
	local r = results[id]
	local state = LiveText()
	if r and r.time then state = state .. ("     |cffaaaaaaupdated %.1fs ago|r"):format(now - r.time) end
	ui.fAge:SetText(state)
end

function HS.Refresh()
	if not ui.frame or not db then return end
	RefreshBuy()
	if ui.panels.focus:IsShown() then RefreshFocus() end
	if ui.panels.shop:IsShown() then RefreshShop() end
	if ui.panels.settings:IsShown() then RefreshSettings() end
	if ui.panels.history:IsShown() then RefreshHistory() end
end

-- ============================================================================
-- Shift-click an item while the add box is active
-- ============================================================================

local function OnInsertLink(link)
	if ui.focusBox and ui.focusBox:HasFocus() and link then
		ui.focusBox:SetText("")
		ui.focusBox:ClearFocus()
		HS.ClosePicker()
		HS.SetFocusItem(ItemIDFromText(link))
		return
	end
	if ui.addBox and ui.addBox:HasFocus() and link then
		local id = ItemIDFromText(link)
		ui.addBox:SetText("")
		ui.addBox:ClearFocus()
		HS.ClosePicker()
		if id then HS.AddItem(id) end
	end
end
if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", OnInsertLink) end
if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink) end

-- ============================================================================
-- Events
-- ============================================================================

local function InitDB()
	if type(HelpmeSniperDB) ~= "table" then HelpmeSniperDB = DeepCopy(DEFAULTS) end
	db = HelpmeSniperDB
	db.items = db.items or {}
	db.prices = db.prices or {}
	db.history = db.history or {}
	db.names = db.names or {}
	db.notSold = db.notSold or {}
	db.market = db.market or {}
	for id, m in pairs(db.market) do
		if not m.at or time() - m.at > 15 * 86400 then db.market[id] = nil end -- gone from the AH
	end
	if (db.version or 1) < 2 then
		-- upgrade from v0.1: keep the watch list, add the new settings
		db.interval = MIN_INTERVAL
		for _, cfg in pairs(db.items) do
			if cfg.enabled == nil then cfg.enabled = true end
		end
		db.version = 2
	end
	if db.version < 3 then
		-- v0.3 adds the Focus tab: open on it the first time
		db.tab = "focus"
		db.version = 3
	end
	if db.version < 4 then
		-- v0.4 adds one-press buying and count down (the new settings come from DEFAULTS below)
		db.version = 4
	end
	if db.version < 5 then
		-- v0.5: Count down on and the window locked by default (both can be changed back);
		-- the "ask an extra time for big buys" setting is gone.
		db.countdown = true
		db.locked = true
		db.maxSpend = nil
		db.version = 5
	end
	if db.version < 6 then
		-- v0.6: the Snipe tab is now part of the Watch List tab
		if db.tab == "snipe" then db.tab = "watch" end
		db.version = 6
	end
	if db.version < 7 then
		-- v0.6.1: the window can be dragged again, and it opens beside the auction house
		-- (any old saved spot is forgotten once so it starts out of the way).
		db.locked = false
		db.pos = nil
		db.version = 7
	end
	if db.version < 8 then
		-- v0.7: the Watch List becomes a shopping list called "My list". Its items keep their
		-- prices (as fixed prices) and amounts; the Focus item keeps its own settings.
		db.lists = db.lists or {}
		if #db.lists == 0 then
			local L = NewListTable("My list")
			for _, id in ipairs(db.order or {}) do
				local old = db.items[id]
				if old and #L.order < MAX_ITEMS then
					L.items[id] = { kind = "list", mode = "fixed", max = old.max or 0, qty = old.qty or 20, enabled = old.enabled ~= false, got = 0, okMax = old.okMax }
					L.order[#L.order + 1] = id
					if id ~= db.focusItem then db.items[id] = nil end
				end
			end
			db.lists[1] = L
		end
		db.order = nil
		db.activeList = 1
		if db.tab == "watch" then db.tab = "shop" end
		db.version = 8
	end
	db.lists = db.lists or {}
	if #db.lists == 0 then db.lists[1] = NewListTable("My list") end
	if not db.lists[db.activeList or 1] then db.activeList = 1 end
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil and type(v) ~= "table" then db[k] = v end
	end
	db.interval = math.min(MAX_INTERVAL, math.max(MIN_INTERVAL, db.interval))
	HS.UpdateMode()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("COMMODITY_PRICE_UPDATED")
ev:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
ev:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
ev:RegisterEvent("COMMODITY_PURCHASE_FAILED")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("ADDON_ACTION_BLOCKED")
ev:RegisterEvent("ADDON_ACTION_FORBIDDEN")
pcall(ev.RegisterEvent, ev, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY") -- not on every client; Tick checks too
pcall(ev.RegisterEvent, ev, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") -- typed item names
pcall(ev.RegisterEvent, ev, "AUCTION_HOUSE_BROWSE_FAILURE")
pcall(ev.RegisterEvent, ev, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED") -- more results of your own searches
pcall(ev.RegisterEvent, ev, "REPLICATE_ITEM_LIST_UPDATE") -- the full auction house copy arrived
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED") -- an item's details finished loading
pcall(ev.RegisterEvent, ev, "ITEM_KEY_ITEM_INFO_RECEIVED") -- an item name finished loading
ev:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == ADDON_NAME then
			InitDB()
			BuildFrame()
			C_Timer.NewTicker(0.05, Tick)
		end
		return
	end
	if not db then return end

	if event == "AUCTION_HOUSE_SHOW" then
		ahOpen = true
		results = {}
		HS.PlaceWindow()
		ui.frame:Show()
		scanning = db.autoStart and true or false
		HS.ShowTab(db.tab or "focus")
		SetStatus(scanning and "Scanning..." or "Paused. Click Start.", 0.8, 0.8, 0.8)
		if not db.seenWelcome then HS.ShowWelcome() end
		SeedNames()
		HS.StartFullScan()

	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
		LearnBrowse(C_AuctionHouse.GetBrowseResults()) -- every search teaches it names, yours too
		if nameSearch and nameSearch.sent and not nameSearch.waiting then
			local s = nameSearch
			s.waiting = true
			C_Timer.After(0.3, function() HS.FinishNameSearch(s) end) -- gives item names a moment to load
		end

	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
		local added = ...
		LearnBrowse(type(added) == "table" and added or C_AuctionHouse.GetBrowseResults())

	elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
		HS.FullScanArrived()

	elseif event == "GET_ITEM_INFO_RECEIVED" then
		local id = ...
		if id then HS.ItemLoaded(id) end

	elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
		local id = ...
		local key = id and keyWaiting[id]
		if key then LearnKey(key) end

	elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
		if nameSearch and nameSearch.sent then
			local s = nameSearch
			nameSearch = nil
			if ui.picker and ui.picker:IsShown() and ui.picker.box == s.box then
				ui.picker.title:SetText("The search didn't work. Keep typing or press Enter.")
			end
		end

	elseif event == "AUCTION_HOUSE_CLOSED" then
		HS.ClosePicker()
		full = nil -- not finished: it tries again next time
		if ui.listMenu then ui.listMenu:Hide() end
		if pending and pending.stage ~= "buying" then CancelQuote() end
		ahOpen = false
		scanning = false
		pending = nil
		awaiting = nil
		lineFreeSince = nil
		othersUntil = 0
		ui.pauseShown = nil
		ui.mouseOnAH = nil
		ui.focusSellTip = nil
		ClearCheckSoon()
		ui.frame:Hide()

	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		local itemID = ...
		if awaiting and awaiting.id == itemID then awaiting = nil end
		if Cfg(itemID) and not pending then Evaluate(itemID) end

	elseif event == "COMMODITY_PRICE_UPDATED" then
		local _, totalPrice = ...
		if pending and pending.stage == "quoting" then
			-- Never pay more than what the addon showed you (already at or under your max). If
			-- someone bought the cheap ones first, it cancels and searches again right away.
			local cap = pending.expected
			if pending.max then cap = math.min(cap, pending.max * pending.qty) end
			-- Accept if the average price stays at or under your max and you can afford it.
			-- If someone bought the cheapest ones first, the leftovers are fine as long as
			-- they're still under your max.
			if totalPrice <= cap and totalPrice <= Spendable() then
				pending.quote = totalPrice
				pending.t = GetTime()
				if db.autoBuy and not db.autoBuyBlocked then
					if LineReady() then
						SendConfirm(true)
					else
						pending.stage = "waitline" -- buys the moment the line frees up
						pending.auto = true
					end
				else
					pending.stage = "ready"
					SetStatus(("READY: press again to buy %d %s for %s"):format(pending.qty, ItemName(pending.itemID), Money(totalPrice)), 0.3, 1, 0.3)
				end
			else
				CancelQuote()
				if totalPrice > Spendable() then
					SetStatus(("Price came back at %s, more than you can spend. Cancelled, nothing bought."):format(Money(totalPrice)), 1, 0.4, 0.4)
				else
					SetStatus(("Price came back over your max (%s vs %s). Someone beat you. Cancelled, nothing bought."):format(Money(totalPrice), Money(pending.expected)), 1, 0.4, 0.4)
				end
				results[pending.itemID] = nil
				priorityID = pending.itemID -- look again right away
				pending = nil
			end
			HS.Refresh()
		end

	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		lineFreeSince = lineFreeSince or GetTime()
		if pending and pending.stage == "waitline" then
			SendConfirm(true)
			HS.Refresh()
		end

	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		-- The game refused the automatic buy: from now on, the buy key takes two presses.
		local addon = ...
		if addon == ADDON_NAME and pending and pending.auto and pending.stage == "buying" then
			db.autoBuyBlocked = true
			pending.stage = "ready"
			pending.auto = nil
			pending.t = GetTime()
			SetStatus(("READY: press again to buy %d %s for %s"):format(pending.qty, ItemName(pending.itemID), Money(pending.quote)), 0.3, 1, 0.3)
			Print("The game blocked buying without a key press, so the buy key now takes two presses. You can try auto-buy again in Settings.")
			HS.Refresh()
		end

	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		if pending then
			SetStatus("Those auctions are gone. Nothing bought.", 1, 0.4, 0.4)
			results[pending.itemID] = nil
			pending = nil
			HS.Refresh()
		end

	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		if pending then
			local total = pending.quote or pending.expected
			table.insert(db.history, 1, { t = time(), id = pending.itemID, qty = pending.qty, total = total })
			while #db.history > 50 do table.remove(db.history) end
			Print(("Bought %d %s for %s."):format(pending.qty, ItemName(pending.itemID), Money(total)))
			local cfg = pending.cfg
			local L = pending.list
			if cfg and cfg.kind == "list" then
				-- Shopping list: count it (Track totals) and add it to the list's receipt.
				if L and L.track then cfg.got = (cfg.got or 0) + pending.qty end
				if L then
					L.log = L.log or {}
					local e = L.log[pending.itemID] or { qty = 0, spent = 0, normal = 0, spentN = 0 }
					e.qty, e.spent = e.qty + pending.qty, e.spent + total
					local typ = Typical(pending.itemID)
					if typ then e.normal, e.spentN = e.normal + typ * pending.qty, e.spentN + total end
					L.log[pending.itemID] = e
				end
			elseif cfg then
				ResetIfStale(cfg)
				cfg.bought = (cfg.bought or 0) + pending.qty
				cfg.boughtAt = time()
			end
			-- Your gold after this buy, even if the game hasn't updated the total yet.
			moneyCap = (pending.moneyAtStart or Money_Now()) - total
			moneyCapAt = GetTime()
			-- Keep buying: take what you just bought off the listings we already know about,
			-- so your very next click can buy the rest without waiting for a new search.
			-- (Every buy is still price-checked first, so stale info can never overspend.)
			local id = pending.itemID
			local r = results[id]
			local more = 0
			if cfg and r and r.under then
				local left = pending.qty
				for _, l in ipairs(r.under) do
					local used = math.min(l.qty, left)
					l.qty = l.qty - used
					left = left - used
					if left <= 0 then break end
				end
				r.avail, r.total = Fill(cfg, r.under, r.typo)
				more = r.avail
				-- Same for the listings table on the Focus page, so it doesn't show what you just bought.
				left = pending.qty
				for _, l in ipairs(r.listings or {}) do
					if l.price <= (r.max or 0) then
						local used = math.min(math.max(0, l.qty), left)
						l.qty = l.qty - used
						left = left - used
						if left <= 0 then break end
					end
				end
			else
				results[id] = nil
			end
			local tracked = cfg and ((cfg.kind == "list" and L and L.track) or (cfg.kind ~= "list" and db.countdown))
			if L and L == ActiveList() and ListAllBought(L) then
				SetStatus("Everything on this list is bought! Click Mark complete when you're ready.", 0.3, 1, 0.3)
			elseif tracked and (cfg.kind == "list" and (cfg.got or 0) >= cfg.qty or cfg.kind ~= "list" and Remaining(cfg) == 0) then
				SetStatus(("Got all %d %s."):format(cfg.qty, ItemName(id)), 0.3, 1, 0.3)
			elseif more > 0 then
				SetStatus(("Bought %d! %d more under your max: click again."):format(pending.qty, more), 0.3, 1, 0.3)
			else
				SetStatus(("Bought %d! Watching for more..."):format(pending.qty), 0.3, 1, 0.3)
			end
			-- Nothing left to buy: search again right away. More left: keep the line free for
			-- your next click (the listings refresh on the slower deal pace instead).
			if more == 0 then priorityID = id end
			pending = nil
			HS.Refresh()
		end

	elseif event == "COMMODITY_PURCHASE_FAILED" then
		if pending then
			SetStatus("Purchase failed (someone else got it?). Nothing bought.", 1, 0.4, 0.4)
			results[pending.itemID] = nil
			priorityID = pending.itemID
			pending = nil
			HS.Refresh()
		end

	elseif event == "PLAYER_MONEY" then
		HS.Refresh()
	end
end)

-- ============================================================================
-- Slash commands: /hsnipe (the window does all of this too)
-- ============================================================================

SLASH_HELPMESNIPER1 = "/hsnipe"
SlashCmdList.HELPMESNIPER = function(msg)
	if not db then return end
	msg = msg or ""
	local hasLink = msg:find("item:") ~= nil
	local linkID = tonumber(msg:match("item:(%d+)"))
	local rest = msg:gsub("|c.-|r", "")
	local args = {}
	for w in rest:gmatch("%S+") do args[#args + 1] = w end
	local cmd = (args[1] or ""):lower()

	if cmd == "add" then
		local id, priceArg, qtyArg
		if hasLink then
			id, priceArg, qtyArg = linkID, args[2], args[3]
		else
			id, priceArg, qtyArg = tonumber(args[2]), args[3], args[4]
		end
		local price = ParseMoney(priceArg)
		local qty = tonumber(qtyArg)
		if not id then
			Print("Usage: /hsnipe add [item link or ID] <max price each, e.g. 20c or 27s> <quantity>")
			return
		end
		HS.AddItem(id)
		local L = ActiveList()
		local cfg = L and L.items[id]
		if cfg and price then cfg.mode, cfg.max = "fixed", price end
		if cfg and qty and qty >= 1 then cfg.qty = math.floor(qty) end
		if cfg then
			local max = MaxFor(cfg, id)
			Print(("%s: up to %d at %s each."):format(ItemName(id), cfg.qty, max and Money(max) or "the % of normal (still learning the normal price)"))
		end

	elseif cmd == "remove" then
		local id = hasLink and linkID or tonumber(args[2])
		local L = ActiveList()
		if id and L and L.items[id] then
			HS.RemoveItem(id)
			Print("Removed " .. ItemName(id) .. " from the list.")
		else
			Print("That item isn't on the open shopping list.")
		end

	elseif cmd == "list" then
		local L = ActiveList()
		if not L or #L.order == 0 then Print("The open shopping list is empty.") end
		for _, id in ipairs(L and L.order or {}) do
			local cfg = L.items[id]
			local max = MaxFor(cfg, id)
			Print(("%s (ID %d): up to %d at %s each%s"):format(ItemName(id), id, cfg.qty, max and Money(max) or "?", cfg.enabled == false and " (off)" or ""))
		end

	elseif cmd == "start" then
		scanning = true
	elseif cmd == "stop" then
		scanning = false
		ClearCheckSoon()
	elseif cmd == "show" then
		if ui.frame then ui.frame:Show() end
	else
		Print("open the auction house and use the window. Commands: /hsnipe add, remove, list, start, stop, show")
	end
	HS.Refresh()
end
