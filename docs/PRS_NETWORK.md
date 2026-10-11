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
master and colony; the physical color codes must agree. The color order is
**Red → colony designator → direction**. Clockwork uses **Blue**, Stardust uses
**Pink**, and the final color is **White for delivery to the colony** or **Black
for returns from the colony**.

| Colony | Delivery channel (to colony) | Return channel (from colony) |
| --- | --- | --- |
| Clockwork | `red-blue-white` | `red-blue-black` |
| Stardust | `red-pink-white` | `red-pink-black` |

Set each channel's master-side and colony-side chests to the same code and access
settings. Enter these labels in both computers' setup. They are checked during the
handshake. The program cannot read the actual dyes or set the chest colors; you
must check them in-game. The controlled item test below establishes that the
configured physical channels agree.

Use physical labels on the chests to distinguish the four channels:

```text
MASTER                                    COLONY
Clockwork delivery: Red-Blue-White   <==>   Clockwork delivery: Red-Blue-White
Clockwork returns:  Red-Blue-Black   <==>   Clockwork returns:  Red-Blue-Black
Stardust delivery:  Red-Pink-White   <==>   Stardust delivery:  Red-Pink-White
Stardust returns:   Red-Pink-Black   <==>   Stardust returns:   Red-Pink-Black
```

Add each chest's local peripheral name to its label. The names at the two ends
may differ even though the color code is the same.

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
5. Run `colony_master --diag` and `colony_master --monitors` to check the visible
   devices, then configure their exact names. Run the controlled `--chesttest`
   described below for each colony before enabling automatic transfers.

Stop all previous programs and disconnect other PRS bridge clients. Do not run a
second master or let other automation race the master's Ender Chest movements.

### Identifying monitors, bridges, and chests

Before setup, use the computer's built-in command to list visible peripherals:

```lua
peripherals
```

Right-click the wired modem attached to the physical monitor, RS Bridge, or chest
to enable its peripheral connection. The connection message identifies its
peripheral name. Match that name with the list on the computer, and write it on
a sign or other label next to the device. For example, label the primary screen
`Overview — monitor_0` and a chest `Clockwork DELIVERY — red-blue-white — <name>`.
Use the actual names reported in your world.

If you cannot tell which name belongs to a device, stop supply automation, run
`peripherals`, disconnect only that device's wired modem or cable, and run the
command again. The missing name identifies it. Reconnect and re-enable the modem,
then verify the name again before selecting it in setup. Avoid disconnecting a
backbone cable that removes several devices at once.

`colony_master --monitors` also lists monitor names, sizes, and dashboard mappings.
There is no automatic reading of a chest's dye colors: use its physical label,
the configured color-channel label, and the controlled chest test together.

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

All suite command-line options use the `--` prefix. Values such as the role,
computer ID, setting key, peripheral name, item ID, shipment ID, or source URL
remain unprefixed. For example, `colony_supply --clear-errors` and
`colony_master --set automationEnabled false` follow the same convention as
`install_colony --repair`. Bare options from earlier releases remain accepted
as compatibility aliases. Running `colony_master` or `colony_supply` without an
option starts the normal application.
Use `install_colony --help`, `colony_master --help`, or `colony_supply --help` to
list that program's options.

Run the indicated setup command before starting automation:

```lua
colony_master --setup
```

For the master, select its overview monitor and PRS Bridge, then add each colony's
computer ID, label, master-side delivery and return inventories, color-channel
labels, and optional dashboard monitor. On each colony run:

```lua
colony_supply --setup
```

Enter the master computer ID, the colony's RS Bridge/Integrator, local chest names,
and the same color-channel labels. CC:Tweaked's `id` command displays the computer
ID.

Setup runs on the **computer's built-in 51 × 19 keyboard screen**, one question
per screen. It does not put setup prompts on the external 5 × 3 operational
monitors. Hardware choices show numbered peripheral names; long names wrap in
full and long lists have pages.

- Enter the listed number for the device you physically identified.
- Type `N` or `P` and press Enter to move between pages.
- Enter keeps a valid current selection, or selects the sole listed choice.
- Optional dashboard monitors can be left unassigned with the displayed **None** choice.
- Type `:q` at any step to cancel. Your existing configuration remains unchanged.

Setup stores explicit hardware names. Review the selections and choose **Yes**
at the final save confirmation; intermediate answers are not saved. Confirmed
master setup leaves **Run supply automation** disabled, including when rerunning
setup on an existing master, so you can check the wiring first.

