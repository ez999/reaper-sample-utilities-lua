-- @description Export selected items to RS5k instances (note-aware, ADSR+loop helper)
-- @version 1.0
-- @author MPL (original) + ez999 (mod)
-- @changelog
--   v1.0  - forked from MPL's "Export selected items to RS5k instances" and extended
-- @about
--   This script is a fork of MPL's:
--     "Export selected items to RS5k instances on selected track (use original source)"
--   with several additions aimed at building playable RS5k instruments, especially
--   from hardware synth recordings.
--
--   Main differences vs original:
--     - Note-aware mapping:
--         - Tries to read the MIDI note (C3, F#2, Bb4, …) from take or file name.
--         - If found, maps the sample to that pitch; otherwise falls back to a base pitch.
--         - Optional OCTAVE_SHIFT at the top of the script to fix C3/C4 conventions.
--
--     - ADSR & sustain in musical units:
--         - User dialog for Attack / Decay / Release in milliseconds, Sustain in dB,
--           and Obey note-offs.
--         - Internally reads RS5k’s formatted values and finds the best normalized
--           parameter value, so you can think in real ms/dB instead of knob positions.
--
--     - Loop control in beats/BPM:
--         - User can set: Loop on/off, BPM (0 = use project tempo at first item),
--           Loop start (beats), Loop length (beats), Loop crossfade (beats).
--         - Converts beats -> ms and applies them to RS5k: loop start offset, loop xfade,
--           and source end, without destroying the initial attack region.
--
--     - Safer source offsets:
--         - Keeps "Start in source" at the original item start, to preserve the attack.
--         - Only shortens "End in source" when a finite loop window is requested.
--
--   The workflow is still compatible with MPL’s original idea:
--     - Select target track.
--     - Select audio items (e.g. one per note from a hardware synth).
--     - Run the script, choose base pitch + ADSR/loop settings.
--     - You get one RS5k instance per item plus a MIDI item that triggers them.
--
--   This version is intended as a more sampler/sound-design oriented variant of the
--   original MPL script, useful for quickly turning rendered hardware synth passes
--   into multisampled RS5k instruments.


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

local function GetDefaults()
  -- Attack, Decay, Release (ms), Sustain (dB), Obey, Loop, BPM import (0=proj), Loop start (beats), Loop length (beats), Crossfade (beats)
  local ok,vals=reaper.GetUserInputs(
    "RS5k defaults (ADS-R in ms, Sustain dB, Loop in beats)",
    10,
    "Attack (ms),Decay (ms),Release (ms),Sustain (dB),Obey note-offs (0/1),Loop (0/1),BPM import (0=proj),Loop start (beats),Loop length (beats),Loop xfade (beats)",
    "0,0,150,0,1,1,0,0,4,0.25"
  )
  if not ok then return nil end
  local a,d,r,sdb,ob,lp,bpm,lb_start,lb_len,lb_xf = vals:match("^%s*([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)%s*$")
  local function to_ms(x) x=tostring(x or "0"):gsub(",", "."); return tonumber(x) or 0 end
  local function to_num(x) x=tostring(x or "0"):gsub(",", "."); return tonumber(x) or 0 end
  a=to_ms(a); d=to_ms(d); r=to_ms(r)
  sdb=to_num(sdb)
  ob = (to_num(ob)~=0) and 1 or 0
  lp = (to_num(lp)~=0) and 1 or 0
  bpm = to_num(bpm)
  lb_start=to_num(lb_start); lb_len=to_num(lb_len); lb_xf=to_num(lb_xf)
  if a<0 then a=0 end; if d<0 then d=0 end; if r<0 then r=0 end
  if lb_start<0 then lb_start=0 end; if lb_len<0 then lb_len=0 end; if lb_xf<0 then lb_xf=0 end
  return a,d,r,sdb,ob,lp,bpm,lb_start,lb_len,lb_xf
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

  local ret,base_pitch=reaper.GetUserInputs(scr_title,1,'Set base pitch',60)
  if not ret or not tonumber(base_pitch) or tonumber(base_pitch)<0 or tonumber(base_pitch)>127 then return end
  base_pitch=math.floor(tonumber(base_pitch))

  local defA,defD,defR,defSdb,defObey,defLoop,defBPM,defLoopStartBeats,defLoopLenBeats,defLoopXfadeBeats = GetDefaults()
  if not defA then return end

  local first_pos=reaper.GetMediaItemInfo_Value(item,'D_POSITION')
  if defBPM<=0 then defBPM=reaper.TimeMap_GetDividedBpmAtTime(first_pos) end
  if defBPM<=0 then defBPM=120 end

  local loopStartMs  = beats_to_ms(defLoopStartBeats,  defBPM)
  local loopLenMs    = beats_to_ms(defLoopLenBeats,    defBPM)
  local loopXfadeMs  = beats_to_ms(defLoopXfadeBeats,  defBPM)

  local proceed_MIDI,MIDI=ExportSelItemsToRs5k_FormMIDItake_data()

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
  reaper.Undo_EndBlock2(0,'Export selected items to RS5k instances (robust loop + ADSR ms + sustain dB)',-1)
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

