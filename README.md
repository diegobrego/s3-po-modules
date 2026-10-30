# S3-PO modules

The module store for [S3-PO](https://github.com/diegobrego/s3-po), a small household droid on an ESP32-S3 that pushes what matters to your phone through [ntfy](https://ntfy.sh).

Each module is one Lua script. S3-PO lists this catalog on its **Modules** page; pick one, and S3-PO downloads it, checks it and runs it straight away, without a firmware update or a restart.

| Module | What it does |
| --- | --- |
| **Game nights** (`nights`) | A push when a day on your Board Game Night calendar reaches "Game on", when it's off again, and a reminder the day before |
| **Game Night Oracle** (`oracle`) | Keeps score for the group: game night briefings with S3-PO's odds, winners with streaks, a monthly recap |
| **Waste collection** (`waste`) | A reminder the evening before a pickup, plus notices like recycling centre closures, from an iCal calendar |
| **Weather** (`weather`) | Official DWD weather warnings for your place (Germany), the severe ones louder and even in quiet hours, and a morning forecast |
| **Fuel prices** (`fuel`) | Prices in Germany (Tankerkönig) and Austria (E-Control), with a push when a station drops to your limit |
| **Zelda concerts** (`zelda`) | A push when the Zelda 40th Anniversary Concert tour adds a date in your countries, and when its tickets change |

## Installing a module

- On S3-PO's page: **http://s3po.local/modules**, then **Install**.
- From your phone: send `store` to see what's there, then `install weather`. `modules` lists what you have, `remove weather` takes one out (its settings stay, in case you change your mind).

Then set it up on the settings page. S3-PO looks for updates daily; depending on its settings it tells you (with an **Update** button) or installs them by itself. `update` installs them on request.

## How it's built

- `modules/<key>.lua`: the modules.
- `index.json`: the catalog S3-PO reads. Made by `tools/make_index.py` from the modules (name, version, size, SHA-256). GitHub Actions rebuilds it on every push, so don't edit it by hand.
- `tools/validate.lua`: checks the modules the way S3-PO loads them. Runs on every push.
- `docs/WRITING.md`: how to write a module. `docs/template.lua`: a starting point.

## Trust

Modules run on your S3-PO, so S3-PO is careful about where they come from. It downloads the catalog and the scripts only over HTTPS with checked certificates (pinned root certificates in the firmware), and installs a script only if its SHA-256 matches `index.json`. A script runs in its own sandbox: no files, no system access, no secrets, limited memory and time.

Anyone who can push to this repository can change what S3-PO runs, so keep write access to people you trust. To use your own catalog, fork this repository and point S3-PO's **Catalog** setting at your fork's `index.json`.

The modules contain no personal data: places, accounts and keys are set on each S3-PO.
