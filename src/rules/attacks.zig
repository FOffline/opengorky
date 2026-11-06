//! Built-in rules: attacks.ss (battle/attacks.zig resolves them).

const rows = @import("rows.zig");
const Num = rows.Num;
const adj = Num.adj;
const n = Num.n;
const S = "short_attack";
const L = "long_attack";
const sf: Num = adj("sf_delay", 30);

/// McFadden (24) and Hutchens (29) have waits shifted by wdelay_* (0x4896f4…0x48973c).
pub const wdelay_heroes = [_]rows.WdelayHero{ .{ .hero = 24, .note = "McFadden" }, .{ .hero = 29, .note = "Hutchens" } };

/// Hero attack (0x48bda2): animation and hit wait by weapon classic_id (the exe ignores
/// `useAnim`). `extra` (wdelay_heroes only): `+` for bayonet knife, pistol (49), shocker
/// (52), shotgun, rifle (98) and grenades, `−` for fist and bat; other weapons have no
/// shift (revolver 50, shocker 55, default rifle).
/// `until_end`: the hit comes after the animation ends (0x428800 queues it, the
/// callback follows), then animation `then`.
/// `after`: wait after the hit until the attack ends (0x428c00 before 0x425630):
/// pistol, rifle and shotgun flash attack_rifle_flash_timeout (5), chaingun
/// attack_chaingun_flash_timeout (80), nitrogen gun attack_nitro_timeout (80).
/// `pre`: beam tick before the hit. For the ion rifle and blaster the callback sets
/// the beam (0x1a → 0x4a2680, 0x1c → 0x4a37c0) and damage comes later: ion when
/// less than 5 ticks of the beam's life (attack_ion_life 27) remain (0x4a1840),
/// blaster with the next callback 5 after attack_blaster_delay2 (14).
pub const hero_attacks = [_]rows.HeroAttack{
    // Fists: attack_fist_hit_delay (50) − wdelay_fist (12), callback 5.
    .{ .weapon = 48, .anim = "attack_boxing", .wait = adj("attack_fist_hit_delay", 50), .extra = .{ .a = .{ .name = "wdelay_fist", .d = 12, .neg = true } }, .note = "fist" },
    .{ .weapon = 70, .anim = "attack_boxing", .wait = adj("attack_fist_hit_delay", 50), .extra = .{ .a = .{ .name = "wdelay_fist", .d = 12, .neg = true } }, .note = "fist" },
    // Bayonet: attack_bayonet_hit_delay (22) + wdelay_bayonet (10); dagger 28.
    .{ .weapon = 43, .anim = "attack_butcher", .wait = adj("attack_bayonet_hit_delay", 22), .extra = adj("wdelay_bayonet", 10), .note = "bayonet" },
    .{ .weapon = 54, .anim = "attack_butcher", .wait = n(28), .note = "dagger" },
    .{ .weapon = 42, .anim = "attack_axe", .wait = n(30), .note = "axe" },
    .{ .weapon = 47, .anim = "attack_axe", .wait = n(30) },
    // Bat: attack_baseball_hit_delay (65) − wdelay_baseball (10) (0x48c416).
    .{ .weapon = 44, .anim = "attack_baseball", .wait = adj("attack_baseball_hit_delay", 65), .extra = .{ .a = .{ .name = "wdelay_baseball", .d = 10, .neg = true } }, .note = "crowbar (0x48c416)" },
    .{ .weapon = 76, .anim = "attack_baseball", .wait = adj("attack_baseball_hit_delay", 65), .extra = .{ .a = .{ .name = "wdelay_baseball", .d = 10, .neg = true } }, .note = "bat" },
    // Shocker 52: + wdelay_shocker (30); 55 has no shift (0x48c287).
    .{ .weapon = 52, .anim = "attack_shocker", .wait = n(20), .extra = adj("wdelay_shocker", 30), .note = "shocker (0x48c287)" },
    .{ .weapon = 55, .anim = "attack_shocker", .wait = n(20), .note = "shocker, no shift" },
    .{ .weapon = 80, .anim = "attack_syringe", .wait = n(30) },
    .{ .weapon = 40, .anim = "attack_knife", .wait = n(25), .note = "throwing knife" },
    .{ .weapon = 41, .anim = "attack_stone", .wait = n(32), .note = "stone" },
    // Grenades: attack_grenade_start_delay (37) + wdelay_grenade (36) (0x48c359,
    // 0x48c398, 0x48cdb1).
    .{ .weapon = 33, .anim = "attack_grenade", .wait = adj("attack_grenade_start_delay", 37), .extra = adj("wdelay_grenade", 36), .note = "grenades (0x48c359, 0x48c398, 0x48cdb1)" },
    .{ .weapon = 35, .anim = "attack_grenade", .wait = adj("attack_grenade_start_delay", 37), .extra = adj("wdelay_grenade", 36) },
    .{ .weapon = 1027, .anim = "attack_grenade", .wait = adj("attack_grenade_start_delay", 37), .extra = adj("wdelay_grenade", 36) },
    // Molotov, vodka, petrol: "molotov" (75) only for Hutchens, "stone" for others.
    .{ .weapon = 86, .hero = 29, .anim = "attack_molotov", .wait = n(75), .note = "molotov, vodka, petrol: Hutchens throws, others as a stone" },
    .{ .weapon = 86, .anim = "attack_stone", .wait = n(32) },
    .{ .weapon = 1030, .hero = 29, .anim = "attack_molotov", .wait = n(75) },
    .{ .weapon = 1030, .anim = "attack_stone", .wait = n(32) },
    .{ .weapon = 1032, .hero = 29, .anim = "attack_molotov", .wait = n(75) },
    .{ .weapon = 1032, .anim = "attack_stone", .wait = n(32) },
    // Time bomb (0x48c507) and decoy (0x48d261): McFadden and Hutchens use
    // attack_timebomb and 50 ticks (0x48c5c9, 0x48d31f), others pickup_start to the
    // end, callback (37 / 5), pickup_end.
    .{ .weapon = 34, .hero = 24, .anim = "attack_timebomb", .wait = n(50), .note = "time bomb (0x48c507), decoy (0x48d261)" },
    .{ .weapon = 34, .hero = 29, .anim = "attack_timebomb", .wait = n(50) },
    .{ .weapon = 34, .anim = "pickup_start", .wait = n(0), .until_end = true, .then = "pickup_end" },
    .{ .weapon = 1031, .hero = 24, .anim = "attack_timebomb", .wait = n(50) },
    .{ .weapon = 1031, .hero = 29, .anim = "attack_timebomb", .wait = n(50) },
    .{ .weapon = 1031, .anim = "pickup_start", .wait = n(0), .until_end = true, .then = "pickup_end" },
    .{ .weapon = 45, .anim = "attack_gun", .wait = adj("attack_dartgun_delay", 40), .note = "dartgun" },
    .{ .weapon = 46, .anim = "attack_gun", .wait = n(35), .note = "flare gun" },
    // Pistol: attack_dartgun_delay (40) + wdelay_pistol (3); the revolver (50) has
    // no shift (0x48c0be). After the shot, a 5-tick flash.
    .{ .weapon = 49, .anim = "attack_gun", .wait = adj("attack_dartgun_delay", 40), .extra = adj("wdelay_pistol", 3), .after = adj("attack_rifle_flash_timeout", 5), .note = "pistol (0x48c0be)" },
    .{ .weapon = 50, .anim = "attack_gun", .wait = adj("attack_dartgun_delay", 40), .after = adj("attack_rifle_flash_timeout", 5), .note = "revolver" },
    .{ .weapon = 98, .anim = "attack_sniper", .wait = n(59), .extra = n(35), .after = adj("attack_rifle_flash_timeout", 5), .note = "rifle" },
    .{ .weapon = 1023, .anim = "attack_rifle", .wait = n(40), .extra = n(15), .after = adj("attack_rifle_flash_timeout", 5), .note = "shotgun" },
    .{ .weapon = 1022, .anim = "attack_chaingun", .wait = n(40), .after = adj("attack_chaingun_flash_timeout", 80), .note = "chaingun" },
    .{ .weapon = 1024, .anim = "attack_bazooka", .wait = n(47), .note = "rocket launcher" },
    .{ .weapon = 1028, .anim = "attack_bazooka", .wait = n(50), .note = "napalm launcher" },
    .{ .weapon = 1026, .anim = "attack_flame", .wait = n(20), .note = "flamethrower" },
    .{ .weapon = 1025, .anim = "attack_flame", .wait = n(34), .after = adj("attack_nitro_timeout", 80), .note = "nitrogen gun" },
    // Ion: beam at tick 35, damage 23 later (27 − 4), end attack_ion_life + 10 (37)
    // after the beam (0x48d078).
    .{ .weapon = 1029, .anim = "attack_ionrifle", .wait = .{ .c = 31, .a = .{ .name = "attack_ion_life", .d = 27 } }, .pre = n(35), .after = n(14), .note = "ion rifle (0x48d078)" },
    // Blaster (0x48d0a5): stream at tick 45 (delay1), damage after delay2 (14), end
    // after delay3 (100).
    .{ .weapon = 1037, .anim = "attack_blaster", .wait = .{ .c = 45, .a = .{ .name = "attack_blaster_delay2", .d = 14 } }, .pre = n(45), .after = n(100), .note = "blaster (0x48d0a5)" },
    // Satellite: the exe passes "ude_radio" (a typo, no such animation).
    .{ .weapon = 1038, .anim = "ude_radio", .wait = n(0), .note = "satellite (the exe's typo: no such animation)" },
    .{ .weapon = 1039, .anim = "ude_radio", .wait = n(0) },
    .{ .weapon = 1040, .anim = "use_radio", .wait = n(0) },
    // Everything else (0x48d57c): attack_rifle, attack_rifle_hit_delay (59), no shift.
    .{ .weapon = 0, .anim = "attack_rifle", .wait = adj("attack_rifle_hit_delay", 59), .note = "every other weapon (0x48d57c)" },
};

