# Writing an S3-PO module

A module is **one Lua file** in `modules/`. It describes itself in a table at the top (name, version, settings, commands) and has a `check()` function that S3-PO runs on a schedule. S3-PO does the rest: the settings page section, the on/off switch, the channel choice, the help text, the status page, error pushes and quiet hours.

Lua is a small language; if you know a bit of JavaScript or Python you can read it right away. The [Lua 5.4 manual](https://www.lua.org/manual/5.4/) has the details. Start from [`template.lua`](template.lua) and look at the modules in `modules/` for real examples: `zelda.lua` (a web page), `weather.lua` (a JSON API), `waste.lua` (an uploaded file), `nights.lua` (Firestore).

## Try it, publish it

1. **Try it on your S3-PO:** open http://s3po.local/modules and use **Install from a file**. If something is wrong, the page says what and in which line. Uploading again replaces it.
2. **Publish it:** commit the file to `modules/` (on github.com: *Add file → Create new file*). GitHub Actions checks it and adds it to `index.json`. A minute later it's in the store on every S3-PO that uses this catalog.
3. **Change it:** raise `version` with every change. S3-PO looks for updates daily and offers them with an **Update** button. Without a new version, installed copies never hear about the change; the Actions run warns you about that.

To check modules on your PC (needs Lua 5.4): `lua5.4 tools/validate.lua modules/*.lua`.

## The description

```lua
local M = {
  key = "zelda",               -- 1-12 lower-case letters and digits; the file is <key>.lua
  name = "Zelda concerts",
  version = "1.0.0",
  about = "One sentence for the store.",
  every = 15,                  -- default check interval in minutes
  minEvery = 5,                -- lowest interval people can set (default 1)
  order = 50,                  -- position on the settings page, lower = higher up (default 100)
  startOff = true,             -- optional: switched off until someone turns it on
  sendTo = "both",             -- optional: "main" (default), "second" or "both"
  api = 1,                     -- optional: the S3-PO API version it needs
  settings = { ... },
}
M.commands = { ... }
function M.check() ... end
return M                       -- the last line
```

### Settings

Each setting is `{ "key", "Label", default, options... }`. The default decides the kind of field:

| Default | Field | `cfg.key` gives |
| --- | --- | --- |
| `"text"` | text box | a string |
| `10` | whole number | an integer |
| `1.65` | decimal number (a comma works too) | a number |
| `true` / `false` | checkbox | a boolean |

Options after the default:

| Option | What it does |
| --- | --- |
| `hint = "..."` | small grey help text |
| `range = { 0, 23 }` | limits for a whole number |
| `options = { "e5\|Super E5", "diesel\|Diesel" }` | a drop-down: stored value, then what's shown |
| `long = true` | a text area (several lines) |
| `secret = true` | a password field: never shown again on the page (API keys) |
| `file = true` | a file upload; read it with `fileText("key")`, `cfg.key` says whether there is one |

Setting keys: 1-15 letters and digits. Read them anywhere as `cfg.key`. They are read-only; people change them on the settings page, and S3-PO then calls `M.settingsChanged()` if you have one.

**Keep defaults neutral.** The catalog is public, so no home towns, accounts or keys in it. People put their own values on the settings page, or in their firmware's `MODULE_DEFAULTS` (S3-PO's `include/config.h`), which fills them in when a module is installed.

### Commands

```lua
M.commands = {
  { "fuel", "sprit, tank, preis", "current fuel prices", function(text) return report() end },
}
```

Name, other words (comma separated), a help line, and a function. The function gets the whole message (`"fuel diesel"`) and returns the reply. A word matches at the start of a word in the message, in any language you list. People can send the command or tap a button with `cmd = "fuel"`.

### Functions S3-PO calls

| Function | When |
| --- | --- |
| `M.check()` | On schedule, on "check" and on the status page's "Check now". `return false, "why"` (or an error) fails the check; anything else is fine. After 3 failures in a row S3-PO pushes one error, and another when it works again. |
| `M.notReady()` | Return why the module can't run yet (`"no API key"`), or nothing. While it returns something, `check()` isn't called. |
| `M.settingsChanged()` | Optional: after the settings were saved or a file uploaded. |

