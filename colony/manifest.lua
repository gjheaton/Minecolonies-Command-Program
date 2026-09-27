-- MineColonies Control Suite local manifest
-- Suite version: 3.0.7
return {
    suiteVersion = "3.0.7",
    repositoryLayout = "cc-mirror",

    components = {
        startup = "1.0.0",
        installer = "3.0.7",
        util = "1.1.0",
        ui = "1.1.0",
        version = "1.0.0",
        updater = "1.1.1",
    },

    apps = {
        command = {
            version = "3.0.0",
            program = "/colony_command.lua",
        },
        supply = {
            version = "3.0.6",
            program = "/colony_supply.lua",
        },
    },

    files = {
        { path = "/startup.lua",             app = "common" },
        { path = "/colony/manifest.lua",     app = "common" },
        { path = "/colony/lib/util.lua",     app = "common" },
        { path = "/colony/lib/ui.lua",       app = "common" },
        { path = "/colony/lib/version.lua",  app = "common" },
        { path = "/colony/lib/updater.lua",  app = "common" },
        { path = "/colony_command.lua",      app = "command" },
        { path = "/colony/command/visitor_jobs.lua", app = "command" },
        { path = "/colony_supply.lua",       app = "supply" },
        { path = "/colony/supply/config.lua",   app = "supply" },
        { path = "/colony/supply/state.lua",    app = "supply" },
        { path = "/colony/supply/cluster.lua",  app = "supply" },
        { path = "/colony/supply/matcher.lua",  app = "supply" },
        { path = "/colony/supply/transfer.lua", app = "supply" },
        { path = "/colony/supply/engine.lua",   app = "supply" },
        { path = "/colony/supply/ui.lua",       app = "supply" },
    },
}
