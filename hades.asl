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
	// Credits: Doom asl I found
	vars.ReadOffset = (Func<Process, IntPtr, int, int, IntPtr>)((proc, ptr, offsetSize, remainingBytes) =>
	{
		byte[] offsetBytes;
		if (ptr == IntPtr.Zero || !proc.ReadBytes(ptr, offsetSize, out offsetBytes))
			return IntPtr.Zero;
		return ptr + offsetSize + remainingBytes + BitConverter.ToInt32(offsetBytes, 0);
	});

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

	vars.screen_manager = ExtensionMethods.ReadPointer(game, vars.app + 0x3B0); // This might change, but unlikely. We can add signature scanning for this offset if it does. -> F3 44 0F 11 40 ? 49 8B 8F ? ? ? ?
	vars.current_player = ExtensionMethods.ReadPointer(game, ExtensionMethods.ReadPointer(game, vars.playermanager + 0x18));

	vars.current_block_count = ExtensionMethods.ReadValue<int>(game, vars.current_player + 0x50);

	/* Misc. vars */
	vars.split = 0;
	vars.current_run_time = "0:0.1";
	vars.current_map = "";
	vars.old_total_seconds = 0.1;
	vars.current_total_seconds = 0.1;
	vars.boss_killed = false;
	vars.has_beat_hades = false;
	vars.exit_to_hades = false;
	vars.totalSplits = 5;
}

