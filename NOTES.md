# logimap — история и заметки по реализации

Сессия: 2026-10-30. Записано после того, как всё заработало.

## Задача

Logitech G603 под macOS (без Logitech G HUB): боковые кнопки мыши должны
работать как **удерживаемые** модификаторы — ближняя к ладони («назад»,
Button 4) = **⌥ Option**, передняя («вперёд», Button 5) = **⌃ Control**.
Модификатор держится, пока держишь кнопку; приложения должны видеть его
в кликах, драгах и скролле (⌥+клик, ⌃+скролл и т.п.).

## Путь решения (и почему не «нормальные» инструменты)

1. **Logi Options+** — не поддерживает G-серию вообще (только MX/Ergo/Signature).
   Для G603 официальный софт — только G HUB, который не хотели.
2. **Mac Mouse Fix** — проверил по исходникам (открытый проект):
   действие `keyboardShortcut` отправляет мгновенный тап keyDown+keyUp,
   а не «держать, пока зажата кнопка»; UI вдобавок не даёт записать ⌥/⌃
   без обычной клавиши. Задачу не решает в принципе.
3. **BetterTouchTool / SteerMouse / LinearMouse** — держание модификатора
   с кнопки мыши либо через костыли (два триггера down/up в BTT, с риском
   залипания), либо открытые feature request'ы.
4. **Karabiner-Elements** — поддержку кнопок мыши убрали ещё в v13.
5. **Hammerspoon** — рабочая попытка №1, см. постмортем ниже. Выявила,
   что события от кнопок G603 приходят как `otherMouseDown/Up` — это важно.
6. **logimap** (этот проект) — свой Swift-демон на CGEventTap. Работает.

## Постмортем: Hammerspoon-инцидент

Первая реализация на Hammerspoon: тап ловил `otherMouse*` и постил
synthetic keyDown/Up модификатора, плюс второй тап «инжектил» флаг
модификатора во ВСЕ события (клики, клавиши, скролл), пока кнопка зажата.

**Что сломалось:** ввод во всей системе заблокировался. Причина — петля
событий: синтетические события, которые мы сами постим из колбэка тапа,
снова попадали в перехват (inject-тап слушал те же типы, что мы постим,
и `hs.alert` в колбэке замедлял тап до таймаута). Итог — лавина, компьютер
пришлось перезагружать. Вторая ошибка той версии: метод называется
`e:getType()`, а не `e:type()` — колбэк падал, но это, наоборот, спасало лог.

**Уроки, заложенные в logimap:**
- ничего не постить из колбэка тапа, который слушает постящиеся типы;
- помечать свои synthetic-события и пропускать их;
- не делать UI из колбэка тапа;
- держать предохранитель (storm detector) и чистый выход с releaseAll().

## Технические факты (выстраданные)

- Нумерация кнопок: CG `mouseEventButtonNumber` **с нуля**. G603:
  ближняя («назад») = **3** (она же «Button 4» в 1-based), передняя = **4**.
- Коды клавиш: левый Option = **58**, левый Control = **59**,
  Command = 55, Shift = 56.
- CGEventFlags: shift = 131072 (1<<17), control = 262144 (1<<18),
  option = 524288 (1<<19), command = 1048576 (1<<20).
- CGEventType: `otherMouseDown` = 25, `otherMouseUp` = 26 (CG-нумерация,
  не путать с NSEvent-типами).
- macOS TCC-грабли:
  - нажал Deny → повторного промпта не будет; лечится
    `tccutil reset Accessibility org.hammerspoon.Hammerspoon` (для любого
    бандла аналогично);
  - после выдачи Accessibility **запущенному** процессу состояние может
    не «подхватиться» — нужен рестарт процесса (поэтому после включения
    тумблера агента перезапустили `logimap restart`);
  - CLI-бинарка, запущенная из терминала, получает TCC-запись *терминала*;
    свой стабильный TCC-identity даёт .app-бандл → logimap живёт в
    `~/Applications/Logimap.app`, LaunchAgent стартует бинарь из бандла.
