// Created by Sebastien S. (SystemFailu.re)

state("Hades")
{
	/*
		There's nothing here because I don't want to use static instance addresses..
		Please refer to `init` to see the signature scanning.
	*/
}

startup
{
// Credits: Doom asl I found
vars.ReadOffset = (Func<Process, IntPtr, int, int, IntPtr>)((proc, ptr, offsetSize, remainingBytes) =>
	{
		byte[] offsetBytes;
		if (ptr == IntPtr.Zero || !proc.ReadBytes(ptr, offsetSize, out offsetBytes))
			return IntPtr.Zero;
		return ptr + offsetSize + remainingBytes + BitConverter.ToInt32(offsetBytes, 0);
	});
}

init
{
	/* Do our signature scanning */

	var engine = modules.Single(x => String.Equals(x.ModuleName, "EngineWin64s.dll", StringComparison.OrdinalIgnoreCase));
	var app_sig_target = new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 74 0A"); // rip = 7
	var world_sig_target = new SigScanTarget(3, "48 89 05 ?? ?? ?? ?? 83 78 0C 00 7E 40");
	var playermanager_sig_target = new SigScanTarget(3, "4C 8B 05 ?? ?? ?? ?? 48 8B CB ");
	var signature_scanner = new SignatureScanner(game, engine.BaseAddress, engine.ModuleMemorySize);
	var app_sig_ptr = signature_scanner.Scan(app_sig_target);
	var world_sig_ptr = signature_scanner.Scan(world_sig_target);
	var playermanager_sig_ptr = signature_scanner.Scan(playermanager_sig_target);
	var app_ptr_ref = vars.ReadOffset(game, app_sig_ptr, 4, 0);
	var world_ptr_ref = vars.ReadOffset(game, world_sig_ptr, 4, 0);
	var playermanager_ptr_ref = vars.ReadOffset(game, playermanager_sig_ptr, 4, 0);
	vars.app = ExtensionMethods.ReadPointer(game, app_ptr_ref);
	vars.world = ExtensionMethods.ReadPointer(game, world_ptr_ref); // Just dereference ptr
	vars.playermanager = ExtensionMethods.ReadPointer(game, playermanager_ptr_ref);
	
	vars.screen_manager = ExtensionMethods.ReadPointer(game, vars.app + 0x3E0); // This might change, but unlikely. We can add signature scanning for this offset if it does. -> F3 44 0F 11 40 ? 49 8B 8F ? ? ? ?
	vars.current_player = ExtensionMethods.ReadPointer(game, ExtensionMethods.ReadPointer(game, vars.playermanager + 0x18));
	//print("Player: 0x" + vars.current_player.ToString("x"));

	vars.current_block_count = ExtensionMethods.ReadValue<int>(game, vars.current_player + 0x50);
	
	/* Misc. vars */
	vars.split = 0;
	vars.current_run_time = 0;
	vars.current_map = 0;
	vars.current_total_seconds = 0;
	vars.can_move_counter = 0;
	vars.has_beat_hades = false;
}

