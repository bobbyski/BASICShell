# ENVELOPE Statement


Defines how a note's loudness and pitch change while it plays, the way BBC
BASIC's `ENVELOPE` does. `SOUND` then plays a note shaped by it when the note's
amplitude is the envelope's number instead of a fixed loudness.

```basic
envelope 1, 1, 0, 0, 0, 0, 0, 0, 126, -4, -1, -2, 126, 80
```

That is a plucked note: it jumps to full loudness, falls quickly to 80, fades
slowly while it lasts, and dies away after.

## The fourteen numbers

```text
ENVELOPE N, T, PI1, PI2, PI3, PN1, PN2, PN3, AA, AD, AS, AR, ALA, ALD
```

| | Range | Means |
| --- | --- | --- |
| `N` | 1 to 16 | Which envelope this defines. |
| `T` | 0 to 255 | The length of one step, in hundredths of a second (0 counts as 1). Add 128 to play the pitch sections once instead of repeating them. |
| `PI1` `PI2` `PI3` | -128 to 127 | How far the pitch moves each step in each of the three pitch sections, in quarter semitones. |
| `PN1` `PN2` `PN3` | 0 to 255 | How many steps each pitch section lasts. |
| `AA` | -127 to 127 | Attack: how much louder each step, from silence up to `ALA`. |
| `AD` | -127 to 127 | Decay: how much each step moves from `ALA` to `ALD`. |
| `AS` | -127 to 0 | Sustain: how much quieter each step while the note lasts. 0 holds it steady. |
| `AR` | -127 to 0 | Release: how much quieter each step after the note ends, until silent. 0 never fades: the note lasts until the next one on its channel cuts it off. |
| `ALA` | 0 to 126 | The loudness the attack climbs to. 126 is the loudest. |
| `ALD` | 0 to 126 | The loudness the decay moves to. |

```text
  loudness 126 ┤    ALA
               │   ╱╲___ALD
               │  ╱     ╲______ sustain, AS a step
               │ ╱ AA  AD      ╲ release, AR a step, after the note's duration
             0 ┼╱───────────────╲──────►  one step every T hundredths of a second
```

Pitch moves `PN1` steps of `PI1`, then `PN2` of `PI2`, then `PN3` of `PI3`, and
then round again unless `T` had 128 added. It carries on from where it is each
time round, so a vibrato's sections are written to add up to zero: `1, -1, 0`
with `PN1` and `PN2` equal wobbles the pitch and brings it back. Pitch wraps
within 0 to 255, as the BBC's did.

## Errors

A number outside its range, an envelope number outside 1 to 16, or a count
other than fourteen is *Illegal function call*. Defining an envelope needs no
sound device; playing a note with one does.

Not modeled: the `SOUND` hold digit, which on the BBC lengthens a release.
