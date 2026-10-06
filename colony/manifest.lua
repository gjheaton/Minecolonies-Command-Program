-- MineColonies Control Suite local manifest
-- Suite version: 4.0.0
return {
    suiteVersion = "4.0.0",
    installationSchema = 4,
    repositoryLayout = "cc-mirror",
    components = {
        startup = "1.1.0", installer = "4.0.0", util = "1.1.0", ui = "1.1.0",
        version = "1.0.0", updater = "1.2.0", network = "4.0.0",
    },
    apps = {
        master = { version = "4.0.0", program = "/colony_master.lua" },
        supply = { version = "4.0.0", program = "/colony_supply.lua" },
        command = { version = "3.0.7", program = "/colony_command.lua" },
    },
    files = {
        { path = "/install_colony.lua", app = "common" },
        { path = "/startup.lua", app = "common" },
        { path = "/colony/manifest.lua", app = "common" },
        { path = "/colony/lib/util.lua", app = "common" },
        { path = "/colony/lib/ui.lua", app = "common" },
        { path = "/colony/lib/version.lua", app = "common" },
        { path = "/colony/lib/updater.lua", app = "common" },
        { path = "/colony/network/config.lua", app = "network" },
        { path = "/colony/network/store.lua", app = "network" },
        { path = "/colony/network/io.lua", app = "network" },
        { path = "/colony/network/protocol.lua", app = "network" },
        { path = "/colony/network/runtime.lua", app = "network" },
        { path = "/colony/network/ui.lua", app = "network" },
        { path = "/colony/network/diagnostics.lua", app = "network" },
        { path = "/colony/supply/matcher.lua", app = "network" },
        { path = "/colony_master.lua", app = "master" },
        { path = "/colony/network/master.lua", app = "master" },
        { path = "/colony_supply.lua", app = "supply" },
        { path = "/colony/network/client.lua", app = "supply" },
        { path = "/colony_command.lua", app = "command" },
        { path = "/colony/command/visitor_jobs.lua", app = "command" },
    },
}
