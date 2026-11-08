-- Helpme Sniper v0.2
-- Personal quick-buy sniper for stackable auction house items (cloth, dye, herbs).
-- Standalone: scans the auction house itself, no other addons needed.
--
-- Tabs:
--   Snipe      live deals + the BUY button (1st press: get price, 2nd press: buy)
--   Watch List add items (drag / shift-click / item ID), set max price, quantity, on/off, order
--   Settings   gold to keep, extra confirm for big buys, search speed, sound, auto-start, lock
--   History    what you bought and how much you spent today
--
-- WoW requires a real key press or click for each purchase step, so nothing buys on its own.
-- Works only for items sold by quantity (cloth, herbs, dye, ...), not gear or bags.

local ADDON_NAME = ...
local HS = {}
_G.HelpmeSniper = HS

BINDING_HEADER_HELPMESNIPER = "Helpme Sniper"
BINDING_NAME_HELPMESNIPER_BUY = "Buy step (1st press: get price, 2nd press: buy)"

-- Prices are stored in copper (100 copper = 1 silver, 10000 copper = 1 gold).
local DEFAULTS = {
	version = 3,
	interval = 0.6,
	autoStart = true,
	sound = true,
	locked = false,
	reserve = 5000, -- keep 50s
	maxSpend = 20000, -- extra confirm above 2g
	tab = "focus",
	mode = "all", -- "focus" = only the Focus tab's item is searched, "all" = the whole watch list
	items = {
		[2589] = { max = 20, qty = 100, enabled = true }, -- Linen Cloth
		[2592] = { max = 85, qty = 60, enabled = true }, -- Wool Cloth
		[249409] = { max = 2700, qty = 5, enabled = true }, -- Cerulean Dye
	},
	order = { 2589, 2592, 249409 },
	prices = {},
	history = {},
}

local MAX_ITEMS = 8
local LISTING_ROWS = 6 -- cheapest listings shown on the Focus tab
local WINDOW_SECONDS = 60
local MAX_PER_WINDOW = 98 -- the game allows ~100 searches per minute
local MIN_INTERVAL = 0.6
local MAX_INTERVAL = 3.0
local PRICE_KEEP_SECONDS = 3 * 24 * 3600 -- price memory: last 3 days
local MIN_SAMPLES = 10 -- scans needed before "Typical" is trusted
local QUOTE_TIMEOUT, READY_TIMEOUT, BUY_TIMEOUT = 6, 20, 8

local db
local ahOpen, scanning = false, false
local lastSend, nextIndex = 0, 1
local sendTimes = {}
local awaiting -- { id = itemID, t = time sent }
local priorityID, focusID
local results = {} -- [itemID] = { avail, total, cheapest }
local pending -- { itemID, qty, expected, quote, stage = quoting|big|ready|buying, t }
local selected, editID
local ui = {}

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

local function Spendable()
	return math.max(0, GetMoney() - (db.reserve or 0))
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

-- Typical price = the middle value of the cheapest prices seen over the last 3 days.
-- Returns nil (still learning) until there are enough scans.
local function Typical(id)
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
	for _, id in ipairs(db.order) do
		local r = results[id]
		if r and r.avail > 0 then return id end
	end
	return nil
end

