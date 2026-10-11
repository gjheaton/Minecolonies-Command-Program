"""Exercise the downloadable CC installer against an in-memory computer.

Run with Python + Lupa's Lua 5.2 runtime, for example:
PYTHONPATH=/workspace/.onboarding/python python3 -m unittest discover -s tests
"""
from pathlib import Path
import re
import unittest

from lupa.lua52 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install_colony.lua").read_text()
CURRENT_VERSION = re.search(r'suiteVersion = "([^"]+)"', INSTALLER).group(1)
_major, _minor, _patch = map(int, CURRENT_VERSION.split("."))
NEXT_VERSION = f"{_major}.{_minor}.{_patch + 1}"
LATER_VERSION = f"{_major}.{_minor}.{_patch + 2}"
PREVIOUS_INSTALLER = (ROOT / "tests/fixtures/installer_4_0_metadata.lua").read_text()
RELEASE_4_0_1_INSTALLER = (ROOT / "tests/fixtures/installer_4_0_1_metadata.lua").read_text()
RELEASE_4_0_1_COMMIT = "4c4e408b3e77ce06c6bc5a073acc4c2e336d77fa"
SOURCE = "https://raw.githubusercontent.com/gjheaton/Minecolonies-Command-Program/supply-master-colony/install_colony.lua"
PINNED = "https://raw.githubusercontent.com/gjheaton/Minecolonies-Command-Program/" + "a" * 40 + "/install_colony.lua"
RELEASE_4_0_1_SOURCE = SOURCE.replace("supply-master-colony", RELEASE_4_0_1_COMMIT)