update
{
	IntPtr hash_table = ExtensionMethods.ReadPointer(game, vars.current_player + 0x40);
	for(int i = 0; i < 4; i++)
	{
		IntPtr block = ExtensionMethods.ReadPointer(game, hash_table + 0x8 * i);

		if(block == IntPtr.Zero)
			continue;

		var block_name = ExtensionMethods.ReadString(game, block, 32); // Guessing on size

		var block_string = "";
		
		if (block_name != null)
			block_string = block_name.ToString();

		if (block_string == "HarpyKillPresentation")
		{
			vars.boss_killed = true; // boss has been killed
		}
		if (block_string == "HadesKillPresentation") 
		{
			vars.has_beat_hades = true;
		}
		if (block_string == "ExitToHadesPresentation")
		{
			vars.exit_to_hades = true;
		}
	}

	/* Get our vector pointers, used to iterate through current screens */
    if(vars.screen_manager != IntPtr.Zero)
	{
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
	}
	

	/* Get our current run time */
	if(vars.game_ui != IntPtr.Zero)
	{
		IntPtr runtime_component = ExtensionMethods.ReadPointer(game, vars.game_ui + 0x518); // Possible to change if they adjust the UI class
		if(runtime_component != IntPtr.Zero)
		{
			/* This might break if the run goes over 99 minutes T_T */
			vars.old_run_time = vars.current_run_time;
			vars.current_run_time = ExtensionMethods.ReadString(game, ExtensionMethods.ReadPointer(game, runtime_component + 0xA98), 0x8); // Can possibly change. -> 48 8D 8E ? ? ? ? 48 8D 05 ? ? ? ? 4C 8B C0 66 0F 1F 44 00
			if(vars.current_run_time == "PauseScr")
			{
				vars.current_run_time = "0:0.1";
			}
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
	(float)(Convert.ToInt32(vars.time_split[0])) * 60 +
	(float)(Convert.ToInt32(vars.time_split[1])) +
	(float)(Convert.ToInt32(vars.time_split[2])) / 100;
}

start
{
	// Start the timer if in the first room and the old timer is greater than the new (memory address holds the value from the previous run)
	if (vars.current_map == "RoomOpening" && vars.old_total_seconds > vars.current_total_seconds)
	{
		vars.totalSplits = 5;
		vars.split = 0;
		vars.boss_killed = false;
		vars.exit_to_hades = false;
		return true;
	}
}

split
{
  // Credits: Museus
  // routed splitting (if setting selected), splits every room transition after start
  if (settings["routed"] && !(vars.current_map == vars.old_map))
  {
	  return true;
  }

  // Credits: cgull
  // resetting boss kill boolean, as sometimes it gets reset to true after splitting
  if (vars.boss_killed && vars.current_map != "A_Boss01" && vars.current_map != "A_Boss02" 
	  && vars.current_map != "A_Boss03" && vars.current_map != "B_Boss01" && vars.current_map != "B_Boss02"
	  && vars.current_map != "C_Boss01")
	  {
	  	vars.boss_killed = false;
	  }
  // multiwep house splits (if setting selected)
  if (settings["multiWep"] && settings["houseSplits"] && vars.current_map == "RoomOpening" && vars.old_total_seconds > vars.current_total_seconds && vars.split % vars.totalSplits == 0 && vars.split > 0)
  {
	  return true;
  }
  // biome splits (boss kill vs room transition)
  if (settings["splitOnBossKill"])
  {
	  // 1st split if in fury room and boss killed
	  if (((vars.current_map == "A_Boss01" || vars.current_map == "A_Boss02" || vars.current_map == "A_Boss03") && vars.boss_killed && vars.split % vars.totalSplits == 0)
	  	||
		// 2nd split if in lernie room and hydra killed
	    ((vars.current_map == "B_Boss01" || vars.current_map == "B_Boss02") && vars.boss_killed && vars.split % vars.totalSplits == 1)
		||
		// 3rd split if in heroes' arena and heroes are both killed 
		(vars.current_map == "C_Boss01" && vars.boss_killed && vars.split % vars.totalSplits == 2)
		||
		// 4th split if old map was the styx hub and the new room is the dad fight
		(vars.exit_to_hades && vars.current_map == "D_Hub" && vars.split % vars.totalSplits == 3)
		||
		// 5th and final split if Hades has been killed
		(vars.current_map == "D_Boss01" && vars.has_beat_hades && vars.split % vars.totalSplits == 4))
		{
			// increment splits, reset tracking variables
			vars.split++;
			vars.has_beat_hades = false;
			vars.boss_killed = false;
			vars.exit_to_hades = false;
			return true;
		}
  } 
  else 
  {
	// Credits: ellomenop
	// 1st Split if old map was one of the furies fights and new room is the Tartarus -> Asphodel mid biome room
	if (((vars.old_map == "A_Boss01" || vars.old_map == "A_Boss02" || vars.old_map == "A_Boss03") && vars.current_map == "A_PostBoss01" && vars.split % vars.totalSplits == 0)
		||
		// 2nd Split if old map was lernie (normal or EM2) and new room is the Asphodel -> Elysium mid biome room
		((vars.old_map == "B_Boss01" || vars.old_map == "B_Boss02") && vars.current_map == "B_PostBoss01" && vars.split % vars.totalSplits == 1)
		||
		// 3rd Split if old map was heroes and new room is the Elysium -> Styx mid biome room
		(vars.old_map == "C_Boss01" && vars.current_map == "C_PostBoss01" && vars.split % vars.totalSplits == 2)
		||
		// 4th Split if old map was the styx hub and new room is the dad fight
		(vars.old_map == "D_Hub" && vars.current_map == "D_Boss01" && vars.split % vars.totalSplits == 3)
		||
		// 5th and final split if we have beat dad
		(vars.current_map == "D_Boss01" && vars.has_beat_hades && vars.split % vars.totalSplits ==  4))
		{
		vars.split++;

		// Clear this flag so that its false for the next weapon in multi-weapon runs
		vars.has_beat_hades = false;
		vars.boss_killed = 0;
		return true;
		}
  }
}

reset
{
  // Reset and clear state if Zag is currently in the courtyard.  Don't reset in multiweapon runs
	if(vars.current_map == "RoomPreRun" && !settings["multiWep"])
	{
		/* Reset all of our dynamic variables. */
		vars.split = 0;
		vars.time_split = "0:0.1".Split(':', '.');
		vars.current_total_seconds = .1;
		vars.has_beat_hades = false;
		vars.boss_killed = 0;
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
	/* Nefarious! */
	return !ExtensionMethods.ReadValue<bool>(game, vars.world);
}
