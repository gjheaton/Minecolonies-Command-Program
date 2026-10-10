# Dedicated PRS master and colony supply

## Hardware and ownership

Use Minecraft 1.20.1 with CC:Tweaked, Advanced Peripherals, MineColonies,
Refined Storage, and the **Ender Chests** mod. Each supply computer needs a modem.
Use Advanced Monitors **5 blocks wide × 3 blocks high at text scale 0.5** for the
master overview, each master-side colony dashboard, and each colony-local supply
screen. At this size CC:Tweaked's `getSize()` reports **100 columns × 38 rows**.
The main shared UI can also run in the computer terminal.

Only the **master computer** connects to the player RS Bridge. Remove the old
Supply Managers' connections to PRS and stop their programs before running v4.
The single-master guarantee depends on that physical boundary: old computers,
other scripts, and additional bridge clients must not continue calling PRS.

The master needs:

- One player RS Bridge.
- One modem, with rednet reachability to each colony.
- Two modem-visible Ender Chests per colony, one for deliveries and one for returns.
- One 5 × 3 Advanced Monitor for the overview, plus an optional separate 5 × 3
  Advanced Monitor for each colony dashboard.

Each **colony computer** needs:

- Its own colony RS Bridge; no player RS Bridge.
- A Colony Integrator inside the correct colony.
- A modem and the colony's matching delivery and return Ender Chests.
- Colony RS External Storage connected to the MineColonies warehouse, with the
  intended warehouse routing. The computer cannot guarantee where an RS network
  with additional storage will choose to put an imported item.

Each pair of Ender Chests shares its color code and ownership/access settings.
Use two exclusive codes per colony. A delivery code must never be shared with a
return code or another colony's channel. Peripheral names can differ between the
master and colony; the physical color codes must agree. Channel labels such as
`red-white-blue` are entered in setup and checked during the handshake. The
controlled item test below establishes that the configured physical channels agree.

**No hoppers, pipes, players, or other computers may move items through these
channels during automated transfers or the test.** Delivery verification depends
on the colony waiting while the master exports and inspects the chest.

Keep the master, colony computers, RS networks, and both ends of the chest channels
loaded. Wired modems must expose the inventories by peripheral name. Wireless
rednet still needs suitable wired connections for inventory/bridge access. Across
dimensions, use rednet-capable equipment with the necessary reach; Ender Chest
item transport alone does not provide computer communications.

### Connecting the master

1. Use a dedicated Advanced Computer for `colony_master`. Connect its single
   configured RS Bridge to **your player's existing Refined Storage network**,
   including the storage and crafters it should use. Colony computers connect to
   their own warehouse RS networks.
2. Attach wired modems to the computer and to each master-side monitor, RS Bridge,
   and Ender Chest. Join the modems with network cables. Right-click each peripheral
   modem to enable its remote connection; its peripheral name should become visible
   from the master. Simply placing cables or a modem beside a device is insufficient
   if that modem's peripheral connection is disabled.
3. Give each colony two Ender Chest channels: delivery and return. Put both
   master-side chests on this wired backbone and place matching chests at the colony.
   Set the colors and ownership/access settings in-game. The program compares your
   configured labels; it does not read or change the chest's physical color code.
4. Connect master and colony computers through compatible rednet modems. A shared
   wired network can carry both messages and peripheral access. If you use wireless
   or Ender Modems for inter-colony messages, keep a local wired network at the
   master for its monitors, bridge, and chests, and a local wired network at each
   colony for that colony's peripherals.
5. Run `colony_master diag` and `colony_master monitors` to check the visible
   devices, then configure their exact names. Run the controlled `chesttest`
   described below for each colony before enabling automatic transfers.

Stop all previous programs and disconnect other PRS bridge clients. Do not run a
second master or let other automation race the master's Ender Chest movements.

## First installation

On each computer:

```lua
wget https://raw.githubusercontent.com/gjheaton/Minecolonies-Command-Program/supply-master-colony/install_colony.lua install_colony_v4.lua
install_colony_v4
```

