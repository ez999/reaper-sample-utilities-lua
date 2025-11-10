# Reactional REAPER helper scripts for Reactional Music
by **ez999** (based on scripts by MPL)

This folder contains three Lua scripts and an example MIDI file.
They are meant to help composers who use REAPER together with Reactional Music,
especially when sampling external hardware synths and turning those recordings
into RS5k based instruments.

Scripts:
- `MidiNoteSeparator.lua`
- `ExplodeMidiToNotesAndCreateNamedRegions.lua`
- `RS5kMapping.lua`
- plus an example MIDI file (`Sampler Midi - from C1 to B8 MIDI 160BPM.mid`).

You are free to modify these scripts for your own workflow.

---

## 0. Installing the scripts in REAPER

### 0.1. Put the .lua files in the Scripts folder

1. In REAPER, go to:
   - `Options -> Show REAPER resource path in explorer/finder...`
2. Open the `Scripts` folder.
3. Create a subfolder, for example:
   - `Scripts/ez999_ReactionalTools/`
4. Copy these files into that folder:
   - `MidiNoteSeparator.lua`
   - `ExplodeMidiToNotesAndCreateNamedRegions.lua`
   - `RS5kMapping.lua`

### 0.2. Load the scripts into the Action List

For each script:

1. Open `Actions -> Show Action List...`.
2. Go to the `ReaScript` tab.
3. Click `Load...`.
4. Select the `.lua` file and confirm.
5. The script now appears in the Action List.

Optional but recommended: assign a shortcut or toolbar button.

1. In the Action List, select the script.
2. In the right panel, click `Add...` under "Shortcuts for selected action".
3. Press the key you want to use (for example `Ctrl+Alt+R`) and confirm.
4. Or right click a toolbar, choose `Customize toolbar...`, click `Add...`,
   pick the script, and then give the button a name and an icon.

---

## 1. Overall workflow

Typical end to end workflow for sampling and building an RS5k instrument:

1. Create a MIDI pattern that plays the notes you want to sample.
   - You can use the included example MIDI file as a starting point. It is programmed with some silence between notes
     to allow long tails to ring out.
2. If you need more or less space between notes, use
   `MidiNoteSeparator.lua` to shift later notes forward and increase
   the gaps. This is useful when sounds have long tails.
3. Route that MIDI to your external synth and record the audio in REAPER.
4. Use `ExplodeMidiToNotesAndCreateNamedRegions.lua` on the MIDI item
   to create one note object per note and named regions.
5. Render the audio so that you get one audio item per note
   (or use regions to batch render).
6. Use `RS5kMapping.lua` on those audio items to automatically create
   a mapped RS5k instrument with envelopes and looping already set.

You can of course swap or skip steps depending on your use case.

---

## 2. MidiNoteSeparator.lua

### 2.1. Purpose

This script increases the pause between selected MIDI notes by moving
later notes forward in musical units (beats). The original note order
and note lengths are preserved, and the MIDI item is extended if
necessary so that no notes are cut off.

The original use case for this script was to give more space between
notes when sampling sounds with long tails, so that the synth can decay
fully before the next note. Users are free to modify the script to
also shorten gaps instead of extending them, or to adapt the logic
for different timing needs.

### 2.2. How it works

- Works on MIDI notes in the active MIDI Editor or in selected MIDI items.
- Groups notes by identical start time (chords are one group).
- Keeps the first group in place.
- Shifts each later group forward by a cumulative offset in beats:
  - group 2 moves by +Delta beats
  - group 3 moves by +2 * Delta beats
  - group 4 moves by +3 * Delta beats
  - and so on.
- Note duration is preserved. Start and end move together.
- A minimum gap between groups can be enforced.
- The owning MIDI item is extended if the last shifted note would
  go beyond the original item end.

### 2.3. Using the script

1. Open the MIDI item in the MIDI Editor.
2. Select the notes that you want to affect.
3. Run `MidiNoteSeparator.lua` from the Action List or your shortcut.
4. A dialog appears with two fields:
   - `Delta per gap (beats, decimals ok)`
     - Example: `0.25` adds a sixteenth note of extra gap between each group,
       in a cumulative way.
   - `Min gap between groups (beats)`
     - Example: `0.0` to ignore, or `0.125` to enforce at least a thirty second
       note of distance.
5. Confirm. The selected notes will move forward, the gaps will grow,
   and the MIDI item will grow if needed.