local function Evaluate(itemID)
	local cfg = db.items[itemID]
	if not cfg then return end
	local money = Spendable()
	local avail, total, cheapest = 0, 0, nil
	local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
	local listings = {}
	for i = 1, math.min(n, LISTING_ROWS) do
		local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		if not info then break end
		listings[#listings + 1] = { price = info.unitPrice, qty = (info.quantity or 0) - (info.numOwnerItems or 0) }
	end
	for i = 1, n do
		local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		if not info then break end
		local price = info.unitPrice
		cheapest = cheapest or price
		if (cfg.enabled == false and itemID ~= focusID) or (cfg.max or 0) <= 0 or price > cfg.max then break end
		local q = (info.quantity or 0) - (info.numOwnerItems or 0) -- skip your own auctions
		if q > 0 then
			local want = cfg.qty - avail
			local afford = math.floor((money - total) / price)
			local take = math.min(q, want, afford)
			if take > 0 then
				avail = avail + take
				total = total + take * price
			end
			if avail >= cfg.qty or take < math.min(q, want) then break end -- got enough, or out of gold
		end
	end
	RecordPrice(itemID, cheapest)
	local prev = results[itemID]
	results[itemID] = { avail = avail, total = total, cheapest = cheapest, listings = listings, time = GetTime() }
	if avail > 0 and (not prev or prev.avail == 0) then
		PlayAlert()
		if not pending then
			SetStatus(("Deal: %d %s at avg %s. Press buy key."):format(avail, ItemName(itemID), Money(total / avail)), 0.3, 1, 0.3)
		end
	end
	HS.Refresh()
end

-- ============================================================================
-- Buying (bound to a key, a macro, or the BUY button)
-- ============================================================================

function HelpmeSniper_BuyStep()
	if not db then return end
	if not ahOpen then
		Print("Open the auction house first.")
		return
	end
	if pending then
		if pending.stage == "big" then
			pending.stage = "ready"
			pending.t = GetTime()
			SetStatus(("Big buy confirmed. Press once more to buy %d %s for %s."):format(pending.qty, ItemName(pending.itemID), Money(pending.quote)), 1, 0.8, 0.2)
		elseif pending.stage == "ready" then
			pending.stage = "buying"
			pending.t = GetTime()
			C_AuctionHouse.ConfirmCommoditiesPurchase(pending.itemID, pending.qty)
			SetStatus(("Buying %d %s..."):format(pending.qty, ItemName(pending.itemID)), 1, 1, 0)
		else
			SetStatus("Waiting for the auction house...", 1, 1, 0)
		end
		HS.Refresh()
		return
	end
	local id = Target()
	if not id then
		SetStatus("No deals right now.", 0.7, 0.7, 0.7)
		return
	end
	local r = results[id]
	pending = { itemID = id, qty = r.avail, expected = r.total, stage = "quoting", t = GetTime() }
	C_AuctionHouse.StartCommoditiesPurchase(id, r.avail)
	SetStatus(("Getting price for %d %s..."):format(r.avail, ItemName(id)), 1, 1, 0)
	HS.Refresh()
end

-- ============================================================================
-- Scanning
-- ============================================================================

local function CanSend(now)
	while sendTimes[1] and now - sendTimes[1] >= WINDOW_SECONDS do table.remove(sendTimes, 1) end
	if #sendTimes >= MAX_PER_WINDOW then return false end
	if now - lastSend < (db.interval or MIN_INTERVAL) then return false end
	if awaiting and now - awaiting.t < 3 then return false end -- wait for the last answer (max 3s)
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then return false end
	return true
end

local function NextItem()
	if priorityID then
		local id = priorityID
		priorityID = nil
		if db.items[id] then return id end
	end
	if not scanning then return nil end
	if db.mode == "focus" then
		return (focusID and db.items[focusID]) and focusID or nil
	end
	local n = #db.order
	for _ = 1, n do
		if nextIndex > n then nextIndex = 1 end
		local id = db.order[nextIndex]
		nextIndex = nextIndex + 1
		local cfg = db.items[id]
		if cfg and cfg.enabled ~= false then return id end
	end
	return nil
end

local function Tick()
	if not db or not ahOpen then return end
	local now = GetTime()
	if HS.UpdateAge then HS.UpdateAge(now) end
	if pending then
		local limit = (pending.stage == "buying" and BUY_TIMEOUT) or (pending.stage == "quoting" and QUOTE_TIMEOUT) or READY_TIMEOUT
		if now - pending.t > limit then
			if pending.stage ~= "buying" then CancelQuote() end
			SetStatus("Timed out, cancelled. Nothing was bought.", 1, 0.6, 0.2)
			pending = nil
			HS.Refresh()
		end
		return -- no searching while a purchase is in progress
	end
	if not scanning and not priorityID then return end
	if not CanSend(now) then return end
	local id = NextItem()
	if not id then return end
	lastSend = now
	sendTimes[#sendTimes + 1] = now
	awaiting = { id = id, t = now }
	C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(id), {}, true)
end

-- ============================================================================
-- Watch list changes
-- ============================================================================

function HS.AddItem(id)
	if not id or not db then return end
	local listed = false
	for _, v in ipairs(db.order) do
		if v == id then listed = true end
	end
	if listed then
		Print(ItemName(id) .. " is already on your watch list.")
	elseif #db.order >= MAX_ITEMS then
		Print("Watch list is full (" .. MAX_ITEMS .. " items). Remove one first.")
		return
	else
		db.items[id] = db.items[id] or { max = 0, qty = 20, enabled = true }
		table.insert(db.order, id)
		Print("Added " .. ItemName(id) .. ". Set your max price on the Watch List tab.")
	end
	editID = id
	priorityID = id -- look up its price right away
	HS.Refresh()
end

function HS.RemoveItem(id)
	if not db.items[id] then return end
	if id ~= db.focusItem then -- the Focus tab's item keeps its price and quantity
		db.items[id] = nil
		results[id] = nil
	end
	for i = #db.order, 1, -1 do
		if db.order[i] == id then table.remove(db.order, i) end
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
		HS.Refresh()
	end
end

function HS.MoveItem(id, delta)
	for i, v in ipairs(db.order) do
		if v == id then
			local j = i + delta
			if j >= 1 and j <= #db.order then
				db.order[i], db.order[j] = db.order[j], db.order[i]
			end
			break
		end
	end
	HS.Refresh()
end

StaticPopupDialogs["HELPMESNIPER_REMOVE"] = {
	text = "Stop watching %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, data) HS.RemoveItem(data) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

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
local function MoneyBoxes(parent, x, y, onCommit)
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
		eb:SetScript("OnEditFocusLost", function()
			if boxes.cancel then
				boxes.cancel = nil
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
-- Window
-- ============================================================================

local TABS = { { key = "focus", label = "Focus" }, { key = "snipe", label = "Snipe" }, { key = "watch", label = "Watch List" }, { key = "settings", label = "Settings" }, { key = "history", label = "History" } }

function HS.ShowTab(key)
	db.tab = key
	if key == "focus" then
		db.mode = "focus"
	elseif key == "snipe" then
		db.mode = "all"
	end
	HS.UpdateMode()
	for _, t in ipairs(TABS) do
		ui.panels[t.key]:SetShown(t.key == key)
		if t.key == key then ui.tabs[t.key]:LockHighlight() else ui.tabs[t.key]:UnlockHighlight() end
	end
	HS.Refresh()
end

local function BuildSnipePanel(p)
	ui.scanLine = Text(p, "GameFontHighlightSmall", 2, -6, 450)

	Text(p, "GameFontNormalSmall", 4, -30, 150):SetText("Item")
	Text(p, "GameFontNormalSmall", 156, -30, 62, "RIGHT"):SetText("Deal qty")
	Text(p, "GameFontNormalSmall", 220, -30, 76, "RIGHT"):SetText("Avg price")
	Text(p, "GameFontNormalSmall", 298, -30, 66, "RIGHT"):SetText("Your max")
	Text(p, "GameFontNormalSmall", 366, -30, 86, "RIGHT"):SetText("Typical")

	ui.snipeRows = {}
	for i = 1, MAX_ITEMS do
		local b = CreateFrame("Button", nil, p)
		b:SetSize(452, 18)
		b:SetPoint("TOPLEFT", 0, -46 - (i - 1) * 19)
		b.hl = b:CreateTexture(nil, "BACKGROUND")
		b.hl:SetAllPoints()
		b.hl:SetColorTexture(0.2, 0.55, 0.2, 0.35)
		b.hl:Hide()
		b.name = Text(b, nil, 4, -3, 150)
		b.qty = Text(b, nil, 156, -3, 62, "RIGHT")
		b.avg = Text(b, nil, 220, -3, 76, "RIGHT")
		b.max = Text(b, nil, 298, -3, 66, "RIGHT")
		b.typ = Text(b, nil, 366, -3, 86, "RIGHT")
		b:SetScript("OnClick", function(self)
			if self.itemID then
				selected = self.itemID
				HS.Refresh()
			end
		end)
		ui.snipeRows[i] = b
	end
	local note = Text(p, "GameFontDisableSmall", 2, -210, 450)
	note:SetText("All ticked items take turns. Click a row to choose which one the buy key buys.")
end

local function BuildWatchPanel(p)
	Text(p, "GameFontNormalSmall", 2, -7):SetText("Add item:")
	local function AddFromCursor()
		local kind, id, link = GetCursorInfo()
		if kind == "item" then
			ClearCursor()
			HS.AddItem(tonumber(id) or ItemIDFromText(link))
			return true
		end
	end
	ui.dropBtn = Button(p, "Drop item here", 60, -2, 120, 22, function()
		if not AddFromCursor() then Print("Pick up an item from your bags, then click or drop it on this button.") end
	end)
	ui.dropBtn:SetScript("OnReceiveDrag", AddFromCursor)

	ui.addBox = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
	ui.addBox:SetSize(150, 20)
	ui.addBox:SetPoint("TOPLEFT", 192, -3)
	ui.addBox:SetAutoFocus(false)
	ui.addBox:SetFontObject("GameFontHighlightSmall")
	ui.addHint = ui.addBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.addHint:SetPoint("LEFT", 2, 0)
	ui.addHint:SetText("or shift-click / name / ID")
	ui.addBox:SetScript("OnEditFocusGained", function() ui.addHint:Hide() end)
	ui.addBox:SetScript("OnEditFocusLost", function(self) ui.addHint:SetShown(self:GetText() == "") end)
	ui.addBox:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
	ui.addBox:SetScript("OnEnterPressed", function(self)
		local id = ItemIDFromText(self:GetText())
		self:SetText("")
		self:ClearFocus()
		if id then HS.AddItem(id) else Print("Couldn't read an item from that. Shift-click an item or type its ID.") end
	end)
	ui.addBox:SetScript("OnReceiveDrag", AddFromCursor)
	Text(p, "GameFontDisableSmall", 350, -8, 104):SetText("max " .. MAX_ITEMS .. " items")

	Text(p, "GameFontNormalSmall", 0, -32, 24):SetText("On")
	Text(p, "GameFontNormalSmall", 26, -32, 110):SetText("Item (click to edit)")
	Text(p, "GameFontNormalSmall", 146, -32, 130):SetText("Max price each")
	Text(p, "GameFontNormalSmall", 286, -32, 80):SetText("Quantity")
	Text(p, "GameFontNormalSmall", 400, -32, 54, "RIGHT"):SetText("Remove")

	ui.watchRows = {}
	for i = 1, MAX_ITEMS do
		local row = CreateFrame("Frame", nil, p)
		row:SetSize(456, 20)
		row:SetPoint("TOPLEFT", 0, -46 - (i - 1) * 21)
		row.sel = row:CreateTexture(nil, "BACKGROUND")
		row.sel:SetAllPoints()
		row.sel:SetColorTexture(0.25, 0.4, 0.7, 0.3)
		row.sel:Hide()

		row.on = Check(row, nil, 0, 0, function(self)
			local cfg = row.itemID and db.items[row.itemID]
			if cfg then
				cfg.enabled = self:GetChecked() and true or false
				if not cfg.enabled then results[row.itemID] = nil end
				HS.Refresh()
			end
		end)

		row.nameBtn = CreateFrame("Button", nil, row)
		row.nameBtn:SetSize(112, 20)
		row.nameBtn:SetPoint("TOPLEFT", 26, 0)
		row.name = Text(row.nameBtn, nil, 0, -4, 112)
		row.nameBtn:SetScript("OnClick", function()
			editID = row.itemID
			HS.Refresh()
		end)

		row.money = MoneyBoxes(row, 140, -1, function(copper)
			local cfg = row.itemID and db.items[row.itemID]
			if cfg then
				cfg.max = copper
				results[row.itemID] = nil
				priorityID = row.itemID
			end
			HS.Refresh()
		end)

		row.minus = Button(row, "-", 286, 0, 20, 20, function()
			local cfg = row.itemID and db.items[row.itemID]
			if cfg then
				cfg.qty = math.max(1, cfg.qty - (IsShiftKeyDown() and 10 or 1))
				HS.Refresh()
			end
		end)
		row.qty = NumberBox(row, 304, -1, 34, 4)
		row.qty:SetJustifyH("CENTER")
		row.qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		row.qty:SetScript("OnEditFocusLost", function(self)
			local cfg = row.itemID and db.items[row.itemID]
			local v = tonumber(self:GetText())
			if cfg and v and v >= 1 then cfg.qty = math.floor(v) end
			HS.Refresh()
		end)
		row.plus = Button(row, "+", 346, 0, 20, 20, function()
			local cfg = row.itemID and db.items[row.itemID]
			if cfg then
				cfg.qty = cfg.qty + (IsShiftKeyDown() and 10 or 1)
				HS.Refresh()
			end
		end)

		row.del = Button(row, "X", 432, 0, 22, 20, function()
			if row.itemID then StaticPopup_Show("HELPMESNIPER_REMOVE", ItemName(row.itemID), nil, row.itemID) end
		end)
		ui.watchRows[i] = row
	end

	ui.editInfo = Text(p, "GameFontHighlightSmall", 2, -220, 450)
	ui.pctLabel = Text(p, "GameFontNormalSmall", 2, -246, 120)
	ui.pctLabel:SetText("Set max to typical x")
	ui.pctBtns = {}
	for i, pct in ipairs({ 70, 80, 90, 100 }) do
		ui.pctBtns[i] = Button(p, pct .. "%", 124 + (i - 1) * 54, -242, 50, 20, function()
			local cfg = editID and db.items[editID]
			local typ = editID and Typical(editID)
			if cfg and typ then
				cfg.max = math.max(1, math.floor(typ * pct / 100))
				results[editID] = nil
				priorityID = editID
				HS.Refresh()
			end
		end)
	end
	Text(p, "GameFontDisableSmall", 344, -247, 110):SetText("Shift +/- = 10")
end

local function BuildSettingsPanel(p)
	Text(p, "GameFontNormalSmall", 2, -8, 220):SetText("Gold to keep (never spend below this):")
	ui.reserve = MoneyBoxes(p, 230, -4, function(copper)
		db.reserve = copper
		HS.Refresh()
	end)
	Text(p, "GameFontNormalSmall", 2, -36, 220):SetText("Ask an extra time for buys over:")
	ui.maxSpend = MoneyBoxes(p, 230, -32, function(copper)
		db.maxSpend = copper
		HS.Refresh()
	end)

	Text(p, "GameFontNormalSmall", 2, -64, 220):SetText("Search speed (seconds per search):")
	Button(p, "-", 236, -60, 22, 20, function()
		db.interval = math.max(MIN_INTERVAL, math.floor((db.interval - 0.1) * 10 + 0.5) / 10)
		HS.Refresh()
	end)
	ui.speedText = Text(p, "GameFontHighlight", 262, -63, 40, "CENTER")
	Button(p, "+", 306, -60, 22, 20, function()
		db.interval = math.min(MAX_INTERVAL, math.floor((db.interval + 0.1) * 10 + 0.5) / 10)
		HS.Refresh()
	end)
	ui.speedNote = Text(p, "GameFontDisableSmall", 2, -84, 450)

	ui.soundCheck = Check(p, "Play a sound when a deal appears", 0, -106, function(self) db.sound = self:GetChecked() and true or false end)
	ui.autoCheck = Check(p, "Start scanning when the auction house opens", 0, -130, function(self) db.autoStart = self:GetChecked() and true or false end)
	ui.lockCheck = Check(p, "Lock window position", 0, -154, function(self) db.locked = self:GetChecked() and true or false end)

	local help = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	help:SetPoint("TOPLEFT", 2, -190)
	help:SetWidth(450)
	help:SetJustifyH("LEFT")
	help:SetText("Buy key: Esc > Options > Keybindings > AddOns > Helpme Sniper.\nOr make a macro: /click HelpmeSniperBuyButton\nThe game allows about 100 searches per minute for all addons combined, so other auction addons scanning at the same time will slow this down.")
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
	ui.focusBox:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
	ui.focusBox:SetScript("OnEnterPressed", function(self)
		local id = ItemIDFromText(self:GetText())
		self:SetText("")
		self:ClearFocus()
		if id then
			HS.SetFocusItem(id)
		else
			Print("Couldn't find that item by name (names only work for items your game has loaded). Drop it or shift-click it instead.")
		end
	end)
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
		local id = db.focusItem
		local cfg = id and db.items[id]
		if cfg then
			cfg.max = copper
			results[id] = nil
			priorityID = id
		end
		HS.Refresh()
	end)
	Text(b, "GameFontNormalSmall", 244, -78, 56):SetText("Quantity:")
	Button(b, "-", 300, -74, 20, 20, function() HS.FocusQty(IsShiftKeyDown() and -10 or -1) end)
	ui.fQty = NumberBox(b, 320, -75, 40, 4)
	ui.fQty:SetJustifyH("CENTER")
	ui.fQty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	ui.fQty:SetScript("OnEditFocusLost", function(self)
		local cfg = db.focusItem and db.items[db.focusItem]
		local v = tonumber(self:GetText())
		if cfg and v and v >= 1 then cfg.qty = math.floor(v) end
		HS.Refresh()
	end)
	Button(b, "+", 372, -74, 20, 20, function() HS.FocusQty(IsShiftKeyDown() and 10 or 1) end)
	Text(b, "GameFontDisableSmall", 398, -78, 58):SetText("Shift = 10")

	Text(b, "GameFontNormalSmall", 2, -104, 120):SetText("Set max to typical x")
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

	ui.fPrices = Text(b, "GameFontHighlightSmall", 2, -128, 450)
	ui.fDeal = Text(b, "GameFontHighlight", 2, -144, 450)

	Text(b, "GameFontNormalSmall", 4, -166, 90, "RIGHT"):SetText("Price each")
	Text(b, "GameFontNormalSmall", 100, -166, 70, "RIGHT"):SetText("Available")
	Text(b, "GameFontNormalSmall", 176, -166, 90, "RIGHT"):SetText("Running total")
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
		local pnt, _, rp, x, y = self:GetPoint()
		db.pos = { pnt, rp, x, y }
	end)
	if db.pos then
		f:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
	else
		f:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
	end
	f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	f:SetBackdropColor(0.05, 0.06, 0.07, 0.95)
	f:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
	f:Hide()
	f:SetScript("OnHide", function() scanning = false end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 10, -9)
	title:SetText("Helpme Sniper")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)

	ui.startBtn = Button(f, "Start", 356, -7, 80, 20, function()
		scanning = not scanning
		SetStatus(scanning and "Scanning..." or "Paused.", 0.8, 0.8, 0.8)
		HS.Refresh()
	end)

	ui.tabs, ui.panels = {}, {}
	for i, t in ipairs(TABS) do
		ui.tabs[t.key] = Button(f, t.label, 8 + (i - 1) * 91, -32, 88, 22, function() HS.ShowTab(t.key) end)
		local p = CreateFrame("Frame", nil, f)
		p:SetPoint("TOPLEFT", 8, -60)
		p:SetPoint("BOTTOMRIGHT", -8, 76)
		p:Hide()
		ui.panels[t.key] = p
	end
	BuildFocusPanel(ui.panels.focus)
	BuildSnipePanel(ui.panels.snipe)
	BuildWatchPanel(ui.panels.watch)
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
end

