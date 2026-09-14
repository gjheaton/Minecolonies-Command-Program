-- MineColonies Control Suite local manifest
-- Suite version: 1.1.27
return {
    suiteVersion = "1.1.27",
    repositoryLayout = "cc-mirror",

    components = {
        startup = "1.0.0",
        installer = "1.1.27",
        util = "1.1.0",
        ui = "1.1.0",
        version = "1.0.0",
        updater = "1.1.1",
    },

    apps = {
        command = {
            version = "2.16",
            program = "/colony_command.lua",
        },
        supply = {
            version = "2.62",
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
        { path = "/colony_supply.lua",       app = "supply" },
    },
}