pub const monster_attacks = [_]rows.MonsterAttack{
    // Jet Elmer (0x48a05d): with rockets (57) long_attack, first rocket after
    // attack_jetelmer_delay1 (43), the second delay2 (28) later, then 30 ticks;
    // 56 short_attack (0x48a152): hit (code 5) after attack_jetelmer_delay (36), a
    // second hit after ftol(attack_jetelmer_scr) (12.0), tail 0x48b864 (30).
    .{ .fighter = 100, .weapon = 57, .anim = L, .hit_delay = adj("attack_jetelmer_delay1", 43), .second_delay = n(28), .after_delay = n(30), .note = "Jet Elmer, rockets (0x48a05d)" },
    .{ .fighter = 100, .anim = S, .hit_delay = adj("attack_jetelmer_delay", 36), .second_delay = adj("attack_jetelmer_scr", 12), .after_delay = n(30), .note = "Jet Elmer, two hits (0x48a152)" },
    // Garcia (0x4897fc): 67 long_attack, chaingun flash and light at
    // garcia_attack_long_delay1 (41), hit delay2 (10) later, then delay3 (20) and
    // sf_delay (30); 66 short_attack, hit after short_delay + delay2 (25 + 20),
    // reaction without damage (code 7) delay3 (20) later, sf_delay (30).
    .{ .fighter = 101, .weapon = 67, .anim = L, .hit_delay = .{ .c = 10, .a = .{ .name = "garcia_attack_long_delay1", .d = 41 } }, .after_delay = .{ .c = 20, .a = sf.a }, .flash_delay = adj("garcia_attack_long_delay1", 41), .note = "Garcia, chaingun (0x4897fc)" },
    .{ .fighter = 101, .anim = S, .hit_delay = n(45), .react_delay = 20, .after_delay = sf, .note = "Garcia, short" },
    // Sphinx (0x489a2e, weapon 73): hit after sphinx_attack_short_delay (28),
    // reaction without damage (code 7) delay2 (20) later, then sf_delay (30).
    .{ .fighter = 102, .anim = S, .hit_delay = adj("sphinx_attack_short_delay", 28), .react_delay = 20, .after_delay = sf, .note = "Sphinx (0x489a2e)" },
    // Cutter Pill (0x489afd): weapon 88 lifts on the claw ("hand"), hit at tick 52
    // (short_delay1 + delay2: 37 + 15), then delay3 (50), release, and 80 more
    // (0x489d40); 89 long_attack, bullet (code 13) after long_start_delay 35.
    .{ .fighter = 105, .weapon = 88, .anim = S, .hit_delay = n(37 + 15), .after_delay = n(50 + 80), .lift_delay = 37, .drop_delay = 50, .note = "Cutter Pill, claw (0x489afd)" },
    .{ .fighter = 105, .anim = L, .hit_delay = n(35), .note = "Cutter Pill, bullet" },
    // RC-28 (0x489d5d, weapon 92): rc28_attack_short_delay (25), then sf_delay (30).
    .{ .fighter = 106, .anim = S, .hit_delay = adj("rc28_attack_short_delay", 25), .after_delay = sf, .note = "RC-28 (0x489d5d)" },
    // Fang (0x489dd5): 91 long_attack, rocket (code 16) after long_delay1 + delay2
    // (22 + 35), then 30; 90 short_attack after short_delay (28).
    .{ .fighter = 107, .weapon = 91, .anim = L, .hit_delay = n(22 + 35), .after_delay = n(30), .note = "Fang, rocket (0x489dd5)" },
    .{ .fighter = 107, .anim = S, .hit_delay = n(28), .note = "Fang, short" },
    // Hound (0x48b46e), Siner (0x48a372): hit after their own delay, then 30
    // (common tail 0x48b864).
    .{ .fighter = 108, .anim = S, .hit_delay = n(23), .after_delay = n(30), .note = "Hound (0x48b46e)" },
    .{ .fighter = 109, .anim = S, .hit_delay = n(40), .after_delay = n(30), .note = "Siner (0x48a372)" },
    // Smoke Rider (0x489e9d): 1003 (smokeridergun) long_attack, rocket (code 19)
    // after attack_smokerider_shot_delay (51), then 30; 1004 ladder_start, callback 21
    // (0x487698) after attack_smokerider_shot2_delay (0): the gunner's long_attack
    // (combat/anim.zig), and after attack_smokerider_shot3_delay (20) a rocket of the
    // second kind (code 20, smokerider_attack2_rocket1_*).
    .{ .fighter = 110, .weapon = 1003, .anim = L, .hit_delay = adj("attack_smokerider_shot_delay", 51), .after_delay = n(30), .note = "Smoke Rider, gun (0x489e9d)" },
    .{ .fighter = 110, .weapon = 1004, .anim = "ladder_start", .hit_delay = .{ .a = .{ .name = "attack_smokerider_shot2_delay", .d = 0 }, .b = .{ .name = "attack_smokerider_shot3_delay", .d = 20 } }, .after_delay = n(30), .linked_anim = L, .note = "Smoke Rider, the gunner's rocket (callback 21, 0x487698)" },
    .{ .fighter = 110, .anim = "ladder_start", .hit_delay = .{ .a = .{ .name = "attack_smokerider_shot2_delay", .d = 0 }, .b = .{ .name = "attack_smokerider_shot3_delay", .d = 20 } }, .after_delay = n(30), .note = "Smoke Rider, other weapons" },
    // Grandma (0x489f71): by weapon, not longAttack: 1006 (grandma_mad_gun, poison
    // spit "atak", code 22) long_attack, 1005 (grandma_std) short_attack; both after
    // attack_grandma_delay (70), then 30.
    .{ .fighter = 113, .weapon = 1006, .anim = L, .hit_delay = adj("attack_grandma_delay", 70), .after_delay = n(30), .note = "Grandma, poison spit (0x489f71)" },
    .{ .fighter = 113, .anim = S, .hit_delay = adj("attack_grandma_delay", 70), .after_delay = n(30), .note = "Grandma, short" },
    // Grandma's grandson (0x489f55): long_attack, attack_grandson_delay (30), then 30.
    .{ .fighter = 114, .anim = L, .hit_delay = adj("attack_grandson_delay", 30), .after_delay = n(30), .note = "Grandson (0x489f55)" },
    // Judge (0x48bc72) and his child (0x48bd0a): judge_delay/delay2 (42/30),
    // judgechild_delay/delay2 (30/40).
    .{ .fighter = 115, .anim = S, .hit_delay = n(42), .after_delay = n(30), .note = "Judge (0x48bc72)" },
    .{ .fighter = 116, .anim = S, .hit_delay = n(30), .after_delay = n(40), .note = "Judge's child (0x48bd0a)" },
    // Shoggoth (0x489fe2, weapon 1015): tail after attack_shogoth_tail_delay (30).
    .{ .fighter = 117, .anim = S, .hit_delay = adj("attack_shogoth_tail_delay", 30), .note = "Shoggoth (0x489fe2)" },
    // Headnail (0x48a72b): two saw strikes, left after delay1+2+3 (30+5+8), right
    // delay4+5 (5+32) later, then delay6 (5); each with sparks and damage.
    .{ .fighter = 118, .strike = 118, .anim = S, .hit_delay = .{ .c = 5 + 8, .a = .{ .name = "attack_headnail_delay1", .d = 30 } }, .second_delay = .{ .c = 32, .a = .{ .name = "attack_headnail_delay4", .d = 5 } }, .after_delay = n(5), .note = "Headnail, two saws (0x48a72b)" },
    // Medusa (0x48a465): 1021 short_attack, hit after attack_medusa_s_delay 47, the
    // mouth beam lasts attack_medusa_s_timeout 72; otherwise long_attack, current
    // (callback 0x1f → 0x4a44e0) after attack_medusa_l_delay 32, then delay2 30 and
    // 20 more ticks.
    .{ .fighter = 119, .strike = 119, .weapon = 1021, .anim = S, .hit_delay = adj("attack_medusa_s_delay", 47), .after_delay = adj("attack_medusa_s_timeout", 72), .note = "Medusa, mouth beam (0x48a465)" },
    .{ .fighter = 119, .strike = 119, .anim = L, .hit_delay = adj("attack_medusa_l_delay", 32), .after_delay = n(50), .note = "Medusa, current (0x4a44e0)" },
    // Invisible (0x48a2a6, any weapon): short_attack ("atak", 76 frames, hit sounds
    // at 32–34), visible at once (+0x311c = 255) and fading in (command 0x2d, state
    // 6 "o", in_fadein); hit after attack_invisible_delay (40); 40 later it vanishes
    // (0x2d, "i", in_fadeout), 80 more and done (0x2e, +0x311c = 0).
    .{ .fighter = 120, .anim = S, .hit_delay = adj("attack_invisible_delay", 40), .vanish_delay = 40, .after_delay = n(80), .note = "Invisible (0x48a2a6)" },
    // Pain God (0x48a20e): stream (code 30) after paingod_delay (20), then delay2 (30).
    .{ .fighter = 121, .strike = 121, .anim = L, .hit_delay = n(20), .after_delay = n(30), .note = "Pain God (0x48a20e)" },
    // Harvester (0x48a390): attack_harvester_delay (32), then 30.
    .{ .fighter = 122, .anim = S, .hit_delay = adj("attack_harvester_delay", 32), .after_delay = n(30), .note = "Harvester (0x48a390)" },
    // Sister of Mercy (0x48ae0c): brain (code 32) after sister_delay (83), delay2 (30).
    .{ .fighter = 123, .anim = S, .hit_delay = n(83), .after_delay = n(30), .note = "Sister of Mercy (0x48ae0c)" },
    // Fatman (0x48aea4): fatmanshort (1075) long_attack "atak1", hit at tick 40
    // (attack_fatman_s_delay), then 30; fatmanlong (1076) short_attack "atak2",
    // flash and shot (code 50) at 68 (attack_fatman_l_delay), flash
    // attack_rifle_flash_timeout (5), then 30 (tail 0x48b5e3).
    .{ .fighter = 124, .weapon = 1075, .anim = L, .hit_delay = adj("attack_fatman_s_delay", 40), .after_delay = n(30), .note = "Fatman, short (0x48aea4)" },
    .{ .fighter = 124, .anim = S, .hit_delay = adj("attack_fatman_l_delay", 68), .after_delay = .{ .c = 30, .a = .{ .name = "attack_rifle_flash_timeout", .d = 5 } }, .note = "Fatman, shot (tail 0x48b5e3)" },
    // Cripple (0x48b12c): flash on "chaingun1" and shot (code 11) after
    // cripple_delay1 (50), 5-tick flash, then delay2 (40).
    .{ .fighter = 125, .anim = L, .hit_delay = n(50), .after_delay = n(5 + 40), .note = "Cripple (0x48b12c)" },
    // Reverend Insect (0x48ab82): "nitro" stream after attack_revinsect_delay (45),
    // hit delay2 (20) later, then delay3 (64).
    .{ .fighter = 126, .strike = 126, .anim = L, .hit_delay = .{ .c = 20, .a = .{ .name = "attack_revinsect_delay", .d = 45 } }, .after_delay = n(64), .flash_delay = adj("attack_revinsect_delay", 45), .note = "Reverend Insect (0x48ab82)" },
    // Stinger (0x48b6be): 1071 short_attack, stream (code 43) after stinger_s_delay
    // (50), then s_delay2 (30); otherwise long_attack, ball (code 44) after l_delay
    // (4), then l_delay2 (80).
    .{ .fighter = 127, .strike = 127, .weapon = 1071, .anim = S, .hit_delay = n(50), .after_delay = n(30), .note = "Stinger, flame (0x48b6be)" },
    .{ .fighter = 127, .strike = 127, .anim = L, .hit_delay = n(4), .after_delay = n(80), .note = "Stinger, ball" },
    // Hornet (0x48b256): lift at hornet_delay1 (40), hit delay2 (5) later, release
    // delay3 (30) later, 30 more.
    .{ .fighter = 128, .anim = L, .hit_delay = n(40 + 5), .after_delay = n(30 + 30), .lift_delay = 40, .drop_delay = 30, .note = "Hornet (0x48b256)" },
    // Lilith and child (0x48b3ff), Needle (0x48a3ae): own delay, then 30.
    .{ .fighter = 129, .anim = S, .hit_delay = n(41), .after_delay = n(30), .note = "Lilith (0x48b3ff)" },
    .{ .fighter = 135, .anim = S, .hit_delay = n(41), .after_delay = n(30), .note = "Lilith's child" },
    .{ .fighter = 130, .anim = S, .hit_delay = n(43), .after_delay = n(30), .note = "Needle (0x48a3ae)" },
    // Guard (0x48afae): 1062 short_attack, hit after attack_guard_1_delay (45);
    // otherwise attack_3 after guard_3_delay (40); both tail 0x48b81a → 0x48b864
    // (code 5, then 30). 1063 long_attack: after guard_2_delay (43) eye beams
    // (code 0x23 → 0x488025, "oko1"/"oko2", no damage), 5 later "smoke2" and
    // damage (code 0x24 → 0x48809c), then guard_2_delay2 (75).
    .{ .fighter = 131, .strike = 131, .weapon = 1062, .anim = S, .hit_delay = adj("attack_guard_1_delay", 45), .after_delay = n(30), .note = "Guard, short (0x48afae)" },
    .{ .fighter = 131, .strike = 131, .weapon = 1063, .anim = L, .hit_delay = n(43 + 5), .after_delay = n(75), .flash_delay = n(43), .note = "Guard, eye beams (0x488025, 0x48809c)" },
    .{ .fighter = 131, .strike = 131, .anim = "attack_3", .hit_delay = n(40), .after_delay = n(30), .note = "Guard, attack_3" },
    // Puppet (0x48b4dc): 1067 short_attack after puppet_s_delay (32), then 30;
    // otherwise long_attack: flash and shot (code 11) after l_delay (53), flash
    // held l_timeout (16), then 30.
    .{ .fighter = 132, .weapon = 1067, .anim = S, .hit_delay = n(32), .after_delay = n(30), .note = "Puppet, short (0x48b4dc)" },
    .{ .fighter = 132, .anim = L, .hit_delay = n(53), .after_delay = .{ .c = 30, .a = .{ .name = "attack_puppet_l_timeout", .d = 16 } }, .note = "Puppet, shot" },
    // Squeaker (0x48a3cc): shake (code 27) after sq_delay (50), then delay2 (30).
    .{ .fighter = 133, .strike = 133, .anim = L, .hit_delay = n(50), .after_delay = n(30), .note = "Squeaker (0x48a3cc)" },
    // Schizo (0x48b914): 1077 short_attack, hit after schizo_t_delay (50), then
    // t_delay2 (40); 1078 long_attack, gas from the bell after g_delay (78), cloud
    // (code 49) g_delay2 (98) later, then g_delay3 (30); 1079 attack_3, flash and
    // shot (code 11) after r_delay (60), flash until r_delay2 (35).
    .{ .fighter = 136, .strike = 136, .weapon = 1077, .anim = S, .hit_delay = n(50), .after_delay = n(40), .note = "Schizo, short (0x48b914)" },
    .{ .fighter = 136, .strike = 136, .weapon = 1078, .anim = L, .hit_delay = n(78 + 98), .after_delay = n(30), .flash_delay = n(78), .gas = true, .note = "Schizo, gas (3x3 gas on the tiles: 0x4885a8)" },
    .{ .fighter = 136, .strike = 136, .anim = "attack_3", .hit_delay = n(60), .after_delay = adj("attack_schizo_r_delay2", 35), .note = "Schizo, shot" },
    // Lucy (0x48ace3): 1057 short_attack after lucy_s_delay (35), then 30;
    // otherwise long_attack: flash and shot (code 11) after l_delay (74), flash
    // attack_rifle_flash_timeout (5), then 20.
    .{ .fighter = 137, .weapon = 1057, .anim = S, .hit_delay = n(35), .after_delay = n(30), .note = "Lucy, short (0x48ace3)" },
    .{ .fighter = 137, .anim = L, .hit_delay = n(74), .after_delay = .{ .c = 20, .a = .{ .name = "attack_rifle_flash_timeout", .d = 5 } }, .note = "Lucy, shot" },
    // Incubus (0x48b626): ball (code 42) after incubus_delay (15), then delay2 (90).
    .{ .fighter = 138, .anim = L, .hit_delay = n(15), .after_delay = n(90), .note = "Incubus (0x48b626)" },
    // Messiah (0x48b7ee): 1073 short_attack after messiah_s_delay (50), then 30;
    // otherwise long_attack after l_delay (48), then 60.
    .{ .fighter = 139, .weapon = 1073, .anim = S, .hit_delay = n(50), .after_delay = n(30), .note = "Messiah, short (0x48b7ee)" },
    .{ .fighter = 139, .anim = L, .hit_delay = n(48), .after_delay = n(60), .note = "Messiah, long" },
};
