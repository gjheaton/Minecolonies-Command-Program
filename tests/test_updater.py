"""Verify shared updater staging, migration guards, and committed results."""
import unittest

import test_installer as installer_fixture

ROOT, INSTALLER, SOURCE, PINNED = (installer_fixture.ROOT, installer_fixture.INSTALLER,
                                 installer_fixture.SOURCE, installer_fixture.PINNED)
CURRENT_VERSION, NEXT_VERSION, LATER_VERSION = (installer_fixture.CURRENT_VERSION,
                                               installer_fixture.NEXT_VERSION, installer_fixture.LATER_VERSION)


class UpdaterTests(unittest.TestCase):
    # Reuse the virtual computer fixture without collecting its tests twice.
    snapshot = installer_fixture.InstallerTests.snapshot
    install = installer_fixture.InstallerTests.install
    seed_v4 = installer_fixture.InstallerTests.seed_v4
    seed_previous_v4 = installer_fixture.InstallerTests.seed_previous_v4

    def setUp(self):
        installer_fixture.InstallerTests.setUp(self)
        self.g.TEST_ROOT = str(ROOT)
        self.g.TEST_BASE_VERSION = CURRENT_VERSION
        self.g.TEST_NEXT_VERSION = NEXT_VERSION
        self.g.TEST_LATER_VERSION = LATER_VERSION
        self.lua.execute('package.path = TEST_ROOT .. "/?.lua;" .. TEST_ROOT .. "/?/init.lua;" .. package.path')
        self.lua.execute('''
            local originalGet = http.get
            http.get = function(url, headers) return originalGet((url:gsub("[?#].*$", "")), headers) end
            term.setTextColor = function() end
            local originalJSON = textutils.unserializeJSON
            textutils.unserializeJSON = function(body)
                local result = originalJSON(body)
                if result and COMMIT_CHAR then result.object.sha = string.rep(COMMIT_CHAR, 40) end
                return result
            end
            shell = { run = function(path, ...)
                SHELL_PATH = path
                SHELL_ARGUMENTS = {...}
                CANONICAL_BEFORE_RUN = FILES["/install_colony.lua"]
                if RUN_MODE == "false" then return false end
                if RUN_MODE == "throw" then error("injected shell failure") end
                if RUN_MODE == "cfg_only" then
                    local cfg = textutils.unserialize(FILES["/colony/app.cfg"])
                    cfg.appVersion, cfg.suiteVersion = TEST_NEXT_VERSION, TEST_NEXT_VERSION
                    put("/colony/app.cfg", textutils.serialize(cfg))
                    return true
                end
                if RUN_MODE == "advance_branch" then
                    local pattern = '"' .. TEST_NEXT_VERSION:gsub("%.", "%%.") .. '"'
                    REMOTE_FILES["install_colony.lua"] = REMOTE_FILES["install_colony.lua"]:gsub(pattern, '"' .. TEST_LATER_VERSION .. '"')
                    REMOTE_FILES["colony/manifest.lua"] = REMOTE_FILES["colony/manifest.lua"]:gsub(pattern, '"' .. TEST_LATER_VERSION .. '"')
                    COMMIT_CHAR = "b"
                end
                local chunk, err = load(FILES[path], "@" .. path, "t", _G)
                if not chunk then return false end
                -- CC shell.run ignores the Lua chunk's return value.
                local executed = pcall(chunk, ...)
                SHELL_SUCCEEDED = executed
                return executed
            end }
            Updater = require("colony.lib.updater")
            function makeUpdater(version, role)
                version, role = version or TEST_BASE_VERSION, role or "master"
                return Updater.new({appId=role,appVersion=version,suiteVersion=version,displayName="Supply Master"})
            end
        ''')

    def seed_update(self):
        self.seed_v4()
        self.current_installer = self.g.FILES["/install_colony.lua"]
        self.g.REMOTE_FILES["install_colony.lua"] = INSTALLER.replace(f'"{CURRENT_VERSION}"', f'"{NEXT_VERSION}"')
        self.g.REMOTE_FILES["colony/manifest.lua"] = (ROOT / "colony/manifest.lua").read_text().replace(f'"{CURRENT_VERSION}"', f'"{NEXT_VERSION}"')
        self.g.RUN_MODE = "real"
        return self.g.makeUpdater()

    def assert_no_reboot(self):
        self.assertFalse(bool(self.g.REBOOTED))
        self.assertFalse(self.g.fs.exists("/install_colony.lua.update_tmp"))

    def test_updater_download_failure_preserves_original_installer(self):
        updater = self.seed_update()
        before = self.snapshot()
        self.g.FAIL_DOWNLOAD = "install_colony.lua"
        self.assertFalse(updater.install())
        self.assertEqual(self.snapshot(), before)
        self.assert_no_reboot()
        self.assertIsNone(self.g.SHELL_PATH)

    def test_updater_package_download_failure_does_not_replace_installer(self):
        updater = self.seed_update()
        before = self.snapshot()
        self.g.FAIL_DOWNLOAD = "colony/network/master.lua"
        self.assertFalse(updater.install())
        self.assertEqual(self.g.CANONICAL_BEFORE_RUN, self.current_installer)
        self.assertEqual(self.snapshot(), before)
        self.assert_no_reboot()

    def test_updater_false_chunk_return_shell_success_requires_actual_install(self):
        updater = self.seed_update()
        before = self.snapshot()
        source = self.g.REMOTE_FILES["install_colony.lua"]
        self.g.REMOTE_FILES["install_colony.lua"] = source.replace(
            'if mode == "--metadata" then return SUITE_INFO end',
            'if mode == "--metadata" then return SUITE_INFO end\nif mode == "--update" then return false end'
        )
        self.assertFalse(updater.install())
        self.assertTrue(self.g.SHELL_SUCCEEDED)
        self.assertEqual(self.snapshot(), before)
        self.assert_no_reboot()

    def test_updater_verified_success_installs_new_canonical_and_reboots(self):
        updater = self.seed_update()
        self.assertEqual(self.g.Updater.COMPONENT_VERSION, "1.2.0")
        self.assertTrue(updater.install())
        self.assertEqual(self.g.SHELL_PATH, "/install_colony.lua.update_tmp")
        self.assertEqual(list(self.g.SHELL_ARGUMENTS.values()), ["--update", "master", SOURCE])
        self.assertEqual(self.g.CANONICAL_BEFORE_RUN, self.current_installer)
        cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
        self.assertEqual(cfg.appVersion, NEXT_VERSION)
        self.assertEqual(cfg.suiteVersion, NEXT_VERSION)
        self.assertEqual(cfg.installationSchema, 4)
        self.assertEqual(cfg.role, "master")
        self.assertEqual(cfg.installedSourceUrl, PINNED)
        self.assertEqual(self.g.FILES["/colony/network.cfg"], "custom network settings")
        self.assertEqual(self.g.FILES["/colony/master_state.cfg"], "durable outstanding transfers")
        self.assertTrue(self.g.REBOOTED)
        self.assertFalse(self.g.fs.exists("/install_colony.lua.update_tmp"))

    def test_updater_accepts_newer_committed_package_when_branch_advances(self):
        updater = self.seed_update()
        self.g.RUN_MODE = "advance_branch"
        self.assertTrue(updater.install())
        cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
        self.assertEqual(cfg.appVersion, LATER_VERSION)
        self.assertEqual(cfg.suiteVersion, LATER_VERSION)
        self.assertIn("/" + "b" * 40 + "/", cfg.installedSourceUrl)
        self.assertTrue(self.g.REBOOTED)

    def test_updater_rejects_cfg_only_success_without_committed_installer(self):
        updater = self.seed_update()
        self.g.RUN_MODE = "cfg_only"
        self.assertFalse(updater.install())
        self.assertEqual(self.g.FILES["/install_colony.lua"], self.current_installer)
        self.assert_no_reboot()

    def test_updater_legacy_installation_requires_clean_migration(self):
        self.g.seedLegacy()
        before = self.snapshot()
        self.g.REMOTE_FILES["install_colony.lua"] = INSTALLER.replace(f'"{CURRENT_VERSION}"', f'"{NEXT_VERSION}"')
        self.assertFalse(self.g.makeUpdater().install())
        self.assertEqual(self.snapshot(), before)
        self.assertIsNone(self.g.SHELL_PATH)
        self.assertTrue(any("CLEAN INSTALL REQUIRED" in line for line in self.g.OUTPUT.values()))
        self.assert_no_reboot()

    def test_updater_wrong_role_is_rejected_before_mutation(self):
        updater = self.seed_update()
        self.lua.execute('''
            local cfg = textutils.unserialize(FILES["/colony/app.cfg"])
            cfg.role = "supply"
            put("/colony/app.cfg", textutils.serialize(cfg))
        ''')
        before = self.snapshot()
        self.assertFalse(updater.install())
        self.assertEqual(self.snapshot(), before)
        self.assertIsNone(self.g.SHELL_PATH)
        self.assert_no_reboot()

    def test_updater_equal_version_prototype_reports_current_and_direct_repair_preserves_data(self):
        for role in ("master", "supply"):
            with self.subTest(role=role):
                self.setUp()
                self.seed_previous_v4(role)
                before = self.snapshot()
                self.g.CONFIRM = "do not clean"
                # Equal release versions do not advertise an automatic update.
                # An explicit same-version repair still refreshes package files.
                self.assertFalse(self.g.makeUpdater("4.0.0", role).install())
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(bool(self.g.REBOOTED))
                self.assertTrue(self.g.runInstaller("--repair", SOURCE))
                for path in ("/colony/network.cfg", f"/colony/{role}_v4_state.a", f"/colony/{role}_v4_state.b"):
                    self.assertEqual(self.g.FILES[path], before[path], path)
                cfg = self.g.textutils.unserialize(self.g.FILES["/colony/app.cfg"])
                self.assertEqual(cfg.appVersion, CURRENT_VERSION)
                self.assertEqual(cfg.suiteVersion, CURRENT_VERSION)
                self.assertEqual(cfg.installationSchema, 4)
                self.assertEqual(cfg.role, role)
                self.assertIsNotNone(self.g.FILES["/colony/network/telemetry.lua"])
                self.assertIsNotNone(self.g.FILES["/colony/network/displays.lua"])
                self.assertIsNotNone(self.g.FILES["/colony/network/setup.lua"])
                self.assertIsNotNone(self.g.FILES["/colony/network/setup_ui.lua"])
                self.assertIsNotNone(self.g.FILES["/colony/network/devices.lua"])
                self.assertFalse(bool(self.g.REBOOTED))
                self.assertFalse(self.g.fs.exists("/install_colony.lua.update_tmp"))

    def test_updater_does_not_delete_a_preexisting_temporary_file(self):
        updater = self.seed_update()
        self.g.put("/install_colony.lua.update_tmp", "personal file")
        before = self.snapshot()
        self.assertFalse(updater.install())
        self.assertEqual(self.snapshot(), before)
        self.assertIsNone(self.g.SHELL_PATH)
        self.assertFalse(bool(self.g.REBOOTED))

    def test_updater_low_space_has_no_destructive_fallback(self):
        updater = self.seed_update()
        before = self.snapshot()
        self.g.FREE_SPACE = 1
        self.assertFalse(updater.install())
        self.assertEqual(self.snapshot(), before)
        self.assertIsNone(self.g.SHELL_PATH)
        self.assert_no_reboot()

    def test_updater_shell_failure_preserves_installer_and_cleans_owned_temp(self):
        for mode in ("false", "throw"):
            with self.subTest(mode=mode):
                self.setUp()
                updater = self.seed_update()
                before = self.snapshot()
                self.g.RUN_MODE = mode
                self.assertFalse(updater.install())
                self.assertEqual(self.snapshot(), before)
                self.assert_no_reboot()


if __name__ == "__main__":
    unittest.main()
