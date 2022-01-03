/*
    Credits
        Sebastien S. (SystemFailu.re) : Creating main script, reversing engine.
        ellomenop : Doing splits, helping test & misc. bug fixes.
        Museus: Routed splitting
        cgull: House splits + splits on boss kill
*/

state("Hades")
{
    /*
        There's nothing here because I don't want to use static instance addresses..
        Please refer to `init` to see the signature scanning.
    */
}

startup
{
    settings.Add("multiWep", false, "Multi Weapon Run");
    settings.Add("houseSplits", false, "Use House Splits", "multiWep");
    settings.Add("splitOnBossKill", false, "Split on Boss Kills");
    settings.Add("routed", false, "Routed (per chamber)");
}

init
{
    /* Kind of hacky, this is used since it may take a second for the game to load our engine module */
    Thread.Sleep(2000);
    /* Do our signature scanning */
    var engine = modules.FirstOrDefault(x => x.ModuleName.StartsWith("EngineWin64s")); // DX = EngineWin64s.dll, VK = EngineWin64sv.dll
    var signature_scanner = new SignatureScanner(game, engine.BaseAddress, engine.ModuleMemorySize);

    var app_signature_target = new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 74 0A"); // rip = 7
    var world_signature_target = new SigScanTarget(3, "48 89 05 ?? ?? ?? ?? 83 78 0C 00 7E 40");
    var player_manager_signature_target = new SigScanTarget(3, "4C 8B 05 ?? ?? ?? ?? 48 8B CB");

    var signature_targets = new [] {
        app_signature_target,
        world_signature_target,
        player_manager_signature_target,
    };

    foreach (var target in signature_targets) {
        target.OnFound = (process, _, pointer) => process.ReadPointer(pointer + 0x4 + process.ReadValue<int>(pointer));
    }

    vars.app = signature_scanner.Scan(app_signature_target);
    vars.world = signature_scanner.Scan(world_signature_target);
    vars.player_manager = signature_scanner.Scan(player_manager_signature_target);

    vars.screen_manager = game.ReadPointer((IntPtr)vars.app + 0x3B0); // This might change, but unlikely. We can add signature scanning for this offset if it does. -> F3 44 0F 11 40 ? 49 8B 8F ? ? ? ?
    vars.current_player = game.ReadPointer(game.ReadPointer((IntPtr)vars.player_manager + 0x18));

    // vars.current_block_count = game.ReadValue<int>((IntPtr)vars.current_player + 0x50);

    current.run_time = "0:0.1";
    current.map = "";
    current.total_seconds = 0f;
}

update
{
    IntPtr hash_table = game.ReadPointer((IntPtr)vars.current_player + 0x40);
    for(int i = 0; i < 4; i++)
    {
        IntPtr block = game.ReadPointer(hash_table + 0x8 * i);
        if(block == IntPtr.Zero)
            continue;

        var block_name = game.ReadString(block, 32); // Guessing on size
        if (block_name == null)
            continue;

        // All bosses use same block string on kill
        if (block_name == "HarpyKillPresentation")
            vars.boss_killed = true;

        // Except Hades, that's a different one
        if (block_name == "HadesKillPresentation")
            vars.has_beat_hades = true;

        if (block_name == "ExitToHadesPresentation")
            vars.exit_to_hades = true;
    }

    /* Get our vector pointers, used to iterate through current screens */
    if (vars.screen_manager != IntPtr.Zero)
    {
        IntPtr screen_vector_begin = game.ReadPointer((IntPtr)vars.screen_manager + 0x48);
        IntPtr screen_vector_end = game.ReadPointer((IntPtr)vars.screen_manager + 0x50);

        // 64-bit IntPtr are 8 bytes each, so divide by 8 to get number of screens
        var num_screens = (screen_vector_end.ToInt64() - screen_vector_begin.ToInt64()) / 8;

        // Maybe only loop once to find game_ui, not sure if pointer is destructed anytime.
        for (int i = 0; i < num_screens; i++)
        {
            IntPtr current_screen = game.ReadPointer(screen_vector_begin + 0x8 * i);
            if (current_screen == IntPtr.Zero)
                continue;

            IntPtr screen_vtable = game.ReadPointer(current_screen); // Deref to get vtable
            IntPtr get_type_method = game.ReadPointer(screen_vtable + 0x68); // Unlikely to change

            int screen_type = game.ReadValue<int>(get_type_method + 0x1);

            if ((screen_type & 0x7) == 7) // We have found the InGameUI screen.
                vars.game_ui = current_screen;
        }
    }


    /* Get our current run time */
    if (vars.game_ui != IntPtr.Zero)
    {
        IntPtr runtime_component = game.ReadPointer((IntPtr)vars.game_ui + 0x518); // Possible to change if they adjust the UI class
        if (runtime_component != IntPtr.Zero)
        {
            /* This might break if the run goes over 99 minutes T_T */
            current.run_time = game.ReadString(game.ReadPointer(runtime_component + 0xA98), 0x8); // 48 8D 8E ? ? ? ? 48 8D 05 ? ? ? ? 4C 8B C0 66 0F 1F 44 00
            if (current.run_time == "PauseScr")
                current.run_time = "0:0.1";
        }
    }

    /* Get our current map name */
    if(vars.world != IntPtr.Zero)
    {
        IntPtr map_data = game.ReadPointer((IntPtr)vars.world + 0xA0); // Unlikely to change.
        if(map_data != IntPtr.Zero)
            current.map = game.ReadString(map_data + 0x8, 0x10);
    }

    /*
    Unused for now
    IntPtr player_unit = game.ReadPointer((IntPtr)vars.current_player + 0x18);

    if(player_unit != IntPtr.Zero)
        IntPtr unit_input = game.ReadPointer(player_unit + 0x560); // 48 8B 91 ? ? ? ? 88 42 08
    */

    vars.time_split = current.run_time.Split(':', '.');
    /* Convert the string time to singles */
    current.total_seconds =
        int.Parse(vars.time_split[0]) * 60 +
        int.Parse(vars.time_split[1]) +
        float.Parse(vars.time_split[2]) / 100;
    }