Each master-side colony dashboard is mapped separately as described below. If
several monitors are attached, select the overview by its exact peripheral name.

The following command also explicitly pauses the master before a hardware test:

```lua
colony_master --set automationEnabled false
```

Reboot colony computers so their clients are listening. Leave the master in the
shell for diagnostics. You can later start `colony_master`, open **SETTINGS**, and
enable **Run supply automation**. Pausing stops new grants but finishes existing
handshakes; it does not cancel deliveries or crafts.

### Connection timing

After an explicit setup command, run `colony_master` on the master and
`colony_supply` on each colony, or reboot the configured computers. Both programs
must be running for a connection check; completing setup alone does not start
the master service.

With the default settings, expect confirmation in about 1–5 seconds. Colonies
send a hello immediately and retry every 5 seconds (`helloSeconds`); the master
normally processes messages every second (`pollIntervalSeconds`). A busy
processor can take longer. The master acknowledges connections even when its
automation is paused, and the colony displays **Master connected; automation
paused**. Connecting does not grant a supply turn or move items.

The colony reports a lost connection after 30 seconds without a master response
by default (`messageTimeoutSeconds`). If it keeps waiting, check that its saved
master ID matches the master's `id`, that the master has a saved route for this
colony's `id`, and that both computers have rednet connectivity. A reply with
mismatched delivery/return color labels shows a connection with a channel error;
correct the labels on both computers before starting transfers. Connection and
item-delivery timeouts are separate configurable settings.

## Ender Chest identification and transfer test

First perform read-only checks on both endpoints:

```lua
colony_master --diag
colony_supply --diag
```

The report checks configured inventory names, size/list access, push/pull methods,
RS Bridge transfer methods, and modem availability. An Ender Chest must expose the
CC:Tweaked inventory API. A modded inventory that does not expose that API is a
hardware integration blocker, rather than an invitation to skip verification.

With normal master automation paused and its program stopped, keep the colony
client running. Empty both channels and put a plain cobblestone in PRS. On the
master run, replacing `12` with the colony computer ID:

```lua
colony_master --chesttest 12
```

You can specify another plain non-NBT test item:

```lua
colony_master --chesttest 12 minecraft:dirt
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

An interrupted test retains its journal. Rerun the **same**
`colony_master --chesttest ID` to resume or reconcile its existing movement without
repeating an uncertain export/import.
If the original return import can be proven from the saved before/after counts,
the test can finish without a second import. If proof is unavailable, manually
inspect/recover the test item and empty both channels, then use:

```lua
colony_master --chesttest --abandon 12
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

Advanced Peripherals reports item NBT data differently from CC:Tweaked's inventory
NBT hash. The master saves the entire chest baseline before exporting the selected
AP `fingerprint`. Binding a new physical identity requires a positive bridge
return, exactly one identity gaining that quantity, and all other quantities
unchanged. A verified
shipment retains both the physical NBT hash and the original AP fingerprint;
colony imports and overflow returns preserve that binding. AP fingerprints describe
the item stack and remain usable across RS networks. An NBT import without a valid
AP selector is blocked; the program never substitutes a CC hash as an AP NBT filter
or falls back to importing any item with the same name.
Every physical import selects the matching source slot, including imports with
an AP fingerprint. This prevents the selector from scanning and changing unrelated
stacks. Plain imports avoid fingerprint matching. From 4.0.15, CC's known hash for
an empty compound is treated as empty root NBT, so an empty tag cannot make an
otherwise plain retained delivery appear to be a different variant. Genuine
tagged variants stay distinct. Ender Chest round-trip tests use the same physical
export evidence and preserve the original AP item for PRS accounting.

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
colony_master --monitors
```

Names such as `monitor_0` are examples; use the names reported by your computer.
If more than one monitor is visible, select the primary overview explicitly:

```lua
colony_master --set monitorName monitor_0
```

Assign a separate master-side monitor to a configured colony, replacing `12`
with that colony computer's ID:

```lua
colony_master --monitor 12 monitor_1
```

The main **SETTINGS** route editor labels this optional field **Master colony
dashboard monitor**. Each route's monitor must be unique and must differ from
the primary overview monitor. A master with N dashboard panels needs N + 1
separate monitors, all built to the same 5 × 3 size. To remove a dashboard:

```lua
colony_master --monitor 12 none
```

These assignments change displays only. The display assignment command preserves
pending supply work; it does not reconfigure bridges or chests. Stop the application
to use shell commands, then restart it to apply the saved mapping. Do not start
another master process alongside the existing one.

On each colony, `colony_supply --setup` or the local **SETTINGS** page selects its
own monitor; `colony_supply --monitors` lists its visible monitors. A master-side
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
colony_supply --set telemetryIntervalSeconds 5
colony_supply --set telemetryMaxRequests 256
colony_master --set telemetryMaxRequests 256
colony_master --set telemetryStaleSeconds 30
colony_master --set telemetryOfflineSeconds 90
```

