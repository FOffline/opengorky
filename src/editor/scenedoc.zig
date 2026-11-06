//! The scene commands for the code editor's tips (hover, the side panel): each one's
//! parameters and what it does, by its exe name (core/scene.zig `ogs_names` gives the OG
//! Script one; an OpenGorky scene's `actor::WalkTo` and a Classic `WALKTO` share a row).
//! From the exe's runner (scene/*_cmds.zig, docs original/script.md "Scenes").

const std = @import("std");
const og_lib = @import("opengorky");
const tx = @import("text.zig");

/// A command's parameters and what it does; `og`: as OG Script writes it, where that differs
/// (`scene::Wait(seconds)`, a pair's `camera::Panorama(on)`; core/scene.zig `Kind`).
pub const Doc = struct { exe: []const u8, params: []const []const u8 = &.{}, what: tx.Msg, og: ?View = null };

pub const View = struct { params: []const []const u8, what: tx.Msg };

fn d(exe: []const u8, params: []const []const u8, en: []const u8, ru: []const u8) Doc {
    return .{ .exe = exe, .params = params, .what = .{ .en = en, .ru = ru } };
}

/// Row `x` with its OG Script form.
fn og(x: Doc, params: []const []const u8, en: []const u8, ru: []const u8) Doc {
    var r = x;
    r.og = .{ .params = params, .what = .{ .en = en, .ru = ru } };
    return r;
}

