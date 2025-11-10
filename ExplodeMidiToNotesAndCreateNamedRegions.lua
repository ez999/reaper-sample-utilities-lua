-- @description Explode MIDI notes to items + create note-named regions (with tail). 
-- Useful for sampling, having MIDI files with each note separated from the next
-- @version 1.0
-- @author ez999
-- @about
--   - For each selected Midi item:
--     1) it creates a split, generating an item for each note (start = note start, end = note end + tail in ms)
--     2) then it creates a region, from the start of a note until the start of the next one, using the name of the note.
--   - Thought to sample hardware instruments that accept MIDI input.

local r = reaper

-- ---------- utils ----------
local function msg(s) r.ShowConsoleMsg(tostring(s).."\n") end

local function get_user_opts()
  local ok, vals = r.GetUserInputs(
    "Explode MIDI to items + regions",
    2,
    "Tail (ms),Prefer sharps? (1=yes,0=flats)",
    "50,1"
  )
  if not ok then return nil end
  local tail_ms, prefer_sharps = vals:match("^%s*([^,]+),([^,]+)%s*$")
  local function to_num(x) x = tostring(x or "0"):gsub(",","."); return tonumber(x) or 0 end
  tail_ms = math.max(0, to_num(tail_ms))
  prefer_sharps = (to_num(prefer_sharps) ~= 0)
  return tail_ms, prefer_sharps
end

local note_names_sharp = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local note_names_flat  = {"C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"}

local function midi_pitch_to_name(pitch, prefer_sharps)
  local n = pitch % 12
  local o = math.floor(pitch / 12) - 1 -- REAPER: C-1=0, C4=60
  local names = prefer_sharps and note_names_sharp or note_names_flat
  return string.format("%s%d", names[n+1], o)
end

local function clone_table(t)
  local out = {}
  for i,v in ipairs(t) do out[i]=v end
  return out
end

-- trova l'item della lista che contiene il tempo t
local function find_item_spanning_time(items, t)
  for i, it in ipairs(items) do
    local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
    local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
    if t > pos + 1e-9 and t < pos + len - 1e-9 then
      return i, it
    end
  end
  return nil, nil
end

-- split "gestito" mantenendo la lista aggiornata
local function split_items_list(items, t)
  local idx, it = find_item_spanning_time(items, t)
  if not idx then return false end
  local right = r.SplitMediaItem(it, t)
  if right then
    table.insert(items, idx+1, right)
    return true
  end
  return false
end

-- ---------- main per un item ----------
local function process_midi_item(item, tail_ms, prefer_sharps)
  local take = r.GetActiveTake(item)
  if not take or not r.TakeIsMIDI(take) then return end
  local track = r.GetMediaItemTrack(item)

  -- raccogli note
  local _, note_cnt, _, _ = r.MIDI_CountEvts(take)
  if note_cnt == 0 then return end

  local notes = {}
  for i=0, note_cnt-1 do
    local _, sel, mute, s_ppq, e_ppq, chan, pitch, vel = r.MIDI_GetNote(take, i)
    local s_t = r.MIDI_GetProjTimeFromPPQPos(take, s_ppq)
    local e_t = r.MIDI_GetProjTimeFromPPQPos(take, e_ppq)
    notes[#notes+1] = {s=s_t, e=e_t, pitch=pitch}
  end

  table.sort(notes, function(a,b)
    if a.s == b.s then return a.e < b.e end
    return a.s < b.s
  end)

  -- limiti item originali
  local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_pos + item_len

  -- 1) costruiamo i "boundaries" per gli split (start delle note e end+tail)
  local bounds = {}
  local function add_bound(t)
    if t <= item_pos + 1e-9 or t >= item_end - 1e-9 then return end
    bounds[#bounds+1] = t
  end

  local tail_s = tail_ms / 1000.0
  for i, n in ipairs(notes) do
    add_bound(n.s)
    local e_tail = math.min(item_end, n.e + tail_s)
    add_bound(e_tail)
  end

  table.sort(bounds)

  -- 2) split gestito: teniamo lista pezzi derivati dall'item
  local pieces = { item }
  for _, t in ipairs(bounds) do
    split_items_list(pieces, t)
  end

  -- 3) mappiamo "pezzo giusto" per ogni nota (start = s, end = e_tail)
  local keep = {}  -- set di item da tenere
  local EPS = 1e-6

  for i, n in ipairs(notes) do
    local e_tail = math.min(item_end, n.e + tail_s)
    -- cerca tra i pezzi quello che coincide con [s, e_tail]
    for _, it in ipairs(pieces) do
      local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
      local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
      local fin = pos + len
      if math.abs(pos - n.s) < EPS and math.abs(fin - e_tail) < EPS then
        keep[it] = true
        -- rinomina take con il nome nota
        local tk = r.GetActiveTake(it)
        local nm = midi_pitch_to_name(n.pitch, prefer_sharps)
        if tk then r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", nm, true) end
        break
      end
    end
  end

  -- 4) elimina i pezzi non utilizzati
  for _, it in ipairs(pieces) do
    if not keep[it] then
      r.DeleteTrackMediaItem(track, it)
    end
  end

  -- 5) crea regioni: start nota -> start nota successiva, nome = nota
  for i, n in ipairs(notes) do
    local nm = midi_pitch_to_name(n.pitch, prefer_sharps)
    local st = n.s
    local en
    if i < #notes then
      en = notes[i+1].s
    else
      -- per l’ultima, usa end item o fine nota + tail (a tua scelta).
      en = math.min(item_end, n.e + tail_s)
    end
    if en > st + 1e-9 then
      r.AddProjectMarker2(0, true, st, en, nm, -1, 0)
    end
  end
end

-- ---------- driver ----------
local function main()
  local tail_ms, prefer_sharps = get_user_opts()
  if not tail_ms then return end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local sel_cnt = r.CountSelectedMediaItems(0)
  if sel_cnt == 0 then
    r.MB("Seleziona almeno un item MIDI.","Explode MIDI",0)
  else
    -- lavoriamo su una copia della selection, perché gli split cambiano gli indici
    local items = {}
    for i=0, sel_cnt-1 do
      items[i+1] = r.GetSelectedMediaItem(0, i)
    end
    for _, it in ipairs(items) do
      process_midi_item(it, tail_ms, prefer_sharps)
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Explode MIDI notes to items + regions", -1)
end

main()

