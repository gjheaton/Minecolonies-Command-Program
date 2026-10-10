-- MineColonies Control Suite Installer
-- Authentic 4.0.0 prototype metadata from commit dc3b689.
-- Test fixture: provides metadata only, never installs files.
local mode = ...
local SUITE_INFO = {
    suiteVersion = "4.0.0", installerVersion = "4.0.0", installationSchema = 4,
    apps = {
        master = { version = "4.0.0", program = "/colony_master.lua", displayName = "MineColonies Supply Master" },
        supply = { version = "4.0.0", program = "/colony_supply.lua", displayName = "MineColonies Colony Supply" },
        command = { version = "3.0.7", program = "/colony_command.lua", displayName = "MineColonies Command Center" },
    },
    components = {
        startup = "1.1.0", installer = "4.0.0", util = "1.1.0", ui = "1.1.0",
        version = "1.0.0", updater = "1.2.0", network = "4.0.0",
    },
    files = {
        { path = "/install_colony.lua", app = "common", remote = "install_colony.lua" },
        { path = "/startup.lua", app = "common", remote = "startup.lua" },
        { path = "/colony/manifest.lua", app = "common", remote = "colony/manifest.lua" },
        { path = "/colony/lib/util.lua", app = "common", remote = "colony/lib/util.lua" },
        { path = "/colony/lib/ui.lua", app = "common", remote = "colony/lib/ui.lua" },
        { path = "/colony/lib/version.lua", app = "common", remote = "colony/lib/version.lua" },
        { path = "/colony/lib/updater.lua", app = "common", remote = "colony/lib/updater.lua" },
        { path = "/colony/network/config.lua", app = "network", remote = "colony/network/config.lua" },
        { path = "/colony/network/store.lua", app = "network", remote = "colony/network/store.lua" },
        { path = "/colony/network/io.lua", app = "network", remote = "colony/network/io.lua" },
        { path = "/colony/network/protocol.lua", app = "network", remote = "colony/network/protocol.lua" },
        { path = "/colony/network/runtime.lua", app = "network", remote = "colony/network/runtime.lua" },
        { path = "/colony/network/ui.lua", app = "network", remote = "colony/network/ui.lua" },
        { path = "/colony/network/diagnostics.lua", app = "network", remote = "colony/network/diagnostics.lua" },
        { path = "/colony/supply/matcher.lua", app = "network", remote = "colony/supply/matcher.lua" },
        { path = "/colony_master.lua", app = "master", remote = "colony_master.lua" },
        { path = "/colony/network/master.lua", app = "master", remote = "colony/network/master.lua" },
        { path = "/colony_supply.lua", app = "supply", remote = "colony_supply.lua" },
        { path = "/colony/network/client.lua", app = "supply", remote = "colony/network/client.lua" },
        { path = "/colony_command.lua", app = "command", remote = "colony_command.lua" },
        { path = "/colony/command/visitor_jobs.lua", app = "command", remote = "colony/command/visitor_jobs.lua" },
    },
}
if mode == "--metadata" then return SUITE_INFO end
error("Historical metadata fixture cannot install a suite", 0)