### Supply settings and policy

Settings are saved in `/colony/network.cfg`; the UI validates ranges and saves them.
Master routes support per-colony overrides for operational policy settings. Client
settings display when a master policy is inherited; change those values on the
master or its route override, rather than changing an ineffective client default.
Overflow settings and keep counts remain local unless explicitly overridden.

### Selecting hardware in SETTINGS and COLONY ROUTES

Touch a peripheral field to open a picker instead of typing its name. The
numbered list shows compatible devices visible to that computer:

- Monitor fields show monitors; bridge fields show RS Bridges; the Colony
  Integrator field shows Colony Integrators.
- Chest fields show inventories exposing the `list` and `size` methods.
- Devices assigned to another field or colony route are hidden. A compatible,
  connected current selection remains available. Optional fields offer
  **None / Auto** where appropriate.

Type a listed number and press Enter, or touch the entry on the monitor.
The picker also appears on the computer's built-in screen for keyboard use,
even when an external monitor is attached. Use `N`/`P` or **PREV / NEXT** for
longer lists. **KEEP CURRENT** retains an available current selection;
**Escape** or **CANCEL** closes the picker without changing the field.
Full names wrap across lines rather than being truncated, and the choices
refresh when peripherals are attached or detached. Required chest fields also
offer **REFRESH** for a rescan. The same compatible-device selection is used
during the initial keyboard setup.

Choosing a device in **SETTINGS** saves that setting. When drafting a colony
route, a chosen delivery chest, return chest, or dashboard
monitor immediately disappears from the other applicable choices in that draft.
The selections do not become saved assignments until **SAVE ROUTE** succeeds.
Cancel discards the draft. Other fields, including computer IDs, color-channel
labels, and timeout values, continue to use normal text or number entry.

The picker cannot identify physical chest colors. Use the wired-modem name and
physical-label procedure above before choosing a chest, then run its controlled
transfer test. Required devices still need to be connected and modem-visible.

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
work remain. The `--setup` and `--set` options also check persisted work. Example scalar
changes while stopped:

```lua
colony_master --set maxRequestsPerTurn 8
colony_master --set craftingTimeoutSeconds 900
colony_master --set autoCraftEnabled false
```

Use the master route editor for labels, inventory names, color codes, and per-colony
policy overrides. Pause automation and finish current handshakes before editing routes.

## Recovery and updates

Two alternating, verified journal slots retain request, craft, and transfer state:
`/colony/master_v4_state.a/.b` and `/colony/supply_v4_state.a/.b`. Disk write failure
stops further mutations. Retain these files when diagnosing a problem. Do not delete
them to force a retry while there may be items in transit or accepted crafts.

The master **HEALTH → RECOVER TRANSFER → RUN RECOVERY** action, the colony
**HEALTH / RECONCILE** action, or `colony_master --reconcile` /
`colony_supply --reconcile`, checks recorded transfers. It credits existing physical
proof rather than blindly reissuing a movement. A definitely reported zero PRS
export with an unchanged chest may use an explicitly requested, journaled one-item
recovery export after the colony acknowledged its paused result. An ambiguous bridge
exception does not authorize that retry. Unprovable quantities stay blocked for
inventory inspection. A processor crash requires restart after recovery; a storage
failure must be repaired before restarting.

For **PROCESSOR_ERROR: Cannot serialize table with repeated entries**, update
the master and every colony supply computer to 4.0.1 or later, then restart them.
Use **CHECK UPDATE → UPDATE**, or `install_colony --update master` on the master
and `install_colony --update supply` on each colony. This code fix preserves
configuration and request/transfer journals and allows shared
request tables to be saved. Requests marked **timed out** can receive updated
statuses when their next turn completes. If restart reports **TURN_INTERRUPTED**,
**IMPORT_UNCERTAIN**, or a transfer verification fault, let the original turn
close and use the corresponding reconciliation command or action described
above; retained transfer safeguards still apply.

### Identifying an active held PRS transfer

