local UpvalueHacker = GLOBAL.require("tools/upvaluehacker")
local debug = GLOBAL.debug
local select = GLOBAL.select
local KEY_TOGGLE = GetModConfigData("TOGGLE_KEY")
local CONTINUOUS_MUSIC = GetModConfigData("continous")
local ENABLE_BUSY_MUSIC = GetModConfigData("enable_busy_music")
local ENABLE_DANGER_MUSIC = GetModConfigData("enable_danger_music")
local _danger_music_playing = false

-- Oh the hoops you have to jump through to modify local functions
-- It's basically lua debug hacker dark magic --KoreanWaffles

AddComponentPostInit("dynamicmusic", function(self)

    --Public
    local inst = self.inst

    --Private
    local _iscave = inst:HasTag("cave")
    local _isenabled = nil
    local _isday = nil
    local _isdusk = nil
    local _isnight = nil
    local _soundemitter = nil
    local _activatedplayer = nil
    local _hasinspirationbuff = nil
    
    -- New variables for continuous music
    local _continuous_music_task = nil
    local _current_ambient_music = nil
	local _phase_grace_period_active = false
    local _grace_period_task = nil

    local source = "scripts/components/dynamicmusic.lua"
    local _OnPlayerActivated
    for i, func in ipairs(inst.event_listeners["playeractivated"][inst]) do
        -- We can find the correct func by the function's source since the
        -- event listeners likely won't have two different events of the same source
        if GLOBAL.debug.getinfo(func, "S").source == source then
            _OnPlayerActivated = inst.event_listeners["playeractivated"][inst][i]
            break
        end
    end

    -- Note: I would recommend trying to avoid getting upvalues from start/stop danger/busy 
    -- as those are the most commonly wrapped functions
    local _StartPlayerListeners = UpvalueHacker.GetUpvalue(_OnPlayerActivated, "StartPlayerListeners")

    local _StartBusy = UpvalueHacker.GetUpvalue(_StartPlayerListeners, "StartBusy")
    local _StartDanger = UpvalueHacker.GetUpvalue(_StartPlayerListeners, "OnAttacked", "StartDanger")
    local _StartTriggeredDanger = UpvalueHacker.GetUpvalue(_StartPlayerListeners, "StartTriggeredDanger")
    local _StartBusyTheme = UpvalueHacker.GetUpvalue(_StartPlayerListeners, "StartFarming", "StartBusyTheme")
    -- since tables are mutable there is no need to reget this upvalue
    local BUSYTHEMES = UpvalueHacker.GetUpvalue(_StartPlayerListeners, "StartFarming", "BUSYTHEMES")
    local ALTERNATE_BUSYTHEMES = {
		FOREST = -1,
		CAVE = -2,
		RUINS = -3,
		LUNARISLAND = -4,
		FOREST_DUSK = -5,
		FOREST_NIGHT = -6,
	}

    local _StopSoundEmitter = UpvalueHacker.GetUpvalue(_OnPlayerActivated, "StopSoundEmitter")

    local _StopDanger = UpvalueHacker.GetUpvalue(_StopSoundEmitter, "StopDanger")
    local _StopBusy = UpvalueHacker.GetUpvalue(_StopSoundEmitter, "StopBusy")

    if not (_StartBusy and _StopBusy and _StartDanger and _StartTriggeredDanger and _StopDanger and _StartBusyTheme and BUSYTHEMES) then
        return
    end

    -- Optimization
    local _, i_busytask = UpvalueHacker.GetUpvalue(_StartBusyTheme, "_busytask")
    local _, i_extendtime = UpvalueHacker.GetUpvalue(_StartBusyTheme, "_extendtime")
    local _, i_dangertask = UpvalueHacker.GetUpvalue(_StartBusyTheme, "_dangertask")
    local _, i_pirates_near = UpvalueHacker.GetUpvalue(_StartBusyTheme, "_pirates_near")
	
    local _, i_triggeredlevel = UpvalueHacker.GetUpvalue(_StartTriggeredDanger, "_triggeredlevel")

    local get_busytask = function() return select(2, debug.getupvalue(_StartBusyTheme, i_busytask)) end
    local get_dangertask = function() return select(2, debug.getupvalue(_StartBusyTheme, i_dangertask)) end
    local get_pirates_near = function() return select(2, debug.getupvalue(_StartBusyTheme, i_pirates_near)) end

    local set_extendtime = function(time) debug.setupvalue(_StartBusyTheme, i_extendtime, time) end
    local set_dangertask = function(task) debug.setupvalue(_StartBusyTheme, i_dangertask, task) end
    local set_triggeredlevel = function(level) debug.setupvalue(_StartTriggeredDanger, i_triggeredlevel, level) end
	
	if not (_StartBusy and _StopBusy and _StartDanger and _StartTriggeredDanger and _StopDanger and _StartBusyTheme and BUSYTHEMES) then
		return
	end

	-- Now wrap _StopDanger after validation
	local _StopDanger_Original = _StopDanger
	local function StopDanger_Safe(...)
		_danger_music_playing = false
		return _StopDanger_Original(...)
	end
	_StopDanger = StopDanger_Safe
	UpvalueHacker.SetUpvalue(_StopSoundEmitter, StopDanger_Safe, "StopDanger")
	
    --------------------------------------------------------------------------------------------------

	local SEASON_BUSY_MUSIC_ALTERNATE =
	{
		autumn = "remade/Autumn/Day",
		winter = "remade/Winter/Day",
		spring = "remade/Spring/Day",
		summer = "remade/Summer/Day",
	}
	local RUINS_BUSY_MUSIC_ALTERNATE = "remade/Ruins/Day"
	local CAVE_BUSY_MUSIC_ALTERNATE = "remade/Caves/Day"
	--local LUNARISLAND_BUSY_MUSIC_ALTERNATE = "farming/music/farming"
	
	local SEASON_EPICFIGHT_MUSIC_ALTERNATE =
	{
		autumn = "remade/Autumn/Boss",
		winter = "remade/Winter/Boss",
		spring = "remade/Spring/Boss",
		summer = "remade/Summer/Boss",
	}

	local SEASON_DANGER_MUSIC_ALTERNATE =
	{
		autumn = "remade/Autumn/Fight",
		winter = "remade/Winter/Fight",
		spring = "remade/Spring/Fight",
		summer = "remade/Summer/Fight",
	}
	
	local SEASON_DUSK_MUSIC_ALTERNATE =	
	{
		autumn = "remade/Autumn/Dusk",
		winter = "remade/Winter/Dusk",
		spring = "remade/Spring/Dusk",
		summer = "remade/Summer/Dusk",
	}
	
	local SEASON_NIGHT_MUSIC_ALTERNATE =
	{
		autumn = "remade/Autumn/Night",
		winter = "remade/Winter/Night",
		spring = "remade/Spring/Night",
		summer = "remade/Summer/Night",
	}
	

	
	--local RUINS_EPICFIGHT_MUSIC_ALTERNATE = "dontstarve/music/music_pigking_minigame"
	local RUINS_DANGER_MUSIC_ALTERNATE = "remade/Ruins/Fight"
	
	--local CAVE_EPICFIGHT_MUSIC_ALTERNATE = "monkeyisland/warning_music/warning_combo"
	local CAVE_DANGER_MUSIC_ALTERNATE = "remade/Caves/Fight"

	local function IsInRuins(player)
		return player.components.areaaware ~= nil
			and player.components.areaaware:CurrentlyInTag("Nightmare")
	end

	local function IsOnLunarIsland(player)
		return player.components.areaaware ~= nil
			and player.components.areaaware:CurrentlyInTag("lunacyarea")
	end
	
    local function IsInHoodedForest(player)
        return player.components.areaaware ~= nil
            and player.components.areaaware:CurrentlyInTag("hoodedcanopy")
    end

    -- continuous music goes here
    local function GetContinuousBusyMusic(player, ...)
		-- Check if busy music is disabled - if so, don't play custom music at all
		if not ENABLE_BUSY_MUSIC then
			return _StartBusy(player, ...)
		end
		
		if math.random() > 0.5 or TUNING.RAMPAGE_MUSIC_CONFIG then
			if _iscave then
				if IsInRuins(player) then
					return RUINS_BUSY_MUSIC_ALTERNATE
				else
					return CAVE_BUSY_MUSIC_ALTERNATE
				end
			else
				if IsInHoodedForest(player) or IsOnLunarIsland(player) then
					-- vanilla music for special areas
					return nil
				else
					if TUNING.RAMPAGE_DUSKNIGHT_CONFIG and _isdusk then
						return SEASON_DUSK_MUSIC_ALTERNATE[inst.state.season]
					elseif TUNING.RAMPAGE_DUSKNIGHT_CONFIG and _isnight then
						return SEASON_NIGHT_MUSIC_ALTERNATE[inst.state.season]
					else
						return SEASON_BUSY_MUSIC_ALTERNATE[inst.state.season]
					end
				end
			end
		else
			return _StartBusy(player, ...)
		end
	end
		

	-- fucking work THIS TIME / force script to use both modded and vanilla music for continuous busy
	local function StartContinuousBusyMusic(player, ...)
		if not ENABLE_BUSY_MUSIC then
			return _StartBusy(player, ...)
		end
		
		if _phase_grace_period_active then
			return
		end
		
		if not CONTINUOUS_MUSIC or not _isenabled or not _soundemitter then
			return
		end
		
		-- FIX: Check _danger_music_playing in addition to dangertask
		if get_dangertask() ~= nil or _danger_music_playing then
			return
		end
		
		if get_busytask() ~= nil then
			return
		end
		
		-- vanilla music paths
		local VANILLA_SEASON_BUSY_MUSIC = {
			autumn = "dontstarve/music/music_work",
			winter = "dontstarve/music/music_work_winter",
			spring = "dontstarve_DLC001/music/music_work_spring",
			summer = "dontstarve_DLC001/music/music_work_summer",
		}
		local VANILLA_CAVE_BUSY_MUSIC = "dontstarve/music/music_work_cave"
		local VANILLA_RUINS_BUSY_MUSIC = "dontstarve/music/music_work_ruins"
		
		-- determine if it should use modded or vanilla music
		local use_modded_music = (math.random() <= 0.5) or TUNING.RAMPAGE_MUSIC_CONFIG
		
		if get_pirates_near() == nil then
			if _iscave then
				if IsInRuins(player) then
					if use_modded_music then
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.RUINS, RUINS_BUSY_MUSIC_ALTERNATE, 999)
					else
						-- Use vanilla ruins music with extended duration
						_StartBusyTheme(player, BUSYTHEMES.RUINS, VANILLA_RUINS_BUSY_MUSIC, 999)
					end
				else
					if use_modded_music then
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.CAVE, CAVE_BUSY_MUSIC_ALTERNATE, 999)
					else
						-- Use vanilla cave music with extended duration
						_StartBusyTheme(player, BUSYTHEMES.CAVE, VANILLA_CAVE_BUSY_MUSIC, 999)
					end
				end
			elseif GLOBAL.TheWorld:HasTag("forest") then
				if IsInHoodedForest(player) or IsOnLunarIsland(player) then
					-- Don't override special area music
					return
				else
					-- Use appropriate music for time of day
					if TUNING.RAMPAGE_DUSKNIGHT_CONFIG and _isdusk then
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.FOREST_DUSK, SEASON_DUSK_MUSIC_ALTERNATE[inst.state.season], 999)
					elseif TUNING.RAMPAGE_DUSKNIGHT_CONFIG and _isnight then
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.FOREST_NIGHT, SEASON_NIGHT_MUSIC_ALTERNATE[inst.state.season], 999)
					else
						if use_modded_music then
							_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.FOREST, SEASON_BUSY_MUSIC_ALTERNATE[inst.state.season], 999)
						else
							-- Use vanilla forest music with extended duration (seasonal)
							_StartBusyTheme(player, BUSYTHEMES.FOREST, VANILLA_SEASON_BUSY_MUSIC[inst.state.season], 999)
						end
					end
				end
			end
		end
	end

    -- shut up
    local function StopContinuousMusic()
        if CONTINUOUS_MUSIC then
            _StopBusy() -- Use the proper stop function
        end
        if _continuous_music_task then
            _continuous_music_task:Cancel()
            _continuous_music_task = nil
        end
    end

    -- NEW STUFF - Schedule continuous music check
	local function ScheduleContinuousMusic(player)
		if CONTINUOUS_MUSIC and _isenabled and GLOBAL.TheWorld:HasTag("forest") and ENABLE_BUSY_MUSIC then
			if _continuous_music_task then
				_continuous_music_task:Cancel()
			end
			-- FIX I HOPE: don't start if danger music is playing
			-- start immediately only if safe to do so
			if not _danger_music_playing and get_dangertask() == nil then
				StartContinuousBusyMusic(player)
			end
			-- Then set up periodic task to maintain it
			_continuous_music_task = inst:DoPeriodicTask(5, function()
				-- FIX: Check _danger_music_playing flag in addition to dangertask
				if get_busytask() == nil and get_dangertask() == nil and not _danger_music_playing then
					StartContinuousBusyMusic(player)
				end
			end)
		end
	end

    local function StartBusy(player, ...)
        -- do not start work music if continuous mode is playing already
        if CONTINUOUS_MUSIC then
            -- original function maintains proper busy state tracking / the continuous system handles the actual music
            return _StartBusy(player, ...)
        end
		
		        -- don't start music if grace period is active
        if _phase_grace_period_active then
            return
        end
        
        -- original contextual behavior when continuous mode is off
        if math.random() > 0.5 or TUNING.RAMPAGE_MUSIC_CONFIG then
            if not (_iscave or _isday or TUNING.RAMPAGE_DUSKNIGHT_CONFIG) then
                return
            elseif get_busytask() ~= nil then
                set_extendtime(GLOBAL.GetTime() + 15)
			elseif get_dangertask() == nil and get_pirates_near() == nil then
				if _iscave then
					-- Check if busy music is disabled for caves
					if not ENABLE_BUSY_MUSIC then
						return _StartBusy(player, ...)
					end
					
					if IsInRuins(player) then
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.RUINS, RUINS_BUSY_MUSIC_ALTERNATE, 15)
					else
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.CAVE, CAVE_BUSY_MUSIC_ALTERNATE, 15)
					end
				elseif GLOBAL.TheWorld:HasTag("forest") then
					if IsInHoodedForest(player) then
						return _StartBusy(player, ...)
					elseif IsOnLunarIsland(player) then
						--_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.LUNARISLAND, LUNARISLAND_BUSY_MUSIC_ALTERNATE, 15)
						return _StartBusy(player, ...)
					else
						-- dusk and night tracks should ALWAYS play (not affected by busy music toggle)
						if TUNING.RAMPAGE_DUSKNIGHT_CONFIG and _isdusk then
							_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.FOREST_DUSK, SEASON_DUSK_MUSIC_ALTERNATE[inst.state.season], 15)
						elseif TUNING.RAMPAGE_DUSKNIGHT_CONFIG and _isnight then
							_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.FOREST_NIGHT, SEASON_NIGHT_MUSIC_ALTERNATE[inst.state.season], 15)
						else
							-- Only check busy music toggle for DAY music
							if not ENABLE_BUSY_MUSIC then
								return _StartBusy(player, ...)
							end
							_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.FOREST, SEASON_BUSY_MUSIC_ALTERNATE[inst.state.season], 15)
						end
					end
				end
			else
				return _StartBusy(player, ...)
            end
        else
            return _StartBusy(player, ...)
        end
    end

    local EPIC_TAGS = { "epic" }
    local NO_EPIC_TAGS = { "noepicmusic" }
	
	local function StartDanger(player, ...)
		-- If danger music is disabled, use vanilla behavior
		if not ENABLE_DANGER_MUSIC then
			return _StartDanger(player, ...)
		end

		-- Don't start danger music during phase grace period
		if _phase_grace_period_active then
			return
		end

		-- Stop continuous music when danger starts
		if CONTINUOUS_MUSIC then
			StopContinuousMusic()
		end

		-- Custom danger music logic
		if math.random() > 0.5 or TUNING.RAMPAGE_MUSIC_CONFIG then
			if get_dangertask() ~= nil then
				-- Extend danger music duration without restarting
				get_dangertask():Cancel()
				set_dangertask(inst:DoTaskInTime(15, function()
					_StopDanger(true)
					_danger_music_playing = false
					if CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC then
						inst:DoTaskInTime(1, function()
							ScheduleContinuousMusic(_activatedplayer)
						end)
					end
				end))
				return
			elseif _isenabled and not GLOBAL.TheWorld:HasOneOfTags({"island","volcano","porkland"}) then
				local x, y, z = player.Transform:GetWorldPosition()
				local epics = TheSim:FindEntities(x, y, z, 30, EPIC_TAGS, NO_EPIC_TAGS)

				_StopBusy()

				if not _danger_music_playing then
					_soundemitter:PlaySound(
						#epics > 0 and (
							(IsInRuins(player) and RUINS_EPICFIGHT_MUSIC_ALTERNATE) or
							(_iscave and CAVE_EPICFIGHT_MUSIC_ALTERNATE) or
							(SEASON_EPICFIGHT_MUSIC_ALTERNATE[inst.state.season])
						) or (
							(IsInRuins(player) and RUINS_DANGER_MUSIC_ALTERNATE) or
							(_iscave and CAVE_DANGER_MUSIC_ALTERNATE) or
							(SEASON_DANGER_MUSIC_ALTERNATE[inst.state.season])
						),
						"danger"
					)
					_danger_music_playing = true
				end

				set_dangertask(inst:DoTaskInTime(12, function()
					_StopDanger(true)
					_danger_music_playing = false
					if CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC then
						inst:DoTaskInTime(1, function()
							ScheduleContinuousMusic(_activatedplayer)
						end)
					end
				end))

				set_triggeredlevel(nil)
				set_extendtime(0)

				if _hasinspirationbuff then
					_soundemitter:SetParameter("danger", "wathgrithr_intensity", _hasinspirationbuff)
				end
			else
				return _StartDanger(player, ...)
			end
		else
			return _StartDanger(player, ...)
		end
	end

    -- All that just to modify one function ಠ_ಠ
    UpvalueHacker.SetUpvalue(_StartPlayerListeners, StartBusy, "StartBusy")
    UpvalueHacker.SetUpvalue(_StartPlayerListeners, StartDanger, "OnAttacked", "StartDanger")

    --------------------------------------------------------------------------------------------------

    local function RA_OnHasInspirationBuff(player, data)
        _hasinspirationbuff = (data ~= nil and data.on) and 1 or 0
    end

    local function RA_OnPhase(inst, phase)
        _isday = phase == "day"
        _isdusk = phase == "dusk"
        _isnight = phase == "night"
		
        -- Activate grace period to let stingers play
        _phase_grace_period_active = true
        if _grace_period_task then
            _grace_period_task:Cancel()
        end
	_grace_period_task = inst:DoTaskInTime(10, function()
		_phase_grace_period_active = false
		_grace_period_task = nil
		
		-- FIX: Don't resume if danger music is active
		if CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC 
		   and not _danger_music_playing and get_dangertask() == nil then
			ScheduleContinuousMusic(_activatedplayer)
		end
	end)
        
		if TUNING.RAMPAGE_DUSKNIGHT_CONFIG then
			if get_dangertask() ~= nil or not _isenabled then
				return
			end
			--Don't want to play overlapping stingers
			local time
			if get_busytask() == nil and i_extendtime ~= 0 then
				time = GLOBAL.GetTime()
				if time < i_extendtime then
					return
				end
			end
			if _isnight then
				_soundemitter:PlaySound("dontstarve/sanity/creature2/idle")
			else
				return
			end
			_StopBusy()
			--Repurpose this as a delay before stingers or busy can start again
			set_extendtime((time or GLOBAL.GetTime()) + 15)
		end
    end

    local function RA_StartPlayerListeners(player)
        inst:ListenForEvent("hasinspirationbuff", RA_OnHasInspirationBuff, player)
    end

    local function RA_StopPlayerListeners(player)
        inst:RemoveEventCallback("hasinspirationbuff", RA_OnHasInspirationBuff, player)
    end

    local function RA_StartSoundEmitter()
        if _soundemitter == nil then
            _soundemitter = GLOBAL.TheFocalPoint.SoundEmitter
            if not _iscave then
                _isday = inst.state.isday
                _isdusk = inst.state.isdusk
                _isnight = inst.state.isnight
                inst:WatchWorldState("phase", RA_OnPhase)
            end
        end
    end

	local function RA_StopSoundEmitter()
		if _soundemitter ~= nil then
			-- debugging output
			print("RA_StopSoundEmitter called")
            
            -- silence now
            StopContinuousMusic()

			-- dusk and night music won't play if they are off (duh)
			if GLOBAL.TUNING.RAMPAGE_DUSKNIGHT_CONFIG and (_isdusk or _isnight) then
				print("Stopping dusk/night music")
				_soundemitter:KillSound("busy")
			end

			inst:StopWatchingWorldState("phase", RA_OnPhase)
			_soundemitter = nil
			_hasinspirationbuff = nil
		end
	end
	
	local function RA_OnPlayerActivated(_inst, player)
		if _activatedplayer == player then
			return
		elseif _activatedplayer ~= nil and _activatedplayer.entity:IsValid() then
			RA_StopPlayerListeners(_activatedplayer)
		end

		_activatedplayer = player
		RA_StopSoundEmitter()
		RA_StartSoundEmitter()
		RA_StartPlayerListeners(player)

		-- start continuous music if enabled (and busy music is enabled)
		if CONTINUOUS_MUSIC and ENABLE_BUSY_MUSIC then
			inst:DoTaskInTime(1, function()
				ScheduleContinuousMusic(player)
			end)

			-- periodic watchdog to ensure music keeps playing
			inst:DoPeriodicTask(15, function()
				-- FIX: Check _danger_music_playing flag
				if _isenabled and _activatedplayer and get_busytask() == nil 
				   and get_dangertask() == nil and not _danger_music_playing then
					print("[RAMPAGE] Watchdog: Resuming busy music")
					StartContinuousBusyMusic(_activatedplayer)
				end
			end)
		end
	end

    local function RA_OnPlayerDeactivated(_inst, player)
        RA_StopPlayerListeners(player)
        if player == _activatedplayer then
            _activatedplayer = nil
            RA_StopSoundEmitter()
        end
    end

    local function RA_OnEnableDynamicMusic(_inst, enable)
        _isenabled = enable
        
        if enable and CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC then
            ScheduleContinuousMusic(_activatedplayer)
        elseif not enable then
            StopContinuousMusic()
        end
    end

	_isenabled = self.enabled == true
    inst:ListenForEvent("playeractivated", RA_OnPlayerActivated)
    inst:ListenForEvent("playerdeactivated", RA_OnPlayerDeactivated)
    inst:ListenForEvent("enabledynamicmusic", RA_OnEnableDynamicMusic)