pub const docs = [_]Doc{
    og(d("PLACEHEROES", &.{"point"}, "Places the whole party around the scene point.", "Ставит весь отряд вокруг точки сцены."), &.{ "area", "floor" }, "Places the whole party in the area.", "Ставит весь отряд в область."),
    d("WALKTO", &.{ "actor", "point" }, "Queues a walk to the point; ends facing the point's angle. Does not wait: follow with actor::Wait.", "Ставит в очередь ходьбу к точке; в конце поворачивается по углу точки. Не ждёт — после неё actor::Wait."),
    d("PLACE", &.{ "actor", "point" }, "Puts the actor on the point at once, facing its angle.", "Сразу ставит актёра в точку, лицом по её углу."),
    d("NO_SKIP", &.{}, "The scene cannot be skipped (space does nothing).", "Сцену нельзя пропустить (пробел не действует)."),
    d("ACTOR_MORPH", &.{ "actor", "class" }, "Turns the actor into another class (a morph).", "Превращает актёра в другой класс (морф)."),
    og(d("EARTHQUAKE", &.{ "time", "strength" }, "Shakes the camera.", "Трясёт камеру."), &.{"seconds"}, "Shakes the camera for that many seconds.", "Трясёт камеру столько секунд."),
    d("MP3_PLAY", &.{"music"}, "Plays a music track; the previous one resumes when the scene ends.", "Включает музыку; прежняя возвращается после сцены."),
    d("MP3_FADE", &.{}, "Fades the music out.", "Плавно глушит музыку."),
    og(d("GUI_DISABLE", &.{}, "Input off: no clicks, no interface.", "Ввод выключен: ни кликов, ни интерфейса."), &.{"on"}, "Player input on (true) or off (false: no clicks, no interface).", "Ввод игрока включён (true) или выключен (false: ни кликов, ни интерфейса)."),
    d("GUI_CREDITS", &.{}, "Shows the credits.", "Показывает титры."),
    d("GUI_MENU", &.{}, "Back to the main menu.", "Выход в главное меню."),
    og(d("GUI_ENABLE", &.{}, "Input on again.", "Ввод снова включён."), &.{"on"}, "Player input on (true) or off (false: no clicks, no interface).", "Ввод игрока включён (true) или выключен (false: ни кликов, ни интерфейса)."),
    og(d("GUI_CUTSCENE", &.{}, "Cutscene input mode: the player only watches (and may skip).", "Режим катсцены: игрок только смотрит (и может пропустить)."), &.{"on"}, "Cutscene mode (true: the player only watches and may skip) or normal play again (false).", "Режим катсцены (true: игрок только смотрит и может пропустить) или снова обычное управление (false)."),
    d("GUI_ENDDEMO", &.{}, "The demo's end screen.", "Экран конца демоверсии."),
    d("GUI_GAMEOVER", &.{}, "The game over screen.", "Экран конца игры."),
    og(d("GUI_NORMAL", &.{}, "Normal play input again.", "Снова обычное управление."), &.{"on"}, "Cutscene mode (true: the player only watches and may skip) or normal play again (false).", "Режим катсцены (true: игрок только смотрит и может пропустить) или снова обычное управление (false)."),
    d("ACTORSETSTATE", &.{ "actor", "state" }, "Sets the actor's state (0 standing, 1 with a gun…): its idles and walk.", "Задаёт состояние актёра (0 — стоит, 1 — с оружием…): его idle и ходьбу."),
    og(d("PLAYAVI", &.{"video"}, "Plays a video full screen.", "Проигрывает видео на весь экран."), &.{ "video", "x", "y", "double" }, "Plays a video full screen (double: twice its size).", "Проигрывает видео на весь экран (double — вдвое крупнее)."),
    d("WAITFORACTOR", &.{"actor"}, "Waits until the actor's queue (walks, animations) is done.", "Ждёт, пока очередь актёра (ходьба, анимации) опустеет."),
    d("FX_WEAPON", &.{ "actor", "on" }, "Muzzle flash of the actor's weapon on (1) or off (0).", "Вспышка выстрела оружия актёра: 1 — вкл, 0 — выкл."),
    d("VOLTAGE", &.{"actor"}, "Electric sparks on the actor (Medusa).", "Электрические искры на актёре (Медуза)."),
    d("ROCKET", &.{ "actor", "x", "y", "z", "weapon" }, "A rocket flies from the actor's hands to world point x, y, z: the launch of `weapon` (OpenGorky; Classic: the rocket launcher's).", "Ракета летит из рук актёра в точку мира x, y, z: запуск оружия `weapon` (OpenGorky; в Classic — ракетомёта)."),
    d("ATTACK", &.{"actor"}, "The actor fires the item in hand. Does not wait.", "Актёр стреляет предметом в руке. Не ждёт."),
    d("USEANIMATION", &.{ "actor", "anim" }, "Plays a use animation (a lever, a door).", "Анимация использования (рычаг, дверь)."),
    d("FAST_ANIMATION", &.{ "actor", "anim" }, "Sets the animation at once, no queue.", "Сразу ставит анимацию, без очереди."),
    og(d("ANIMATION", &.{ "actor", "anim", "count", "back" }, "Queues an animation (count times, back: reversed). Does not wait.", "Ставит анимацию в очередь (count раз, back — задом наперёд). Не ждёт."), &.{ "actor", "anim", "count", "back" }, "Queues an animation (count times; back: true plays it reversed). Does not wait.", "Ставит анимацию в очередь (count раз; back = true — задом наперёд). Не ждёт."),
    d("SYSTEMANIMATION", &.{ "actor", "anim" }, "Plays an engine animation of the actor.", "Системная анимация актёра."),
    d("GO_RUNFUN", &.{ "object", "function" }, "Runs a function of an object by its name.", "Вызывает функцию объекта по имени."),
    d("SIGNATURE_ON", &.{"frame"}, "Shows the date signature (a frame of intro.spr) at the bottom of the screen.", "Показывает подпись с датой (кадр intro.spr) внизу экрана."),
    d("SIGNATURE_OFF", &.{}, "Hides the date signature.", "Прячет подпись с датой."),
    d("IMPULSEOBJECT", &.{ "object", "time" }, "Pushes an object (a lever, a console) and waits for it.", "Толкает объект (рычаг, пульт) и ждёт его."),
    d("ABA_MOVE", &.{ "anim", "x", "y", "speed" }, "Moves a bitmap animation of the level.", "Двигает битмап-анимацию уровня."),
    d("ABA_POS", &.{ "anim", "x", "y" }, "Puts a bitmap animation at a place.", "Ставит битмап-анимацию на место."),
    d("ABA_STATE", &.{ "anim", "state" }, "Sets a bitmap animation's state (plays, stops).", "Задаёт состояние битмап-анимации (играет, стоит)."),
    d("WAITFORANIMATION", &.{"anim"}, "Waits until a bitmap animation finishes.", "Ждёт, пока битмап-анимация доиграет."),
    og(d("DELAY", &.{"ticks"}, "Waits that many ticks.", "Ждёт столько тиков."), &.{"seconds"}, "Waits that many seconds.", "Ждёт столько секунд."),
    d("LOADLEVEL", &.{"level"}, "Loads a level (a battle: the fight starts).", "Загружает уровень (бой — начинается схватка)."),
    d("PREVLEVEL", &.{}, "Back to the previous level.", "Возврат на предыдущий уровень."),
    og(d("DIALOG_INIT", &.{ "name", "dialog" }, "Opens a dialog (dialogs/<name>.ogs): its lines for dialog::Say.", "Открывает диалог (dialogs/<имя>.ogs): его реплики для dialog::Say."), &.{"dialog"}, "Opens a dialog (`~d\"name\"`: dialogs/<name>.ogs): its lines for dialog::Say.", "Открывает диалог (`~d\"имя\"`: dialogs/<имя>.ogs): его реплики для dialog::Say."),
    d("DIALOG_DISPLAY", &.{"line"}, "Says line n of the open dialog with its voice and waits for it.", "Произносит реплику n открытого диалога с озвучкой и ждёт её."),
    d("DIALOG_SHOW", &.{"line"}, "Shows line n without waiting.", "Показывает реплику n, не ожидая."),
    og(d("PANORAMA_OFF", &.{}, "Removes the black bars (2 px a tick) and waits.", "Убирает чёрные полосы (2 пикселя за тик) и ждёт."), &.{"on"}, "Black bars top and bottom (true: cinema) or none (false: they go 2 px a tick, it waits).", "Чёрные полосы сверху и снизу (true — кино) или без них (false: уходят по 2 пикселя за тик, ждёт)."),
    og(d("PANORAMA_ON", &.{}, "Black bars top and bottom (cinema).", "Чёрные полосы сверху и снизу (кино)."), &.{"on"}, "Black bars top and bottom (true: cinema) or none (false: they go 2 px a tick, it waits).", "Чёрные полосы сверху и снизу (true — кино) или без них (false: уходят по 2 пикселя за тик, ждёт)."),
    og(d("AUTOCAMERA_ON", &.{}, "The camera follows the party again.", "Камера снова следует за отрядом."), &.{"on"}, "The camera follows the party (true) or stays where camera::Move puts it (false).", "Камера следует за отрядом (true) или остаётся там, куда её ставит camera::Move (false)."),
    og(d("AUTOCAMERA_OFF", &.{}, "The camera stays where camera::Move puts it.", "Камера остаётся там, куда её ставит camera::Move."), &.{"on"}, "The camera follows the party (true) or stays where camera::Move puts it (false).", "Камера следует за отрядом (true) или остаётся там, куда её ставит camera::Move (false)."),
    og(d("DISABLEOBJECT", &.{ "object", "on" }, "Switches an object off (0) or on (1).", "Выключает (0) или включает (1) объект."), &.{ "object", "on" }, "Switches an object on (true: how scene actors appear) or off (false).", "Включает (true — так появляются актёры сцены) или выключает (false) объект."),
    d("DELETEOBJECT", &.{"object"}, "Deletes an object from the level.", "Удаляет объект с уровня."),
    og(d("IDLE_OFF", &.{"actor"}, "The actor stops its idle animations.", "Актёр перестаёт играть idle-анимации."), &.{ "actor", "on" }, "The actor plays its idle animations (true) or stops them (false).", "Актёр играет idle-анимации (true) или перестаёт (false)."),
    d("ASSIGN_ITEM", &.{ "actor", "item" }, "Gives the actor an item.", "Даёт актёру предмет."),
    og(d("IDLE_ON", &.{"actor"}, "The actor plays its idle animations again.", "Актёр снова играет idle-анимации."), &.{ "actor", "on" }, "The actor plays its idle animations (true) or stops them (false).", "Актёр играет idle-анимации (true) или перестаёт (false)."),
    d("IDLE_ANIMATION", &.{ "actor", "anim" }, "Sets the actor's idle animation (queued).", "Задаёт idle-анимацию актёра (в очередь)."),
    d("WALK_ANIMATION", &.{ "actor", "anim", "speed" }, "Sets the actor's walk animation and speed (queued).", "Задаёт анимацию и скорость ходьбы актёра (в очередь)."),
    d("FADE_IN", &.{}, "Fades in from black (10 ticks) and waits.", "Проявляется из чёрного (10 тиков) и ждёт."),
    d("FADE_BLACK", &.{}, "The screen black at once.", "Экран сразу чёрный."),
    d("FADE_OUT", &.{}, "Fades to black (10 ticks) and waits.", "Уходит в чёрное (10 тиков) и ждёт."),
    d("WALK_ON_SCENERY_TRACK", &.{ "actor", "track" }, "Walks the actor along a path of the level.", "Ведёт актёра по пути уровня."),
    d("ACTOR_GOINDOWN", &.{ "actor", "z", "speed" }, "Lowers (or raises) the actor to height z and waits.", "Опускает (или поднимает) актёра до высоты z и ждёт."),
    og(d("ZOOM", &.{ "percent", "time" }, "Camera zoom, 100–200 %.", "Приближение камеры, 100–200 %."), &.{ "zoom", "seconds" }, "Camera zoom 1.0–2.0 over that many seconds (0: at once).", "Приближение камеры 1.0–2.0 за столько секунд (0 — сразу)."),
    og(d("DOLLY", &.{ "point", "time", "zoom" }, "Moves the camera to the point over time (1/100 s), zoom 100–200 %.", "Ведёт камеру к точке за время (1/100 с), приближение 100–200 %."), &.{ "point", "seconds", "zoom" }, "Moves the camera to the point over that many seconds, zoom 1.0–2.0.", "Ведёт камеру к точке за столько секунд, приближение 1.0–2.0."),
    og(d("WEAPON", &.{ "actor", "weapon" }, "Puts a weapon in the actor's hand.", "Даёт актёру оружие в руку."), &.{ "actor", "weapon", "two_hands" }, "Puts a weapon in the hand of the actor (two_hands: true, held in both); no weapon: takes it away.", "Даёт актёру оружие в руку (two_hands = true — в обе руки); без оружия — убирает."),
    d("SOUND", &.{"sound"}, "Plays a sound.", "Проигрывает звук."),
    og(d("ALLOW_WALK_IN_AREA", &.{"area"}, "Heroes may walk in the area again.", "В области снова можно ходить."), &.{ "area", "on" }, "Heroes may walk in the area (true) or not (false).", "В области можно ходить (true) или нельзя (false)."),
    og(d("FORBID_WALK_IN_AREA", &.{"area"}, "Heroes may not walk in the area.", "В области ходить нельзя."), &.{ "area", "on" }, "Heroes may walk in the area (true) or not (false).", "В области можно ходить (true) или нельзя (false)."),
    d("ADDONSCRIPTLET", &.{"scene"}, "The scene to play when this one ends.", "Сцена, которая начнётся после этой."),
    og(d("SETHERO", &.{ "hero", "on" }, "A hero joins (1) or leaves (0) the party.", "Герой вступает в отряд (1) или уходит (0)."), &.{ "hero", "on" }, "A hero joins (true) or leaves (false) the party.", "Герой вступает в отряд (true) или уходит (false)."),
    d("STOP_HEROES", &.{}, "The party stops and looks around (fightlook).", "Отряд останавливается и осматривается (fightlook)."),
    og(d("WALKAREA", &.{ "area", "floor", "on" }, "Switches a walk area of the map on or off.", "Включает или выключает область ходьбы карты."), &.{ "area", "floor", "on" }, "Switches a walk area of the map on (true) or off (false).", "Включает (true) или выключает (false) область ходьбы карты."),
};

/// Scene command `name` (either spelling) as that spelling writes it, if any.
pub fn find(name: []const u8) ?View {
    const exe = og_lib.core.scene.exeOf(name);
    for (&docs) |*x| if (std.ascii.eqlIgnoreCase(x.exe, exe)) {
        if (std.mem.indexOf(u8, name, "::") != null) if (x.og) |o| return o;
        return .{ .params = x.params, .what = x.what };
    };
    return null;
}

test "every scene command has a tip" {
    for (og_lib.core.scene.commands) |p| try std.testing.expect(find(p.ogs) != null);
}