Lua variables outside the functions keep their values between checks (until a restart or an update), like the `armed` list in `fuel.lua`. For what must survive a restart, use `remember`.

## The API

| Call | What it does |
| --- | --- |
| `http.get(url)` | Body as a string, or `nil, "HTTP 503"`. Time spent waiting doesn't count against the time limit. |
| `http.post(url, body [, contentType])` | The same for POST (default `application/json`). |
| `json.decode(text)` / `json.encode(value)` | JSON to Lua tables and back. JSON `null` becomes `nil`. |
| `firestore.list{ project=, key=, collection=, fields={...} }` | Every document of a public Firestore collection, typed values unwrapped; each has `_id`. Nested fields as `"game.name"`. |
| `firestore.range{ ..., from="2026-11-01", to="2026-11-30" }` | Documents whose id lies between `from` and `to`. |
| `notify(title, message, tag, buttons, priority)` | A push to the module's channel(s). Or `notify{ title=, message=, tag=, buttons=, priority= }`. `tag`: an [ntfy emoji name](https://docs.ntfy.sh/emojis/). Up to 3 buttons: `{ "Label", cmd = "command" }` or `{ "Label", url = "https://..." }`. Priority 1-5; 4 and 5 are louder and go out even during quiet hours. |
| `status("...")` | One line for the status page and the `status`/`check` replies. |
| `isNew(id)` | `true` the first time an id is seen, then `false`. Remembers the last 300 ids in flash. |
| `firstCheck()` | `true` until the module's first successful check. Use it to stay quiet about what already existed. |
| `remember(value [, name])` / `recall([name])` | Keep a string or a table in flash (tables as JSON). `name` defaults to `"state"`; letters, digits and `_`. `remember(nil, name)` deletes it. |
| `fileText("key")` | The content of an uploaded file setting, or `nil`. |
| `today([days])` | Local date, `"2026-11-08"`; `today(1)` is tomorrow. |
| `hour()` | Local hour, 0-23. |
| `dateLabel("2026-11-08")` | `"Sun 8 Nov"` |
| `addDays(date, n)` / `daysBetween(a, b)` | Date arithmetic on `"YYYY-MM-DD"`. |
| `nowText()` | `"08.11. 14:35"` |
| `millis()` | Milliseconds since S3-PO started. |
| `urlEncode(s)` | For query parameters. |
| `log("fmt", ...)` / `print(...)` | A line in S3-PO's log (status page). |
| `blink(n)` | Blinks the LED n times. |
| `trim(s)`, `split(s, sep)`, `startsWith(s, prefix)`, `contains(list, x)`, `sortedKeys(t)` | Small helpers. `split` trims the parts and drops empty ones; `sep` defaults to `","`. |
| `s3po.version`, `s3po.api`, `s3po.url` | About the firmware. |

Also there: Lua's `string`, `table`, `math`, `utf8` and `coroutine` libraries, and `load` for text. Not there: files (`io`), the operating system (`os`), `require`, and S3-PO's own secrets.

## Limits and safety

- **Memory:** each module has its own Lua state with up to 1 MB (in the board's PSRAM). Over that, the check fails with "not enough memory".
- **Time:** a check or command may compute for 20 seconds, not counting network waits. Then it's stopped with an error.
- **Sandbox:** a module only sees the API above. It can't read files, the Wi-Fi password, the ntfy topics or other modules.
- **Downloads:** S3-PO fetches the catalog and modules only over HTTPS with checked certificates, and installs a file only if its SHA-256 matches `index.json`.
- Strings are bytes: `string.upper` and friends only change ASCII letters (see `cap()` in `zelda.lua` for umlauts).
- Table order from `pairs()` is random. Use `sortedKeys()` or an array when the order shows up in a message.

## Testing

`tools/validate.lua` checks the description and runs `notReady()` with the default settings. The full behaviour is tested in S3-PO's repository: its host tests install every module from this catalog through the real store code and run them against sample data (`test/host/test.cpp`). When you add a module, a test there is worth having.
