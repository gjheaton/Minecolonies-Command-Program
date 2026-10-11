# MineColonies Control Suite

The `supply-master-colony` branch provides Supply 4.0.12: one dedicated computer owns
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

After installation, run `colony_master --setup` or `colony_supply --setup`, as indicated
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

Suite command-line options begin with `--`, including `colony_supply --clear-errors`
and `colony_master --diag`. Their values stay unprefixed, for example
`colony_master --set automationEnabled false`. Older bare options remain accepted
as compatibility aliases; use the prefixed forms for new commands.
Use `install_colony --help`, `colony_master --help`, or `colony_supply --help` to
list the available options.

## Updates

Use the UI's **CHECK UPDATE / UPDATE** control or the same installer:

```lua
install_colony --update master
```

Use `supply` or `command` instead of `master` on those computers. The stored update
source remains this development branch until explicitly changed. In 4.0.9, the
master UPDATE button saves an automation pause, drains reserved turns, then installs
the available update. Colony updates also queue until their current turn finishes.
Older masters require manually pausing automation before using UPDATE. Settings and request/transfer
journals are preserved. Resume automation after all computers have restarted with
the new release. Update both roles together when a release changes the protocol.

After the first clean installation, use **Update** or **Repair** for future
releases. Both preserve settings and request journals. Pause master automation
and let current handshakes finish before updating.

In 4.0.2, update checks can run while a supply turn is active. Installing an update
still requires the current turn to finish safely. The local **SETTINGS** page
shows **Update:** with the latest check result and time, plus **Source:**. The
terminal also reports changes to update status. Remote dashboards stay read-only.

If **CHECK UPDATE** on an older 4.0.0 installation does nothing, pause master
automation and let current handshakes finish. Stop the application and startup
launcher to reach the shell, then run this same command on the master and every
colony supply computer:

```lua
install_colony --repair https://raw.githubusercontent.com/gjheaton/Minecolonies-Command-Program/supply-master-colony/install_colony.lua
reboot
```

This preserves the installed role, settings, and journals, and sets the update
source to the moving `supply-master-colony` branch so future releases can be found.
Do not choose `CLEAN`. Resume automation after all computers have restarted.

Use `install_colony --repair` for a forced reinstall of the installed role, including
damaged files or a code fix that still has the same version number. Restart the
application afterward. Rerun
`colony_master --setup` or `colony_supply --setup` if you need the hardware wizard.
Repair preserves configuration and journals; do not choose `CLEAN` to obtain
the corrected setup screens or peripheral pickers.

Versions use **MAJOR.MINOR.PATCH**:

- **Major**, the first number, changes for incompatible behavior or migrations.
- **Minor**, the second number, changes for compatible new features.
- **Patch**, the third number, changes for fixes and maintenance updates.

This update is **4.0.12**. Future fixes increase the patch number so **CHECK UPDATE**
can detect them. A minor release resets the patch number, such as `4.1.0`; a major
release resets both later numbers, such as `5.0.0`.

In 4.0.3, an active held PRS transfer shows its attempted item, quantity, colony,
and chest on **HEALTH**. To inspect the exact registry ID and item variant without
moving anything, stop the master application and launcher to reach its shell and
run `colony_master --transferdiag`. Keep delivery chest contents and transfer
records intact while investigating.

Release 4.0.4 preserves the bridge's error reason for a held zero export.
For that case, `colony_master --transferdiag` also validates the configured
target with a zero-count call that moves no items. A readable CC inventory
alone does not establish that Advanced Peripherals can transfer into it.

Release 4.0.5 avoids AP fingerprint cache mutation for ordinary items when the
complete stock snapshot proves one plain same-name variant. Tools and tagged
items retain exact fingerprint selection. Unexpected tagged output remains held.

Release 4.0.6 queues colony updates during active turns. The current handshake
finishes before installation; fresh grants wait until installation completes or
the update fails. Uncertain transfers still require reconciliation. To obtain
this fix on older versions, pause master automation, let current turns finish,
then press UPDATE again on each colony.

Release 4.0.7 adds **HEALTH → RECOVER TRANSFER → RUN RECOVERY** on the master.
It saves an automation pause, verifies the held transfer, and displays RECOVERED
or BLOCKED without stopping the application. A recorded zero export may send one
guarded recovery item. Automation stays paused afterward; error history is kept.

Command Center is now **4.0.1**, packaged in suite **4.0.12**. Its monitor header
and installer metadata use the same application version. Existing V4 Command
installations can update without resetting their settings.

Release 4.0.9 queues master updates and fixes equipment selection: stocked accepted
tools take priority over absent higher tiers, then craftable alternatives. Exact
fingerprints and MineColonies’ serialized allowed alternatives remain required.

## Development checks

```bash
python3 -m pip install 'lupa==2.6'
python3 tests/run.py
```

The published Codex cloud environment already provides Lua 5.2 through Lupa.
Tests simulate the CC:Tweaked hardware boundary, messages, inventories, persistence,
installer failure/recovery, and shared UI. Actual mod interoperability still needs
in-game testing; run the Ender Chest diagnostics before automatic transfers.

Command 4.0.1 adds **MARK** beside huts on **BUILDINGS**, **HELP WANTED**, and **CONSTRUCTION**,
and **MARK HUT** in their detail views. Connect an Advanced Peripherals Chat Box
to the Command computer, directly or through its wired peripheral network.
Press MARK to share the hut's coordinates in public chat. Click the location
message while in the colony's dimension to create a JourneyMap waypoint; enable
its beacon in JourneyMap if needed. The Chat Box's configured range and dimension
rules apply. A successful send confirms chat delivery, not waypoint creation.

Construction Orders marks only a uniquely identified target hut. If duplicate
huts make the target ambiguous, select the desired hut from Buildings.

Suite 4.0.11 adds `colony_supply --reconcile-zero-return` for an unknown overflow
return that an operator confirms moved nothing. Keep master automation paused
since the failure, restore the colony bridge, and leave both chests untouched.
The command checks the original physical inventory and outstanding deliveries,
then asks you to type `ZERO` to acknowledge the displayed operation (4.0.12). It audits the acknowledgment
without moving or crediting items. Changed or ambiguous inventories remain held.
Restart the colony program after success, verify HEALTH, then resume automation.