Select the role and type `CLEAN`. The installer downloads and compiles the complete
role package, checks its manifest, stages a recoverable transaction, and only then
removes old suite data. `/colony` is suite-owned and is cleared, along with known
legacy root state/log files and suite entry programs. Unrelated files are retained.
An unrelated `/startup.lua` is refused rather than overwritten.

The separate download filename avoids overwriting the previous installer before
migration succeeds. The installed canonical `install_colony.lua` handles subsequent
updates and repairs; you do not need to download or clean-install again.

The installer can also select a role explicitly:

```lua
install_colony --install master
install_colony --install supply
install_colony --install command
```

These are **clean installations**, including when used on an existing v4 machine.
Use `--update` or `--repair` to preserve data.

Run the indicated setup command before starting automation:

```lua
colony_master setup
```

For the master, choose its PRS Bridge and add each colony's computer ID, label,
master-side delivery and return inventory names, and color-channel labels. On each
colony run:

```lua
colony_supply setup
```

Enter the master computer ID, the colony's RS Bridge/Integrator, local chest names,
and the same color-channel labels. CC:Tweaked's `id` command displays the computer
ID. Setup lists visible peripherals. Blank bridge/monitor overrides work only when
exactly one peripheral of that type is visible; explicit names are preferable.
When several monitors are attached, explicitly set `monitorName` to the master
overview monitor. Each colony dashboard is mapped separately as described below.

Set the master to paused before the initial hardware test:

```lua
colony_master set automationEnabled false
```

Reboot colony computers so their clients are listening. Leave the master in the
shell for diagnostics. You can later start `colony_master`, open **SETTINGS**, and
enable **Run supply automation**. Pausing stops new grants but finishes existing
handshakes; it does not cancel deliveries or crafts.

## Ender Chest identification and transfer test

First perform read-only checks on both endpoints:

```lua
colony_master diag
colony_supply diag
```

The report checks configured inventory names, size/list access, push/pull methods,
RS Bridge transfer methods, and modem availability. An Ender Chest must expose the
CC:Tweaked inventory API. A modded inventory that does not expose that API is a
hardware integration blocker, rather than an invitation to skip verification.

With normal master automation paused and its program stopped, keep the colony
client running. Empty both channels and put a plain cobblestone in PRS. On the
master run, replacing `12` with the colony computer ID:

```lua
colony_master chesttest 12
```

You can specify another plain non-NBT test item:

```lua
colony_master chesttest 12 minecraft:dirt
```

The test:

1. Reserves the idle colony and checks that labels agree and both channels are empty.
2. Exports exactly one item from PRS and verifies the master delivery chest.
3. Checks that the colony sees that exact item in its delivery chest.
4. Moves it from the colony delivery chest into the colony return chest.
5. Verifies the master sees it in the return channel and no longer in delivery.
6. Imports it back into PRS, verifies the return chest emptied and stock increased,
   and releases the reservation.

The test does not import into the warehouse or claim that MineColonies fulfillment
has passed. Test a small real colony request separately after the chest round trip.
Do not run the test from a second master computer. Stop the existing master program
first; if the startup launcher is running, terminate the application and launcher
to reach the shell.

An interrupted test retains its journal. Rerun the **same** `chesttest ID` to resume
or reconcile its existing movement without repeating an uncertain export/import.
If the original return import can be proven from the saved before/after counts,
the test can finish without a second import. If proof is unavailable, manually
inspect/recover the test item and empty both channels, then use:

```lua
colony_master chesttest abandon 12
```

This requires typing `ABANDON`, checks that the colony also sees empty channels,
clears the reservation, and records a warning. It **does not record a passing test**.
Run a new round trip before enabling automation.

## Turn sequence and request accounting

The master polls configured colonies in round-robin order. Each turn is a persisted
handoff, with a session and turn ID:

1. The master grants a colony permission to drain previously verified deliveries.
2. The colony imports those deliveries, stages optional overflow, scans MineColonies,
   and submits a bounded batch plus all outstanding request IDs and cumulative receipts.
