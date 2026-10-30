-- Zelda concerts: watches the tour page of The Legend of Zelda 40th Anniversary Concert
-- (zelda.gameconcerts.com) and pushes when a concert in one of your countries appears,
-- and when the ticket status of one of them changes (sales open, sold out).
--
-- The page is plain HTML, one card per concert:
--   <div class="col-12 ... articletype-0 text-center mb-4"><div>
--     <p>UK</p><p>LONDON</p><p>3. APR 2027</p><p>14:30 Uhr</p>
--     <p><strong>London Symphony Orchestra</strong><br>Royal Albert Hall</p>
--     <a href="https://..." class="btn btn-secondary">Info</a>        <- tickets on sale
--   </div></div>
-- Instead of the Info link a card can end in a status text ("ausverkauft",
-- "Verkauf ab 25. Mär 2027"). The German page writes countries in German capitals
-- (UK, KANADA, USA), so Germany is DEUTSCHLAND.

local M = {
  key = "zelda",
  name = "Zelda concerts",
  version = "1.0.0",
  about = "A push when the Zelda 40th Anniversary Concert tour adds a date in your countries, and when its tickets change.",
  order = 50,
  every = 15,
  minEvery = 5,
  settings = {
    { "url", "Tour page", "https://zelda.gameconcerts.com/de/", hint = "zelda.gameconcerts.com tour list" },
    { "countries", "Countries", "DEUTSCHLAND",
      hint = "as written on the page, comma separated; empty = every new date worldwide" },
  },
}

local CARD = "articletype-0"
local watched = {}      -- concerts in watched countries, from the last check
local totalCards = 0