end)

-- PAUSE MUSIC BUTTON --

AddSimPostInit(function()
	GLOBAL.TheInput:AddKeyDownHandler(KEY_TOGGLE, function()
		local player = GLOBAL.ThePlayer  -- Local shorthand for easier access
		if player then
			local soundEmitter = GLOBAL.TheFocalPoint.SoundEmitter
			if soundEmitter then
				soundEmitter:KillSound("busy") -- Stop the current "busy" music channel
					
				-- check if the player has the 'talker' component before calling Say
				if player.components.talker then
                    -- List of possible messages
                    local messages = {
                        "Music goes off. Enjoy some quiet time!",
                        "Silence falls over the dusk.",
                        "No more tunes for now.",
                        "The melody takes a break.",
                        "Hushed music echoes in the distance."
                    }
                    -- Select a random message
                    local random_message = messages[math.random(#messages)]
                    player.components.talker:Say(random_message)
                else
					print("Error: Player does not have a 'talker' component.")
				end
			end
		end
	end)  -- end of AddKeyDownHandler function
end)  -- end of AddSimPostInit function

-- INSIDIOUS LURKER COMPATIBILITY --

if not GLOBAL.KnownModIndex:IsModEnabled("workshop-3554727934") then
    return
end
	
AddPlayerPostInit(function(inst)
	inst:DoPeriodicTask(0.5, function()
--		print ("insidious lurker enabled")
		local player = GLOBAL.ThePlayer 
		if player and inst:HasTag("horror_fog_client") then
			local soundEmitter = GLOBAL.TheFocalPoint.SoundEmitter
			if soundEmitter then
				soundEmitter:KillSound("busy")
				soundEmitter:KillSound("danger")
		--		print("horror_fog_client on player → enforce silence")
		--	else
		--		print("no soundemitter")
			end
--		else
--			print("horror_fog_client not on player → music")
		end
	end)
end)