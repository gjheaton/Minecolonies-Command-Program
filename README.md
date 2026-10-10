# MineColonies Control Suite

The `supply-master-colony` branch provides Supply 4.0.0: one dedicated computer owns
Player Refined Storage (PRS), and colony supply computers communicate with it over
rednet. Each colony has a delivery and a return Ender Chest channel. Command Center
is also available through the same installer.

The master can now show its overview and a separate read-only dashboard for each
colony. The master overview, master-side colony dashboards, and colony-local supply
screens all use **5 blocks wide × 3 blocks high Advanced Monitors at text scale 0.5**
(CC:Tweaked reports **100 × 38 characters**). Each dashboard has independent tabs
and paging. See the [monitor setup and wiring instructions](docs/PRS_NETWORK.md#master-and-colony-monitors)
for assigning monitors and checking the live telemetry.

## Install in CC:Tweaked

Download the **single installer** on every computer that will run a suite role:

```lua
wget https://raw.githubusercontent.com/gjheaton/Minecolonies-Command-Program/supply-master-colony/install_colony.lua install_colony_v4.lua
install_colony_v4
```

Choose **PRS Master**, **Colony Supply**, or **Command Center**. The first v4
installation requires typing `CLEAN`: it removes the previous suite's files,
settings, request records, and logs from that computer. It preserves unrelated
files and does not remove Minecraft inventories or items. Downloads are validated
before cleanup. Later **Update** and **Repair** preserve the new settings and state.

After installation, run `colony_master setup` or `colony_supply setup`, as indicated
by the installer. Setup uses the computer's built-in keyboard screen, with one
question at a time and numbered peripheral choices. Use `N`/`P` for pages or
`:q` to cancel without saving; settings are saved only after the final confirmation.
Master setup leaves automation paused for wiring tests. See the
[hardware, configuration, and testing guide](docs/PRS_NETWORK.md)
before enabling automatic supply. HTTP access to `raw.githubusercontent.com` and
`api.github.com` is required; the installer resolves each download batch to one Git
commit so all installed modules come from the same revision.

**SETTINGS** and **COLONY ROUTES** also offer numbered, touch-selectable lists of
compatible unused peripherals, so you do not have to type long device names.
Names wrap in full, lists have pages, and choices refresh when hardware changes.
Route selections are saved only when you choose **SAVE ROUTE**.

## Updates

Use the UI's **CHECK UPDATE / UPDATE** control or the same installer:

```lua
install_colony --update master
```

Use `supply` or `command` instead of `master` on those computers. The stored update
source remains this development branch until explicitly changed. Update the master
and all colony clients together when a release changes the protocol.

After the first clean installation, use **Update** or **Repair** for future
releases. Both preserve settings and request journals. Pause master automation
and let current handshakes finish before updating.

For a fix to an already installed 4.0.0 build with the same version number, run
`install_colony --repair`, then restart the application. Rerun
`colony_master setup` or `colony_supply setup` if you need the hardware wizard.
Repair preserves configuration and journals; do not choose `CLEAN` to obtain
the corrected setup screens or peripheral pickers.

## Development checks

```bash
python3 -m pip install 'lupa==2.6'
python3 tests/run.py
```

The published Codex cloud environment already provides Lua 5.2 through Lupa.
Tests simulate the CC:Tweaked hardware boundary, messages, inventories, persistence,
installer failure/recovery, and shared UI. Actual mod interoperability still needs
in-game testing; run the Ender Chest diagnostics before automatic transfers.
