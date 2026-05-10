# Balance Breakdown

All numbers pulled from `client/game/*.odin` as of this snapshot. Cross-references in `file:line` form so it's easy to jump to the source.

## Resources

| | value | source |
|---|---|---|
| Starting food | 30 | `world.odin:20` |
| Sell refund | cost × 0.5 | `world.odin:211` |
| Tick rate | 10 Hz (food granted continuously) | `game.odin:103` |

Scrap is awarded but **never spent** anywhere — it's a dead currency right now (`combat.odin:154`). That's a balance lever sitting unused.

## Build costs (food)

| Tile | Cost | T1→T2 | T2→T3 | Total to T3 |
|---|---|---|---|---|
| Wall | 3 | 3 | 6 | **12** |
| Wire | 4 | — | — | 4 |
| Farm | 5 | 5 | 10 | **20** |
| Relay | 8 | 8 | 16 | **32** |
| Generator | 10 | 10 | 20 | **40** |
| Turret | 15 | 15 | 30 | **60** |

Source: `world.odin:126` (cost), `world.odin:45` (upgrade = base × current_tier).

## Tile HP

| Tile | T1 | T2 | T3 |
|---|---|---|---|
| Core | 200 | — | — |
| Wall | 200 | 350 | 500 |
| Turret | 80 | 96 | 112 |
| Generator | 60 | 69 | 78 |
| Relay | 50 | 60 | 70 |
| Farm | 50 | 57.5 | 65 |
| Wire | 30 | — | — |

Source: `world.odin:217`.

## Farm output (the headline issue)

| Tier | food/s | Time to recoup tile | Time to recoup tile + upgrades |
|---|---|---|---|
| T1 | 1.0 | 5.0 s | 5.0 s |
| T2 | 1.6 | 3.1 s | 9.4 s (cost 15) |
| T3 | 2.4 | 2.1 s | 8.3 s (cost 20) |

Source: `world.odin:64`.

A farm pays itself off **in five seconds** at the worst tier. Compounding 5–10 farms during the 30 s grace period means the player walks into wave 1 with effectively unlimited build budget.

## Turret combat

| | value | source |
|---|---|---|
| Range | 280 px | `combat.odin:5` |
| Fire interval | 0.9 s | `combat.odin:6` |
| Base damage | 8 | `combat.odin:7` |
| T2/T3 damage | 12.8 (×1.6) | `world.odin:81` |
| T3 back gun | yes (doubles DPS) | `world.odin:88` |
| Projectile speed | 640 px/s | `combat.odin:11` |
| Aim tolerance | ~10° | `combat.odin:9` |

| Turret | DPS | Crawler TTK | Brute TTK | Spitter TTK |
|---|---|---|---|---|
| T1 | 8.89 | 2.25 s | 11.25 s | 3.38 s |
| T2 | 14.22 | 1.41 s | 7.03 s | 2.11 s |
| T3 (back gun) | 28.44 | 0.70 s | 3.52 s | 1.05 s |

T3 isn't 1.4× T2 — it's **2×** T2 because the back gun fires the same damage. That's a sharp power spike.

## Enemies

| Kind | HP | Speed (px/s) | Damage (per s, contact) | Range | Scrap |
|---|---|---|---|---|---|
| Crawler | 20 | 80 | 10 | melee | 1 |
| Brute | 100 | 35 | 30 | melee | 4 |
| Spitter | 30 | 55 | 14 | 70 px standoff | 2 |

Source: `enemies.odin:30`, `combat.odin:40`. Damage is *applied per second while in contact* (`enemies.odin:191`), not on a tick — a Brute hugging a Wall does 30 dmg/s, killing a T1 Wall (200 hp) in 6.7 s.

## Wave timing

| | value | source |
|---|---|---|
| Grace period (no spawns) | 30 s | `waves.odin:5` |
| First surge | 90 s | `waves.odin:6` |
| Surge gap | `max(90 / surge_index, 30)` s | `waves.odin:141` |
| Surge duration | 4 s | `waves.odin:8` |
| Trickle base interval | 8 s | `waves.odin:11` |
| Trickle ramp | −0.04 s/s | `waves.odin:12` |
| Trickle floor | 0.6 s | `waves.odin:13` |

Trickle interval at time `t` (after grace): `max(8 − 0.04·t, 0.6)`. Hits the floor at **t = 185 s**.

Surge gap math (note `surge_index` increments *after* the surge fires, then divides):

| After surge # | Next gap |
|---|---|
| 1 | 90 / 1 = 90 s |
| 2 | 90 / 2 = 45 s |
| 3 | 90 / 3 = 30 s (clamped) |
| 4+ | 30 s (floor) |

Surges arrive at: **90, 180, 225, 255, 285, 315, …** (s).

## Surge composition

`crawlers = 8 + 2·i`, `brutes = 2 + 2·i`, `spitters = 2 + i` where `i` is 0-based surge index. (`waves.odin:67`)

| Surge | Crawlers | Brutes | Spitters | Total HP arriving | Scrap on full clear |
|---|---|---|---|---|---|
| 1 | 8 | 2 | 2 | 8·20 + 2·100 + 2·30 = **420** | 8 + 8 + 4 = 20 |
| 2 | 10 | 4 | 3 | 200 + 400 + 90 = **690** | 30 |
| 3 | 12 | 6 | 4 | 240 + 600 + 120 = **960** | 40 |
| 4 | 14 | 8 | 5 | 280 + 800 + 150 = **1230** | 50 |
| 5 | 16 | 10 | 6 | 320 + 1000 + 180 = **1500** | 60 |
| 6 | 18 | 12 | 7 | 360 + 1200 + 210 = **1770** | 70 |

Surges spawn over 4 s, so DPS pressure on the wall = (incoming HP) / 4 / (player DPS). Surge 1 needs ~105 DPS sustained to no-leak — that's **12 T1 turrets** simultaneously on target, which is unrealistic given line-of-sight, target switching, and aim ramp-up.

## Power & range

| | T1 | T2 | T3 |
|---|---|---|---|
| Generator radius (hexes) | 1 | 2 | 3 |
| Relay build radius (hexes) | 2 (= `BUILD_RANGE`) | 3 | 4 |

A T1 generator powers up to 6 adjacent hexes (a hex ring). Turrets are the only consumer (`world.odin:139`).

## Headline issues

1. **Farm payback is 5 s.** Even ignoring upgrades the player snowballs during the 30 s grace. Pre-surge food intake is unbounded.
2. **T3 turret is a 2× spike** rather than the smooth `+30%`-style scaling the rest of the system uses (Wall, HP). Either retune T3 damage to ×2.0 base (instead of ×1.6 + back gun) or make the back gun cost something.
3. **Scrap is dead.** Awarded on kills but spent nowhere; surges currently have zero economic feedback.
4. **Trickle hits its floor at 185 s** — past surge 2 (180 s) the only real threat is the surge timer, since trickle plateaus at 1 crawler / 0.6 s = 1.67/s forever.
5. **Surge gap clamps at 30 s after surge 3** with linear composition growth. Difficulty is bounded by linear HP growth at fixed cadence — no exponential pressure curve.
6. **Wall HP/cost is the best ratio in the game** (T3 wall = 500 HP for 12 food). The "use scrap for X" hole probably belongs filled with a Wall sink.

## See also

`balance.html` in this directory — open it in a browser for an interactive sim that lets you tweak every number above and watch the curves live.
