# AppleBar

A compact raid marker bar for **TurtleWoW** (vanilla 1.12 client). Designed for efficient mob marking during groups and raids, with intelligent auto-mark memory that learns from your marking habits over time.

## Requirements

- **[SuperWoW](https://github.com/balakethelock/SuperWoW)** *(required)* — extends the vanilla Lua API with GUID-based unit functions
- **[UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3)** *(optional but recommended)* — enables accurate yard-based range checks (100yd) and proximity detection. Without it, range checks fall back to ~28yd
- **[AutoMarker](https://github.com/Smuu/AutoMarker)** *(optional)* — if loaded, AppleBar reads AutoMarker's NPC pack databases and unit cache to power smarter auto-marking

---

## Installation

Drop the `AppleBar/` folder into `Interface/AddOns/`. Requires SuperWoW to be installed and active.

---

## The Bar

A single row of 10 buttons:

```
[Skull][Cross][Square][Moon][Triangle][Diamond][Circle][Star] [Apple] [Scroll]
  ↑ 8 raid mark slots                                         ↑ Auto  ↑ Clear/Save
```

Use `/ab flip` to mirror the layout (utility buttons on the left, marks on the right).

### Mark slots (8 icons)

| Click | Behavior |
|---|---|
| **Left-click** | Target the mob carrying that mark |
| **Right-click (with target)** | Assign this mark to your current target |
| **Right-click (no target)** | Clear this mark |

Icons are **color-coded** based on state:
- **Full bright** — marked, mob is alive and within 100 yards
- **Red** — marked, but mob is dead or out of range
- **Faded (30%)** — slot is empty

Slots **sort dynamically**: active marks (alive mobs) cluster together, inactive marks (empty or dead) push to the other side. Both groups sort skull-first within their half.

### Apple button (AutoMark)

| Click | Behavior |
|---|---|
| **Left-click** | Mark the target's pack immediately (like `/am mark`) |
| **Right-click** | Toggle auto-mark mode on/off (green glow when active) |

### Scroll button (Clear/Save)

| Click | Behavior |
|---|---|
| **Left-click** | Clear all 8 marks (requires leader/assist in a group) |
| **Right-click** | Save currently marked mobs as a remembered pack for this zone |

---

## Auto-Mark Mode

When auto-mark mode is **ON** (right-click the Apple button), AppleBar automatically marks mobs as you target them.

### What gets marked

- **Elite mobs** — always marked when targeted
- **Non-elite mobs** — only marked if they have a previously observed or manually saved mark assignment
- **Packs** — if the target has elite mobs nearby (within 20 yards), the entire group is marked at once

### Mark priority

When deciding what mark to assign, AppleBar checks in this order:

1. Your manual override for this specific mob (GUID)
2. Your manual override matched by NPC ID (catches respawns with new GUIDs)
3. AutoMarker's runtime pack tables (if AutoMarker is loaded)
4. AutoMarker's default NPC database (if AutoMarker is loaded)
5. Learned consensus from observed marks (see below)
6. Next free mark slot (elites first, skull down to star)

### Elite prioritization

Within a pack, elites are sorted first and receive higher-priority marks (skull, then cross, then square, etc.). Non-elites fill remaining slots after elites have been assigned.

---

## Mark Memory

AppleBar remembers your marking choices across sessions using three layers of data stored in `AppleBarDB`:

### 1. Manual overrides (`guidMarkOverrides`)

When you right-click a mark slot to assign it to a target, AppleBar saves `NPC ID + name → mark index`. This overrides any default or learned mark for that mob type going forward.

### 2. Custom packs (`customPacks`)

When you **right-click the Scroll button**, AppleBar saves all currently marked mobs as a named pack for the current zone. Packs include:
- The GUID of each mob at save time
- The NPC ID (extracted from the GUID) for respawn matching
- The mob name as a fallback identifier
- The mark index assigned

When looking up a pack, AppleBar matches on GUID first, then falls back to NPC ID — so packs still work correctly after a reset that gives mobs new GUIDs.

Right-clicking also performs a **proximity sweep**: any marked mobs within 20 yards of a saved mob are automatically included in the pack, using social aggro range as the grouping baseline.

### 3. Observation learning (`observations`)

AppleBar passively observes every `RAID_TARGET_UPDATE` event — from anyone in your group or raid — and records a full history of every mark assigned to each NPC type. For each NPC, it tracks how many times each mark index has been observed across all sessions, accumulating over time.

When deciding what mark to assign, the mark with the highest observation count for that NPC type wins. A minimum of 2 observations is required before a learned mark is used, filtering out one-off noise from unusual or accidental assignments.

Over many sessions, the consensus naturally self-corrects — if skull goes on the healer 15 out of 17 times, skull wins regardless of the two outliers.

**Junk filtering**: marks assigned by AppleBar's own free-slot fallback in auto-mode (random assignments on unknown mobs) are flagged and excluded from the observation data, preventing noise from accumulating. Only intentional marks — from raid leaders, assists, or yourself via manual slot right-click — are recorded.

---

## Slash Commands

| Command | Description |
|---|---|
| `/ab` | Show help |
| `/ab auto` | Toggle auto-mark mode |
| `/ab mark` | Mark target/group now (like `/am mark`) |
| `/ab clear` | Clear all 8 marks |
| `/ab flip` | Mirror the bar orientation |
| `/ab scale 0.8` | Set bar scale (0.3 – 3.0) |
| `/ab lock` | Toggle drag lock |
| `/ab reset` | Reset bar position to center screen |
| `/ab clearoverrides` | Wipe all overrides, custom packs, and observations |
| `/ab show` / `/ab hide` | Show or hide the bar |

---

## Without AutoMarker

AppleBar works standalone. Without AutoMarker loaded, the NPC pack database and unit cache are unavailable, but all AppleBar-native features still work:

- Manual mark assignments are remembered by NPC ID
- Packs you save with right-click are stored and reused
- Observation learning still runs from any marks set in the session
- Proximity-based pack marking falls back to target-only (no unit cache to scan)
- Range checks fall back to ~28yd if UnitXP_SP3 is also not loaded

Over time, AppleBar builds its own mark memory organically from your manual marking behavior, becoming progressively smarter about your usual packs without requiring any explicit setup.

---

## SavedVariables

All data is stored in `AppleBarDB` in your WTF folder. Use `/ab clearoverrides` to wipe everything and start fresh.
