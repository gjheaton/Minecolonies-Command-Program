# MineColonies Control Suite

The `supply-master-colony` branch introduces Supply v4: one dedicated computer owns
Player Refined Storage (PRS), and colony supply computers communicate with it over
rednet. Each colony has a delivery and a return Ender Chest channel. Command Center
is also available through the same installer.

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
by the installer, then reboot. See the [hardware, configuration, and testing guide](docs/PRS_NETWORK.md)
before enabling automatic supply. HTTP access to `raw.githubusercontent.com` and
`api.github.com` is required; the installer resolves each download batch to one Git
commit so all installed modules come from the same revision.

## Updates

Use the UI's **CHECK UPDATE / UPDATE** control or the same installer:

```lua
install_colony --update master
```

Use `supply` or `command` instead of `master` on those computers. The stored update
source remains this development branch until explicitly changed. Update the master
and all colony clients together when a release changes the protocol.

## Development checks

```bash
python3 -m pip install 'lupa==2.6'
python3 tests/run.py
```

The published Codex cloud environment already provides Lua 5.2 through Lupa.
Tests simulate the CC:Tweaked hardware boundary, messages, inventories, persistence,
installer failure/recovery, and shared UI. Actual mod interoperability still needs
in-game testing; run the Ender Chest diagnostics before automatic transfers.
