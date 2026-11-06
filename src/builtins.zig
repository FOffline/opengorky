//! Script builtins: exe name → handler table, with what the Classic importer may assume
//! of each (`Runtime.Sig`: result and parameter types as `editor/api.zig` documents them,
//! `pure`, `data`). Pure: no effects, no failure, no debug counters (`args.targetObject` counts
//! missing objects, so `FighterGetHp`, `GetNameID`, `Item_Get*` are not). Data: with
//! literal arguments in a creation event it is part of the object's model
//! (`script/classic/lift.zig`): animation slots, walk speed, scale, inventory, placement,
//! ambient sounds. A `bool` result marks a yes/no answer (the handler's int 1/0 stays
//! int in Classic and is `bool` in OGS, `Runtime.builtinResult`); counts, ids, hp and
//! success flags of actions stay `int`. A parameter typed `level`, `scene`, `sound` is a
//! string naming one (`script/ir.zig Sigil`): OGS checks a sigil passed there (`~l"…"`).
//! `ogs`, `classic`, `this`: the one table of names between the languages (docs/og-script.md
//! §16; `script/classic/rename.zig` converts, `ogs/link.zig` resolves, the editor shows).

const std = @import("std");
const world_mod = @import("state.zig").world;
const World = world_mod.World;
const Sig = @import("script.zig").runtime.Sig;

const objects_bi = @import("builtins/objects.zig");
pub const actors = @import("builtins/actors.zig");
const combat_bi = @import("builtins/combat.zig");
const items_bi = @import("builtins/items.zig");
pub const level = @import("builtins/level.zig");

pub fn registerBuiltins(w: *World) !void {
    inline for (table) |entry| try w.rt.registerBuiltinSig(entry[0], w, entry[1], entry[2]);
    w.rt.host_fields = .{ .ctx = w, .get = combat_bi.hostField };
    w.rt.field_words = items_bi.actionWord;
    w.rt.natives = .{ .ctx = w, .call = combat_bi.native };
    w.rt.native_components = @import("combat.zig").natives.call;
}

