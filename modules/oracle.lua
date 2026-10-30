-- The Game Night Oracle: S3-PO keeps score for your board game group.
--
-- It reads a Board Game Night site's hall of fame (every logged game), the players'
-- collections, the calendar and the campaigns, and:
--   - on a game night (from noon) sends a briefing: who's coming, S3-PO's odds for
--     tonight's winner, the most-voted game, a forgotten game from someone's shelf,
--     a campaign session if one is planned, and a word of droid wisdom
--   - when a game is logged, announces the winner with streaks, firsts and the table
--   - on the 1st of the month sends a recap of the month before
--   - answers "oracle" (or "stats", "leaderboard") with this year's table
-- Win rates follow the site: games without a winner (co-op) don't count against anyone.

local M = {
  key = "oracle",
  name = "Game Night Oracle",
  version = "1.0.0",
  about = "Keeps score for your Board Game Night group: briefings with S3-PO's odds, winners with streaks, a monthly recap.",
  order = 15,
  every = 15,
  minEvery = 5,
  settings = {
    { "me", "Your name on the site", "", hint = "for your own line in the stats; optional" },
    { "briefing", "Briefing on game night days", true },
    { "briefHour", "Briefing from (hour)", 12, range = { 0, 23 } },
    { "onlyMine", "Briefings only for nights I'm in", false },
    { "results", "Announce results when a game is logged", true },
    { "recap", "Monthly recap on the 1st", true },
    { "quips", "Droid commentary", true },
    { "minPlayers", "Players for game on", 3, range = { 1, 50 } },
    { "site", "Calendar page", "", hint = "the site's address, for the Open button" },
    { "project", "Firebase project id", "", hint = "projectId in the site's js/config.js" },
    { "apiKey", "Firebase web API key", "", hint = "apiKey in the site's js/config.js (public)" },
    { "place", "Usual place", "", hint = "shown when a night has no place saved" },
    { "time", "Usual start time", "17:00", hint = "the site's default" },
  },
}

local players = {}   -- id -> { name =, games = { names } }
local plays = {}     -- oldest first: { date, game, winner ("" = none), players, names, createdAt }

-- --- Reading the site (same as in Game nights) -------------------------------------
local function fs(collection, fields, from, to)
  local args = { project = cfg.project, key = cfg.apiKey, collection = collection, fields = fields, from = from, to = to }
  if from then return firestore.range(args) end
  return firestore.list(args)
end