-- ============================================================================
-- Refresh (redraws whatever is on screen)
-- ============================================================================

local function TypicalText(id)
	local typ, n = Typical(id)
	if typ then return Money(typ) end
	return "|cff888888learning " .. n .. "/" .. MIN_SAMPLES .. "|r"
end

local function RefreshSnipe()
	if focusID then
		ui.scanLine:SetText((scanning and "|cff33ff33Scanning|r" or "|cffff8833Paused|r") .. "  |cffffd100Focus: " .. ItemName(focusID) .. "|r")
	else
		ui.scanLine:SetText((scanning and "|cff33ff33Scanning|r" or "|cffff8833Paused|r") .. "   Gold " .. Money(GetMoney()) .. "  (keep " .. Money(db.reserve) .. ")")
	end

	local target = Target()
	local i = 1
	for _, id in ipairs(db.order) do
		local cfg = db.items[id]
		local r = results[id]
		local row = ui.snipeRows[i]
		row.itemID = id
		row:Show()
		row.name:SetText(ItemName(id))
		row.max:SetText(cfg.max > 0 and Money(cfg.max) or "|cffff5555set price|r")
		row.typ:SetText(TypicalText(id))
		if cfg.enabled == false then
			row.qty:SetText("|cff888888paused|r")
			row.avg:SetText("")
			row.name:SetTextColor(0.45, 0.45, 0.45)
		elseif r and r.avail > 0 then
			row.qty:SetText(r.avail .. "/" .. cfg.qty)
			row.avg:SetText(Money(r.total / r.avail))
			row.name:SetTextColor(0.3, 1, 0.3)
		else
			row.qty:SetText("-")
			row.avg:SetText(r and r.cheapest and ("low " .. Money(r.cheapest)) or "-")
			row.name:SetTextColor(focusID and focusID ~= id and 0.45 or 0.8, focusID and focusID ~= id and 0.45 or 0.8, focusID and focusID ~= id and 0.45 or 0.8)
		end
		row.hl:SetShown(target == id)
		i = i + 1
	end
	for j = i, MAX_ITEMS do
		ui.snipeRows[j].itemID = nil
		ui.snipeRows[j]:Hide()
	end