3. The colony waits. It performs no more chest movements until another grant.
4. The master imports returns, then exports available request items or submits bounded
   crafts, with one processor serializing all PRS operations.
5. Every export is recorded before the bridge call and verified by the chest's actual
   item/NBT quantity change. The master sends results and verified shipment records.
6. The colony durably stores those results and acknowledges them. It drains the new
   deliveries only at the beginning of a later turn.

Timeouts never revoke permission to drain a chest already handed to a colony. An
offline colony retains its original turn; other colonies can be serviced after its
response deadline. The master cannot write to that colony's delivery chest until
the matching drained batch arrives. Lost grants, batches, results, and acknowledgments
are retried with the same IDs and quantities.

| Status | Meaning |
| --- | --- |
| requested | Submitted or queued for master processing. |
| crafting | A PRS crafting request has been accepted. |
| in progress | Delivery is underway, verified in the chest, or imported while awaiting MineColonies. |
| missing | No usable stock and no usable recipe, or autocrafting is disabled. |
| timed out | The applicable delivery, crafting, or acknowledgment deadline expired; existing work remains recorded. |
| error | Transfer proof, hardware, recipe query, or accounting is unsafe or unavailable. |
| delivered | The request disappeared from a successful MineColonies request snapshot. Recorded in history. |

Warehouse import does **not** complete a request. A request can remain open while a
courier processes items, so already shipped and imported quantities remain credited
and are not automatically resent. Disappearance can also mean MineColonies cancelled
the request; the computer cannot distinguish that from fulfillment through absence
alone. A failed request scan never means all requests completed.

Craft jobs are shared across colonies by exact item identity. Accepted or uncertain
crafts are retained across timeouts and reboots. A timeout is not permission to submit
the same craft again. Output observation and verified exports reconcile the reservation.
Crafting continues between colony turns; a long craft does not monopolize a turn.

## Configuration and shared UI

Both applications use `colony.lib.ui` and the existing theme. Tabs are **HOME**,
**REQUESTS**, **HEALTH**, **HISTORY**, **ERRORS**, and **SETTINGS**, with the persistent
update control in the header. Terminal output with an attached monitor reports
health warnings/errors rather than mirroring request rows.

### Master and colony monitors

Build every Supply screen from Advanced Monitor blocks in a **5-wide × 3-high**
rectangle, with all blocks facing the same way. Leave a gap between separate
panels so they do not join into one larger multiblock monitor. Supply 4.0.0 fixes
the text scale at **0.5**. The overview, remote colony dashboards, and colony-local
screens share the same layout.

| Screen | Connect it to | Configuration | Controls |
| --- | --- | --- | --- |
| Master overview | Master computer's wired network | Master `monitorName` | Master supply controls |
| Colony dashboard at the master | Master computer's wired network | That colony route's optional `monitorName` | Read-only browsing |
| Colony-local supply screen | Colony computer's wired network | Colony `monitorName` | Local colony controls |

List the master's available monitors and their mappings:

```lua
colony_master monitors
```

Names such as `monitor_0` are examples; use the names reported by your computer.
If more than one monitor is visible, select the primary overview explicitly:

```lua
colony_master set monitorName monitor_0
```

Assign a separate master-side monitor to a configured colony, replacing `12`
with that colony computer's ID:

```lua
colony_master monitor 12 monitor_1
```

The main **SETTINGS** route editor labels this optional field **Master colony
dashboard monitor**. Each route's monitor must be unique and must differ from
the primary overview monitor. A master with N dashboard panels needs N + 1
separate monitors, all built to the same 5 × 3 size. To remove a dashboard:

```lua
colony_master monitor 12 none
```

These assignments change displays only. The display assignment command preserves
pending supply work; it does not reconfigure bridges or chests. Stop the application
to use shell commands, then restart it to apply the saved mapping. Do not start
another master process alongside the existing one.

