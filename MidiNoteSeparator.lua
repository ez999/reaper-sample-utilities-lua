-- @description Shift successive selected notes forward by x beats (cumulative, preserve duration, extend item)
-- @version 1.02
-- @author ez999
-- @about
--   Increases the gap between selected notes by shifting later notes FORWARD.
--   - x beats is cumulative: the 2nd group is shifted by x, the 3rd by 2x, etc.
--   - Groups = all notes with the same start (chords) move together.
--   - Preserves note length (start+end are shifted by the same amount).
--   - "min gap" option to enforce a minimum spacing between groups.
--   - Extends the item length if notes go beyond the end.

local r = reaper

local function to_num(s)
  s = tostring(s or "0"):gsub(",", ".")
  return tonumber(s) or 0
end

local function get_user_opts()
  local ok, vals = r.GetUserInputs(
    "Shift successive notes (cumulative)",
    2,
    "Delta per gap (beats, decimals ok),Min gap between groups (beats)",
    "0.25,0"
  )
  if not ok then return nil end
  local d_gap_str, min_gap_str = vals:match("^%s*([^,]+),([^,]+)%s*$")
  local delta_beats = to_num(d_gap_str)
  local min_gap = math.max(0, to_num(min_gap_str))
  return delta_beats, min_gap
end

-- collect selected notes in a take, sorted by start (QN)
local function collect_selected_notes(take)
  local _, note_cnt = r.MIDI_CountEvts(take)
  local notes = {}
  for i = 0, note_cnt - 1 do
    local ok, sel, mute, s_ppq, e_ppq, ch, pitch, vel = r.MIDI_GetNote(take, i)
    if ok and sel then
      local s_qn = r.MIDI_GetProjQNFromPPQPos(take, s_ppq)
      local e_qn = r.MIDI_GetProjQNFromPPQPos(take, e_ppq)
      notes[#notes+1] = {
        idx=i, sel=sel, mute=mute,
        s_ppq=s_ppq, e_ppq=e_ppq,
        s_qn=s_qn, e_qn=e_qn,
        ch=ch, pitch=pitch, vel=vel
      }
    end
  end
  table.sort(notes, function(a,b)
    if a.s_qn == b.s_qn then return a.e_qn < b.e_qn end
    return a.s_qn < b.s_qn
  end)
  return notes
end

-- group by start time (QN) ~ chords
local function group_by_start(notes)
  local groups = {}
  local EPS = 1e-9
  for _, n in ipairs(notes) do
    if #groups == 0 or math.abs(groups[#groups].start_qn - n.s_qn) > EPS then
      groups[#groups+1] = { start_qn = n.s_qn, notes = {n}, max_end_qn = n.e_qn }
    else
      local g = groups[#groups]
      g.notes[#g.notes+1] = n
      if n.e_qn > g.max_end_qn then g.max_end_qn = n.e_qn end
    end
  end
  return groups
end

local function process_take(take, delta_beats, min_gap)
  local notes = collect_selected_notes(take)
  if #notes <= 1 then return end

  local groups = group_by_start(notes)

  -- the first group stays where it is
  local prev_new_end = groups[1].max_end_qn

  for gi = 2, #groups do
    local g = groups[gi]

    -- ideal cumulative shift: (gi-1) * delta
    local ideal_shift = (gi - 1) * delta_beats

    -- ensure minimum gap: new_start >= previous_end + min_gap
    local needed = (prev_new_end + min_gap) - (g.start_qn + ideal_shift)
    local extra = math.max(0, needed)

    local shift = ideal_shift + extra

    -- apply shift to all notes in the group, preserving duration
    local new_group_max_end = -1e9
    for _, n in ipairs(g.notes) do
      local s_new_qn = n.s_qn + shift
      local e_new_qn = n.e_qn + shift
      local s_new_ppq = r.MIDI_GetPPQPosFromProjQN(take, s_new_qn)
      local e_new_ppq = r.MIDI_GetPPQPosFromProjQN(take, e_new_qn)
      r.MIDI_SetNote(
        take, n.idx, true, n.mute,
        s_new_ppq, e_new_ppq, n.ch, n.pitch, n.vel, true -- noSort
      )
      if e_new_qn > new_group_max_end then new_group_max_end = e_new_qn end
    end

    prev_new_end = new_group_max_end
  end

  -- sort MIDI events after modifications
  r.MIDI_Sort(take)

  -- extend item if necessary to contain all notes
  local item = r.GetMediaItemTake_Item(take)
  if item then
    local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_pos + item_len

    local _, note_cnt = r.MIDI_CountEvts(take)
    local max_end_time = item_pos
    for i = 0, note_cnt - 1 do
      local ok, _, _, _, e_ppq = r.MIDI_GetNote(take, i)
      if ok then
        local t = r.MIDI_GetProjTimeFromPPQPos(take, e_ppq)
        if t > max_end_time then max_end_time = t end
      end
    end

    if max_end_time > item_end then
      local new_len = max_end_time - item_pos
      r.SetMediaItemInfo_Value(item, "D_LENGTH", new_len)
    end
  end
end

local function run()
  local delta_beats, min_gap = get_user_opts()
  if not delta_beats then return end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local processed = false
  local me = r.MIDIEditor_GetActive()

  if me then
    local take = r.MIDIEditor_GetTake(me)
    if take and r.TakeIsMIDI(take) then
      process_take(take, delta_beats, min_gap)
      processed = true
    end
  end

  if not processed then
    local sel_it = r.CountSelectedMediaItems(0)
    for i = 0, sel_it - 1 do
      local it = r.GetSelectedMediaItem(0, i)
      local take = r.GetActiveTake(it)
      if take and r.TakeIsMIDI(take) then
        process_take(take, delta_beats, min_gap)
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Shift successive selected notes forward (cumulative) + extend item", -1)
end

run()