end

local function RefreshBuy()
	ui.startBtn:SetText(scanning and "Stop" or "Start")
	local target = Target()
	if pending and pending.stage == "big" then
		ui.buyBtn:SetText("BIG BUY " .. Money(pending.quote) .. " - press again to continue")
	elseif pending and pending.stage == "ready" then
		ui.buyBtn:SetText("CONFIRM: buy " .. pending.qty .. " for " .. Money(pending.quote))
	elseif pending then
		ui.buyBtn:SetText("Working...")
	elseif target then
		ui.buyBtn:SetText("BUY " .. results[target].avail .. " " .. ItemName(target))
	else
		ui.buyBtn:SetText("BUY (no deals yet)")
	end
end

local function RefreshWatch()
	local i = 1
	for _, id in ipairs(db.order) do
		local cfg = db.items[id]
		local row = ui.watchRows[i]
		row.itemID = id
		row:Show()
		row.on:SetChecked(cfg.enabled ~= false)
		row.name:SetText(ItemName(id))
		row.name:SetTextColor(cfg.enabled == false and 0.5 or 1, cfg.enabled == false and 0.5 or 1, cfg.enabled == false and 0.5 or 1)
		row.money.Set(cfg.max)
		if not row.qty:HasFocus() then row.qty:SetText(tostring(cfg.qty)) end
		row.sel:SetShown(editID == id)
		i = i + 1
	end
	for j = i, MAX_ITEMS do
		ui.watchRows[j].itemID = nil
		ui.watchRows[j]:Hide()
	end

	local cfg = editID and db.items[editID]
	if cfg then
		local typ, n = Typical(editID)
		local low = LowToday(editID)
		local r = results[editID]
		ui.editInfo:SetText(("|cffffd100%s|r   Typical: %s   Low today: %s   Cheapest now: %s"):format(
			ItemName(editID),
			typ and Money(typ) or ("learning " .. n .. "/" .. MIN_SAMPLES),
			low and Money(low) or "-",
			(r and r.cheapest) and Money(r.cheapest) or "-"))
		for _, b in ipairs(ui.pctBtns) do b:SetEnabled(typ ~= nil) end
	else
		ui.editInfo:SetText("|cff888888Click an item name to see its prices and quick-set buttons.|r")
		for _, b in ipairs(ui.pctBtns) do b:SetEnabled(false) end
	end