On each colony, `colony_supply setup` or the local **SETTINGS** page selects its
own monitor; `colony_supply monitors` lists its visible monitors. A master-side
dashboard shows snapshots sent by that colony; it
does not connect to the colony's local monitor or access its RS Bridge.

The primary master display has the normal controls. Every colony dashboard has
its own tab and page selection, and touch events go only to the screen touched.
Remote dashboards are **read-only**: you can browse requests, health, history,
errors, and effective settings, but cannot change settings, update software,
reconcile transfers, or edit routes there. Use the master overview for master
controls and the colony's local screen for colony controls.

The program checks physical monitors through `getSize()` at scale 0.5. If a
monitor does not report **100 × 38**, it shows a size warning without stopping
supply. The main controls remain available on the computer terminal; an incorrectly
sized remote dashboard waits for a suitable monitor. This check does not require
the computer terminal itself to be 100 × 38. A detached dashboard does not take
over the computer terminal.

### Dashboard telemetry and freshness

Colony supply computers send compact snapshots to the master independently of
supply turns. The master caches them in memory; it does not query a colony's RS
Bridge to build its dashboard. Restarting the master returns remote panels to
**WAITING** until a snapshot arrives.

| Header state | Meaning with default settings |
| --- | --- |
| WAITING | No snapshot has arrived from this configured colony yet. |
| ONLINE | The cached snapshot is no more than 20 seconds old. |
| STALE | The snapshot is older than 20 seconds; last known rows remain visible. |
| OFFLINE | The snapshot is older than 60 seconds; last known rows remain visible. |

The header shows snapshot age and **PARTIAL** when snapshot limits
truncate the data. Freshness also considers when the snapshot was generated,
so a delayed message can remain stale even when it just arrived. These states
describe dashboard freshness; they do not revoke supply turns or establish that
a MineColonies request was delivered. **HOME** also shows the colony's reported
processor status: fresh **ONLINE** telemetry does not itself mean supply is running.

| Setting | Default | Effect |
| --- | --- | --- |
| `telemetryIntervalSeconds` | 5 seconds | Colony publication interval; on the master, retry interval while requesting an initial snapshot. |
| `telemetryStaleSeconds` | 20 seconds | Master threshold for marking cached data stale. |
| `telemetryOfflineSeconds` | 60 seconds | Master threshold for marking cached data offline. |
| `telemetryMaxRequests` | 128 rows | Maximum request rows sent or retained for a dashboard. |
| `telemetryHistoryEntries` | 40 rows | Maximum recent history rows sent or retained. |
| `telemetryErrorEntries` | 20 rows | Maximum recent error rows sent or retained. |

The effective offline threshold is the greater of the configured stale and
offline thresholds. Row limits apply on both the sending colony and receiving
master, so increase both computers' limits if you want larger remote pages.
The snapshot includes shown and total counts, and can be further shortened to
fit the message budget. Truncation does not delete the colony's local history,
errors, or request ledger. Use the local colony screen to inspect data omitted
from a remote snapshot.

Set these values in the appropriate computer's **SETTINGS** or while stopped:

```lua
colony_supply set telemetryIntervalSeconds 5
colony_supply set telemetryMaxRequests 256
colony_master set telemetryMaxRequests 256
colony_master set telemetryStaleSeconds 30
colony_master set telemetryOfflineSeconds 90
```

### Supply settings and policy

Settings are saved in `/colony/network.cfg`; the UI validates ranges and saves them.
Master routes support per-colony overrides for operational policy settings. Client
settings display when a master policy is inherited; change those values on the
master or its route override, rather than changing an ineffective client default.
Overflow settings and keep counts remain local unless explicitly overridden.

Configurable settings include:

- On-hand delivery, crafting, MineColonies acknowledgment, colony response,
  message-response, transfer-verification, and chest-test timeouts.
- Poll, hello, message retry, craft output check/cooldown, transfer settle/check,
  failure retry, and recovery probe intervals.