-- "TORONTO, ON" -> "Toronto, ON", "MÜNCHEN" -> "München"
local function cap(input)
  local out, wordStart, i = {}, true, 1
  while i <= #input do
    local c = input:byte(i)
    if c == 0xC3 and i < #input then          -- UTF-8 Ä Ö Ü
      local d = input:byte(i + 1)
      if not wordStart and (d == 0x84 or d == 0x96 or d == 0x9C) then d = d + 0x20 end
      out[#out + 1] = string.char(c, d)
      wordStart = false
      i = i + 2
    else
      local ch = string.char(c)
      if ch:match("%a") then
        if not wordStart then ch = ch:lower() end
        wordStart = false
      else
        wordStart = ch ~= "'"
      end
      out[#out + 1] = ch
      i = i + 1
    end
  end
  local s = table.concat(out)
  -- Keep a 2-letter state code after the last comma in capitals ("Toronto, ON").
  local last, pos = nil, 1
  while true do
    local a = s:find(", ", pos, true)
    if not a then break end
    last, pos = a, a + 1
  end
  if last and #s - last + 1 == 4 then s = s:sub(1, last + 1) .. input:sub(last + 2) end
  return s
end

local function stripTags(html)
  local out, inTag = {}, false
  for i = 1, #html do
    local c = html:sub(i, i)
    if c == "<" then
      inTag = true
      if html:sub(i, i + 2) == "<br" then out[#out + 1] = " | " end
    elseif c == ">" then
      inTag = false
    elseif not inTag then
      out[#out + 1] = (c == "\n" or c == "\r" or c == "\t") and " " or c
    end
  end
  local s = table.concat(out)
  s = s:gsub("&amp;", "&"):gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#039;", "'")
  s = s:gsub("  +", " ")
  return trim(s)
end

-- The <p>...</p> contents of one card, as plain text.
local function paragraphs(card)
  local ps, pos = {}, 1
  while true do
    local a = card:find("<p>", pos, true)
    if not a then break end
    local b = card:find("</p>", a, true)
    if not b then break end
    ps[#ps + 1] = stripTags(card:sub(a + 3, b - 1))
    pos = b + 4
  end
  return ps
end

local function watchedCountry(country, list)
  if trim(list) == "" then return true end   -- empty = every country
  country = trim(country):upper()
  for _, item in ipairs(split(list:upper(), ",")) do
    if item == country then return true end
  end
  return false
end

local function key(c) return c.country .. "|" .. c.city .. "|" .. c.date .. "|" .. c.time end
local function title(c) return cap(c.city) .. ", " .. c.date end
local function line(c)
  local s = cap(c.city) .. ", " .. c.date
  if c.time ~= "" then s = s .. ", " .. c.time end
  if c.venue ~= "" then s = s .. ", " .. c.venue end
  return s .. " (" .. c.status .. ")"
end

local function parse(page, countries)
  local list, cards, pos = {}, 0, 1
  while true do
    local m = page:find(CARD, pos, true)
    if not m then break end
    local nextCard = page:find(CARD, m + 1, true)
    local e = page:find("</div></div>", m, true)
    if not e or (nextCard and e > nextCard) then e = nextCard or (#page + 1) end
    local card = page:sub(m, e - 1)
    pos = m + 1
    cards = cards + 1

    local p = paragraphs(card)
    if #p >= 3 then
      local c = { country = p[1], city = p[2], date = p[3], time = p[4] or "",
                  orchestra = "", venue = "", status = "", link = "" }
      if p[5] then
        local bar = p[5]:find(" | ", 1, true)
        c.orchestra = bar and p[5]:sub(1, bar - 1) or p[5]
        c.venue = bar and p[5]:sub(bar + 3) or ""
      end
      -- Status: an Info link means tickets are on sale; otherwise the text after the last <p>.
      local lastP, at = nil, 1
      while true do
        local f = card:find("</p>", at, true)
        if not f then break end
        lastP, at = f, f + 1
      end
      local tail = lastP and card:sub(lastP + 4) or ""
      local href = tail:find('href="', 1, true)
      if href then
        local q = tail:find('"', href + 6, true)
        c.link = tail:sub(href + 6, (q or #tail + 1) - 1)
        c.status = "Tickets"
      else
        c.status = stripTags(tail)
        if c.status == "" then c.status = "no tickets yet" end
      end
      if watchedCountry(c.country, countries) then list[#list + 1] = c end
    end
  end
  return list, cards
end

local function list()
  if totalCards == 0 then return "No check yet." end
  if #watched == 0 then
    return "No concert in " .. cfg.countries .. " yet (" .. totalCards ..
           " concerts elsewhere). I'll tell you as soon as one appears."
  end
  local lines = {}
  for _, c in ipairs(watched) do lines[#lines + 1] = "- " .. line(c) end
  return table.concat(lines, "\n")
end

M.commands = {
  { "zelda", "list, liste, concert, konzert", "Zelda concerts in your countries", function() return list() end },
}

function M.notReady()
  if not startsWith(cfg.url, "http") then return "no tour page set" end
end

function M.check()
  local url, countries = cfg.url, cfg.countries
  local page, err = http.get(url)
  if not page then return false, err end
  local found, cards = parse(page, countries)
  if cards == 0 then return false, "no concert cards on the page (layout changed?)" end
  totalCards = cards

  local state = recall()
  local known = type(state) == "table" and state.known or {}   -- key -> last ticket status
  local first = firstCheck()
  local pushes = 0
  for _, c in ipairs(found) do
    local k = key(c)
    local buttons = {}
    if c.link ~= "" then buttons[#buttons + 1] = { "Tickets / info", url = c.link } end
    buttons[#buttons + 1] = { "Open page", url = url }
    buttons[#buttons + 1] = { "All concerts", cmd = "zelda" }
    if known[k] == nil then
      if not first then
        notify("New Zelda concert: " .. title(c),
               c.orchestra ~= "" and (line(c) .. "\n" .. c.orchestra) or line(c), "musical_note", buttons)
        pushes = pushes + 1
      end
    elseif not first and known[k] ~= c.status then
      notify("Ticket update: " .. title(c), "Was: " .. known[k] .. "\nNow: " .. c.status .. "\n" .. line(c),
             "ticket", buttons)
      pushes = pushes + 1
    end
    known[k] = c.status
  end
  remember({ known = known })
  watched = found

  if first then
    local msg = cards .. " concerts on the page, " .. #found .. " in your countries (" .. countries .. ")."
    if #found > 0 then msg = msg .. "\n" .. list() end
    notify("S3-PO watches the Zelda concerts", msg, "musical_note",
           { { "Open page", url = url }, { "All concerts", cmd = "zelda" } })
  end
  if pushes > 0 then blink(5) end
  status(cards .. " concerts, " .. #found .. " in watched countries" ..
         (pushes > 0 and (", " .. pushes .. " push" .. (pushes == 1 and "" or "es")) or ""))
end

return M