end

local function RefreshSettings()
	ui.reserve.Set(db.reserve)
	ui.maxSpend.Set(db.maxSpend)
	ui.speedText:SetText(("%.1f"):format(db.interval))
	local active = 0
	for _, id in ipairs(db.order) do
		if db.items[id] and db.items[id].enabled ~= false then active = active + 1 end
	end
	ui.speedNote:SetText(("Focus tab: your one item is checked every %.1fs. Snipe tab: %d items take turns, each about every %.1fs."):format(db.interval, active, db.interval * math.max(1, active)))
	ui.soundCheck:SetChecked(db.sound)
	ui.autoCheck:SetChecked(db.autoStart)
	ui.lockCheck:SetChecked(db.locked)
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

	local typ, n = Typical(id)
	for _, btn in ipairs(ui.fPct) do btn:SetEnabled(typ ~= nil) end
	local low = LowToday(id)
	local r = results[id]
	ui.fPrices:SetText(("Cheapest now: %s     Typical: %s     Low today: %s"):format(
		(r and r.cheapest) and Money(r.cheapest) or "-",
		typ and Money(typ) or ("learning " .. n .. "/" .. MIN_SAMPLES),
		low and Money(low) or "-"))

	if (cfg.max or 0) <= 0 then
		ui.fDeal:SetText("Set your max price above to start sniping.")
		ui.fDeal:SetTextColor(1, 0.35, 0.35)
	elseif r and r.avail > 0 then
		ui.fDeal:SetText(("DEAL: %d at avg %s (total %s). Press buy!"):format(r.avail, Money(r.total / r.avail), Money(r.total)))
		ui.fDeal:SetTextColor(0.3, 1, 0.3)
	elseif r and r.cheapest then
		ui.fDeal:SetText(("No deal yet: cheapest is %s, your max is %s."):format(Money(r.cheapest), Money(cfg.max)))
		ui.fDeal:SetTextColor(0.65, 0.65, 0.65)
	elseif r then
		ui.fDeal:SetText("None listed right now.")
		ui.fDeal:SetTextColor(0.65, 0.65, 0.65)
	else
		ui.fDeal:SetText("Waiting for the first search...")
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
	local state = scanning and ("|cff33ff33Searching every " .. ("%.1f"):format(db.interval) .. "s|r") or "|cffff8833Paused - click Start|r"
	if r and r.time then state = state .. ("     last update %.1fs ago"):format(now - r.time) end
	ui.fAge:SetText(state)