- Autocrafting enablement, concurrent recipes, recipes per turn, and craft batch size.
- Requests per turn, master items per turn, transfer chunk size, colony import limit,
  overflow limit, and reserved empty chest slots.
- Overflow enablement, ordinary/building item keep counts, and per-item keep counts.
- Completed request retention/count, history/error limits, update cadence, and monitor assignments.
- Colony telemetry intervals, freshness timeouts, and request/history/error snapshot limits.

Overflow is disabled by default. When enabled, the colony returns stock above the
configured keep counts during its turn. Any item acceptable to an outstanding
request is protected from overflow, including equipment alternatives.

By default bridges use `exportItemToPeripheral` / `importItemFromPeripheral`, targeting
the same named inventory being verified. If those methods are unsupported, explicitly
disable **Transfer by peripheral name** and configure each directional path. The
chest test must pass for that physical arrangement. Do not disable inventory checks.

The UI guards hardware/route changes while transfers, staged shipments, or uncertain
work remain. The `setup` and `set` commands also check persisted work. Example scalar
changes while stopped:

```lua
colony_master set maxRequestsPerTurn 8
colony_master set craftingTimeoutSeconds 900
colony_master set autoCraftEnabled false
```

Use the master route editor for labels, inventory names, color codes, and per-colony
policy overrides. Pause automation and finish current handshakes before editing routes.

## Recovery and updates

Two alternating, verified journal slots retain request, craft, and transfer state:
`/colony/master_v4_state.a/.b` and `/colony/supply_v4_state.a/.b`. Disk write failure
stops further mutations. Retain these files when diagnosing a problem. Do not delete
them to force a retry while there may be items in transit or accepted crafts.

The **HEALTH / RECONCILE** action, or `colony_master reconcile` /
`colony_supply reconcile`, checks recorded transfers. It credits existing physical
proof rather than blindly reissuing a movement. A definitely reported zero PRS
export with an unchanged chest may use an explicitly requested, journaled one-item
recovery export after the colony acknowledged its paused result. An ambiguous bridge
exception does not authorize that retry. Unprovable quantities stay blocked for
inventory inspection. A processor crash requires restart after recovery; a storage
failure must be repaired before restarting.

For updates, pause the master, let turns finish, then use the shared update control
or the same installer:

```lua
install_colony --update master
install_colony --update supply
install_colony --repair
```

Run the appropriate command on each role; do not update two processes concurrently
on one computer. `--repair` restores code while keeping the same role/configuration
and ledger. A legacy installation must use the first clean v4 installation rather
than an in-place update. Update both roles for protocol-changing releases.

After the first clean Supply 4.0.0 installation, future **Update** and **Repair**
operations preserve the schema 4 configuration, monitor assignments, and request
journals. Do not use `--install` or type `CLEAN` when preserving an existing
installation.

The installer resolves `supply-master-colony` to a Git SHA through GitHub's API and
downloads all modules from that immutable revision. If GitHub API access is disabled,
an explicit raw installer URL containing a full commit SHA can be supplied after
the role argument. TLS verification remains enabled. Future updates follow the
stored source; a commit-pinned source stays pinned until deliberately changed.

An installer interruption is recovered by the startup launcher or:

```lua
install_colony --recover
```

The staged transaction retains old files/data until installation commits. Failed
downloads or validation do not remove the previous installation. Insufficient disk
space blocks installation rather than using an unsafe partial replacement.

## Validation scope

Run `python3 tests/run.py` in the repository. The simulations execute the real Lua
master, colony client, inventory adapter, persistence, shared UI, diagnostics, and
installer with synthetic mod peripherals and controlled failure injection. They
exercise message loss, partial/delayed transfers, desync, crafting, restart safety,
history compaction, and install/update rollback.

These checks do not establish compatibility with a specific Ender Chests release,
live RS asynchronous behavior, chunk loading, or MineColonies courier behavior.
Initial in-game testing should use small noncritical requests with overflow and
autocrafting disabled, then enable crafting and add the second colony after the
chest round trip and request acknowledgment have passed.
