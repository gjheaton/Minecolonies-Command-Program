# Cloud simulation checks

Run the complete suite from the repository root:

```sh
python3 tests/run.py
```

The published Codex environment supplies `lupa==2.6` under
`/workspace/.onboarding/python`. On another machine, install that package into
your Python environment first. The runner explicitly uses its Lua 5.2 runtime,
compiles every Lua file, and exits nonzero if a simulation, installer, or updater test
fails.

The network simulations execute the production master, client, hardware
adapter, protocol, matcher, configuration, and persistent journal. A
deterministic Minecraft boundary models independent computers, PRS and colony
RS stock, crafting completion, shared Ender Chest color channels, inventory
slots, Rednet message loss and reordering, clock advancement, and journal
write failures. Its inventory API deliberately does not expose RS fingerprints.

The checks cover single PRS ownership, round-robin service, bounded transfers,
request fairness, per-colony policy, MineColonies-only completion, partial
imports, craft reservation and timeout behavior, restart reconciliation,
uncertain transfers, phantom stock, exact item variants, overflow safety, and
completed-request retention. Runtime checks exercise typed CLI settings and
prevent changing hardware around retained turns, crafts, or deliveries.
The Ender Chest suite runs the real one-item round-trip diagnostic, including
incorrect physical channels behind otherwise matching labels, lost probe
messages, interrupted verification, exclusive reservations, and explicit
abandonment after manual item recovery. Installer
tests verify clean migration, repeat updates, preserved configuration and
journals, download validation, and transaction recovery. Updater tests check
that failed downloads and installs keep the working installer and application,
and that a successful update proves its package metadata before rebooting.

These checks validate program behavior against the simulated API. They do not
establish that a particular Minecraft mod version exposes those APIs or avoids
desync. Use the installed `chesttest` command against the actual Ender Chests
before enabling supply automation, following `docs/PRS_NETWORK.md`.