end

function HS.Refresh()
	if not ui.frame or not db then return end
	RefreshBuy()
	if ui.panels.focus:IsShown() then RefreshFocus() end
	if ui.panels.snipe:IsShown() then RefreshSnipe() end
	if ui.panels.watch:IsShown() then RefreshWatch() end
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
		HS.SetFocusItem(ItemIDFromText(link))
		return
	end
	if ui.addBox and ui.addBox:HasFocus() and link then
		local id = ItemIDFromText(link)
		ui.addBox:SetText("")
		ui.addBox:ClearFocus()
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
	db.order = db.order or {}
	db.prices = db.prices or {}
	db.history = db.history or {}
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
ev:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == ADDON_NAME then
			InitDB()
			BuildFrame()
			C_Timer.NewTicker(0.1, Tick)
		end
		return
	end
	if not db then return end

	if event == "AUCTION_HOUSE_SHOW" then
		ahOpen = true
		results = {}
		ui.frame:Show()
		scanning = db.autoStart and true or false
		HS.ShowTab(db.tab or "snipe")
		SetStatus(scanning and "Scanning..." or "Paused. Click Start.", 0.8, 0.8, 0.8)

	elseif event == "AUCTION_HOUSE_CLOSED" then
		if pending and pending.stage ~= "buying" then CancelQuote() end
		ahOpen = false
		scanning = false
		pending = nil
		awaiting = nil
		ui.frame:Hide()

	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		local itemID = ...
		if awaiting and awaiting.id == itemID then awaiting = nil end
		if db.items[itemID] and not pending then Evaluate(itemID) end

	elseif event == "COMMODITY_PRICE_UPDATED" then
		local _, totalPrice = ...
		if pending and pending.stage == "quoting" then
			local cfg = db.items[pending.itemID]
			local cap = cfg and (cfg.max * pending.qty) or pending.expected
			-- Accept only if the quote matches what we saw (1c per item slack for rounding)
			-- and the average never goes over your max.
			if totalPrice <= pending.expected + pending.qty and totalPrice <= cap then
				pending.quote = totalPrice
				pending.t = GetTime()
				if totalPrice > (db.maxSpend or 0) and (db.maxSpend or 0) > 0 then
					pending.stage = "big"
					SetStatus(("Over your %s limit: %d %s for %s. Press again if you're sure."):format(Money(db.maxSpend), pending.qty, ItemName(pending.itemID), Money(totalPrice)), 1, 0.8, 0.2)
				else
					pending.stage = "ready"
					SetStatus(("READY: press again to buy %d %s for %s"):format(pending.qty, ItemName(pending.itemID), Money(totalPrice)), 0.3, 1, 0.3)
				end
			else
				CancelQuote()
				SetStatus(("Price came back higher (%s vs %s). Someone beat you. Cancelled, nothing bought."):format(Money(totalPrice), Money(pending.expected)), 1, 0.4, 0.4)
				results[pending.itemID] = nil
				pending = nil
			end
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
			SetStatus("Bought! Watching for more...", 0.3, 1, 0.3)
			results[pending.itemID] = nil
			priorityID = pending.itemID -- check for more right away
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
		local cfg = db.items[id]
		if cfg and price then cfg.max = price end
		if cfg and qty and qty >= 1 then cfg.qty = math.floor(qty) end
		if cfg then Print(("%s: up to %d at %s each."):format(ItemName(id), cfg.qty, Money(cfg.max))) end

	elseif cmd == "remove" then
		local id = hasLink and linkID or tonumber(args[2])
		if id and db.items[id] then
			HS.RemoveItem(id)
			Print("Stopped watching " .. ItemName(id) .. ".")
		else
			Print("That item isn't on the watch list.")
		end

	elseif cmd == "list" then
		if #db.order == 0 then Print("Watch list is empty.") end
		for _, id in ipairs(db.order) do
			local cfg = db.items[id]
			Print(("%s (ID %d): up to %d at %s each%s"):format(ItemName(id), id, cfg.qty, Money(cfg.max), cfg.enabled == false and " (paused)" or ""))
		end

	elseif cmd == "start" then
		scanning = true
	elseif cmd == "stop" then
		scanning = false
	elseif cmd == "show" then
		if ui.frame then ui.frame:Show() end
	else
		Print("open the auction house and use the window. Commands: /hsnipe add, remove, list, start, stop, show")
	end
	HS.Refresh()
end