Release 4.0.3 shows the attempted item and quantity, affected colony, and chest
with the master's active transfer fault on **HEALTH**. This information comes
from the retained transfer record. The attempted quantity describes the bridge
call; it does not prove that the items moved.

For the exact registry ID, recorded bridge result, and AP fingerprint/NBT, pause
master automation, stop its application and startup launcher to reach the shell,
then run:

```lua
colony_master --transferdiag
```

This command is read-only. It also compares the held selection with the chest's
current contents. Use the registry ID and variant details to identify the item
in the PRS grid. Leave delivery chest items untouched and retain the transfer
hold and journals while investigating; moving items or clearing the hold can
invalidate the saved transfer evidence. If no held master transfer exists, the
command reports that rather than guessing from historical errors.

If the active hold blocks the UI's **UPDATE** action, pause automation and let
the current colony result handshake finish. Then stop the master application
and launcher and run `install_colony --repair`, followed by `reboot`, to install
the diagnostic improvement. Repair preserves the held transfer and its original
evidence. The fault still needs reconciliation; updating does not clear it.

#### A held export that reported zero

Release 4.0.4 retains the second value returned by the AP bridge, such as
`0, INVALID_TARGET`, and reports a zero export without assuming desync caused it.
A zero bridge result with no chest increase means the attempted delivery has
not been verified; it does not identify the cause by itself.

Advanced Peripherals 0.7.48r can report `INVALID_TARGET` even when CC:Tweaked can
list the chest's contents. AP must find a compatible inventory handler through
the selected bridge's transfer method and target. CC inventory visibility alone
does not prove that path is available.

Keep master automation paused and leave the delivery contents and retained hold
untouched. Let any current result handshake finish, then stop the master program
and launcher to reach its shell. Obtain the diagnostic update and restart:

```lua
install_colony --repair
reboot
```

Repair preserves settings, journals, and held transfer evidence. Stop the master
program and launcher again, then inspect the held transfer:

```lua
colony_master --transferdiag
```

For a held export with a definitely recorded zero result, the command checks the
configured transfer path using the same bridge API and peripheral or direction
with `{name = <held item ID>, count = 0}`. It supplies no fingerprint and requests
zero items. This target check moves no items, submits no craft, and leaves the
transfer journal unchanged. It reports the bridge name, connection state,
transfer method, selected target, and AP result or error.

An accepted zero-count target check proves that AP can find the handler. It does
not prove that the held item can be inserted or that a nonzero export will work.
An item-selection, insertion, or cached-NBT/fingerprint issue remains a possible
cause to investigate after the target check. Unknown results and held imports
are inspected without this export target check. Retain the original hold while
investigating; do not repeatedly retry, clear the journal, manually substitute an
unguarded name-only item filter, or move delivery items to make a check pass.

#### Ordinary-item selection on AP 0.7.48r

Release 4.0.5 addresses an AP fingerprint lookup that calls `getOrCreateTag`
on actual Refined Storage cache stacks. A plain stack's null tag can become
an empty compound before extraction; an NBT-sensitive disk comparison can then
return zero. An accepted target handler alone does not establish this cause
for a particular failed transfer, because it does not test insertion or extraction.

The master uses `{name = <item ID>, count = <quantity>}` only when the request
is an ordinary non-NBT item and the full stock snapshot shows positive stock
of that name with one original fingerprint and no tagged alternatives. Candidate
variants alone cannot establish this because they exclude rejected tagged items.
Missing or ambiguous evidence, equipment, and tagged requests retain fingerprint
selection. The chosen selector mode is journaled before the bridge call. The
original AP fingerprint and full physical chest baseline remain recorded.

Physical verification of a `plain-name` export requires a single plain same-name
increase matching the reported count, with no other chest changes. Tagged output
remains quarantined and receives no shipment credit. Updating does not clear an
existing hold or automatically repeat a failed export.

For an existing zero-export hold, leave master automation paused and delivery
items untouched. Install 4.0.5 with `install_colony --repair`, then `reboot`.
Keep the colony client running so it can acknowledge any outstanding result.
Stop the master program and startup launcher and run:

```lua
colony_master --reconcile
```

This existing command checks the original physical baseline and fresh stock
identity, obtains the colony's channel confirmation, and may perform **one
journaled recovery item**. It is not a read-only diagnostic. The probe must be
physically verified before the hold is released; its quantity is credited to the
original request, leaving only the remaining quantity to supply. A changed chest,
changed fingerprint, or unacknowledged turn blocks the probe. Existing cached
metadata or insertion problems can still produce zero; if it remains blocked,
inspect with `colony_master --transferdiag` rather than repeatedly retrying.

