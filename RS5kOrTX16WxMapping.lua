-- @description Export selected items to RS5k or TX16Wx sampler (note-aware, ADSR+loop)
-- @version 2.0
-- @author MPL (original) + ez999 (mod)
-- @changelog
--   v2.0  - Added TX16Wx support with single-instance multi-region mapping
--         - Improved UI with Yes/No dialogs for sampler and loop selection
--         - TX16Wx: generates .txprog XML presets with full ADSR and loop support
--         - Removed "Obey note-offs" parameter (always enabled)
--         - Loop parameters shown only when loop is enabled
--   v1.0  - forked from MPL's "Export selected items to RS5k instances" and extended
-- @about
--   This script is a fork of MPL's:
--     "Export selected items to RS5k instances on selected track (use original source)"
--   with several additions aimed at building playable sampler instruments, especially
--   from hardware synth recordings.
--
--   Main features:
--     - Dual sampler support:
--         - ReaSamplOmatic5000 (RS5k): Creates multiple instances, one per sample
--         - TX16Wx: Creates single instance with multiple regions in .txprog format
--         - User-friendly Yes/No dialogs for sampler and loop selection
--
--     - Note-aware mapping:
--         - Automatically reads MIDI note names (C3, F#2, Bb4, etc.) from take or file names
--         - Falls back to sequential base pitch if no note name is found
--         - Optional OCTAVE_SHIFT constant to fix C3/C4 convention differences
--
--     - ADSR envelope control:
--         - Attack, Decay, Release in milliseconds
--         - Sustain level in dB
--         - For RS5k: uses extended normalized parameter ranges (beyond UI limits)
--         - For TX16Wx: generates proper XML with tx:aeg envelope parameters
--
--     - Loop control in beats/BPM:
--         - Enable/disable loop via Yes/No dialog
--         - BPM: 0 = use project tempo, or specify custom BPM
--         - Loop start, length, and crossfade in beats (musical time)
--         - RS5k: converts to ms and applies via loop parameters
--         - TX16Wx: converts to samples and writes to .txprog XML
--
--     - TX16Wx .txprog preset generation:
--         - Creates proper TX16Wx XML with namespace declarations
--         - Maps each sample to a region with correct note bounds
--         - Includes ADSR envelope and loop settings
--         - Preset named after track name for easy organization
--         - File saved in project folder with instructions for loading
--
--     - Safer source offsets (RS5k):
--         - Preserves "Start in source" at original item position (keeps attack intact)
--         - Only modifies "End in source" when loop length is specified
--
--   Workflow:
--     1. Select target track in REAPER
--     2. Select audio items (e.g., one per note from hardware synth recordings)
--     3. Run script
--     4. Choose sampler: RS5k (YES) or TX16Wx (NO)
--     5. Set base pitch (MIDI note number, e.g., 60 for C4)
--     6. Enable loop? YES or NO
--     7. Enter ADSR parameters (and loop parameters if loop enabled)
--     8. For RS5k: Instances created automatically with MIDI item
--     9. For TX16Wx: Load the generated .txprog file via TX16Wx menu
--
--   This version supports both quick multi-sampling workflows (RS5k) and
--   advanced single-instance mapping (TX16Wx), making it suitable for various
--   sampler-based instrument creation scenarios.


for key in pairs(reaper) do _G[key]=reaper[key] end

--------------------------- utils ---------------------------
local OCTAVE_SHIFT = 0 -- use +12/-12 if octaves seem shifted

local function NoteNameToMidi(str)
  if not str or str=="" then return nil end
  local L,acc,oct
  for l,a,o in tostring(str):gmatch("([A-Ga-g])([#bB]?)(%-?%d)") do
    L,acc,oct = l,a,o
  end
  if not L then return nil end
  local map={C=0,D=2,E=4,F=5,G=7,A=9,B=11}
  local semi=map[L:upper()]; if not semi then return nil end
  if acc=="#" then semi=semi+1 elseif acc=="b" or acc=="B" then semi=semi-1 end
  local o=tonumber(oct) or 0
  local midi=(o+1)*12+semi+OCTAVE_SHIFT
  if midi<0 then midi=0 elseif midi>127 then midi=127 end
  return midi
end

local function FindParamByName(track, fx, mustContain)
  local cnt=reaper.TrackFX_GetNumParams(track, fx)
  local mc=(mustContain or ""):lower()
  for p=0,cnt-1 do
    local _,nm=reaper.TrackFX_GetParamName(track,fx,p,"")
    nm=(nm or ""):lower()
    if nm:find(mc,1,true) then return p end
  end
  return nil
end

local function FindParamExact(track, fx, exactLower)
  local cnt=reaper.TrackFX_GetNumParams(track, fx)
  for p=0,cnt-1 do
    local _,nm=reaper.TrackFX_GetParamName(track,fx,p,"")
    if nm and nm:lower()==exactLower then return p end
  end
  return nil
end

-- find the "Loop" toggle parameter, avoiding start/end/offset/xfade/cross/cache
local function FindParamLoopToggle(track, fx)
  local cnt=reaper.TrackFX_GetNumParams(track, fx)
  local best_p, best_score = nil, -1
  for p=0,cnt-1 do
    local _,nm=reaper.TrackFX_GetParamName(track,fx,p,"")
    local lnm=(nm or ""):lower()
    if lnm:find("loop",1,true)
       and not lnm:find("start",1,true)
       and not lnm:find("offset",1,true)
       and not lnm:find("end",1,true)
       and not lnm:find("xfade",1,true)
       and not lnm:find("cross",1,true)
       and not lnm:find("cache",1,true) then
         -- score higher if the name is exactly "loop"
         local score = (lnm=="loop") and 2 or 1
         if score > best_score then best_score, best_p = score, p end
    end
  end
  return best_p
end

local function formatted_to_number_and_unit(track, fx, p)
  local _,txt=reaper.TrackFX_GetFormattedParamValue(track,fx,p,"")
  if not txt or txt=="" then return nil,nil end
  local low=txt:lower()
  local numtxt=low:match("[-%d%,%.]+"); if not numtxt then return nil,nil end
  numtxt=numtxt:gsub(",", ".")
  local val=tonumber(numtxt); if not val then return nil,nil end
  if low:find("db") then return val,"db" end
  if low:find("ms") then return val,"ms" end
  if low:find(" sec") or low:find(" s") then return val,"s" end
  return val,"?"
end

local function SetParamMs(track, fx, p, target_ms)
  if not p then return false end
  -- Extended range: some RS5k params go beyond 1.0 normalized
  local max_normalized = 10.0  -- search up to 10.0 to find extended ranges
  local samples=200  -- increased for better precision
  local function to_ms(v,unit)
    if not v then return nil end
    if unit=="ms" then return v end
    if unit=="s"  then return v*1000 end
    return v
  end
  
  -- First pass: find the real range by sampling with extended normalized range
  local best_n=0; local best_err=1e15
  for i=0,samples do
    local n = i/samples * max_normalized  -- scan 0 to max_normalized
    reaper.TrackFX_SetParamNormalized(track,fx,p,n)
    local raw,unit=formatted_to_number_and_unit(track,fx,p)
    local ms = to_ms(raw,unit)
    if ms then
      local err=math.abs(ms-target_ms)
      if err<best_err then best_err, best_n = err, n end
    end
  end
  
  -- Second pass: refinement around the best value
  local refinement_range = max_normalized / samples
  local refine_samples = 50
  for i=0,refine_samples do
    local n = best_n + (i - refine_samples/2) * refinement_range / refine_samples
    if n >= 0 then  -- removed upper limit check
      reaper.TrackFX_SetParamNormalized(track,fx,p,n)
      local raw,unit=formatted_to_number_and_unit(track,fx,p)
      local ms = to_ms(raw,unit)
      if ms then
        local err=math.abs(ms-target_ms)
        if err<best_err then best_err, best_n = err, n end
      end
    end
  end
  
  reaper.TrackFX_SetParamNormalized(track,fx,p,best_n)
  return true
end

local function SetParamDb(track, fx, p, target_db)
  if not p then return false end
  local samples=200  -- increased for better precision
  
  -- First pass: complete scan
  local best_n=0; local best_err=1e15
  for i=0,samples do
    local n=i/samples
    reaper.TrackFX_SetParamNormalized(track,fx,p,n)
    local raw,unit=formatted_to_number_and_unit(track,fx,p)
    if raw and (unit=="db" or unit=="?") then
      local err=math.abs(raw-target_db)
      if err<best_err then best_err, best_n = err, n end
    end
  end
  
  -- Second pass: refinement around the best value
  local refinement_range = 1.0 / samples
  local refine_samples = 50
  for i=0,refine_samples do
    local n = best_n + (i - refine_samples/2) * refinement_range / refine_samples
    if n >= 0 and n <= 1 then
      reaper.TrackFX_SetParamNormalized(track,fx,p,n)
      local raw,unit=formatted_to_number_and_unit(track,fx,p)
      if raw and (unit=="db" or unit=="?") then
        local err=math.abs(raw-target_db)
        if err<best_err then best_err, best_n = err, n end
      end
    end
  end
  
  reaper.TrackFX_SetParamNormalized(track,fx,p,best_n)
  return true
end

local function GetSamplerChoice()
  -- MB returns: 6=Yes, 7=No, 2=Cancel
  local result = reaper.MB("Choose sampler type:\n\nYES = RS5k (multi-instance, one per sample)\nNO = TX16Wx (single-instance, multiple regions)", "Sampler Selection", 3)
  if result == 2 then return nil end  -- Cancel
  if result == 7 then return "TX16Wx" end  -- No
  return "RS5k"  -- Yes (6) or default
end

local function GetLoopChoice()
  local result = reaper.MB("Enable loop?", "Loop", 3)
  if result == 2 then return nil end  -- Cancel
  return (result == 6) and 1 or 0  -- Yes=1, No=0
end

local function GetDefaults(sampler)
  -- Ask loop on/off with dialog
  local loop_choice = GetLoopChoice()
  if loop_choice == nil then return nil end
  
  -- Get ADSR parameters
  local ok, vals
  if loop_choice == 1 then
    -- With loop: include BPM and loop parameters
    ok, vals = reaper.GetUserInputs(
      "Sampler parameters (ADSR + Loop)",
      8,
      "Attack (ms),Decay (ms),Release (ms),Sustain (dB),BPM (0=use project),Loop start (beats),Loop length (beats),Loop xfade (beats)",
      "0,0,150,0,0,0,4,0.25"
    )
    if not ok then return nil end
    local a, d, r, sdb, bpm, lb_start, lb_len, lb_xf = vals:match("^%s*([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)%s*$")
    local function to_num(x) x = tostring(x or "0"):gsub(",", "."); return tonumber(x) or 0 end
    a = to_num(a); d = to_num(d); r = to_num(r); sdb = to_num(sdb)
    bpm = to_num(bpm)
    lb_start = to_num(lb_start); lb_len = to_num(lb_len); lb_xf = to_num(lb_xf)
    if a < 0 then a = 0 end; if d < 0 then d = 0 end; if r < 0 then r = 0 end
    if lb_start < 0 then lb_start = 0 end; if lb_len < 0 then lb_len = 0 end; if lb_xf < 0 then lb_xf = 0 end
    return a, d, r, sdb, 1, loop_choice, bpm, lb_start, lb_len, lb_xf
  else
    -- Without loop: only ADSR
    ok, vals = reaper.GetUserInputs(
      "Sampler parameters (ADSR only)",
      4,
      "Attack (ms),Decay (ms),Release (ms),Sustain (dB)",
      "0,0,150,0"
    )
    if not ok then return nil end
    local a, d, r, sdb = vals:match("^%s*([^,]+),([^,]+),([^,]+),([^,]+)%s*$")
    local function to_num(x) x = tostring(x or "0"):gsub(",", "."); return tonumber(x) or 0 end
    a = to_num(a); d = to_num(d); r = to_num(r); sdb = to_num(sdb)
    if a < 0 then a = 0 end; if d < 0 then d = 0 end; if r < 0 then r = 0 end
    return a, d, r, sdb, 1, 0, 120, 0, 0, 0  -- loop off, dummy loop values
  end
end

local function beats_to_ms(beats, bpm)
  if bpm<=0 then return 0 end
  return beats * (60000.0 / bpm) -- quarter notes
end
--------------------------- /utils ---------------------------

function VF_CheckReaperVrs(rvrs, showmsg)
  local vrs_num=GetAppVersion(); vrs_num=tonumber(vrs_num:match('[%d%.]+'))
  if rvrs>vrs_num then if showmsg then reaper.MB('Update REAPER to '..rvrs..'+','',0) end return else return true end
end

local scr_title='Export selected items to RS5k instances on selected track (use original source)'

function ExportSelItemsToRs5k_FormMIDItake_data()
  local MIDI={}
  local item=reaper.GetSelectedMediaItem(0,0); if not item then return end
  MIDI.it_pos=reaper.GetMediaItemInfo_Value(item,'D_POSITION')
  MIDI.it_end_pos=MIDI.it_pos+0.1
  local proceed_MIDI=true
  local it_tr0=reaper.GetMediaItemTrack(item)
  for i=1,reaper.CountSelectedMediaItems(0) do
    local it=reaper.GetSelectedMediaItem(0,i-1)
    local it_pos=reaper.GetMediaItemInfo_Value(it,'D_POSITION')
    local it_len=reaper.GetMediaItemInfo_Value(it,'D_LENGTH')
    MIDI[#MIDI+1]={pos=it_pos,end_pos=it_pos+it_len}
    MIDI.it_end_pos=it_pos+it_len
    local it_tr=reaper.GetMediaItemTrack(it)
    if it_tr~=it_tr0 then proceed_MIDI=false break end
  end
  return proceed_MIDI,MIDI
end

function main()
  Undo_BeginBlock2(0)
  local track=GetSelectedTrack(0,0); if not track then return end
  local item =GetSelectedMediaItem(0,0); if not item  then return true end

  -- Choose sampler first
  local sampler = GetSamplerChoice()
  if not sampler then return end

  local ret,base_pitch=reaper.GetUserInputs(scr_title,1,'Set base pitch',60)
  if not ret or not tonumber(base_pitch) or tonumber(base_pitch)<0 or tonumber(base_pitch)>127 then return end
  base_pitch=math.floor(tonumber(base_pitch))

  local defA,defD,defR,defSdb,defObey,defLoop,defBPM,defLoopStartBeats,defLoopLenBeats,defLoopXfadeBeats = GetDefaults(sampler)
  if not defA then return end

  local first_pos=reaper.GetMediaItemInfo_Value(item,'D_POSITION')
  if defBPM<=0 then defBPM=reaper.TimeMap_GetDividedBpmAtTime(first_pos) end
  if defBPM<=0 then defBPM=120 end

  local loopStartMs  = beats_to_ms(defLoopStartBeats,  defBPM)
  local loopLenMs    = beats_to_ms(defLoopLenBeats,    defBPM)
  local loopXfadeMs  = beats_to_ms(defLoopXfadeBeats,  defBPM)

  local proceed_MIDI,MIDI=ExportSelItemsToRs5k_FormMIDItake_data()

  if sampler == "TX16Wx" then
    -- TX16Wx: single instance, multiple zones
    main_TX16Wx(track, base_pitch, defA, defD, defR, defSdb, defObey, defLoop, loopStartMs, loopLenMs, loopXfadeMs, MIDI)
  else
    -- RS5k: multiple instances (original behavior)
    main_RS5k(track, base_pitch, defA, defD, defR, defSdb, defObey, defLoop, loopStartMs, loopLenMs, loopXfadeMs, proceed_MIDI, MIDI)
  end

  reaper.Undo_EndBlock2(0,'Export selected items to sampler instances',-1)
end

function main_RS5k(track, base_pitch, defA, defD, defR, defSdb, defObey, defLoop, loopStartMs, loopLenMs, loopXfadeMs, proceed_MIDI, MIDI)

  for i=1,CountSelectedMediaItems(0) do
    local it=GetSelectedMediaItem(0,i-1)
    local it_len=GetMediaItemInfo_Value(it,'D_LENGTH')
    local take=GetActiveTake(it)
    if not take or TakeIsMIDI(take) then goto skip end

    local tk_src=GetMediaItemTake_Source(take)
    local offs=0
    if GetMediaSourceParent(tk_src)~=nil then
      local _,o,len,rev=reaper.PCM_Source_GetSectionInfo(tk_src)
      offs=o or 0
      tk_src=GetMediaSourceParent(tk_src)
    end
    local s_offs=GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')+offs
    local src_len=GetMediaSourceLength(tk_src)
    local filepath=GetMediaSourceFileName(tk_src,'')

    local _,takename=reaper.GetSetMediaItemTakeInfo_String(take,'P_NAME','',false)
    local pitch=NoteNameToMidi(takename) or NoteNameToMidi(filepath)
    if not pitch then pitch=base_pitch+i-1 end

    local fx=TrackFX_AddByName(track,'ReaSamplomatic5000',false,-1)
    TrackFX_SetNamedConfigParm(track,fx,'FILE0',filepath)
    TrackFX_SetNamedConfigParm(track,fx,'DONE','')

    TrackFX_SetParamNormalized(track,fx,2,0)
    local nrm=pitch/127
    TrackFX_SetParamNormalized(track,fx,3,nrm)
    TrackFX_SetParamNormalized(track,fx,4,nrm)
    TrackFX_SetParamNormalized(track,fx,5,0.5)
    TrackFX_SetParamNormalized(track,fx,6,0.5)
    TrackFX_SetParamNormalized(track,fx,8,0)

    -- Set ADSR via parameter index (these work but may have UI limits on some params)
    local pA=FindParamByName(track,fx,'attack')
    local pD=FindParamByName(track,fx,'decay')
    local pR=FindParamByName(track,fx,'release')
    local pS=FindParamByName(track,fx,'sustain')
    if pA then SetParamMs(track,fx,pA,defA) end
    if pD then SetParamMs(track,fx,pD,defD) end
    if pR then SetParamMs(track,fx,pR,defR) end
    if pS then SetParamDb(track,fx,pS,defSdb) end

    local pObey=FindParamByName(track,fx,'obey') or 11
    TrackFX_SetParamNormalized(track,fx,pObey,(defObey~=0) and 1 or 0)

    -- === Robust LOOP ===
    local pLoop = FindParamLoopToggle(track,fx)
    if defLoop ~= 0 then
      if pLoop then
        TrackFX_SetParamNormalized(track,fx,pLoop,1)
      end
      -- verify; if not active, force it via config param and recheck
      local ok_on = (pLoop and (reaper.TrackFX_GetParamNormalized(track,fx,pLoop) or 0) >= 0.5)
      if not ok_on then
        TrackFX_SetNamedConfigParm(track,fx,'LOOP','1')
        TrackFX_SetNamedConfigParm(track,fx,'DONE','')
        if pLoop then ok_on = (reaper.TrackFX_GetParamNormalized(track,fx,pLoop) or 0) >= 0.5 end
      end
    else
      if pLoop then TrackFX_SetParamNormalized(track,fx,pLoop,0) end
    end

    -- Loop start offset (ms from sample start)
    local pLoopStart = FindParamExact(track,fx,'loop start offset') or FindParamByName(track,fx,'loop start')
    if pLoopStart and defLoop ~= 0 and loopStartMs > 0 then
      SetParamMs(track,fx,pLoopStart,loopStartMs)
    end

    -- Crossfade (ms from beats)
    local pXfade = FindParamByName(track,fx,'xfade') or FindParamByName(track,fx,'crossfade')
    if pXfade and defLoop ~= 0 and loopXfadeMs > 0 then
      SetParamMs(track,fx,pXfade,loopXfadeMs)
    end

    -- Delimit ONLY the end (End in source - 14); Start (13) stays at s_offs
    if src_len and src_len > 0 then
      local region_start = s_offs
      local region_end   = s_offs + it_len
      if defLoop ~= 0 and loopLenMs > 0 then
        region_end = math.min(s_offs + it_len, s_offs + (loopStartMs + loopLenMs) / 1000.0)
      end
      local startN = math.max(0, math.min(1, region_start / src_len))
      local endN   = math.max(0, math.min(1, region_end   / src_len))
      TrackFX_SetParamNormalized(track,fx,13,startN)  -- Start in source (unchanged)
      TrackFX_SetParamNormalized(track,fx,14,endN)    -- End in source
    end
    -- === /LOOP ===

    ::skip::
  end

  reaper.Main_OnCommand(40006,0)
  local proceed_MIDI,MIDI=ExportSelItemsToRs5k_FormMIDItake_data()
  if proceed_MIDI then ExportSelItemsToRs5k_AddMIDI(track,MIDI,base_pitch) end
end

function main_TX16Wx(track, base_pitch, defA, defD, defR, defSdb, defObey, defLoop, loopStartMs, loopLenMs, loopXfadeMs, MIDI)
  -- Create single TX16Wx instance
  local fx = TrackFX_AddByName(track, 'VSTi: TX16Wx (CWITEC)', false, -1)
  if fx < 0 then
    reaper.MB("TX16Wx not found! Please install TX16Wx VST3 or choose RS5k.", "Error", 0)
    return
  end

  -- Get track name for preset naming
  local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if track_name == "" then track_name = "Sampler" end

  -- Collect all items with their pitches
  local samples = {}
  for i = 1, CountSelectedMediaItems(0) do
    local it = GetSelectedMediaItem(0, i-1)
    local take = GetActiveTake(it)
    if take and not TakeIsMIDI(take) then
      local tk_src = GetMediaItemTake_Source(take)
      local offs = 0
      if GetMediaSourceParent(tk_src) ~= nil then
        local _, o = reaper.PCM_Source_GetSectionInfo(tk_src)
        offs = o or 0
        tk_src = GetMediaSourceParent(tk_src)
      end
      
      local filepath = GetMediaSourceFileName(tk_src, '')
      local _, takename = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
      local pitch = NoteNameToMidi(takename) or NoteNameToMidi(filepath)
      if not pitch then pitch = base_pitch + i - 1 end
      
      -- Get note name for TX16Wx format (e.g., "C4", "A#1")
      local note_names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
      local note_n = pitch % 12
      local note_o = math.floor(pitch / 12) - 1
      local note_name = note_names[note_n + 1] .. note_o
      
      samples[#samples + 1] = {
        filepath = filepath,
        pitch = pitch,
        note_name = note_name,
        item = it
      }
    end
  end

  if #samples == 0 then
    reaper.MB("No audio items found to map.", "Error", 0)
    return
  end

  -- Sort by pitch for cleaner mapping
  table.sort(samples, function(a, b) return a.pitch < b.pitch end)

  -- Create TX16Wx XML preset with correct format
  local preset_name = track_name:gsub("[^%w%s%-]", "_")
  local preset_path = reaper.GetProjectPath("") .. "/" .. preset_name .. ".txprog"
  
  -- Convert file paths to URI format
  local function to_uri(path)
    -- Convert to file:/// URI and URL-encode spaces and special chars
    local uri = "file://" .. path:gsub(" ", "%%20"):gsub("#", "%%23")
    return uri
  end
  
  -- Start XML with TX16Wx namespace
  local xml = '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
  xml = xml .. '<tx:program xmlns:tx="http://www.tx16wx.com/3.0/program" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"\n'
  xml = xml .. '   xsi:schemaLocation="http://www.tx16wx.com/3.0/ program" tx:created-by="30700" tx:quality="Default" tx:name="' .. track_name .. '">\n'
  
  -- Add all waves (samples)
  for idx, smp in ipairs(samples) do
    local wave_id = idx - 1
    
    -- Get sample rate and length for loop calculations
    local src = reaper.PCM_Source_CreateFromFile(smp.filepath)
    local sample_rate = 44100  -- default
    local length_samples = 792000  -- default
    if src then
      sample_rate = reaper.GetMediaSourceSampleRate(src)
      local length_sec = reaper.GetMediaSourceLength(src)
      length_samples = math.floor(length_sec * sample_rate)
      reaper.PCM_Source_Destroy(src)
    end
    
    xml = xml .. string.format('   <tx:wave tx:root="C-1" tx:id="%d"\n', wave_id)
    xml = xml .. string.format('      tx:path="%s">\n', to_uri(smp.filepath))
    
    -- Only add loop tag if loop is enabled
    if defLoop ~= 0 then
      -- Calculate loop points in samples
      local loop_start_sec = (loopStartMs / 1000.0)
      local loop_len_sec = (loopLenMs / 1000.0)
      local loop_start_samples = math.floor(loop_start_sec * sample_rate)
      local loop_end_samples = math.floor((loop_start_sec + loop_len_sec) * sample_rate)
      -- Clamp to file length
      if loop_end_samples > length_samples then loop_end_samples = length_samples end
      if loop_start_samples > length_samples then loop_start_samples = 0 end
      
      xml = xml .. string.format('      <tx:loop tx:end="%d" tx:start="%d" tx:mode="Forward" tx:name="1"/>\n', 
        loop_end_samples, loop_start_samples)
    end
    
    xml = xml .. '   </tx:wave>\n'
  end
  
  -- Global bounds
  xml = xml .. '   <tx:bounds tx:high-vel="127" tx:high-key="G9" tx:low-vel="0" tx:low-key="C-1"/>\n'
  
  -- Soundshape (ADSR and other parameters)
  -- Convert dB to linear for sustain if needed, but TX16Wx uses dB format
  xml = xml .. '   <tx:soundshape tx:unison-cyclic-spread="false" tx:unison-spread="0Ct" tx:unison-depth="100%" tx:unison-pan="100%"\n'
  xml = xml .. '      tx:glide-mode="Held" tx:pwm="0%" tx:volume="0 dB" tx:id="default-soundshape"\n'
  xml = xml .. '      tx:unison-start="0ms" tx:name="' .. track_name .. '" tx:unison="1" tx:pan="0%">\n'
  xml = xml .. string.format('      <tx:aeg tx:level2="0 dB" tx:level1="0 dB" tx:release-shape="-50%%" tx:release="%.1fms" tx:decay2-shape="-50%%"\n', defR)
  xml = xml .. string.format('         tx:sustain="%.1f dB" tx:decay2="500ms" tx:decay1-shape="-50%%" tx:decay1="%.1fms" tx:attack-shape="-50%%"\n', defSdb, defD)
  xml = xml .. string.format('         tx:attack="%.1fms"/>\n', defA)
  xml = xml .. '      <tx:send tx:level="0 dB"/>\n'
  xml = xml .. '      <tx:send tx:level="0 dB"/>\n'
  xml = xml .. '      <tx:send tx:level="0 dB"/>\n'
  xml = xml .. '      <tx:modulation/>\n'
  xml = xml .. '   </tx:soundshape>\n'
  
  -- Group with regions
  xml = xml .. '   <tx:group tx:soundshape="default-soundshape" tx:color="antiquewhite" tx:scale="100" tx:output="--"\n'
  xml = xml .. '      tx:noteprio="Last" tx:quality="Default" tx:playback="Resample" tx:polymode="Poly" tx:playmode="Normal" tx:fine="0"\n'
  xml = xml .. '      tx:coarse="0" tx:choke-group="0" tx:pan="0%" tx:volume="0 dB" tx:name="' .. track_name .. '">\n'
  
  -- Add regions (one per sample)
  for idx, smp in ipairs(samples) do
    local wave_id = idx - 1
    xml = xml .. string.format('      <tx:region tx:fine="0" tx:wave="%d" tx:release="0" tx:root="%s" tx:loop="0" tx:pan="0%%" tx:attenuation="0 dB"\n', 
      wave_id, smp.note_name)
    xml = xml .. '         tx:mode="DFD">\n'
    xml = xml .. string.format('         <tx:bounds tx:high-vel="127" tx:high-key="%s" tx:low-vel="0" tx:low-key="%s"/>\n',
      smp.note_name, smp.note_name)
    xml = xml .. '      </tx:region>\n'
  end
  
  xml = xml .. '   </tx:group>\n'
  xml = xml .. '</tx:program>\n'

  -- Save preset
  local file = io.open(preset_path, "w")
  if file then
    file:write(xml)
    file:close()
    
    -- Show success message
    local msg = string.format(
      "✓ TX16Wx preset created successfully!\n\n" ..
      "Name: %s\n" ..
      "Path: %s\n\n" ..
      "Mapped %d samples (%s to %s)\n\n" ..
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n" ..
      "TO LOAD:\n" ..
      "1. Open TX16Wx interface\n" ..
      "2. Click dropdown menu (top-left)\n" ..
      "3. Select 'Load Program'\n" ..
      "4. Navigate to and open the .txprog file\n\n" ..
      "All regions will be automatically mapped!",
      track_name, preset_path, #samples, 
      samples[1].note_name, samples[#samples].note_name
    )
    
    local response = reaper.MB(msg, "TX16Wx Preset Ready", 1)
    
    -- Open file location if user clicks OK
    if response == 1 then
      if reaper.CF_LocateInExplorer then
        reaper.CF_LocateInExplorer(preset_path)
      else
        reaper.Main_OnCommand(41929, 0)
      end
    end
  else
    reaper.MB("Could not create preset file.", "Error", 0)
  end

  -- Create MIDI item
  reaper.Main_OnCommand(40006, 0)
  if MIDI then
    ExportSelItemsToRs5k_AddMIDI(track, MIDI, base_pitch)
  end
end

function ExportSelItemsToRs5k_AddMIDI(track, MIDI, base_pitch, do_not_increment)
  if not MIDI then return end
  local new_it=reaper.CreateNewMIDIItemInProj(track,MIDI.it_pos,MIDI.it_end_pos)
  local new_tk=reaper.GetActiveTake(new_it)
  for i=1,#MIDI do
    local s=reaper.MIDI_GetPPQPosFromProjTime(new_tk,MIDI[i].pos)
    local e=reaper.MIDI_GetPPQPosFromProjTime(new_tk,MIDI[i].end_pos)
    local pitch=base_pitch+i-1
    if do_not_increment then pitch=base_pitch end
    reaper.MIDI_InsertNote(new_tk,false,false,s,e,0,pitch,100,true)
  end
  reaper.MIDI_Sort(new_tk)
  reaper.GetSetMediaItemTakeInfo_String(new_tk,'P_NAME','sliced loop',1)
  reaper.UpdateArrange()
end

-- legacy
function ExportItemToRS5K(note,filepath,start_offs,end_offs,track)
  local fx=TrackFX_AddByName(track,'ReaSamplomatic5000',false,-1)
  TrackFX_SetNamedConfigParm(track,fx,'FILE0',filepath)
  TrackFX_SetNamedConfigParm(track,fx,'DONE','')
  TrackFX_SetParamNormalized(track,fx,2,0)
  TrackFX_SetParamNormalized(track,fx,3,note/127)
  TrackFX_SetParamNormalized(track,fx,4,note/127)
  TrackFX_SetParamNormalized(track,fx,5,0.5)
  TrackFX_SetParamNormalized(track,fx,6,0.5)
  TrackFX_SetParamNormalized(track,fx,8,0)
  TrackFX_SetParamNormalized(track,fx,9,0)
  TrackFX_SetParamNormalized(track,fx,11,1)
  if start_offs and end_offs then
    TrackFX_SetParamNormalized(track,fx,13,start_offs)
    TrackFX_SetParamNormalized(track,fx,14,end_offs)
  end
end

if VF_CheckReaperVrs(5.95,true) then reaper.Undo_BeginBlock(); main(); reaper.Undo_EndBlock(scr_title,1) end