MOCK = r'''
FILES, DIRS, OUTPUT, HTTP_LOG = {}, { ["/"] = true }, {}, {}
FREE_SPACE = 10000000
local function normal(path)
    path = tostring(path)
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    path = path:gsub("/+", "/"):gsub("/$", "")
    return path ~= "" and path or "/"
end
local function within(path, root) return path == root or path:sub(1, #root + 1) == root .. "/" end
local function mkdir(path)
    path = normal(path)
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then mkdir(parent) end
    DIRS[path] = true
end
function put(path, body)
    path = normal(path)
    mkdir(path:match("^(.*)/[^/]+$") or "/")
    FILES[path] = body
end
fs = {
    exists = function(path) path = normal(path); return FILES[path] ~= nil or DIRS[path] == true end,
    isDir = function(path) return DIRS[normal(path)] == true end,
    getDir = function(path) return normal(path):match("^(.*)/[^/]+$") or "/" end,
    makeDir = mkdir,
    getFreeSpace = function() return FREE_SPACE end,
    getSize = function(path) return #(FILES[normal(path)] or "") end,
}
fs.delete = function(path)
    path = normal(path)
    for name in pairs(FILES) do if within(name, path) then FILES[name] = nil end end
    for name in pairs(DIRS) do if within(name, path) then DIRS[name] = nil end end
end
fs.move = function(source, dest)
    source, dest = normal(source), normal(dest)
    if FAIL_COPY == dest then
        FAIL_COPY = nil
        error("injected package write failure: " .. dest)
    end
    if FAIL_RECOVERY and source:match("^/%.colony_install_transaction/old/") then
        error("injected recovery failure")
    end
    assert(fs.exists(source), "missing move source " .. source)
    assert(not fs.exists(dest), "move destination exists " .. dest)
    local parent = normal(fs.getDir(dest))
    assert(DIRS[parent], "missing move parent " .. parent)
    local movedFiles, movedDirs = {}, {}
    for name, body in pairs(FILES) do
        if within(name, source) then movedFiles[dest .. name:sub(#source + 1)] = body end
    end
    for name in pairs(DIRS) do
        if within(name, source) then movedDirs[dest .. name:sub(#source + 1)] = true end
    end
    fs.delete(source)
    for name, body in pairs(movedFiles) do FILES[name] = body end
    for name in pairs(movedDirs) do DIRS[name] = true end
end
fs.copy = function(source, dest)
    source, dest = normal(source), normal(dest)
    if FAIL_COPY == dest then
        FAIL_COPY = nil
        error("injected copy failure: " .. dest)
    end
    assert(FILES[source] ~= nil, "missing copy source " .. source)
    assert(not fs.exists(dest), "copy destination exists " .. dest)
    assert(DIRS[normal(fs.getDir(dest))], "missing copy parent " .. dest)
    FILES[dest] = FILES[source]
end
fs.open = function(path, mode)
    path = normal(path)
    if mode == "r" then
        if FILES[path] == nil then return nil, "not found" end
        return { readAll = function() return FILES[path] end, close = function() end }
    end
    assert(mode == "w", "unexpected open mode " .. mode)
    assert(DIRS[normal(fs.getDir(path))], "missing write parent " .. path)
    FILES[path] = ""
    return { write = function(body) FILES[path] = FILES[path] .. body end, close = function() end }
end
local function serialize(value)
    if type(value) == "table" then
        local parts = {}
        for key, item in pairs(value) do parts[#parts + 1] = "[" .. serialize(key) .. "]=" .. serialize(item) end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    elseif type(value) == "string" then return string.format("%q", value)
    else return tostring(value) end
end
textutils = {
    serialize = serialize,
    unserialize = function(body)
        local chunk = load("return " .. body, "table", "t", {})
        return chunk and chunk() or nil
    end,
    unserializeJSON = function(body)
        if body == "commit response" then return { object = { type = "commit", sha = string.rep("a", 40) } } end
        return nil
    end,
}
http = {
    get = function(url)
        HTTP_LOG[#HTTP_LOG + 1] = url
        if url:match("^https://api%.github%.com/") then
            if API_FAILURE then return nil, "API blocked" end
            return { readAll = function() return "commit response" end, close = function() end }
        end
        local reference,remote = url:match("^https://raw%.githubusercontent%.com/[^/]+/[^/]+/([^/]+)/(.+)$")
        if FAIL_DOWNLOAD == remote then return nil, "injected download failure" end
        local files=(REMOTE_REVISIONS and REMOTE_REVISIONS[reference]) or REMOTE_FILES
        local body = remote and files[remote]
        if not body then return nil, "unknown remote " .. tostring(remote) end
        return { readAll = function() return body end, close = function() end }
    end,
}
term = { isColor = function() return false end, setBackgroundColor = function() end,
    clear = function() end, setCursorPos = function() end }
colors = { black = 32768, white = 1, red = 16384, yellow = 16, lime = 32, cyan = 512 }
print = function(...) local parts = {}; for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end; OUTPUT[#OUTPUT+1] = table.concat(parts, " ") end
write = function() end
read = function() return CONFIRM or "CLEAN" end
sleep = function() end
os.reboot = function() REBOOTED = true end
function runInstaller(...)
    local chunk, err = load(SUITE_SOURCE, "@install_colony.lua", "t", _G)
    assert(chunk, err)
    return chunk(...)
end
function seedLegacy()
    put("/colony/app.cfg", textutils.serialize({ app="supply", role="supply", suiteVersion="3.0.33", suiteSourceUrl=SOURCE_URL }))
    put("/colony/supply_v3_state.txt", "old request records")
    put("/colony/supply_v3.log", "old log")
    put("/colony/lib/util.lua", "old utility")
    put("/colony_supply_state.txt", "legacy state")
    put("/colony_supply_state.txt.bak", "legacy backup")
    put("/colony_supply.log", "legacy log")
    put("/colony_requests_debug.txt", "legacy debug")
    put("/colony_supply.lua", "old supply program")
    put("/startup.lua", "-- MineColonies Control Suite generic startup launcher\n")
    put("/install_colony.lua", "old installer")
    put("/my_other_program.lua", "unrelated")
end
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCK)
        self.g = self.lua.globals()
        self.g.SUITE_SOURCE = INSTALLER
        self.g.SOURCE_URL = SOURCE
        loader = self.lua.eval('function(body) local c,e=load(body,"installer","t",{}); assert(c,e); return c("--metadata") end')
        self.info = loader(INSTALLER)
        files = {}
        for entry in self.info.files.values():
            path = ROOT / entry.remote
            # Isolate installer transaction behavior while other roles are
            # being implemented. The manifest test below separately requires
            # every advertised real package file to exist and compile.
            files[entry.remote] = path.read_text() if path.exists() else "return {}\n"
        self.g.REMOTE_FILES = self.lua.table_from(files)

    def snapshot(self):
        return dict(self.g.FILES.items())

    def install(self, role="master", source=SOURCE):
        return self.g.runInstaller("--install", role, source)

    def seed_v4(self, role="master"):
        self.install(role)
        self.lua.execute('''
            put("/colony/network.cfg", "custom network settings")
            put("/colony/master_state.cfg", "durable outstanding transfers")
            put("/my_other_program.lua", "unrelated")
            local cfg = textutils.unserialize(FILES["/colony/app.cfg"])
            cfg.customExtension = "keep this"
            put("/colony/app.cfg", textutils.serialize(cfg))
        ''')

    def seed_previous_v4(self, role="master"):
        """Seed prior 4.0.0 prototype metadata and persisted schema-4 data."""
        loader = self.lua.eval('function(body) local c,e=load(body,"old installer","t",{}); assert(c,e); return c("--metadata") end')
        previous = loader(PREVIOUS_INSTALLER)
        self.assertEqual(previous.suiteVersion, "4.0.0")
        self.g.PREVIOUS_INFO = previous
        self.g.PREVIOUS_INSTALLER = PREVIOUS_INSTALLER
        self.g.SEED_ROLE = role
        self.lua.execute('''
            for _, entry in ipairs(PREVIOUS_INFO.files) do
                if entry.app == "common" or entry.app == SEED_ROLE or entry.app == "network" then
                    put(entry.path, "-- MineColonies Control Suite 4.0.0 managed file\\nreturn {}\\n")
                end
            end
            put("/install_colony.lua", PREVIOUS_INSTALLER)
            local app = PREVIOUS_INFO.apps[SEED_ROLE]
            put("/colony/app.cfg", textutils.serialize({schema=4,installationSchema=4,role=SEED_ROLE,
                app=SEED_ROLE,program=app.program,displayName=app.displayName,appVersion=app.version,
                suiteVersion=PREVIOUS_INFO.suiteVersion,suiteSourceUrl=SOURCE_URL,customExtension="keep this"}))
            put("/colony/network.cfg", textutils.serialize({schema=4,role=SEED_ROLE,
                monitorName="monitor_legacy",monitorTextScale=.5,masterId=9,autoCraftEnabled=false,
                colonies={{id=17,label="Original colony",deliveryChest="delivery_17",returnChest="returns_17",
                    deliveryChannel="red/blue/green",returnChannel="yellow/white/black",
                    overrides={onHandTimeoutSeconds=180}}}}))
            put("/colony/"..SEED_ROLE.."_v4_state.a", textutils.serialize({schema=4,revision=8,
                requests={one={id="persistent_request",status="in progress",delivered=12}},history={},errors={}}))
            put("/colony/"..SEED_ROLE.."_v4_state.b", textutils.serialize({schema=4,revision=9,
                requests={one={id="persistent_request",status="in progress",delivered=16}},history={},errors={}}))
            put("/my_other_program.lua", "unrelated")
        ''')
        self.assertIsNone(self.g.FILES["/colony/network/telemetry.lua"])
        self.assertIsNone(self.g.FILES["/colony/network/displays.lua"])

    def seed_release_4_0_1(self, role="master"):
        """Seed the authentic deployed 4.0.1 package metadata and schema-4 data."""
        loader = self.lua.eval('function(body) local c,e=load(body,"4.0.1 installer","t",{}); assert(c,e); return c("--metadata") end')
        previous = loader(RELEASE_4_0_1_INSTALLER)
        self.assertEqual(previous.suiteVersion, "4.0.1")
        self.g.RELEASE_INFO = previous
        self.g.RELEASE_INSTALLER = RELEASE_4_0_1_INSTALLER
        self.g.RELEASE_SOURCE = RELEASE_4_0_1_SOURCE
        self.g.SEED_ROLE = role
        self.lua.execute('''
            for _,entry in ipairs(RELEASE_INFO.files) do
                if entry.app=="common" or entry.app==SEED_ROLE or entry.app=="network" then
                    put(entry.path,"-- MineColonies Control Suite 4.0.1 managed file\\nreturn {}\\n")
                end
            end
            put("/install_colony.lua",RELEASE_INSTALLER)
            local app=RELEASE_INFO.apps[SEED_ROLE]
            put("/colony/app.cfg",textutils.serialize({schema=4,installationSchema=4,role=SEED_ROLE,
                app=SEED_ROLE,program=app.program,displayName=app.displayName,appVersion=app.version,
                suiteVersion=RELEASE_INFO.suiteVersion,suiteSourceUrl=SOURCE_URL,
                installedSourceUrl=RELEASE_SOURCE,customExtension="keep this"}))
            put("/colony/network.cfg",textutils.serialize({schema=4,role=SEED_ROLE,
                automationEnabled=false,masterId=1,monitorName="monitor_stardust",monitorTextScale=.5,
                deliveryChestName="delivery_4",returnChestName="returns_4",colonyBridgeName="crs_4",
                colonyIntegratorName="integrator_4",deliveryChannel="red-pink-white",
                returnChannel="red-pink-black",autoCraftEnabled=false,
                colonies={{id=4,label="Stardust",deliveryChest="delivery_4",returnChest="returns_4",
                    deliveryChannel="red-pink-white",returnChannel="red-pink-black",
                    overrides={onHandTimeoutSeconds=180}}}}))
            for index,suffix in ipairs({".a",".b"}) do
                put("/colony/"..SEED_ROLE.."_v4_state"..suffix,
                    textutils.serialize({schema=4,revision=7+index,history={},errors={}}))
            end
            put("/my_other_program.lua","unrelated")
        ''')

    def seed_held_transfers(self, role):
        """Add transfer safety state whose bytes must survive a package update."""
        self.g.SEED_ROLE = role
        self.g.SEED_MATCHER_SOURCE = (ROOT / "colony/supply/matcher.lua").read_text()
        self.lua.execute('''
            local matcher=assert(load(SEED_MATCHER_SOURCE,"matcher","t",_G))().new(
                {equipmentAllowedNamespaces={minecraft=true}}, {})
            local path="/colony/"..SEED_ROLE.."_v4_state"
            for _, suffix in ipairs({".a", ".b"}) do
                local journal=textutils.unserialize(FILES[path..suffix])
                journal.history={{kind="OPERATOR_BIND_EXPORT",context={shipmentId="shipment-27"}}}
                journal.errors={{code="TRANSFER_VERIFY",message="Held transfer must survive update"}}
                local fingerprint=string.rep("a",32)
                local physical={name="minecraft:shears",nbt=string.rep("b",32)}
                local item={name=physical.name,nbt=physical.nbt,fingerprint=fingerprint}
                local request={id="request-28",name="Shears",count=1,items={{name=item.name}}}
                local shipment={id="shipment-27",requestId=request.id,generation=1,item=item,
                    count=1,imported=0,verified=true,createdAt=90,session="master-1",turn=12}
                if SEED_ROLE=="master" then
                    local source={name=item.name,nbt={Damage=0},fingerprint=fingerprint}
                    local previous={id="shipment-27",requestId="request-27",generation=1,
                        item={name="minecraft:stone"},count=3,imported=0,verified=true,
                        createdAt=80,session="master-1",turn=11}
                    journal.master={sessionCounter=1,turnCounter=12,shipmentCounter=27,colonyCursor=0,
                        pendingTransfer={kind="export",colonyId=4,requestId=request.id,generation=1,
                            chest="delivery_4",item=source,candidate=matcher.requestCandidates(request)[1],
                            variant={name=source.name,nbt=source.nbt,fingerprint=fingerprint,amount=8},
                            count=1,before=0,reported=1,session="master-1",turn=12,startedAt=90,
                            verifySeconds=5,pollSeconds=.25,uncertain=true,lastDelta=0},
                        quarantine={code="TRANSFER_VERIFY",message="Held physical identity mismatch",
                            context={colonyId=4,requestId=request.id,item=item.name,expected=1,reported=1}},
                        colonies={["4"]={id=4,routeConfirmed=true,requestCursor=0,
                            requests={[request.id]={id=request.id,generation=1,requested=1,status="error",
                                errorCode="PRS_QUARANTINE",request=request,
                                signature=matcher.itemIdentity(request.items[1]),createdAt=90},
                                [previous.requestId]={id=previous.requestId,generation=1,requested=3,
                                    status="in progress",request={id=previous.requestId,count=3,
                                        items={{name="minecraft:stone"}}},createdAt=80}},
                            shipments={previous}}},
                        craftJobs={["minecraft:bread|NBT|"]={identity="minecraft:bread|NBT|",
                            item={name="minecraft:bread"},count=64,baseline=0,exported=12,proven=12,
                            createdAt=70,nextPollAt=105,timeoutSeconds=600,pollSeconds=15,
                            stableReadsRequired=2,state="crafting",colonyId=4,requestId="request-26"}}}
                else
                    journal.client={intent={kind="import",shipmentId=shipment.id,item=item,
                        chest="delivery_4",count=1,beforeChest=1,beforeImported=0,startedAt=90,
                        session="master-1",turn=12,uncertain=true},
                        fault={code="IMPORT_UNCERTAIN",message="Held import needs reconciliation",time=90},
                        shipments={[shipment.id]=shipment},
                        returnSelectors={[matcher.itemIdentity(physical)]={item=physical,fingerprint=fingerprint}},
                        requests={[request.id]={id=request.id,request=request,status="in progress"}},
                        session="master-1",turn={turn=12,phase="preparing",session="master-1"},
                        retiredSessions={},seenTurns={["12"]=true},cursor=0}
                end
                put(path..suffix,textutils.serialize(journal))
            end
        ''')

    def test_metadata_is_safe_and_every_packaged_file_compiles(self):
        manifest = self.lua.eval('function(body) local c,e=load(body,"manifest","t",{}); assert(c,e); return c() end')(
            (ROOT / "colony/manifest.lua").read_text()
        )
        self.assertEqual(self.info.suiteVersion, manifest.suiteVersion)
        self.assertEqual(self.info.installationSchema, 4)
        self.assertEqual(self.info.apps.command.version, "3.0.7")
        self.assertEqual(self.info.components.ui, "1.1.0")
        self.assertEqual(self.info.installerVersion, CURRENT_VERSION)
        self.assertEqual(self.info.apps.master.version, CURRENT_VERSION)
        self.assertEqual(self.info.apps.supply.version, CURRENT_VERSION)
        self.assertEqual(self.info.components.network, CURRENT_VERSION)
        self.assertEqual(self.info.components.installer, CURRENT_VERSION)
        config = self.lua.eval('function(body) local c,e=load(body,"config","t",{ipairs=ipairs}); assert(c,e); return c() end')(
            (ROOT / "colony/network/config.lua").read_text()
        )
        self.assertEqual(config.VERSION, CURRENT_VERSION)
        command_source = (ROOT / "colony_command.lua").read_text()
        self.assertEqual(re.search(r'local SUITE_VERSION = "([^"]+)"', command_source).group(1), CURRENT_VERSION)
        self.assertEqual(re.search(r'local PROGRAM_VERSION = "([^"]+)"', command_source).group(1), self.info.apps.command.version)
        for app_id, app in self.info.apps.items():
            self.assertEqual(app.version, manifest.apps[app_id].version)
        for component_id, version in self.info.components.items():
            self.assertEqual(version, manifest.components[component_id])
        self.assertEqual(len(self.info.files), len(manifest.files))
        for i in range(1, len(self.info.files) + 1):
            entry = self.info.files[i]
            self.assertEqual(entry.path, manifest.files[i].path)
            self.assertEqual(entry.app, manifest.files[i].app)
            path = ROOT / entry.remote
            self.assertTrue(path.is_file(), f"Missing advertised package file: {entry.remote}")
            self.lua.eval('function(body,name) local c,e=load(body,name,"t",{}); assert(c,e) end')(path.read_text(), entry.remote)

    def test_help_needs_no_filesystem_http_or_terminal_and_lists_prefixed_options(self):
        lines, result = self.lua.eval('''function(body)
            local lines={}
            local chunk,err=load(body,"installer help","t",{print=function(line) lines[#lines+1]=line end})
            assert(chunk,err)
            local result=chunk("--help")
            return lines,result
        end''')(INSTALLER)
        self.assertTrue(result)
        output="\n".join(lines.values())
        for option in ("--install", "--update", "--repair", "--recover", "--metadata", "--help"):
            self.assertIn(option, output)
        self.assertIn("removes previous suite data", output)
        self.assertIn("preserve data", output)
        self.assertIn(CURRENT_VERSION, output)

    def test_clean_migration_removes_legacy_suite_data_only(self):
        self.g.seedLegacy()
        self.assertTrue(self.install())
        for path in ("/colony/supply_v3_state.txt", "/colony/supply_v3.log", "/colony_supply_state.txt",
                     "/colony_supply_state.txt.bak", "/colony_supply.log", "/colony_requests_debug.txt", "/colony_supply.lua"):
            self.assertIsNone(self.g.FILES[path], path)
        self.assertEqual(self.g.FILES["/my_other_program.lua"], "unrelated")
        cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
        self.assertEqual(cfg.role, "master")
        self.assertEqual(cfg.installationSchema, 4)
        self.assertEqual(cfg.suiteSourceUrl, SOURCE)
        self.assertEqual(cfg.installedSourceUrl, PINNED)
        self.assertFalse(self.g.fs.exists("/.colony_install_transaction"))
        self.assertIsNotNone(self.g.FILES["/colony/network/diagnostics.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/telemetry.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/displays.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/setup.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/setup_ui.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/devices.lua"])
        self.assertIsNone(self.g.FILES["/colony/network/client.lua"])
        for url in self.g.HTTP_LOG.values():
            if url.startswith("https://raw.githubusercontent.com/"):
                self.assertIn("/" + "a" * 40 + "/", url)

    def test_command_and_supply_packages_include_role_dependencies(self):
        self.assertTrue(self.install("command"))
        self.assertIsNotNone(self.g.FILES["/colony/command/visitor_jobs.lua"])
        self.assertIsNone(self.g.FILES["/colony/network/client.lua"])
        self.assertIsNone(self.g.FILES["/colony/network/setup.lua"])
        self.assertIsNone(self.g.FILES["/colony/network/setup_ui.lua"])
        self.assertIsNone(self.g.FILES["/colony/network/devices.lua"])
        self.assertTrue(self.install("supply"))
        self.assertIsNotNone(self.g.FILES["/colony/network/client.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/telemetry.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/displays.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/setup.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/setup_ui.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/network/devices.lua"])
        self.assertIsNotNone(self.g.FILES["/colony/supply/matcher.lua"])
        self.assertIsNone(self.g.FILES["/colony/network/master.lua"])
        self.assertIsNone(self.g.FILES["/colony_command.lua"])

    def test_default_clean_migration_does_not_follow_legacy_main_source(self):
        self.g.seedLegacy()
        self.lua.execute('''
            local cfg = textutils.unserialize(FILES["/colony/app.cfg"])
            cfg.suiteSourceUrl = "https://raw.githubusercontent.com/gjheaton/Minecolonies-Command-Program/main/install_colony.lua"
            put("/colony/app.cfg", textutils.serialize(cfg))
        ''')
        self.assertTrue(self.g.runInstaller("--install", "master"))
        self.assertIn("https://api.github.com/repos/gjheaton/Minecolonies-Command-Program/git/ref/heads/supply-master-colony",
                      list(self.g.HTTP_LOG.values()))

    def test_cancelled_clean_install_preserves_every_file(self):
        self.g.seedLegacy()
        before = self.snapshot()
        self.g.CONFIRM = "no"
        with self.assertRaisesRegex(Exception, "cancelled"):
            self.install()
        self.assertEqual(self.snapshot(), before)

    def test_download_failure_preserves_every_file(self):
        self.g.seedLegacy()
        before = self.snapshot()
        self.g.FAIL_DOWNLOAD = "colony/network/master.lua"
        with self.assertRaisesRegex(Exception, "Download failed"):
            self.install()
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.g.fs.exists("/.colony_install_transaction"))

    def test_invalid_lua_preserves_every_file(self):
        self.g.seedLegacy()
        before = self.snapshot()
        self.g.REMOTE_FILES["colony/network/master.lua"] = "this is invalid lua !"
        with self.assertRaisesRegex(Exception, "Syntax error"):
            self.install()
        self.assertEqual(self.snapshot(), before)

    def test_manifest_mismatch_preserves_every_file(self):
        self.g.seedLegacy()
        before = self.snapshot()
        body = self.g.REMOTE_FILES["colony/manifest.lua"]
        self.g.REMOTE_FILES["colony/manifest.lua"] = body.replace(f'suiteVersion = "{CURRENT_VERSION}"', 'suiteVersion = "9.0.0"')
        with self.assertRaisesRegex(Exception, "metadata disagree"):
            self.install()
        self.assertEqual(self.snapshot(), before)

    def test_failed_copy_restores_previous_programs_and_all_cleaned_data(self):
        self.g.seedLegacy()
        before = self.snapshot()
        self.g.FAIL_COPY = "/colony/network/master.lua"
        with self.assertRaisesRegex(Exception, "previous installation was restored"):
            self.install()
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.g.fs.exists("/.colony_install_transaction"))

    def test_durable_recovery_can_resume_after_recovery_was_interrupted(self):
        self.g.seedLegacy()
        before = self.snapshot()
        self.g.FAIL_COPY = "/colony/network/master.lua"
        self.g.FAIL_RECOVERY = True
        with self.assertRaisesRegex(Exception, "recovery requires running"):
            self.install()
        self.assertTrue(self.g.fs.exists("/.colony_install_transaction/plan.cfg"))
        self.g.FAIL_RECOVERY = False
        self.assertTrue(self.g.runInstaller("--recover"))
        self.assertEqual(self.snapshot(), before)

    def test_update_and_repair_preserve_settings_state_and_extension_data(self):
        self.seed_v4()
        self.assertTrue(self.g.runInstaller("--update", "master", SOURCE))
        self.assertTrue(self.g.runInstaller("--repair", SOURCE))
        self.assertEqual(self.g.FILES["/colony/network.cfg"], "custom network settings")
        self.assertEqual(self.g.FILES["/colony/master_state.cfg"], "durable outstanding transfers")
        self.assertEqual(self.g.FILES["/my_other_program.lua"], "unrelated")
        cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
        self.assertEqual(cfg.customExtension, "keep this")

    def test_same_version_repair_restores_setup_dependencies_for_both_supply_roles(self):
        for role in ("master", "supply"):
            with self.subTest(role=role):
                self.setUp()
                self.seed_v4(role)
                for path in ("/colony/network/setup.lua", "/colony/network/setup_ui.lua", "/colony/network/devices.lua"):
                    self.g.fs.delete(path)
                before = self.snapshot()
                self.g.CONFIRM = "do not clean"
                self.assertTrue(self.g.runInstaller("--repair", SOURCE))
                for remote in ("colony/network/setup.lua", "colony/network/setup_ui.lua", "colony/network/devices.lua"):
                    self.assertEqual(self.g.FILES["/" + remote], self.g.REMOTE_FILES[remote])
                for path in ("/colony/network.cfg", "/colony/master_state.cfg", "/my_other_program.lua"):
                    self.assertEqual(self.g.FILES[path], before[path], path)
                cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
                self.assertEqual(cfg.appVersion, CURRENT_VERSION)
                self.assertEqual(cfg.role, role)
                self.assertEqual(cfg.customExtension, "keep this")

    def test_failed_update_restores_code_and_preserves_state(self):
        self.seed_v4()
        before = self.snapshot()
        self.g.FAIL_COPY = "/colony/network/master.lua"
        with self.assertRaisesRegex(Exception, "previous installation was restored"):
            self.g.runInstaller("--update", "master", SOURCE)
        self.assertEqual(self.snapshot(), before)

    def test_prior_v4_update_adds_new_modules_and_preserves_configuration_and_journal(self):
        for role in ("master", "supply"):
            with self.subTest(role=role):
                self.setUp()
                self.seed_previous_v4(role)
                self.seed_held_transfers(role)
                before = self.snapshot()
                # Updates must proceed without destructive confirmation.
                self.g.CONFIRM = "do not clean"
                self.assertTrue(self.g.runInstaller("--update", role, SOURCE))
                for path in ("/colony/network.cfg", f"/colony/{role}_v4_state.a", f"/colony/{role}_v4_state.b"):
                    self.assertEqual(self.g.FILES[path], before[path], path)
                cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
                self.assertEqual(cfg.appVersion, CURRENT_VERSION)
                self.assertEqual(cfg.suiteVersion, CURRENT_VERSION)
                self.assertEqual(cfg.installationSchema, 4)
                self.assertEqual(cfg.customExtension, "keep this")
                self.assertIsNotNone(self.g.FILES["/colony/network/telemetry.lua"])
                self.assertIsNotNone(self.g.FILES["/colony/network/displays.lua"])
                self.assertIsNotNone(self.g.FILES["/colony/network/setup.lua"])
                self.assertIsNotNone(self.g.FILES["/colony/network/setup_ui.lua"])
                self.assertIsNotNone(self.g.FILES["/colony/network/devices.lua"])
                self.assertEqual(self.g.FILES["/my_other_program.lua"], "unrelated")

    def test_4_0_1_patch_update_preserves_held_journals_and_moving_source(self):
        for role in ("master", "supply"):
            with self.subTest(role=role):
                self.setUp()
                self.seed_release_4_0_1(role)
                self.seed_held_transfers(role)
                before = self.snapshot()
                self.g.CONFIRM = "do not clean"
                self.assertTrue(self.g.runInstaller("--update", role))
                for path in ("/colony/network.cfg", f"/colony/{role}_v4_state.a", f"/colony/{role}_v4_state.b"):
                    self.assertEqual(self.g.FILES[path], before[path], path)
                cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
                self.assertEqual(cfg.appVersion, CURRENT_VERSION)
                self.assertEqual(cfg.suiteVersion, CURRENT_VERSION)
                self.assertEqual(cfg.suiteSourceUrl, SOURCE)
                self.assertEqual(cfg.installedSourceUrl, PINNED)
                self.assertNotEqual(cfg.installedSourceUrl, RELEASE_4_0_1_SOURCE)
                self.assertEqual(cfg.customExtension, "keep this")
                self.assertEqual(cfg.role, role)
                self.assertEqual(cfg.installationSchema, 4)

    def test_failed_prior_v4_update_restores_old_package_and_journal(self):
        self.seed_previous_v4()
        before = self.snapshot()
        self.g.FAIL_COPY = "/colony/network/master.lua"
        with self.assertRaisesRegex(Exception, "previous installation was restored"):
            self.g.runInstaller("--update", "master", SOURCE)
        self.assertEqual(self.snapshot(), before)
        self.assertIsNone(self.g.FILES["/colony/network/telemetry.lua"])
        self.assertIsNone(self.g.FILES["/colony/network/displays.lua"])

    def test_legacy_or_different_role_cannot_use_update(self):
        self.g.seedLegacy()
        before = self.snapshot()
        with self.assertRaisesRegex(Exception, "clean migration"):
            self.g.runInstaller("--update", "supply", SOURCE)
        self.assertEqual(self.snapshot(), before)
        self.seed_v4()
        before = self.snapshot()
        with self.assertRaisesRegex(Exception, "same role"):
            self.g.runInstaller("--update", "supply", SOURCE)
        self.assertEqual(self.snapshot(), before)

    def test_api_failure_requires_immutable_url_without_modifying_install(self):
        self.g.seedLegacy()
        before = self.snapshot()
        self.g.API_FAILURE = True
        with self.assertRaisesRegex(Exception, "full 40-character commit SHA"):
            self.install()
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(self.install(source=PINNED))
        cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
        self.assertEqual(cfg.suiteSourceUrl, PINNED)
        self.assertEqual(cfg.installedSourceUrl, PINNED)

    def test_low_disk_space_and_unrelated_startup_are_preserved(self):
        self.g.seedLegacy()
        before = self.snapshot()
        self.g.FREE_SPACE = 1
        with self.assertRaisesRegex(Exception, "Not enough free space"):
            self.install()
        self.assertEqual(self.snapshot(), before)
        self.g.FREE_SPACE = 10000000
        self.g.put("/startup.lua", "print('another application')")
        before = self.snapshot()
        with self.assertRaisesRegex(Exception, "belongs to another program"):
            self.install()
        self.assertEqual(self.snapshot(), before)

    def test_unrecognized_transaction_directory_is_not_deleted(self):
        self.g.put("/.colony_install_transaction/personal.txt", "unrelated")
        before = self.snapshot()
        with self.assertRaisesRegex(Exception, "Unrecognized"):
            self.g.runInstaller("--recover")
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