You can use the provided example MIDI file, run this script to change
the spacing of the notes, and then record your hardware synth while
it plays that pattern.

---

## 3. ExplodeMidiToNotesAndCreateNamedRegions.lua

### 3.1. Purpose

This script converts a MIDI item into a set of note based items and
creates project regions with note names. It is aimed at sampling
workflows where each MIDI note will later correspond to one audio
sample.

### 3.2. What it does

Given a MIDI item with notes:

- Splits the item so that you get one item per note:
  - item start = note start
  - item end = note end + a user defined tail in milliseconds.
- Renames each resulting take with the note name, for example `C3`, `F#2`, `Bb4`.
- Creates project regions:
  - one region per note,
  - from the note start to the next note start,
  - the region name is the note name.

This makes it very easy to render notes as separate files
and to map them later using `RS5kMapping.lua`.

### 3.3. Using the script

1. In the arrange view, select the MIDI item you want to explode.
2. Run `ExplodeMidiToNotesAndCreateNamedRegions.lua`.
3. A dialog appears with:
   - `Tail (ms)`
     - extra time after the note off that should be included
       inside each item. Example: `100` for 100 milliseconds.
   - `Prefer sharps? (1=yes,0=flats)`
     - `1` means names like `C#3`.
     - `0` means names like `Db3`.
4. Confirm. The item will be split into one per note and regions will
   be created with matching names.

You can now align or record audio against these notes and regions,
then render each region or item to get separate audio files per note.

---

## 4. RS5kMapping.lua

### 4.1. Purpose

This script turns a set of audio items into a multi sample instrument
using ReaSamplomatic5000 (RS5k). It was originally based on MPLs
"Export selected items to RS5k instances" script, and then heavily
extended for sampling and sound design.

### 4.2. Main features

- One RS5k instance per selected audio item on the target track.
- Each instance is mapped to a single MIDI note.
- The script tries to detect the MIDI note from the take or file
  name (C3, F#2, Bb4, etc). If that fails it falls back to a base
  pitch you specify.
- A new MIDI item is created that triggers all samples in sequence.
- ADSR and sustain can be entered in musical units:
  - Attack, Decay, Release in milliseconds
  - Sustain in dB
  - Obey note offs on or off
- Loop settings can be entered in beats and BPM:
  - Loop on or off
  - BPM (0 means use project tempo at the first item)
  - Loop start in beats
  - Loop length in beats
  - Loop crossfade in beats
- Internally the script reads RS5k formatted values and computes
  the best matching normalized parameter values, so you can think
  in ms, dB and beats rather than knob positions.
- The script is careful to keep the attack region of the sample.
  It does not move the "Start in source" offset, and only shortens
  the "End in source" parameter when a finite loop window is set.

### 4.3. Using the script

1. Prepare your audio items:
   - Each item should contain one note or sound that you want to map.
   - It is helpful if the take or file names contain note names
     (C2, D#2, F3, Bb4, etc), as this improves automatic mapping.
2. Create or select the track that will host the RS5k instances.
3. Select all audio items you want to turn into a multisample.
4. Run `RS5kMapping.lua`.
5. First dialog: Base pitch
   - Enter a MIDI note number (0 to 127) used as fallback when
     no note can be parsed from names.
6. Second dialog: ADSR and loop defaults
   - Attack (ms)
   - Decay (ms)
   - Release (ms)
   - Sustain (dB)
   - Obey note offs (0 or 1)
   - Loop (0 or 1)
   - BPM import (0 means use project tempo)
   - Loop start (beats)
   - Loop length (beats)
   - Loop xfade (beats)
7. Confirm.

The script will:
- insert one RS5k instance per item on the selected track,
- map each instance to its MIDI note,
- set the ADSR and loop parameters according to your input,
- create a MIDI item that triggers all samples.

You can now play or sequence this RS5k instrument inside REAPER
or as part of a Reactional Music authoring workflow.

---

## 5. Credits and licensing

`RS5kMapping.lua` started as a fork of MPLs
"Export selected items to RS5k instances on selected track (use original source)".
The logic has been extended with note name parsing, parameter handling
in ms/dB, and loop control in beats and BPM.

The other two scripts were written specifically to support sampling
and Reactional oriented workflows, but you are free to adapt them
for your own projects.

Please keep the credit lines to MPL and ez999 if you publish
modified versions, and feel free to share improvements back with the
community.

