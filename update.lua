-- MineColonies Control Suite quick updater.
-- Updates the currently installed role, then reboots only on success.

if not fs.exists("/install_colony.lua") then
    error("Missing /install_colony.lua",0)
end

print("Updating MineColonies Control Suite...")
local ok = shell.run("/install_colony.lua","--update")
if ok ~= true then
    print("Update failed; reboot cancelled.")
    return
end

print("Update complete. Rebooting...")
sleep(1)
os.reboot()