- Hammerspoon API: `hs.eventtap.event` имеет `getType/getFlags/setFlags`;
  метода `type()` нет (был источник падений колбэков).

## Как устроен logimap

```
Sources/logimap/
  Modifiers.swift    — спецификации модификаторов + алиасы (alt/ctrl/cmd)
  Engine.swift       — BindEngine: кнопка→модификатор, дедуп down/up,
                       рефкаунты, activeFlags, releaseAll, composeFlags;
                       StormDetector (окно 0.5 c, лимит 2000)
  Config.swift       — ~/.config/logimap/config.json (JSON, с дефолтами)
  TapController.swift— CGEventTap'ы:
                       watch (только otherMouse*): кнопка → press/release
                       модификатора, замапленные кнопки проглатываются;
                       inject (keyDown/Up, flagsChanged, все mouse*, scrollWheel):
                       пока модификатор активен, добавляет флаг в события.
  Commands.swift     — run/stop/buttons/doctor/init-config/install-agent/
                       uninstall-agent/restart
  main.swift         — диспетчер CLI
Tests/logimapTests/  — 19 тестов: движок, шторм-детектор, конфиг, флаги
Resources/Info.plist — LSUIElement, бандл com.lex.logimap
```

**Безопасность от петли (главное отличие от Hammerspoon-версии):**
1. Все synthetic-события помечены магическим числом в `eventSourceUserData`
   (`TapController.synthTag`); inject-тап их пропускает не глядя.
2. Inject только мутирует `event.flags` на месте и возвращает тот же объект —
   из его колбэка ничего не постится.
3. Watch-тап слушает только otherMouse*; synthetic-клавиатура в его маску
   не входит — в watch-колбэке постить можно.
4. StormDetector: >2000 событий за 0.5 c → inject отключается,
   модификаторы отпускаются, в лог пишется `‼ STORM`.
5. Анти-залипание: дубликаты down/up игнорируются, рефкаунты,
   SIGINT/SIGTERM/SIGHUP → releaseAll → exit.
6. Synthetic flagsChanged объединяет физические флаги с нашими
   (composeFlags) — реальное ⌘ с клавиатуры не теряется.

## Что и где установлено

- `~/Applications/Logimap.app` — само приложение (LSUIElement, без иконки).
- `~/Library/LaunchAgents/com.lex.logimap.plist` — агент: RunAtLoad, лог в
  `~/Library/Logs/logimap.log`.
- Конфига нет → дефолты G603: CG#3 → option, CG#4 → control, inject = on.
- Исходники: `~/Projects/personal/logimap` (git init сделан, коммитов нет).
- Остатки прошлых попыток (обезврежены, можно снести):
  Hammerspoon — пустой `~/.hammerspoon/init.lua`, автозапуск снят;
  Mac Mouse Fix — установлен, но `Remaps` пуст (не перехватывает кнопки).

## Эксплуатация

```bash
tail -f ~/Library/Logs/logimap.log                    # что происходит
~/Applications/Logimap.app/Contents/MacOS/logimap doctor
~/Applications/Logimap.app/Contents/MacOS/logimap restart
make buttons    # в каталоге проекта: калибровка номеров кнопок
make uninstall  # снести всё
```

Смена биндов: `logimap init-config`, правка `~/.config/logimap/config.json`,
`logimap restart`.

## Идеи на будущее

- per-app правила (как в BTT): разные бинды для конкретных приложений.
- Проброс «назад/вперёд» по короткому клику, модификатор — по удержанию
  (сейчас кнопка полностью занята модификатором).
- Нотаризация бинаря — стабильный TCC-identity без плясок.
- Обработка Secure Input (когда какое-то приложение включило защищённый ввод,
  inject-тапы получают меньше событий — предупреждать в doctor).
- Менюбар-иконка со статусом и быстрым вкл/выкл.
