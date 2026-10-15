local UpvalueHacker = GLOBAL.require("tools/upvaluehacker")
local debug = GLOBAL.debug
local select = GLOBAL.select
local KEY_TOGGLE = GetModConfigData("TOGGLE_KEY")
local CONTINUOUS_MUSIC = GetModConfigData("continous")
local ENABLE_BUSY_MUSIC = GetModConfigData("enable_busy_music")
local ENABLE_DANGER_MUSIC = GetModConfigData("enable_danger_music")
local ENABLE_CELESTIAL_MUSIC = GetModConfigData("celestial_music")
if ENABLE_CELESTIAL_MUSIC == nil then
	ENABLE_CELESTIAL_MUSIC = true
end
local _danger_music_playing = false

-- god it was so tedious to fix
local RA_DEBUG = false
local _ra_music_paused = false
local RA_ResumeMusic = nil
local RA_PauseMusic = nil

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
	
	-- Celestial Champion state
	local _celestial_active = false
	local _celestial_current_phase = nil
	local _celestial_check_task = nil
	local _celestial_grace_task = nil
	local _celestial_ent = nil
	local _celestial_pending_phase = nil
	local _celestial_pending_count = 0
	local _celestial_unavailable = false
	local _celestial_verify_task = nil
	local _celestial_heal_attempts = 0

	local function RA_Say(msg)
		if not RA_DEBUG then
			return
		end
		print(msg)
		local player = GLOBAL.ThePlayer
		if player ~= nil and player.components.talker ~= nil then
			player.components.talker:Say(msg)
		end
	end

	-- Per-tick trace, log only, deduped so a steady state doesn't flood.
	local _ra_last_trace = nil
	local function RA_Trace(msg)
		if not RA_DEBUG or msg == _ra_last_trace then
			return
		end
		_ra_last_trace = msg
		print(msg)
	end

	local function RA_RefreshSoundEmitter()
		local current = GLOBAL.TheFocalPoint ~= nil and GLOBAL.TheFocalPoint.SoundEmitter or nil
		if current ~= nil and current ~= _soundemitter then
			RA_Say("[RA] sound emitter changed - resyncing")
			_soundemitter = current
			-- A verdict reached against the old emitter says nothing about this one.
			_celestial_unavailable = false
			_celestial_heal_attempts = 0
			_celestial_current_phase = nil
			_celestial_active = false
		end
		return _soundemitter
	end

	local function RA_IsChannelPlaying(channel)
		if _soundemitter == nil then
			return false
		end
		if _soundemitter.PlayingSound == nil then
			return nil
		end
		return _soundemitter:PlayingSound(channel)
	end

    local source = "scripts/components/dynamicmusic.lua"
    local _OnPlayerActivated
    for i, func in ipairs(inst.event_listeners["playeractivated"][inst]) do
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
    local set_busytask = function(task) debug.setupvalue(_StartBusyTheme, i_busytask, task) end

    -- One-time dump: names the upvalues StartBusyTheme actually closes over, so the
    -- theme tracker below is confirmed rather than assumed.
    do
        local names = {}
        local n = 1
        while true do
            local name = debug.getupvalue(_StartBusyTheme, n)
            if name == nil then break end
            names[#names + 1] = n .. ":" .. name
            n = n + 1
        end
        print("[RA] StartBusyTheme upvalues: " .. table.concat(names, ", "))
    end

    -- Vanilla skips PlaySound when the requested theme matches the one it believes
    -- is already playing, so a paused channel never restarts. Clearing the tracker
    -- forces a real play. Guarded: if the name differs in your build, the dump above
    -- shows the right one and this stays a no-op rather than corrupting an upvalue.
    local i_busytheme = nil
    do
        local n = 1
        while true do
            local name = debug.getupvalue(_StartBusyTheme, n)
            if name == nil then break end
            if name == "_busytheme" then
                i_busytheme = n
                break
            end
            n = n + 1
        end
        if i_busytheme == nil then
            print("[RA] WARNING: _busytheme upvalue not found - resume may not restart audio")
        end
    end
    local set_busytheme = function(theme)
        if i_busytheme ~= nil then
            debug.setupvalue(_StartBusyTheme, i_busytheme, theme)
        end
    end
    local set_dangertask = function(task) debug.setupvalue(_StartBusyTheme, i_dangertask, task) end
    local set_triggeredlevel = function(level) debug.setupvalue(_StartTriggeredDanger, i_triggeredlevel, level) end
	
	if not (_StartBusy and _StopBusy and _StartDanger and _StartTriggeredDanger and _StopDanger and _StartBusyTheme and BUSYTHEMES) then
		return
	end

	-- wrapping _StopDanger after validation
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
	local LUNARISLAND_BUSY_MUSIC_ALTERNATE = "remade/LunarIsland/Day"
	
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


	local CELESTIAL_MUSIC_PHASES = {
		[1] = "remade/CelestialChampion/Phase1",
		[2] = "remade/CelestialChampion/Phase2",
		--[3] = "remade/CelestialChampion/Phase3",
	}
	-- prefab → numer fazy. Zweryfikuj nazwy prefabów jeśli detekcja nie działa.
	local CELESTIAL_PREFAB_TO_PHASE = {
		alterguardian_phase1 = 1,
		alterguardian_phase2 = 2,
		alterguardian_phase3 = 3,
	}
	-- 30 was too tight: knockback, phase-3 flight and repositioning all push the
	-- player outside it mid-fight, which tore the channel down and restarted it.
	local CELESTIAL_DETECTION_RADIUS = 60
	-- how far the player can get from a *locked* boss
	local CELESTIAL_RELEASE_RADIUS = 80
	local CELESTIAL_GRACE_TIME = 15
	local CELESTIAL_CHECK_INTERVAL = 1
	-- consecutive polls at new phase must be seen on before we cut the track.
	local CELESTIAL_PHASE_CONFIRM_TICKS = 2
	-- replay attempts allowed before we conclude the channel simply won't hold.
	local CELESTIAL_MAX_HEAL_ATTEMPTS = 3
	local CELESTIAL_SOUND_CHANNEL = "celestial"
	-- ============================================================

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
		-- CC priority: nothing else plays while celestial music is active
		if _celestial_active then
			return
		end
		
		if _ra_music_paused then
			return
		end
		
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
						-- vanilla ruins music with extended duration
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
				if IsInHoodedForest(player) then
					-- Don't override special area music
					return
				elseif IsOnLunarIsland(player) then
					if use_modded_music then
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.LUNARISLAND, LUNARISLAND_BUSY_MUSIC_ALTERNATE, 999)
					else
						-- vanilla lunar island music or default forest music
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.LUNARISLAND, LUNARISLAND_BUSY_MUSIC_ALTERNATE, 999)
					end
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
			_StopBusy() -- proper stop function
		end
		if _continuous_music_task then
			_continuous_music_task:Cancel()
			_continuous_music_task = nil
		end
	end

	-- NEW STUFF - Schedule continuous music check
	local function ScheduleContinuousMusic(player)
		-- CC priority
		if _celestial_active then
			return
		end
		
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
				-- FIX: Check _danger_music_playing flag in addition to dangertask + CC
				if not _celestial_active and get_busytask() == nil and get_dangertask() == nil and not _danger_music_playing then
					StartContinuousBusyMusic(player)
				end
			end)
		end
	end

	-- CELESTIAL CHAMPION FUNCTIONS
	local CELESTIAL_FILTER_TAGS = { "epic" }
	
	local function DetectCelestialChampion(player)
		if not (player and player:IsValid() and player.Transform) then
			return nil
		end
		local x, y, z = player.Transform:GetWorldPosition()
		local ents = GLOBAL.TheSim:FindEntities(x, y, z, CELESTIAL_DETECTION_RADIUS, CELESTIAL_FILTER_TAGS)

		local best_phase, best_ent = nil, nil
		for _, ent in ipairs(ents) do
			local phase = CELESTIAL_PREFAB_TO_PHASE[ent.prefab]
			if phase ~= nil and (best_phase == nil or phase > best_phase) then
				best_phase, best_ent = phase, ent
			end
		end

		if best_phase ~= nil then
			_celestial_ent = best_ent
			return best_phase
		end

		if _celestial_ent ~= nil then
			if _celestial_ent:IsValid()
			   and _celestial_ent:GetDistanceSqToPoint(x, y, z) <= CELESTIAL_RELEASE_RADIUS * CELESTIAL_RELEASE_RADIUS then
				local phase = CELESTIAL_PREFAB_TO_PHASE[_celestial_ent.prefab]
				if phase ~= nil then
					return phase
				end
			end
			_celestial_ent = nil
		end

		return nil
	end
	
	local function PlayCelestialPhase(phase, force, reason)
		if not _soundemitter or not CELESTIAL_MUSIC_PHASES[phase] then
			return
		end

		if not force and _celestial_active and _celestial_current_phase == phase then
			RA_Trace("[RA] suppressed redundant replay of phase "..tostring(phase))
			return
		end
		RA_Say(string.format("[RA] celestial %s -> %s (%s)",
			tostring(_celestial_current_phase), tostring(phase), tostring(reason)))
		_soundemitter:KillSound(CELESTIAL_SOUND_CHANNEL)
		_soundemitter:PlaySound(CELESTIAL_MUSIC_PHASES[phase], CELESTIAL_SOUND_CHANNEL)
		_celestial_current_phase = phase
	end
	
	-- forward declaration
	local StopCelestialMusic

	local function StartCelestialMusic(phase)
		-- kill everything
		_StopBusy()
		StopContinuousMusic()
		
		if _soundemitter then
			_soundemitter:KillSound("danger")
		end
		_danger_music_playing = false
		
		-- cancel any pending danger task so it doesn't fire later
		local dt = get_dangertask()
		if dt then
			dt:Cancel()
			set_dangertask(nil)
		end
		
		_celestial_active = true
		PlayCelestialPhase(phase, false, "onset")

		if _celestial_verify_task then
			_celestial_verify_task:Cancel()
		end
		_celestial_verify_task = inst:DoTaskInTime(1, function()
			_celestial_verify_task = nil
			if not _celestial_active then
				return
			end
			if RA_IsChannelPlaying(CELESTIAL_SOUND_CHANNEL) == false then
				RA_Say("[RA] celestial event did not start - check FMOD build. Standing down.")
				_celestial_unavailable = true
				StopCelestialMusic()
			end
		end)
	end

	function StopCelestialMusic()
		if _soundemitter then
			_soundemitter:KillSound(CELESTIAL_SOUND_CHANNEL)
		end
		RA_Say("[RA] celestial stop")
		_celestial_active = false
		_celestial_current_phase = nil
		_celestial_ent = nil
		_celestial_pending_phase = nil
		_celestial_pending_count = 0
		_celestial_heal_attempts = 0
		
		if _celestial_grace_task then
			_celestial_grace_task:Cancel()
			_celestial_grace_task = nil
		end
		
		-- resume normal music flow
		if CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC then
			ScheduleContinuousMusic(_activatedplayer)
		end
	end
	
	local function CheckCelestialPresence(player)
		if not ENABLE_CELESTIAL_MUSIC then
			return
		end
		
		RA_RefreshSoundEmitter()
		
		-- no boss music for ghosts
		if player ~= nil and player:HasTag("playerghost") then
			if _celestial_active then
				StopCelestialMusic()
			end
			return
		end
		
		if _celestial_unavailable then
			return
		end
		
		if not _isenabled or not _soundemitter or not ENABLE_DANGER_MUSIC then
			if _celestial_active then
				StopCelestialMusic()
			end
			return
		end
		
		local detected_phase = DetectCelestialChampion(player)
		
		if RA_DEBUG then
			RA_Trace(string.format("[RA] det=%s cur=%s active=%s grace=%s lock=%s danger=%s",
				tostring(detected_phase), tostring(_celestial_current_phase),
				tostring(_celestial_active), tostring(_celestial_grace_task ~= nil),
				tostring(_celestial_ent ~= nil and _celestial_ent:IsValid()),
				tostring(RA_IsChannelPlaying("danger"))))
		end
		
		if detected_phase ~= nil and _soundemitter then
			_soundemitter:KillSound("danger")
			_danger_music_playing = false
		end
		
		if detected_phase then
			if _celestial_grace_task then
				_celestial_grace_task:Cancel()
				_celestial_grace_task = nil
			end
			
			if not _celestial_active then
				_celestial_pending_phase = nil
				_celestial_pending_count = 0
				StartCelestialMusic(detected_phase)
			elseif _celestial_current_phase ~= detected_phase then
				if _celestial_pending_phase == detected_phase then
					_celestial_pending_count = _celestial_pending_count + 1
				else
					_celestial_pending_phase = detected_phase
					_celestial_pending_count = 1
				end
				
				if _celestial_pending_count >= CELESTIAL_PHASE_CONFIRM_TICKS then
					_celestial_pending_phase = nil
					_celestial_pending_count = 0
					PlayCelestialPhase(detected_phase, false, "phasechange")
				end
			else
				_celestial_pending_phase = nil
				_celestial_pending_count = 0
				
				if RA_IsChannelPlaying(CELESTIAL_SOUND_CHANNEL) == false then
					_celestial_heal_attempts = _celestial_heal_attempts + 1
					if _celestial_heal_attempts > CELESTIAL_MAX_HEAL_ATTEMPTS then
						RA_Say("[RA] celestial channel will not stay alive - standing down")
						_celestial_unavailable = true
						StopCelestialMusic()
					else
						PlayCelestialPhase(detected_phase, true, "heal "..tostring(_celestial_heal_attempts))
					end
				else
					_celestial_heal_attempts = 0
				end
			end
		else
			if _celestial_active and not _celestial_grace_task then
				_celestial_grace_task = inst:DoTaskInTime(CELESTIAL_GRACE_TIME, function()
					_celestial_grace_task = nil
					StopCelestialMusic()
				end)
			end
		end
	end
	
	local function ScheduleCelestialCheck(player)
		if _celestial_check_task then
			_celestial_check_task:Cancel()
			_celestial_check_task = nil
		end
		if not ENABLE_CELESTIAL_MUSIC then
			return
		end
		_celestial_check_task = inst:DoPeriodicTask(CELESTIAL_CHECK_INTERVAL, function()
			if _activatedplayer then
				CheckCelestialPresence(_activatedplayer)
			end
		end)
	end
	
	local function CancelCelestialCheck()
		if _celestial_verify_task then
			_celestial_verify_task:Cancel()
			_celestial_verify_task = nil
		end
		if _celestial_check_task then
			_celestial_check_task:Cancel()
			_celestial_check_task = nil
		end
		if _celestial_grace_task then
			_celestial_grace_task:Cancel()
			_celestial_grace_task = nil
		end
		if _celestial_active then
			if _soundemitter then
				_soundemitter:KillSound(CELESTIAL_SOUND_CHANNEL)
			end
			_celestial_active = false
			_celestial_current_phase = nil
		end
		_celestial_ent = nil
		_celestial_pending_phase = nil
		_celestial_pending_count = 0
		_celestial_heal_attempts = 0
	end

    local function StartBusy(player, ...)
        -- CC has absolute priority - nothing else plays during boss music
        if _celestial_active then
            return
        end
        
        if _ra_music_paused then
            return
        end
        
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
						if not ENABLE_BUSY_MUSIC then
							return _StartBusy(player, ...)
						end
						_StartBusyTheme(player, ALTERNATE_BUSYTHEMES.LUNARISLAND, LUNARISLAND_BUSY_MUSIC_ALTERNATE, 15)
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
		-- CC has absolute priority
		if _celestial_active then
			return
		end
		
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
					if CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC and not _celestial_active then
						inst:DoTaskInTime(1, function()
							ScheduleContinuousMusic(_activatedplayer)
						end)
					end
				end))
				return
			elseif _isenabled and not GLOBAL.TheWorld:HasOneOfTags({"island","volcano","porkland"}) then
				local x, y, z = player.Transform:GetWorldPosition()
				local epics = GLOBAL.TheSim:FindEntities(x, y, z, 30, EPIC_TAGS, NO_EPIC_TAGS)

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
					if CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC and not _celestial_active then
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
		
		if CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC 
		   and not _danger_music_playing and get_dangertask() == nil and not _celestial_active then
			ScheduleContinuousMusic(_activatedplayer)
		end
	end)
        
		if TUNING.RAMPAGE_DUSKNIGHT_CONFIG then
			-- CC overrides phase stingers too
			if _celestial_active then
				return
			end
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
            CancelCelestialCheck()

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
		RA_Say("[RA] playeractivated same="..tostring(_activatedplayer == player))
		_celestial_unavailable = false
		_celestial_ent = nil
		_celestial_pending_phase = nil
		_celestial_pending_count = 0
		_celestial_heal_attempts = 0
		RA_RefreshSoundEmitter()
		
		if _activatedplayer == player then
			-- Emitter may have been rebuilt; make sure the poll is still alive.
			ScheduleCelestialCheck(player)
			return
		elseif _activatedplayer ~= nil and _activatedplayer.entity:IsValid() then
			RA_StopPlayerListeners(_activatedplayer)
		end

		_activatedplayer = player
		RA_StopSoundEmitter()
		RA_StartSoundEmitter()
		RA_StartPlayerListeners(player)
		
		-- Schedule CC presence check (runs always while player is active)
		ScheduleCelestialCheck(player)

		-- start continuous music if enabled (and busy music is enabled)
		if CONTINUOUS_MUSIC and ENABLE_BUSY_MUSIC then
			inst:DoTaskInTime(1, function()
				ScheduleContinuousMusic(player)
			end)

			-- periodic watchdog to ensure music keeps playing
			inst:DoPeriodicTask(15, function()
				-- FIX: Check _danger_music_playing flag and CC
				if _isenabled and _activatedplayer and get_busytask() == nil 
				   and get_dangertask() == nil and not _danger_music_playing and not _celestial_active then
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
            CancelCelestialCheck()
            RA_StopSoundEmitter()
        end
    end

    local function RA_OnEnableDynamicMusic(_inst, enable)
        _isenabled = enable
        RA_Say("[RA] enabledynamicmusic "..tostring(enable))
        
        if enable then
            _celestial_unavailable = false
            RA_RefreshSoundEmitter()
        end
        
        if enable and CONTINUOUS_MUSIC and _activatedplayer and ENABLE_BUSY_MUSIC then
            ScheduleContinuousMusic(_activatedplayer)
        elseif not enable then
            StopContinuousMusic()
            -- If dynamic music globally disabled, kill CC too
            if _celestial_active then
                StopCelestialMusic()
            end
        end
    end

	_isenabled = self.enabled == true

	-- Published for the pause key, which lives outside this closure.
	RA_PauseMusic = function()
		_ra_music_paused = true
		if _soundemitter then
			_soundemitter:KillSound("busy")
		end
		StopContinuousMusic()
		local bt = get_busytask()
		if bt then
			bt:Cancel()
		end
		set_busytask(nil)
		set_busytheme(nil)
		set_extendtime(0)
		RA_Say("[RA] music paused")
	end

	local function RA_PickBusyTheme(player)
		local use_modded = (math.random() <= 0.5) or TUNING.RAMPAGE_MUSIC_CONFIG
		if not ENABLE_BUSY_MUSIC then
			use_modded = false
		end
		
		if _iscave then
			if IsInRuins(player) then
				return use_modded and ALTERNATE_BUSYTHEMES.RUINS or BUSYTHEMES.RUINS,
					use_modded and RUINS_BUSY_MUSIC_ALTERNATE or "dontstarve/music/music_work_ruins"
			end
			return use_modded and ALTERNATE_BUSYTHEMES.CAVE or BUSYTHEMES.CAVE,
				use_modded and CAVE_BUSY_MUSIC_ALTERNATE or "dontstarve/music/music_work_cave"
		end
		
		if IsInHoodedForest(player) then
			return nil, nil
		end
		
		if IsOnLunarIsland(player) then
			return ALTERNATE_BUSYTHEMES.LUNARISLAND, LUNARISLAND_BUSY_MUSIC_ALTERNATE
		end
		
		if TUNING.RAMPAGE_DUSKNIGHT_CONFIG and _isdusk then
			return ALTERNATE_BUSYTHEMES.FOREST_DUSK, SEASON_DUSK_MUSIC_ALTERNATE[inst.state.season]
		elseif TUNING.RAMPAGE_DUSKNIGHT_CONFIG and _isnight then
			return ALTERNATE_BUSYTHEMES.FOREST_NIGHT, SEASON_NIGHT_MUSIC_ALTERNATE[inst.state.season]
		end
		
		local VANILLA_SEASON_BUSY_MUSIC = {
			autumn = "dontstarve/music/music_work",
			winter = "dontstarve/music/music_work_winter",
			spring = "dontstarve_DLC001/music/music_work_spring",
			summer = "dontstarve_DLC001/music/music_work_summer",
		}
		return use_modded and ALTERNATE_BUSYTHEMES.FOREST or BUSYTHEMES.FOREST,
			use_modded and SEASON_BUSY_MUSIC_ALTERNATE[inst.state.season]
				or VANILLA_SEASON_BUSY_MUSIC[inst.state.season]
	end

	RA_ResumeMusic = function()
		_ra_music_paused = false
		RA_RefreshSoundEmitter()
		
		local player = _activatedplayer
		local blocked =
			(player == nil and "no active player")
			or (not _isenabled and "dynamic music disabled")
			or (_soundemitter == nil and "no sound emitter")
			or (_celestial_active and "celestial active")
			or (_phase_grace_period_active and "phase grace period")
			or ((_danger_music_playing or get_dangertask() ~= nil) and "danger music playing")
			or (get_pirates_near() ~= nil and "pirates near")
			or nil
		
		if blocked then
			RA_Say("[RA] resume deferred: "..blocked)
			return
		end
		
		local theme, event = RA_PickBusyTheme(player)
		if theme == nil then
			RA_Say("[RA] resume deferred: special area")
			return
		end
		
		-- Continuous holds the track open; contextual gives it the normal window.
		local duration = CONTINUOUS_MUSIC and 999 or 15
		_StartBusyTheme(player, theme, event, duration)
		RA_Say("[RA] music resumed: "..tostring(event))
		
		if CONTINUOUS_MUSIC and ENABLE_BUSY_MUSIC then
			ScheduleContinuousMusic(player)
		end
	end

    inst:ListenForEvent("playeractivated", RA_OnPlayerActivated)
    inst:ListenForEvent("playerdeactivated", RA_OnPlayerDeactivated)
    inst:ListenForEvent("enabledynamicmusic", RA_OnEnableDynamicMusic)
end)