update
{
	int last_block_count = vars.current_block_count;
	vars.current_block_count = ExtensionMethods.ReadValue<int>(game, vars.current_player + 0x50);
	
	/* Check if hash table size has changed */
	if(last_block_count  != vars.current_block_count)
	{
		IntPtr hash_table = ExtensionMethods.ReadPointer(game, vars.current_player + 0x40);
		for(int i = 0; i < 2; i++)
		{
			IntPtr block = ExtensionMethods.ReadPointer(game, hash_table + 0x8 * i);
			if(block == IntPtr.Zero)
				continue;
			var block_name = ExtensionMethods.ReadString(game, block, 32); // Guessing on size
			if(block_name.ToString() == "HadesKillPresentation")
				vars.has_beat_hades = true; // Run has finished!
		}
	}

	/* Get our vector pointers, used to iterate through current screens */
	/* We might need to nullptr check these */
	IntPtr screen_vector_begin = ExtensionMethods.ReadPointer(game, vars.screen_manager + 0x48);
	IntPtr screen_vector_end = ExtensionMethods.ReadPointer(game, vars.screen_manager + 0x50);
	var num_screens = (screen_vector_end.ToInt64() - screen_vector_begin.ToInt64()) >> 3;
	for(int i = 0; i < num_screens; i++)
	{
		IntPtr current_screen = ExtensionMethods.ReadPointer(game, screen_vector_begin + 0x8 * i);
		if(current_screen == IntPtr.Zero)
			continue;
		IntPtr screen_vtable = ExtensionMethods.ReadPointer(game, current_screen); // Deref to get vtable
		IntPtr get_type_method = ExtensionMethods.ReadPointer(game, screen_vtable + 0x68); // Unlikely to change
		int screen_type = ExtensionMethods.ReadValue<int>(game,get_type_method + 0x1);
		if((screen_type & 0x7) == 7)
		{
			// We have found the InGameUI screen.
			vars.game_ui = current_screen;
			// Possibly stop loop once this has been found? Not sure if this pointer is destructed anytime.
		}
	}

	/* Get our current run time */
	if(vars.game_ui != IntPtr.Zero)
	{
		IntPtr runtime_component = ExtensionMethods.ReadPointer(game, vars.game_ui + 0x510); // Possible to change if they adjust the UI class
		if(runtime_component != IntPtr.Zero)
		{
			/* This might break if the run goes over 99 minutes T_T */
      vars.old_run_time = vars.current_run_time;
			vars.current_run_time = ExtensionMethods.ReadString(game, ExtensionMethods.ReadPointer(game, runtime_component + 0xAB8), 0x8); // Can possibly change. -> 48 8D 8E ? ? ? ? 48 8D 05 ? ? ? ? 4C 8B C0 66 0F 1F 44 00
			//print("Time: " + vars.current_run_time + ", Last: " + vars.old_run_time);
		}
	}

	/* Get our current map name */
	if(vars.world != IntPtr.Zero)
	{
		vars.is_running = ExtensionMethods.ReadValue<bool>(game, vars.world); // 0x0
		IntPtr map_data = ExtensionMethods.ReadPointer(game, vars.world + 0xA0); // Unlikely to change.
		if(map_data != IntPtr.Zero)
		{
      vars.old_map = vars.current_map;
			vars.current_map = ExtensionMethods.ReadString(game, map_data + 0x8, 0x10);
			//print("Map: " + vars.current_map + ", Last:" + vars.old_map);
		}
	}
	
	/* Unused for now */
	IntPtr player_unit = ExtensionMethods.ReadPointer(game, vars.current_player + 0x18);
	if(player_unit != IntPtr.Zero)
	{
		IntPtr unit_input = ExtensionMethods.ReadPointer(game, player_unit + 0x560); // Could change -> 48 8B 91 ? ? ? ? 88 42 08 
		
	}

  vars.old_total_seconds = vars.current_total_seconds;
  vars.time_split = vars.current_run_time.Split(':', '.');
  /* Convert the string time to singles */
  vars.current_total_seconds =
      Convert.ToSingle(vars.time_split[0]) * 60 +
      Convert.ToSingle(vars.time_split[1]) +
      Convert.ToSingle(vars.time_split[2]) / 100;
}

start
{
		return (vars.current_map == "RoomOpening" && vars.old_total_seconds > vars.current_total_seconds);
}

split
{
  // Credits: ellemonop
  if (((vars.old_map == "A_Boss01" || vars.old_map == "A_Boss02" || vars.old_map == "A_Boss03") && vars.current_map == "A_PostBoss01" && vars.split == 0)
     ||
     ((vars.old_map == "B_Boss01" || vars.old_map == "B_Boss02") && vars.current_map == "B_PostBoss01" && vars.split == 1)
     ||
     (vars.old_map == "C_Boss01" && vars.current_map == "C_PostBoss01" && vars.split == 2)
     ||
     (vars.old_map == "D_Hub" && vars.current_map == "D_Boss01" && vars.has_beat_hades && vars.split == 3))
    {
      vars.split++;
      return true;
    }
}

reset
{
	if(vars.current_map == "RoomPreRun")
	{
		vars.split = 0;
		vars.time_split = "0:0.0".Split(':', '.');
		vars.current_total_seconds = 0;
		vars.can_move_counter = 0;
		vars.has_beat_hades = false;
		return true;
	}
}

gameTime
{
  int h = Convert.ToInt32(vars.time_split[0]) / 60;
  int m = Convert.ToInt32(vars.time_split[0]) % 60;
  int s = Convert.ToInt32(vars.time_split[1]);
  int ms = Convert.ToInt32(vars.time_split[2] + "0");

  return new TimeSpan(0, h, m, s, ms);
}

isLoading
{
	/*
		Our player's `unit` is deleted upon level exit and recreated upon level enter,
		This can be considered our 'loading time'
	*/
	IntPtr player_unit = ExtensionMethods.ReadPointer(game, vars.current_player + 0x18);
	return player_unit != IntPtr.Zero;
	
	/*
		TODO: We now have the ability to track input blocks, we can add these to the checks.
	*/
}