/// Name, handler, `Runtime.Sig`.
pub const table = .{
    .{ "s_stricmp", objects_bi.biStricmp, Sig{ .text = "int(string, string)", .pure = true, .classic = true } },
    // OpenGorky: `s_stricmp`'s yes/no for OGS (a case-insensitive `==`).
    .{ "EqualsIgnoreCase", objects_bi.biEqualsIgnoreCase, Sig{ .text = "bool(string a, string b)", .pure = true } },
    .{ "print", objects_bi.biPrint, Sig{ .text = "int(string)" } },
    .{ "GetName", objects_bi.biGetName, Sig{ .text = "string()", .pure = true, .classic = true } },
    .{ "EnableObject", objects_bi.biEnableObject, Sig{ .text = "int(string)", .ogs = "object::Enable" } },
    .{ "DisableObject", objects_bi.biDisableObject, Sig{ .text = "int(string)", .ogs = "object::Disable" } },
    .{ "DeleteObject", objects_bi.biDeleteObject, Sig{ .text = "int(string)", .ogs = "object::Delete" } },
    .{ "ABA_Impulse", actors.biAbaImpulse, Sig{ .text = "int(string)", .ogs = "object::Impulse" } },
    .{ "PlaySound", objects_bi.biPlaySound, Sig{ .text = "int(sound, ?int)", .ogs = "sound::Play" } },
    .{ "PlayRandomSound2D", objects_bi.biPlayRandomSound2D, Sig{ .text = "int(int, int, string, ?int)", .ogs = "sound::PlayRandom2D" } },
    .{ "Ambient_New", objects_bi.biAmbientNew, Sig{ .text = "int(string, int, int, string)", .data = true, .ogs = "sound::NewAmbient" } },
    .{ "PlaceActor", actors.biPlaceActor, Sig{ .text = "int(string, string, int, ?int)", .data = true, .ogs = "actor::Place" } },
    .{ "RegisterIdleAnimation", actors.biRegisterIdleAnimation, Sig{ .text = "int(int, string, int)", .data = true, .ogs = "actor::RegisterIdleAnimation" } },
    .{ "RegisterAnimation", actors.biRegisterAnimation, Sig{ .text = "int(int, string, string)", .data = true, .ogs = "actor::RegisterAnimation" } },
    .{ "NotInPlaceAnimation", actors.biNotInPlaceAnimation, Sig{ .text = "int(string)", .data = true, .ogs = "actor::NotInPlaceAnimation" } },
    .{ "ReferenceAnimation", actors.biReferenceAnimation, Sig{ .text = "int(string)", .data = true, .ogs = "actor::ReferenceAnimation" } },
    .{ "Actor_SetAsyncAnimation", actors.biActorSetAsyncAnimation, Sig{ .text = "int(string, string, ?int, ?int)", .ogs = "actor::SetAsyncAnimation" } },
    .{ "Actor_TextEffect", actors.biActorTextEffect, Sig{ .text = "int(string, any)", .ogs = "actor::TextEffect" } },
    .{ "IsObject", objects_bi.biIsObject, Sig{ .text = "bool(string)", .pure = true, .ogs = "object::Exists" } },
    .{ "IsHere", objects_bi.biIsHere, Sig{ .text = "bool(any x)", .pure = true, .ogs = "object::IsHere" } },
    .{ "Disable", actors.biDisable, Sig{ .text = "int()", .classic = true } },
    .{ "SetActorState", actors.biSetActorState, Sig{ .text = "int(int)", .ogs = "actor::InitState" } },
    .{ "ActorInArea", actors.biActorInArea, Sig{ .text = "bool(string, string)", .pure = true, .ogs = "actor::InArea" } },
    .{ "Actor_HaveAmmoForWeapon", items_bi.biActorHaveAmmoForWeapon, Sig{ .text = "bool(string, string)", .ogs = "item::HasAmmo" } },
    .{ "AnyHero_HaveAmmoForWeapon", items_bi.biAnyHeroHaveAmmoForWeapon, Sig{ .text = "bool(string)", .ogs = "hero::AnyHasAmmo" } },
    .{ "SetGlobalStringVariable", level.biSetGlobalStringVariable, Sig{ .text = "int(string, string)", .ogs = "level::SetGlobalString" } },
    .{ "ActorSetWalkSpeed", actors.biActorSetWalkSpeed, Sig{ .text = "int(string, float)", .data = true, .ogs = "actor::SetWalkSpeed" } },
    .{ "Actor_SetAnimation", actors.biActorSetAnimation, Sig{ .text = "int(string, string, ?int)", .ogs = "actor::SetAnimation" } },
    .{ "Actor_SetState", actors.biActorSetState, Sig{ .text = "int(string, int, ?int)", .ogs = "actor::SetState" } },
    .{ "AdjustAngle", actors.biAdjustAngle, Sig{ .text = "int(float)", .ogs = "actor::SetModelAngle" } },
    .{ "AttachActorsByLink", actors.biAttachActorsByLink, Sig{ .text = "int(string, string, string)", .ogs = "actor::AttachByLink" } },
    .{ "DetachActorsFrom", actors.biDetachActorsFrom, Sig{ .text = "int(string)", .ogs = "actor::DetachAllFrom" } },
    .{ "WalkOnSceneryTrack", actors.biWalkOnSceneryTrack, Sig{ .text = "int(string, string, ?float, ?int)", .ogs = "actor::WalkOnTrack" } },
    .{ "StopActor", actors.biStopActor, Sig{ .text = "int(string)", .ogs = "actor::Stop" } },
    .{ "Vibrato", actors.biVibrato, Sig{ .text = "int(string, float, float)", .ogs = "actor::Vibrato" } },
    .{ "HeroInArea", level.biHeroInArea, Sig{ .text = "bool(string)", .pure = true, .ogs = "hero::AnyInArea" } },
    .{ "GUI_GetSelectedHero", level.biGetSelectedHero, Sig{ .text = "string()", .pure = true, .ogs = "hero::GetSelected" } },
    .{ "StartScriptlet", level.biStartScriptlet, Sig{ .text = "int(scene)", .ogs = "scene::Start" } },
    .{ "GUI_Panorama", level.biGuiPanorama, Sig{ .text = "int(int)", .ogs = "gui::Panorama" } },
    .{ "LEVEL_Load", level.biLevelLoad, Sig{ .text = "int(level)", .ogs = "level::Load" } },
    .{ "LEVEL_LoadAB", level.biLevelLoadAB, Sig{ .text = "int(level)", .ogs = "level::LoadAfterBattle" } },
    .{ "PlaceCombatActor", combat_bi.biPlaceCombatActor, Sig{ .text = "int(string, float, float, float)", .data = true, .ogs = "battle::PlaceProp" } },
    .{ "AIFreeTile", combat_bi.biAIFreeTile, Sig{ .text = "bool(int, int)", .pure = true, .ogs = "battle::IsFreeTile" } },
    .{ "EnableHeroes", level.biEnableHeroes, Sig{ .text = "int()", .ogs = "hero::EnableAll" } },
    .{ "DisableHeroes", level.biDisableHeroes, Sig{ .text = "int()", .ogs = "hero::DisableOthers" } },
    .{ "AIEnemyAppear", combat_bi.biAIEnemyAppear, Sig{ .text = "int(string, int, int, int, int)", .ogs = "fighter::Appear" } },
    .{ "Weapon_New", items_bi.biWeaponNew, Sig{ .text = "int(string, string, ?string, ?int)", .data = true, .ogs = "item::NewWeapon" } },
    .{ "Item_New", items_bi.biItemNew, Sig{ .text = "int(string, string, ?string, ?int)", .data = true, .ogs = "item::New" } },
    .{ "FighterGetHp", combat_bi.biFighterGetHp, Sig{ .text = "int(string)", .ogs = "fighter::GetHp" } },
    .{ "FighterSetHp", combat_bi.biFighterSetHp, Sig{ .text = "int(string, int)", .ogs = "fighter::SetHp" } },
    .{ "FighterSetWeaponSkillLevel", items_bi.biFighterSetWeaponSkillLevel, Sig{ .text = "int(string, int, int)", .ogs = "fighter::SetWeaponSkill" } },
    .{ "AIGetTurnNo", combat_bi.biAIGetTurnNo, Sig{ .text = "int()", .pure = true, .ogs = "battle::GetTurnNo" } },
    .{ "BattleNearest", combat_bi.biBattleNearest, Sig{ .text = "any(list tile, string side)", .pure = true, .ogs = "battle::Nearest" } },
    .{ "EndTurnGlobal", combat_bi.biEndTurnGlobal, Sig{ .text = "int()", .ogs = "battle::EndTurn" } },
    .{ "AITargetLock", combat_bi.biAITargetLock, Sig{ .text = "int(string, string)", .ogs = "fighter::LockTarget" } },
    .{ "Item_Animation", items_bi.biItemAnimation, Sig{ .text = "int(string, string, int)", .ogs = "item::Animation", .this = true } },
    .{ "Item_SetPos", items_bi.biItemSetPos, Sig{ .text = "int(string, float, float, float)", .ogs = "item::SetPos", .this = true } },
    .{ "Item_SetAngle", items_bi.biItemSetAngle, Sig{ .text = "int(string, float)", .ogs = "item::SetAngle", .this = true } },
    .{ "Item_SetNameID", items_bi.biItemSetNameID, Sig{ .text = "int(string, int)", .ogs = "item::SetNameID", .this = true } },
    .{ "ForbidWalkInArea", level.biForbidWalkInArea, Sig{ .text = "int(string, ?int)", .ogs = "level::ForbidWalk" } },
    .{ "TestActorMapChange", level.biTestActorMapChange, Sig{ .text = "int(string, int)", .ogs = "level::TestFloorChange" } },
    .{ "SetActorMap", level.biSetActorMap, Sig{ .text = "int(string, int)", .ogs = "actor::SetFloor" } },
    .{ "ActorSetWalkAnimation", actors.biActorSetWalkAnimation, Sig{ .text = "int(string, ?int)", .ogs = "path::SetWalkAnimation" } },
    .{ "ActorAnimation", actors.biActorAnimation, Sig{ .text = "int(string, ?int, ?int, ?int)", .ogs = "path::Animation" } },
    .{ "ActorAsyncAnimation", actors.biActorAsyncAnimation, Sig{ .text = "int(string, ?int, ?int, ?int)", .ogs = "path::AsyncAnimation" } },
    .{ "ActorQueueWalkAnimation", actors.biActorQueueWalkAnimation, Sig{ .text = "int(string, ?int, ?int, ?int)", .ogs = "path::QueueWalkAnimation" } },
    .{ "ActorAdjustAngle", actors.biActorAdjustAngle, Sig{ .text = "int()", .ogs = "path::AdjustAngle" } },
    .{ "Signature", level.biSignature, Sig{ .text = "int(int)", .ogs = "scene::Signature" } },
    .{ "GUI_IsHero", combat_bi.biGuiIsHero, Sig{ .text = "bool(string)", .pure = true, .ogs = "hero::InParty" } },
    .{ "LEVEL_IncAdvVar", level.biAdvInc, Sig{ .text = "int()", .ogs = "level::IncAdvVar" } },
    .{ "LEVEL_DecAdvVar", level.biAdvDec, Sig{ .text = "int()", .ogs = "level::DecAdvVar" } },
    .{ "LEVEL_GetAdvVar", level.biAdvGet, Sig{ .text = "int()", .pure = true, .ogs = "level::GetAdvVar" } },
    .{ "LEVEL_SetAdvVar", level.biAdvSet, Sig{ .text = "int(int)", .ogs = "level::SetAdvVar" } },
    .{ "GetNameID", objects_bi.biGetNameID, Sig{ .text = "int(string)", .ogs = "object::GetNameID", .this = true } },
    .{ "GetClass", objects_bi.biGetClass, Sig{ .text = "string(string)", .ogs = "object::GetClass", .this = true } },
    .{ "str", objects_bi.biStr, Sig{ .text = "string(any)", .pure = true } },
    .{ "GetLevel", level.biGetLevel, Sig{ .text = "string()", .pure = true, .ogs = "level::GetName" } },
    .{ "Item_GetNameID", items_bi.biItemGetNameID, Sig{ .text = "int(string)", .ogs = "item::GetNameID", .this = true } },
    .{ "SetAddonScriptlet", level.biSetAddonScriptlet, Sig{ .text = "int(scene)", .ogs = "scene::StartNext" } },
    .{ "DialogInit", level.biDialogInit, Sig{ .text = "int(string, string)", .classic = true } },
    .{ "Dialog", level.biDialog, Sig{ .text = "int(dialog)", .ogs = "scene::Dialog" } },
    .{ "SetActorAddVariables", actors.biSetActorAddVariables, Sig{ .text = "int(string, float, float, float)", .data = true, .ogs = "actor::SetModelOffset" } },
    .{ "HERO_EnableEnumerate", combat_bi.biHeroEnableEnumerate, Sig{ .text = "int(string, int)", .ogs = "hero::SetInParty" } },
    .{ "FighterSetLevel", combat_bi.biFighterSetLevel, Sig{ .text = "int(string, int)", .ogs = "fighter::SetLevel" } },
    .{ "LinkActor", actors.biLinkActor, Sig{ .text = "int(string, string)", .ogs = "actor::LinkRider" } },
    .{ "PutLargeTimeBomb", combat_bi.biPutLargeTimeBomb, Sig{ .text = "int(int, int)", .ogs = "battle::PutLargeTimeBomb" } },
    .{ "ActorModifyScale", actors.biActorModifyScale, Sig{ .text = "int(float)", .data = true, .ogs = "actor::ModifyScale" } },
    .{ "FadeIn", level.biFadeIn, Sig{ .text = "int()", .ogs = "scene::FadeIn" } },
    // Model links, actor queue, video, GUI modes.
    .{ "Actor_QueueDelay", actors.biActorQueueDelay, Sig{ .text = "int(string, int)", .ogs = "actor::QueueDelay" } },
    .{ "Actor_QueueJustifyPosition", actors.biActorQueueJustifyPosition, Sig{ .text = "int(string)", .ogs = "actor::QueueJustifyPosition" } },
    .{ "Actor_QueuePlace", actors.biActorQueuePlace, Sig{ .text = "int(string, string, int)", .ogs = "actor::QueuePlace" } },
    .{ "Actor_ActivateLink", actors.biActorActivateLink, Sig{ .text = "int(string, string)", .ogs = "actor::ShowItemInHand" } },
    .{ "Actor_DeactivateAllLinks", actors.biActorDeactivateAllLinks, Sig{ .text = "int(string)", .ogs = "actor::HideAllLinkMeshes" } },
    .{ "ActivateLink", actors.biActivateLink, Sig{ .text = "int(string, string, ?int)", .ogs = "actor::ShowLinkMesh" } },
    .{ "AVI_Play", level.biAVIPlay, Sig{ .text = "int(string, int, int, int)", .ogs = "scene::PlayVideo" } },
    .{ "GUI_SelectMode", level.biGUISelectMode, Sig{ .text = "int(string)", .ogs = "gui::SelectMode" } },
    .{ "PlaceHeroes", level.biPlaceHeroes, Sig{ .text = "int(string, ?int)", .ogs = "hero::PlaceAll" } },
    .{ "GUI_Disable", level.biGUIDisable, Sig{ .text = "int(int)", .ogs = "gui::SetMode" } },
    .{ "ActorEnableRotation", actors.biActorEnableRotation, Sig{ .text = "int(int)", .ogs = "path::EnableRotation" } },
    .{ "ActorDisableInterpolation", actors.biActorDisableInterpolation, Sig{ .text = "int()", .ogs = "path::DisableInterpolation" } },
    .{ "ActorQueueWaitForAnimation", actors.biActorQueueWaitForAnimation, Sig{ .text = "int(?string)", .ogs = "path::WaitForAnimation" } },
    .{ "ActorQueueWaitForInterpolation", actors.biActorQueueWaitForInterpolation, Sig{ .text = "int()", .ogs = "path::WaitForInterpolation" } },
    .{ "ActorDelay", actors.biActorDelay, Sig{ .text = "int(int)", .ogs = "path::Delay" } },
    // 0x4bff10 is ActorDelay's handler byte for byte (int → 0x428c00, command 0x16).
    .{ "ActorQueueDelay", actors.biActorDelay, Sig{ .text = "int(int)", .ogs = "path::Delay" } },
    .{ "Actor_QueueState", actors.biActorQueueState, Sig{ .text = "int(string, int)", .ogs = "actor::QueueState" } },
    .{ "ActorPutBackItem", actors.biActorPutBackItem, Sig{ .text = "int(string)", .ogs = "actor::PutBackItem" } },
    .{ "ActorPutFrontItem", actors.biActorPutFrontItem, Sig{ .text = "int(string)", .ogs = "actor::PutFrontItem" } },
    .{ "AttachActors", actors.biAttachActors, Sig{ .text = "int(string, string, float, float, float, float)", .ogs = "actor::Attach" } },
    .{ "DeactivateLink", actors.biDeactivateLink, Sig{ .text = "int(string)", .ogs = "actor::HideLinkMesh" } },
    .{ "RegisterExtraBody", actors.biRegisterExtraBody, Sig{ .text = "int(int, int, string)", .data = true, .ogs = "actor::RegisterExtraBody" } },
    .{ "ActorAsyncWalkAnimation", actors.biActorAsyncWalkAnimation, Sig{ .text = "int(?int, ?int)", .ogs = "path::AsyncWalkAnimation" } },
    .{ "AllowWalkInArea", level.biAllowWalkInArea, Sig{ .text = "int(string, ?int)", .ogs = "level::AllowWalk" } },
    .{ "Item_SetPlace", items_bi.biItemSetPlace, Sig{ .text = "int(string, int)", .ogs = "item::SetPlace", .this = true } },
    .{ "Item_GetPlace", items_bi.biItemGetPlace, Sig{ .text = "int(string)", .ogs = "item::GetPlace", .this = true } },
    .{ "Item_SetVisible", items_bi.biItemSetVisible, Sig{ .text = "int(string, int)", .ogs = "item::SetVisible", .this = true } },
    .{ "Item_SetFuncID", items_bi.biItemSetFuncID, Sig{ .text = "int(string, any)", .ogs = "item::SetFuncID", .this = true } },
    .{ "ActionId", items_bi.biActionId, Sig{ .text = "int(string name)", .pure = true, .ogs = "object::ActionId" } },
    .{ "Item_GetType", items_bi.biItemGetType, Sig{ .text = "int(string)", .ogs = "item::GetType", .this = true } },
    .{ "Item_EnableWalkCircle", items_bi.biItemEnableWalkCircle, Sig{ .text = "int(string)", .ogs = "item::EnableWalkCircle", .this = true } },
    .{ "Item_DisableWalkCircle", items_bi.biItemDisableWalkCircle, Sig{ .text = "int(string)", .ogs = "item::DisableWalkCircle", .this = true } },
    .{ "Actor_QueueGOScriptFunc", actors.biActorQueueGOScriptFunc, Sig{ .text = "int(string, string, string)", .ogs = "actor::QueueCall" } },
    .{ "Actor_GORunFun", actors.biActorGORunFun, Sig{ .text = "any(string, string, string)", .ogs = "actor::Call" } },
    .{ "GO_RunFun", level.biGORunFun, Sig{ .text = "any(string, string)", .ogs = "object::Call" } },
    .{ "AnyHero_HaveItem", items_bi.biAnyHeroHaveItem, Sig{ .text = "bool(string)", .pure = true, .ogs = "hero::AnyHasItem" } },
    .{ "AIGuardPoint", combat_bi.biAIGuardPoint, Sig{ .text = "int(string, int, int)", .ogs = "fighter::GuardTile" } },
    // OpenGorky: a fighter's scripted abilities in battle (named parameters).
    .{ "FighterDamage", combat_bi.biFighterDamage, Sig{ .text = "int(string who, int amount, ?string kind, ?string from)", .ogs = "fighter::Damage" } },
    .{ "FighterSetTarget", combat_bi.biFighterSetTarget, Sig{ .text = "int(string who, string target)", .ogs = "fighter::SetTarget" } },
    .{ "FighterGetLastAttacker", combat_bi.biFighterGetLastAttacker, Sig{ .text = "any(string who)", .ogs = "fighter::GetLastAttacker" } },
    .{ "FighterNative", combat_bi.biFighterNative, Sig{ .text = "any(string who, string name)", .ogs = "fighter::Native" } },
    .{ "FighterAddState", combat_bi.biFighterAddState, Sig{ .text = "int(string who, string state, ?int turns)", .ogs = "fighter::AddState" } },
    .{ "FighterSide", combat_bi.biFighterSide, Sig{ .text = "string(string who)", .ogs = "fighter::Side" } },
    .{ "FighterAlive", combat_bi.biFighterAlive, Sig{ .text = "bool(string who)", .ogs = "fighter::IsAlive" } },
    .{ "FighterPopup", combat_bi.biFighterPopup, Sig{ .text = "int(string who, string text)", .ogs = "fighter::Popup" } },
    .{ "FighterTransform", combat_bi.biFighterTransform, Sig{ .text = "int(string who, string into, ?string anim, ?string idle, ?sound sound)", .ogs = "fighter::Transform" } },
    .{ "BattleSpawnEnemy", combat_bi.biBattleSpawnEnemy, Sig{ .text = "any(character fighter, int x, int y)", .ogs = "battle::SpawnEnemy" } },
    .{ "BattleSpawnHero", combat_bi.biBattleSpawnHero, Sig{ .text = "any(character fighter, int x, int y)", .ogs = "battle::SpawnHero" } },
    .{ "BattleSpawnCivilian", combat_bi.biBattleSpawnCivilian, Sig{ .text = "any(character fighter, int x, int y, ?string ai)", .ogs = "battle::SpawnCivilian" } },
    .{ "BattleWin", combat_bi.biBattleWin, Sig{ .text = "int()", .ogs = "battle::Win" } },
    .{ "BattleLose", combat_bi.biBattleLose, Sig{ .text = "int()", .ogs = "battle::Lose" } },
    .{ "BattleGetVar", combat_bi.biBattleGetVar, Sig{ .text = "any(string name)", .ogs = "battle::GetVar" } },
    .{ "BattleSetVar", combat_bi.biBattleSetVar, Sig{ .text = "any(string name, any value)", .ogs = "battle::SetVar" } },
    .{ "BattleAddVar", combat_bi.biBattleAddVar, Sig{ .text = "any(string name, any delta)", .ogs = "battle::AddVar" } },
    // OpenGorky: events between components (docs/og-script.md §14.1).
    .{ "Subscribe", combat_bi.biSubscribe, Sig{ .text = "bool(string event, method handler)", .ogs = "events::Subscribe" } },
    .{ "Unsubscribe", combat_bi.biUnsubscribe, Sig{ .text = "int(string event, ?method handler)", .ogs = "events::Unsubscribe" } },
    .{ "Emit", combat_bi.biEmit, Sig{ .text = "int(string event, ?any args...)", .ogs = "events::Emit" } },
};

test {
    _ = combat_bi;
}

test "every builtin is in a package, the root's core, or Classic only" {
    const link = @import("script.zig").ogs.link;
    var used: [link.packages.len]bool = @splat(false);
    inline for (table) |e| {
        const sig: Sig = e[2];
        const name = if (sig.ogs.len > 0) sig.ogs else e[0];
        if (std.mem.indexOf(u8, name, "::")) |k| {
            const at = for (link.packages, 0..) |p, i| {
                if (std.mem.eql(u8, p, name[0..k])) break i;
            } else return error.NoPackage;
            used[at] = true;
        } else if (!sig.classic) {
            // The root: the core only.
            const core = [_][]const u8{ "print", "str", "EqualsIgnoreCase" };
            for (core) |c| {
                if (std.mem.eql(u8, c, name)) break;
            } else return error.NotCore;
        }
    }
    for (used) |u| try std.testing.expect(u);
}