### Tools held after an identity mismatch

Earlier 4.0.0 code could export a tool successfully but fail chest verification
because it compared AP NBT data directly with a CC inventory hash. Leave those
items untouched and pause master automation. Update the **master and every Supply
computer** to 4.0.1 or later before resuming transfers: the fix changes how exact
item selectors are carried between them. Update keeps their configuration and journals.

If the original Stardust turn is still open, leave both normal programs running
with automation paused until its batch/result/acknowledgment handshake closes.
Then use **CHECK UPDATE → UPDATE** on each computer, or stop the applications and
startup launchers to reach their shells and run `install_colony --update master`
on the master and `install_colony --update supply` on each colony. On the **master**,
for Stardust at colony computer ID `4`, run:

```lua
colony_master --transferdiag
colony_master --reconcile-bind 4
```

`--transferdiag` is read-only and shows the held AP selection beside the physical
CC identity. `--reconcile-bind` previews an older, single-item export with a known
reported count of one, an original count of zero, and no complete saved chest
baseline. It requires restored PRS access, a finished handshake, one unambiguous
physical identity, and the other retained deliveries still present.

Type the literal `BIND 4` only after confirming the shears were **absent before
that export** and the delivered pair has remained untouched and unreplaced. The
command durably records **OPERATOR_BIND_EXPORT** and creates one verified shipment
for the existing item without exporting again. A false confirmation can credit
an unrelated item; any other input cancels. Only after **OK:** and updates on all
computers, reboot the master and clients, then resume master automation. If
**BLOCKED:** appears, retain the items and journals and inspect the reported cause.

### Unknown colony transfer result

For local **TRANSFER_DESYNC: Transfer result unknown**, pause master automation.
Stop the affected colony application and startup launcher to reach the shell,
then update to the current release and run its read-only diagnostic:

```lua
install_colony --update supply
colony_supply --diag
```

The report shows the selected RS Bridge name, `isConnected`, stock-read result,
and any held operation, item, chest, quantity, and reported count (**UNKNOWN**
when absent). An older journal may lack the bridge's original error reason.

Advanced Peripherals 1.20.1 can return `nil, NOT_CONNECTED` when the bridge cannot
access an RS network. Check the colony warehouse's RS Bridge, cables, controller,
storage routing, and chunk loading. `isConnected = true` alone does not prove
the controller has power. For named transfers, the bridge and chest must be
accessible on the same enabled CC wired network, using the bridge's remote
peripheral name. A target outside that scope can return `0, INVALID_TARGET`,
which differs from an unknown result.

A zero observed chest delta plus an unknown reported count does **not** justify
resetting or retrying the transfer. Diagnose the connection without repeatedly
attempting transfers. Fixing it leaves the existing unknown intent held: inspect
the physical chest and warehouse against the retained ledger before deciding on
recovery. Repair and diagnostics do not clear that intent or guarantee that
automatic reconciliation will succeed.

#### Operator-confirmed zero colony import

`colony_supply --reconcile-zero <shipment ID>` is a local Supply recovery for an
unknown import that you can confirm moved **no items**, with none subsequently
replaced in the source chest. An unchanged stack alone cannot prove that; a
false zero confirmation can cause excess deliveries when normal imports resume.
Ordinary reconciliation still blocks an unknown return.

Keep master automation paused and update the affected Supply computer to obtain
the command. If its original turn is still waiting for the master result, run
both normal programs while paused until that handshake finishes, then stop the
colony application and startup launcher again. For Stardust's held rice import:

```lua
install_colony --update supply
colony_supply --reconcile-zero shipment-27
```

Before confirming, inspect the delivery chest and warehouse: the original one
rice must still be present, the other five delivery items must remain in their
recorded quantities, and the failed call must have moved nothing. Do not move or
replace items to make the check pass. The preview requires a finished turn, a
connected colony RS Bridge, readable stock, the original chest and exact item/NBT,
unchanged source/imported quantities, and coverage of every retained shipment.

Check the preview, then type the literal `ZERO shipment-27` only if those facts
are certain. Any other input cancels. The command durably records
**OPERATOR_ZERO_IMPORT** before clearing that selected intent and its fault; it
moves no items and preserves all shipment/imported quantities and other deliveries.
Only after an **OK:** result, reboot the colony and resume master automation.
For **BLOCKED:** or uncertain physical history, leave automation paused and inspect
the reported cause; do not clear the journal to bypass the guard.