onStart
{
    current.map = "";
    current.total_seconds = 0.1;

    vars.boss_killed = false;
    vars.has_beat_hades = false;
    vars.exit_to_hades = false;

    vars.still_in_arena = false;
}

start
{
    // Start the timer if in the first room and the old timer is greater than the new (memory address holds the value from the previous run)
    if (current.map == "RoomOpening" && old.total_seconds > current.total_seconds)
        return true;
}

onSplit
{
    vars.boss_killed = false;
    vars.has_beat_hades = false;
    vars.exit_to_hades = false;

    // Disable boss kill detection until we leave the boss arena
    vars.still_in_arena = true;
}

split
{
    // Split on Hades Kill
    if (vars.has_beat_hades)
        return true;

    // Split on Boss Kill
    if (settings["splitOnBossKill"] && (vars.boss_killed || vars.exit_to_hades))
        return true;

    var starting_new_run = current.map == "RoomOpening" && old.total_seconds > current.total_seconds;
    // Split on run start if House Splits are enabled
    if (settings["multiWep"] && settings["houseSplits"] && starting_new_run)
        return true;

    var entered_new_room = current.map != old.map;
    // Split every chamber if Routed is enabled
    if (settings["routed"] && entered_new_room)
        return true;

    var in_postboss_room_or_hades_fight = current.map == "A_PostBoss01" || current.map == "B_PostBoss01" || current.map == "C_PostBoss01" || current.map == "D_Boss01";
    // Split on room transition
    if (!settings["splitOnBossKill"] && entered_new_room && in_postboss_room_or_hades_fight)
        return true;
}

onReset
{
    vars.time_split = "0:0.1".Split(':', '.');
    current.total_seconds = 0f;

    vars.has_beat_hades = false;
    vars.boss_killed = false;

    vars.still_in_arena = false;
}

reset
{
  // Reset and clear state if Zag is currently in the courtyard.  Don't reset in multiweapon runs
    if(current.map == "RoomPreRun" && !settings["multiWep"])
        return true;
}

gameTime
{
    int h = int.Parse(vars.time_split[0]) / 60;
    int m = int.Parse(vars.time_split[0]) % 60;
    int s = int.Parse(vars.time_split[1]);
    int ms = int.Parse(vars.time_split[2] + "0");

    return new TimeSpan(0, h, m, s, ms);
}

isLoading
{
    /*
    Because we just override the gameTime constantly with in-game timer, we
    don't need a fancy load sensor. For a Loadless RTA setting, this will need
    to be actually evaluated, but for now just pretend we are always loading.
    */
    return true;
}