-- PAUSE / RESUME MUSIC BUTTON --

local RA_PAUSE_MESSAGES = {
	"Music goes off. Enjoy some quiet time!",
	"Silence falls over the dusk, or something.",
	"Why do I speak out of the blue.",
	"The melody takes a break.",
	"Shutting up, yes.",
}

local RA_RESUME_MESSAGES = {
	"Music comes back, hopefully.",
	"Beeps and bops again.",
	"Orchestra unsleeps.",
	"Tunes back on.",
	"This was a very gentle keystroke.",
}

AddSimPostInit(function()
	GLOBAL.TheInput:AddKeyDownHandler(KEY_TOGGLE, function()
		local player = GLOBAL.ThePlayer
		if not player then
			return
		end
		
		-- The component post-init may not have run yet (or the component may be
		-- absent); fall back to the old one-shot kill rather than doing nothing.
		if RA_PauseMusic == nil or RA_ResumeMusic == nil then
			print("[RA] pause hooks not published - component post-init has not run")
			local soundEmitter = GLOBAL.TheFocalPoint and GLOBAL.TheFocalPoint.SoundEmitter
			if soundEmitter then
				soundEmitter:KillSound("busy")
			end
			return
		end
		
		local messages
		if _ra_music_paused then
			RA_ResumeMusic()
			messages = RA_RESUME_MESSAGES
		else
			RA_PauseMusic()
			messages = RA_PAUSE_MESSAGES
		end
		
		if player.components.talker then
			player.components.talker:Say(messages[math.random(#messages)])
		else
			print("Error: Player does not have a 'talker' component.")
		end
	end)
end)

-- INSIDIOUS LURKER COMPATIBILITY --

if not GLOBAL.KnownModIndex:IsModEnabled("workshop-3554727934") then
    return
end
	
AddPlayerPostInit(function(inst)
	inst:DoPeriodicTask(0.5, function()
		local player = GLOBAL.ThePlayer 
		if player and inst:HasTag("horror_fog_client") then
			local soundEmitter = GLOBAL.TheFocalPoint.SoundEmitter
			if soundEmitter then
				soundEmitter:KillSound("busy")
				soundEmitter:KillSound("danger")
				soundEmitter:KillSound("celestial")
			end
		end
	end)
end)