### Recovering from a full computer disk

1. Pause **Run supply automation** on the master, then stop the server or leave
   the singleplayer world. If the full disk prevents saving the pause setting,
   after increasing the quota stop the master application and startup launcher
   at the shell, run `colony_master --set automationEnabled false`, then update
   and reboot it as below.
2. In the existing `<world>/serverconfig/computercraft-server.toml`, change the
   root setting to `computer_space_limit = 10000000` (10 MB), then restart the
   server or reopen the world. A computer `reboot` alone does not apply the new
   capacity. This keeps computer IDs, files, journals, and inventories intact.
3. On the master and **every** colony supply computer, update to 4.0.1 or later
   with **CHECK UPDATE → UPDATE**. Alternatively, stop the application and startup
   launcher to reach the shell, run `install_colony --update master` on the master
   or `install_colony --update supply` on a colony, then run `reboot`. Updates
   preserve configuration and request/transfer journals. If damaged files prevent
   an ordinary update, use `install_colony --repair` for a forced reinstall.
   Do not use `CLEAN`, delete journal slots, or empty delivery chests to force a retry.
4. Keep the master and affected colony programs running with new automation
   paused. Existing turns still finish their original batch/result/acknowledgment
   handshake. If Stardust retains an interrupted-transfer fault, use **HEALTH →
   RECONCILE** on its own colony screen once that turn closes. If reconciliation
   says to wait for the master result, leave both programs running and retry
   after the original turn finishes.
5. Resume master automation only after reconciliation succeeds and the active
   fault clears. **Reconciliation queued** is not success: check **HISTORY** for
   the successful **RECOVERY** / **RECONCILED** result. A blocked result requires
   inspection of the reported transfer; do not reset its ledger to bypass it.

The **ERRORS** page contains recorded history; use **HEALTH** for current faults.
Resolved historical entries disappear from the terminal status display. Recorded
errors remain saved across reboots and are available on **ERRORS** until cleared.
On the computer that owns those records, select **ERRORS → CLEAR HISTORY** to
remove the saved list. Master-side remote colony dashboards are read-only; clear
a colony's history on its own Supply computer. At the shell, the equivalent
commands are:

```lua
colony_supply --clear-errors
colony_master --clear-errors
```

Clearing recorded errors preserves active faults, transfer intents, shipments,
requests, craft jobs, configuration, and the separate **HISTORY** event list. A
successful clear adds an **ERROR_HISTORY_CLEARED** event and persists across
reboots. An active **ERROR** or stopped processor still needs attention on
**HEALTH**; clearing history does not reconcile or restart it. If saving cannot be
confirmed, the clear reports failure and retains the records in the current display.

For updates, pause the master, let current turns finish, then use
**CHECK UPDATE → UPDATE** on each computer or the same installer:

```lua
install_colony --update master
install_colony --update supply
```

Run the appropriate command on each role; do not update two processes concurrently
on one computer. Update the master and every colony supply computer to 4.0.9 before
resuming automation, and update both roles together for protocol-changing releases.
An older v3 installation must use the first clean v4 installation instead of an
in-place update.

After the first clean Supply 4.0.0 installation, future **Update** and **Repair**
operations preserve the schema 4 configuration, monitor assignments, and request
journals. Do not use `--install` or type `CLEAN` when preserving an existing
installation.

Release 4.0.2 permits update checks during active turns. Installing an update
still waits for safe, closed turns and the existing transfer guards. Open the
local **SETTINGS** page to inspect **Update:** for the latest check result and
time, and **Source:** for the configured source. The terminal reports changes
to this status; master-side remote dashboards remain read-only.
A check can report a newer version, no update, or a download/check failure;
the result does not mean that new code has already been installed.

If **CHECK UPDATE** on an older 4.0.0 installation appears unresponsive or cannot
find the release, pause master automation and let current handshakes finish.
Stop the application and startup launcher to reach the shell, then run on the
master and every colony supply computer:

```lua
install_colony --repair https://raw.githubusercontent.com/gjheaton/Minecolonies-Command-Program/supply-master-colony/install_colony.lua
reboot
```

The same command works for either installed role. It preserves configuration and
request/transfer journals, and resets `suiteSourceUrl` to the moving
`supply-master-colony` branch. This lets future **CHECK UPDATE** actions find later
patch releases, including when the previous source was pinned to an old commit. Do not choose
`CLEAN`. Resume automation only after every computer has restarted.

