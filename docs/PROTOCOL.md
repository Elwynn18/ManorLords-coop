# Wire protocol (version 1)

One TCP connection, host listens (default port 27015), guest connects. UTF-8 text lines ending in
`\n`, except file transfers. Lord names are escaped: `%` and whitespace become `%XX`. Coordinates
are Unreal units (cm) as decimal text unless said otherwise; shape points are integers in tenths
of a unit.

## Session

| Direction | Message | Meaning |
|---|---|---|
| guest -> host | `HELLO <proto> <modVersion> <gameVersion> <lord>` | `gameVersion` is the escaped `GI.Version` string; both sides must match |
| host -> guest | `WELCOME <proto> <modVersion>` | accepted; the world follows |
| host -> guest | `REFUSE <reason> [detail]` | `mod_version`, `game_version`, `lord_name_taken`; host closes nothing, guest stops |
| host -> guest | `FILE <name> <length>` + `length` raw bytes | a file of the save folder: `coop_world.sav`, `coop_world_descr.sav`, `coop_world_coat_N.png`; the guest refuses any other name, the host refuses every file |
| host -> guest | `REGION <tag> <owner\|-> <settled 0/1>` | the host's ownership table (one per region) |
| host -> guest | `HOST_LORD <lord>` | the host's lord name (the save does not keep the pawn's name) |
| host -> guest | `WORLD_SENT <slot>` | all world files and tables sent |
| guest -> host | `SETTLE <lord> <regionTag> <x> <y> <z> <seed>` | the guest settled this region at this spawner; host does the same for its passive copy, after `srand(seed)` |
| host -> guest | `SETTLE_OK <lord> <tag>` / `SETTLE_REFUSED <tag>` | refused when the region is not free on the host |
| host -> guest | `LORD_SETTLE <lord> <tag> <x> <y> <z> <seed>` | a new host-owned lord settled a region (guest makes a passive copy) |

## World facts (both directions, for lords the sender owns)

| Message | Meaning |
|---|---|
| `BLD <lord> <id> <type> <x> <y> <z> <yaw>` | a building was set up (`id` is the sender's building id, informative) |
| `FLD <lord> <id> <type> <x> <y> <z> <yaw> <workers> <flag> <clockwise> P <n> <xyz>... B <n> <xyz>... H <hex48> <hex192>` | a building with a shape (field, pasture, market, residential plot): FieldPoints, fieldBorderPoints and the plot geometry blocks it had when `SetupBuilding` ran |
| `RM <lord> <x> <y> <z>` | a building of that lord at that place is gone (receiver removes the nearest within 1 m) |
| `ROAD <lord> 1 <start xyz> <n> <xyz>...` | a successful road commit (tenths); receiver replays it on the passive lord |
| `DAY <daysTotal>` (host -> guest) | calendar; guest calls `setDay` if it differs |

## Native helper commands (Lua -> coopnative.dll, through `writeUnitDebugLog`)

`ping`, `build`, `buildlocal`, `fieldbuild`, `testfield`, `srand`, `cursor`, `remote 0|1`,
`net host <port>`, `net join <ip> <port>`, `net send <text>`, `net sendfile <name>`.
Lab only: `hover <pawn> <building|0>` (what the cursor does: the pawn's hovered building changes),
`peek <building>` (logs whether the building and its marker component still look alive).
Outbox lines (native -> Lua): `setup 0x<addr> <id> <type> local|remote|field|road`,
`fielddata 0x<addr> <payload>`, `road 0x<pawn> <payload>`.
Inbox lines: `NATIVE ready|refused ...`, `NET listening|connecting|connected|disconnected|error ...`,
`MSG <line>`, `FILE_DONE <name>`, `PONG <version>`.