local function loadPlayers()
  local docs, err = fs("players", { "name", "games" })
  if not docs then return nil, err end
  local list = {}
  for _, d in ipairs(docs) do
    local games = {}
    for _, g in ipairs(d.games or {}) do
      if g.name and g.name ~= "" then games[#games + 1] = g.name end
    end
    list[d._id] = { name = (d.name and d.name ~= "") and d.name or "?", games = games }
  end
  return list
end

local function voteKey(id, name)
  if id and tostring(id) ~= "" and tostring(id) ~= "0" then return "g" .. tostring(id) end
  local slug, gap = "", false
  for i = 1, #name do
    local c = name:sub(i, i):lower()
    if c:match("%w") then
      if gap and slug ~= "" then slug = slug .. "_" end
      slug, gap = slug .. c, false
    else
      gap = true
    end
  end
  return "n_" .. (slug ~= "" and slug:sub(1, 60) or "unnamed")
end

local function loadDays(from, to)
  local docs, err = fs("days", { "players", "times", "details", "games", "votes" }, from, to)
  if not docs then return nil, err end
  local days = {}
  for _, d in ipairs(docs) do
    local day = { date = d._id, players = d.players or {}, topGame = "", topVotes = 0 }
    local details, times = d.details or {}, d.times or {}
    if details.time and details.time ~= "" then
      day.time = details.time
    else
      local latest = cfg.time
      for _, p in ipairs(day.players) do
        if times[p] and times[p] > latest then latest = times[p] end
      end
      day.time = latest
    end
    day.place = details.place ~= nil and tostring(details.place) or cfg.place
    local votes = d.votes or {}
    for _, g in ipairs(d.games or {}) do
      local n = #(votes[voteKey(g.id, g.name or "")] or {})
      if n > day.topVotes then day.topVotes, day.topGame = n, g.name or "" end
    end
    days[#days + 1] = day
  end
  return days
end

local function loadPlays()
  local docs, err = fs("plays", { "date", "game.name", "winner", "players", "names", "createdAt" })
  if not docs then return nil, err end
  local list = {}
  for _, d in ipairs(docs) do
    if type(d.date) == "string" and #d.date == 10 then
      list[#list + 1] = { date = d.date, game = (d.game or {}).name or "", winner = d.winner or "",
                          players = d.players or {}, names = d.names or {}, createdAt = d.createdAt or "" }
    end
  end
  table.sort(list, function(a, b)
    if a.date ~= b.date then return a.date < b.date end
    return a.createdAt < b.createdAt
  end)
  return list
end

local function loadCampaigns()
  local docs = fs("campaigns", { "title", "game.name", "next", "status" }) or {}
  local list = {}
  for _, d in ipairs(docs) do
    list[#list + 1] = { title = d.title or "", game = (d.game or {}).name or "", next = d.next or "", status = d.status or "" }
  end
  return list
end
-- -----------------------------------------------------------------------------------

local function name(id, play)
  if players[id] then return players[id].name end
  if play and play.names[id] then return play.names[id] end
  return "?"
end

local function namesOf(ids)
  local names = {}
  for _, id in ipairs(ids) do names[#names + 1] = name(id) end
  return table.concat(names, ", ")
end

local function isIn(ids)
  local me = cfg.me:lower()
  for _, id in ipairs(ids) do
    if me ~= "" and name(id):lower() == me then return true end
  end
  return false
end

local function loadAll(playsOnly)
  local p, err = loadPlays()
  if not p then return false, err end
  plays = p
  if playsOnly and next(players) then return true end
  local pl, err2 = loadPlayers()
  if not pl then return false, err2 end
  players = pl
  return true
end

local function winnerText(p) return p.winner ~= "" and (name(p.winner, p) .. " won") or "no winner" end

-- Wins and games with a winner for one player, up to and including play number `upTo`.
local function record(id, upTo, year)
  local wins, contested = 0, 0
  for i = 1, math.min(upTo, #plays) do
    local p = plays[i]
    if p.winner ~= "" and contains(p.players, id) and (not year or p.date:sub(1, 4) == year) then
      contested = contested + 1
      if p.winner == id then wins = wins + 1 end
    end
  end
  return wins, contested
end

-- Wins in a row, counting back from play number `upTo` over the games this player played.
local function streak(id, upTo)
  local n = 0
  for i = math.min(upTo, #plays), 1, -1 do
    local p = plays[i]
    if p.winner ~= "" and contains(p.players, id) then
      if p.winner ~= id then break end
      n = n + 1
    end
  end
  return n
end

local function standings(year)
  local rows = {}
  for _, p in ipairs(plays) do
    if (not year or p.date:sub(1, 4) == year) and p.winner ~= "" then
      for _, id in ipairs(p.players) do
        rows[id] = rows[id] or { id = id, wins = 0, games = 0 }
        rows[id].games = rows[id].games + 1
      end
      rows[p.winner] = rows[p.winner] or { id = p.winner, wins = 0, games = 0 }
      rows[p.winner].wins = rows[p.winner].wins + 1
    end
  end
  local list = {}
  for _, id in ipairs(sortedKeys(rows)) do list[#list + 1] = rows[id] end
  table.sort(list, function(a, b)
    if a.wins ~= b.wins then return a.wins > b.wins end
    if a.games ~= b.games then return a.games < b.games end   -- same wins in fewer games ranks higher
    return a.id < b.id
  end)
  return list
end

local function ordinal(n)
  local suffix = (n % 100 >= 11 and n % 100 <= 13) and "th" or n % 10 == 1 and "st" or n % 10 == 2 and "nd"
                 or n % 10 == 3 and "rd" or "th"
  return n .. suffix
end

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
                 "October", "November", "December" }
local function monthName(ym) return (MONTHS[tonumber(ym:sub(6, 7))] or ym) .. " " .. ym:sub(1, 4) end

local function hash(s)   -- FNV-1a, 32 bit
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  return h
end

local QUIPS = {
  "My odds are 94 % accurate, give or take 94 %.",
  "Please remember to shuffle. I have no hands.",
  "Statistically, the snacks will run out before the game does.",
  "Reminder: flipping the table is not a valid strategy.",
  "I have polished the dice. Metaphorically.",
  "Whoever reads the rules aloud gets my eternal respect.",
  "A droid is never late. The rules explanation, however, may be.",
  "If anyone asks, I was rooting for you.",
}

local function announce(idx)
  local p = plays[idx]
  local title = p.winner ~= "" and (name(p.winner, p) .. " wins " .. p.game) or (p.game .. ": played together")
  local who = {}
  for _, id in ipairs(p.players) do who[#who + 1] = name(id, p) end
  local msg = dateLabel(p.date) .. " - " .. table.concat(who, ", ")

  -- Facts, the most remarkable first; at most two.
  local facts, firstTime, previousWinner = {}, true, ""
  for i = 1, idx - 1 do
    if plays[i].game:lower() == p.game:lower() then
      firstTime = false
      if plays[i].winner ~= "" then previousWinner = plays[i].winner end
    end
  end
  if p.winner ~= "" then
    local wins = record(p.winner, idx)
    local s = streak(p.winner, idx)
    if wins == 1 then facts[#facts + 1] = "First win ever. Congratulations!" end
    if s >= 2 then facts[#facts + 1] = "That's " .. s .. " wins in a row!" end
    if previousWinner ~= "" and previousWinner ~= p.winner then
      facts[#facts + 1] = "Takes the " .. p.game .. " crown from " .. name(previousWinner) .. "."
    end
  end
  if firstTime then facts[#facts + 1] = "First time " .. p.game .. " hit the table." end
  for i = 1, math.min(2, #facts) do msg = msg .. "\n" .. facts[i] end

  if p.winner ~= "" then
    local year = p.date:sub(1, 4)
    for r, row in ipairs(standings(year)) do
      if row.id == p.winner then
        msg = msg .. "\n" .. name(p.winner, p) .. " is now " .. ordinal(r) .. " in " .. year .. " with " ..
              row.wins .. (row.wins == 1 and " win." or " wins.")
      end
    end
  end
  notify(title, msg, "trophy", { { "Leaderboard", cmd = "oracle" }, { "Hall of fame", url = cfg.site } })
end

-- A game from tonight's players' collections that has never (or not for longest) been played.
local function dustyShelf(d)
  local list, seen = {}, {}
  for _, id in ipairs(d.players) do
    local pl = players[id]
    if pl then
      for _, g in ipairs(pl.games) do
        if not seen[g:lower()] then
          seen[g:lower()] = true
          local c = { game = g, owner = pl.name, last = "" }
          for _, p in ipairs(plays) do
            if p.game:lower() == g:lower() and p.date > c.last then c.last = p.date end
          end
          list[#list + 1] = c
        end
      end
    end
  end
  if #list == 0 then return "" end
  local never = {}
  for _, c in ipairs(list) do
    if c.last == "" then never[#never + 1] = c end
  end
  if #never > 0 then
    local c = never[hash(d.date) % #never + 1]
    return "From the dusty shelf: " .. c.game .. " (" .. c.owner .. "'s) has never been played at a game night."
  end
  local oldest = list[1]
  for _, c in ipairs(list) do
    if c.last < oldest.last then oldest = c end
  end
  local days = daysBetween(oldest.last, d.date)
  if days < 60 then return "" end
  return "From the dusty shelf: " .. oldest.game .. " (" .. oldest.owner .. "'s), last played " .. days // 30 ..
         " months ago."
end

local function briefing(d, campaigns)
  local lines = { "Lineup: " .. namesOf(d.players) .. " (" .. d.time .. (d.place ~= "" and (" at " .. d.place) or "") .. ")" }

  -- Odds: smoothed win rate per player, normalised over tonight's lineup.
  local odds, total, data = {}, 0, 0
  for _, id in ipairs(d.players) do
    local wins, contested = record(id, #plays)
    data = data + contested
    local w = (wins + 1) / (contested + 2)
    odds[#odds + 1] = { id = id, w = w }
    total = total + w
  end
  table.sort(odds, function(a, b) return a.w > b.w end)
  local parts = {}
  for i = 1, math.min(4, #odds) do
    parts[#parts + 1] = name(odds[i].id) .. " " .. math.floor(100 * odds[i].w / total + 0.5) .. " %"
  end
  lines[#lines + 1] = "My odds: " .. table.concat(parts, ", ") .. (data < 6 and " (barely any data, mostly guessing)" or "")

  for _, id in ipairs(d.players) do
    local n = streak(id, #plays)
    if n >= 2 then lines[#lines + 1] = name(id) .. " is on a " .. n .. "-game winning streak." end
  end
  if d.topGame ~= "" then
    lines[#lines + 1] = "Top pick so far: " .. d.topGame .. " (" .. d.topVotes .. (d.topVotes == 1 and " vote)" or " votes)")
  end
  local dusty = dustyShelf(d)
  if dusty ~= "" then lines[#lines + 1] = dusty end
  for _, c in ipairs(campaigns) do
    if c.status == "active" and c.next == d.date then
      lines[#lines + 1] = "Campaign session today: " .. c.title ..
                          ((c.game ~= "" and c.game ~= c.title) and (" (" .. c.game .. ")") or "")
    end
  end
  if cfg.quips then lines[#lines + 1] = QUIPS[hash(d.date) % #QUIPS + 1] end
  return table.concat(lines, "\n")
end

-- Highest count and who has it (in key order).
local function best(counts)
  local top, who = 0, {}
  for _, k in ipairs(sortedKeys(counts)) do top = math.max(top, counts[k]) end
  for _, k in ipairs(sortedKeys(counts)) do
    if counts[k] == top then who[#who + 1] = k end
  end
  return top, who
end

local function recap(month)
  local games, nights, atNight, gameCount, wins = 0, {}, {}, {}, {}
  for _, p in ipairs(plays) do
    if p.date:sub(1, 7) == month then
      games = games + 1
      if not atNight[p.date] then
        atNight[p.date] = {}
        nights[#nights + 1] = p.date
      end
      for _, id in ipairs(p.players) do atNight[p.date][id] = true end
      gameCount[p.game] = (gameCount[p.game] or 0) + 1
      if p.winner ~= "" then wins[p.winner] = (wins[p.winner] or 0) + 1 end
    end
  end
  if games == 0 then return "" end
  local present = {}
  for _, who in pairs(atNight) do
    for id in pairs(who) do present[id] = (present[id] or 0) + 1 end
  end
  local s = #nights .. (#nights == 1 and " game night, " or " game nights, ") .. games .. (games == 1 and " game." or " games.")
  if next(wins) then
    local top, who = best(wins)
    local names = {}
    for _, id in ipairs(who) do names[#names + 1] = name(id) end
    s = s .. "\nChampion: " .. table.concat(names, " & ") .. " (" .. top .. (top == 1 and " win)" or " wins)")
  end
  local topGames, gameList = best(gameCount)
  if topGames > 1 then s = s .. "\nMost played: " .. gameList[1] .. " (" .. topGames .. "x)" end
  local always = {}
  for _, id in ipairs(sortedKeys(present)) do
    if present[id] == #nights and #nights > 1 then always[#always + 1] = name(id) end
  end
  if #always > 0 then s = s .. "\nNever missed a night: " .. table.concat(always, ", ") end
  return s
end

local function leaderboard(year)
  if #plays == 0 then return "No games logged yet. Log your next game night on the site and I'll keep score." end
  local rows = standings(year)
  local lines = {}
  if #rows == 0 then
    lines[1] = "No games with a winner in " .. year .. " yet."
  else
    lines[1] = year .. " so far (wins / games with a winner):"
    for i = 1, math.min(6, #rows) do
      local r = rows[i]
      lines[#lines + 1] = i .. ". " .. name(r.id) .. " " .. r.wins .. "/" .. r.games .. " (" ..
                          (r.games > 0 and (100 * r.wins // r.games) or 0) .. " %)"
    end
    local me = cfg.me:lower()
    for i, r in ipairs(rows) do
      if me ~= "" and i > 6 and name(r.id):lower() == me then lines[#lines + 1] = "You: " .. ordinal(i) .. " place" end
    end
  end
  local count, nights, nightCount = {}, {}, 0
  for _, p in ipairs(plays) do
    count[p.game] = (count[p.game] or 0) + 1
    if not nights[p.date] then nights[p.date], nightCount = true, nightCount + 1 end
  end
  local top, n = "", 0
  for _, g in ipairs(sortedKeys(count)) do
    if count[g] > n then top, n = g, count[g] end
  end
  lines[#lines + 1] = "Most played ever: " .. top .. " (" .. n .. "x)"
  lines[#lines + 1] = "Hall of fame: " .. #plays .. " games on " .. nightCount .. " nights"
  return table.concat(lines, "\n")
end

M.commands = {
  { "oracle", "orakel, stats, leaderboard, rangliste, hall, odds, score", "this year's table and stats", function()
      local ok, err = loadAll(true)
      if not ok then return "Could not read the hall of fame: " .. err end
      return leaderboard(today():sub(1, 4))
    end },
}

function M.notReady()
  if cfg.project == "" or cfg.apiKey == "" then return "no Board Game Night project set" end
end

function M.check()
  local ok, err = loadAll(false)
  if not ok then return false, err end
  local state = recall()
  if type(state) ~= "table" then state = {} end
  local pushes = 0

  -- 1. New results: plays created after the newest one seen so far.
  local newest = state.newest or ""
  local maxCreated, fresh = newest, {}
  for i, p in ipairs(plays) do
    if p.createdAt > maxCreated then maxCreated = p.createdAt end
    if newest ~= "" and p.createdAt > newest then fresh[#fresh + 1] = i end
  end
  if not firstCheck() and cfg.results and newest ~= "" then
    if #fresh > 3 then
      local lines = {}
      for _, i in ipairs(fresh) do
        lines[#lines + 1] = dateLabel(plays[i].date) .. ": " .. plays[i].game .. " - " .. winnerText(plays[i])
      end
      notify(#fresh .. " games logged", table.concat(lines, "\n"), "trophy", { { "Leaderboard", cmd = "oracle" } })
      pushes = pushes + 1
    else
      for _, i in ipairs(fresh) do
        announce(i)
        pushes = pushes + 1
      end
    end
  end
  state.newest = maxCreated

  -- 2. Briefing on a game night day.
  local now = today()
  if cfg.briefing and hour() >= cfg.briefHour and state.briefed ~= now then
    local days = loadDays(now, now)
    local d = days and days[1]
    if d and #d.players >= cfg.minPlayers and (not cfg.onlyMine or isIn(d.players)) then
      notify("Game night briefing: " .. dateLabel(now), briefing(d, loadCampaigns()), "crystal_ball",
             { { "Open calendar", url = cfg.site }, { "Leaderboard", cmd = "oracle" } })
      state.briefed = now
      pushes = pushes + 1
    end
  end

  -- 3. Monthly recap on the 1st, from 10:00.
  local month = now:sub(1, 7)
  if cfg.recap and now:sub(9, 10) == "01" and hour() >= 10 and state.recap ~= month then
    local prev = addDays(now, -1):sub(1, 7)
    local text = recap(prev)
    if text ~= "" then
      notify("Monthly recap: " .. monthName(prev), text, "bar_chart", { { "Leaderboard", cmd = "oracle" } })
      pushes = pushes + 1
    end
    state.recap = month
  end

  remember(state)
  status(#plays .. " games in the hall of fame" ..
         (pushes > 0 and (", " .. pushes .. " push" .. (pushes == 1 and "" or "es")) or ""))
end

return M