Use `install_colony --repair` for a forced reinstall when files are damaged or
when retrieving a same-version code fix. Repair preserves configuration and
request journals. The earlier fixes published as 4.0.0 required Repair because
the update control only detects a greater version. Release 4.0.1 and subsequent
fixes increment the patch number and can use the normal update control.
Restart the application to use its updated screens and commands.
Run `colony_master --setup` or `colony_supply --setup` if you need to repeat the
hardware wizard; do not use `CLEAN` to obtain an update or repair.

Versions follow **MAJOR.MINOR.PATCH**. The first number changes for incompatible
behavior or migrations, the second for compatible new features, and the third
for fixes and maintenance. This release is **4.0.17**; later fixes increase the
third number. A minor release resets the patch number (`4.1.0`), and a major
release resets both later numbers (`5.0.0`). The update control compares all three
numbers and offers installation when the published version is greater.

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

### Colony updates during active automation

Release 4.0.6 makes the colony UPDATE button queue installation during an active
turn. The client continues its existing batch/result/receipt handshake and
refuses fresh grants while the update is queued. Once that reservation closes,
the runtime rechecks installation safety and runs the installer. No shipment or
transfer journal is discarded. Queued state is visible in the header and SETTINGS.

Installation failure releases the admission hold and displays the failure. A
transfer intent needing reconciliation cancels the queued update so recovery
controls remain available. The master still keeps held-transfer installation
guards. Masters through 4.0.8 require manually pausing automation and finishing
reserved turns before using UPDATE.

Older colony versions only display a waiting notice; they do not queue an update.
To obtain 4.0.6 through those buttons, pause Run supply automation on the master,
let reserved turns finish, then press UPDATE again on each colony. Alternatively,
stop the program and startup launcher and use `install_colony --repair`, followed
by `reboot`. Resume master automation after the updates finish. Future colony
updates can be queued while ordinary turns are active.

### Master recovery from the monitor

In 4.0.7, correct the connection or storage problem, leave the affected colony
computer running, then select **HEALTH → RECOVER TRANSFER** on the master. Review
the explanation and select **RUN RECOVERY**. The processor saves an automation
pause before checking the original transfer. It may submit one guarded recovery
item for a definitely reported zero export with unchanged chest evidence; it
never blindly repeats an uncertain transfer. Repeated clicks do not queue
additional recovery probes.

The screen displays **RECOVERED** only after the engine verifies the transfer,
or **BLOCKED** with the reason. Verification has a bounded wait using the configured
transfer verification timeout; a timeout retains the journal and safety hold.
A blocked result may require the colony to acknowledge its existing turn before
you try again. A chest test or stopped processor blocks monitor recovery until
the test finishes or the processor is restarted.

Automation remains paused after the check. Review **HEALTH**, then enable
**SETTINGS → Run supply automation** when ready. There is no reboot requirement
for an ordinary transfer hold recovered by this button. Recorded errors remain
in **ERRORS**; **CLEAR HISTORY** removes the archive without changing active faults.
Remote colony dashboards remain read-only.

Suite 4.0.8 packages Command Center **4.0.0**. Its application version is separate
from the suite version; both participate in update checks. Existing V4 Command
installations can use CHECK UPDATE → UPDATE while preserving their settings.

### Master updates and available equipment in 4.0.9

After CHECK UPDATE finds a newer version, pressing UPDATE on the master queues
installation, saves Run supply automation as disabled, and refuses new turns.
Existing granted turns, deliveries, and result acknowledgments continue. Ordinary
pending chest verification may finish; uncertain transfer holds, PRS quarantine,
chest tests, and stopped processors block installation and display the reason.
Once reserved turns close, the installer rechecks the available version and
updates with settings and journals preserved. Automation stays paused after the
update or an installation failure. Re-enable it in SETTINGS when ready.

Masters running older releases need one manual pause and completed turns to install
4.0.9 through the UI, or a stopped application followed by install_colony --repair
and reboot. Subsequent master updates can use the queued workflow.

Equipment selection now ranks stocked accepted alternatives before absent ones,
then craftable alternatives before unavailable recipes. Higher tiers are preferred
within those groups. A nonexistent netherite hoe can no longer hide stocked wooden,
stone, or diamond hoes or a craftable iron hoe. MineColonies' item alternatives
remain authoritative for allowed levels; the matcher does not invent tools outside
that list or weaken exact NBT / fingerprint rules for damaged or enchanted variants.

### Command hut waypoints in 4.0.1 (suite 4.0.10)

Connect an Advanced Peripherals Chat Box to the Command computer directly or
via an enabled wired modem and networking cable. Command discovers it when you
press **MARK** on a **BUILDINGS**, **HELP WANTED**, or **CONSTRUCTION** row, or **MARK HUT** in
their detail views. Help Wanted marks the hiring hut, not a citizen's position.

The button broadcasts a JourneyMap location message in public chat. Players click
that message in the colony's dimension to create their own waypoint and select
its beacon display in JourneyMap. Chat Box range/dimension settings control who
receives it. Command reports missing hardware, cooldowns, and rejected messages
without requiring a Chat Box for its normal operation. It never places blocks
or automatically creates waypoints on players' clients.

Construction Orders marks only a uniquely identified target hut. If duplicate
huts make the target ambiguous, select the desired hut from Buildings.

### Unknown overflow return with confirmed zero movement (4.0.11)

Normal reconciliation refuses an unknown bridge result. For a failed overflow
return, keep master automation paused from the failure onward and verify that no
items moved and nobody moved or replaced return-chest items. Restore the colony
RS Bridge, then stop the colony supply program and run:

```lua
colony_supply --reconcile-zero-return
```

The preview identifies the exact held item, quantity, and return chest. The
command requires a finished reserved turn, a connected/readable colony network,
an unchanged full physical return-chest baseline, and intact outstanding
deliveries. Starting in 4.0.12, enter `ZERO` to acknowledge the displayed operation only when the
zero-movement conditions above are true. Any other answer cancels.

Recovery saves an audit acknowledgment before releasing the intent and fault;
it performs no transfer, credits no returned quantity, and preserves delivery
and return-selector ledgers. Disk-write failures retain the hold. Restart the
colony program, verify its HEALTH and the master's reported colony status, and
only then resume automation. If the master drained the return chest or anyone
replaced items, this acknowledgment must not be used.

### Refreshing recovered colony status (4.0.13)

The master now accepts current colony fault status from a hello whose configured
color routes match. This works with automation paused and does not grant a turn
or touch inventories. Recovered colonies clear their reported fault within the
normal hello interval (five seconds by default) after their program resumes.
Master-detected faults, transfer quarantine, and recorded error history remain.
Older journals without fault provenance migrate only the known colony transfer
error messages; other ambiguous errors still require normal reconciliation.

### Inspecting a missing verified delivery (4.0.14)

Pause master automation and stop the affected colony's supply program. Run
`colony_supply --deliverydiag shipment-183`, replacing the ID with the one on
the colony's ERRORS screen. This reads the retained record and original configured
delivery chest without starting the engine, transferring items, crediting an
import, or clearing a fault. Compare the expected exact item with both physical
chests' contents and verify their actual colors match the configured channel.
Same-name items with different NBT do not establish the shipment's identity.
Do not remove journal entries or resend stock merely because an item is absent.

### Recovering a delivery with empty root NBT (4.0.15)

CC:Tweaked reports the empty-compound NBT hash
`41883520c3071f5f4a4a4613fb005e0c` when a stack has an empty root tag. Release
4.0.15 treats only that known empty hash as equivalent to `nil` or `{}` at the
root. Other hashes and tagged item variants remain exact. Slot-bound physical
imports also prevent AP fingerprint predicates from scanning unrelated stacks.

This fixes a false **DELIVERY_MISSING** when a verified plain item is still in
the correct chest but now carries that empty tag. For example, Stardust's
shipment `shipment-183` recorded three carrots, with zero imported, while its
delivery chest contained 36 carrots with the empty-compound hash. Those existing
carrots can cover the retained shipment; they do not need to be supplied again.

Keep master automation paused and leave both delivery chests untouched. Stop
Stardust's application and startup launcher to reach the shell, then run:

```lua
install_colony --repair
colony_supply --reconcile
reboot
```

Repair preserves settings and journals. In this false-missing case, reconciliation
checks the existing chest quantity against the retained deliveries and clears the
fault when all required quantities are present. It transfers no items and credits
no imported quantity. The next normal supply turn handles the imports.

After Stardust restarts, verify its **HEALTH** is healthy. Its next route-confirmed
hello clears the old reported colony fault on the master while automation remains
paused. Resume automation only after both show healthy. This recovery requires no
new supply, manual movement, or `ZERO` acknowledgment. If reconciliation remains
blocked, retain the records and contents and inspect `--deliverydiag` rather than
resetting the journal or forcing another delivery.
