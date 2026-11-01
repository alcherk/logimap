# logimap

Свой маппер кнопок мыши **Logitech G603** под macOS: боковые кнопки превращаются
в **удерживаемые модификаторы** — ближняя к ладони («назад») = **⌥ Option**,
передняя («вперёд») = **⌃ Control**. Модификатор держится, пока держишь кнопку,
и приложения видят его в кликах, драгах и скролле (⌥+клик, ⌃+скролл и т.п.).

Никаких Logitech G HUB / Options+, нативный Swift-демон на CGEventTap.

## Почему это не повторяет историю с Hammerspoon

Прошлая версия на Hammerspoon улетала в петлю событий и блокировала ввод.
Здесь петля исключена конструктивно:

1. **Метки на synthetic-событиях.** Все события, которые отправляем мы сами,
   помечены магическим числом в поле `eventSourceUserData`; inject-тап их
   пропускает не глядя — замкнутого контура физически нет.
2. **Inject только мутирует флаги «на месте».** Из колбэка inject-тапа ничего
   не постится — порождать новые события нечем. Watch-тап слушает только
   `otherMouse*`, наша synthetic-клавиатура в его маску не входит.
3. **StormDetector.** Если за окно 0.5 с через тап проходит >2000 событий —
   inject аварийно отключается, все модификаторы отпускаются, в лог пишется `‼ STORM`.
4. **Анти-залипание.** Дубликаты down/up игнорируются, счётчик ссылок на
   модификатор, `releaseAll()` по SIGINT/SIGTERM/SIGHUP — при любом выходе
   зажатые модификаторы отпускаются.
5. Синтетический flagsChanged объединяет **физически** зажатые модификаторы
   с нашими — реальное ⌘ с клавиатуры не теряется.

## Сборка и установка

```bash
cd ~/Projects/personal/logimap
make test      # 19 юнит-тестов логики
make install   # release-сборка + ~/Applications/Logimap.app + LaunchAgent
```

После `make install`:

1. macOS попросит разрешение — открой **System Settings → Privacy & Security →
   Accessibility** и включи **Logimap** (спросит Touch ID/пароль — это норма).
2. Агент сам подхватит работу в течение секунды после разрешения.
   Перезапуск вручную: `~/Applications/Logimap.app/Contents/MacOS/logimap restart`.

Проверка: зажми ближнюю кнопку и кликни меню  — «About This Mac»
превратится в «System Information…» (значит ⌥ реально держится).

## Конфиг

`~/.config/logimap/config.json` (если файла нет — дефолт для G603):

```json
{
  "mappings": [
    { "button": 3, "modifier": "option"  },
    { "button": 4, "modifier": "control" }
  ],
  "injectFlags": true
}
```

- `button` — CG-номер кнопки **с нуля**: 3 = «Button 4» (ближняя на G603),
  4 = «Button 5» (передняя). Не знаешь номера — см. `make buttons`.
- `modifier` — `option` / `control` / `command` / `shift` (алиасы: `alt`, `ctrl`, `cmd`).
- `injectFlags` — подмешивание флага модификатора в события мыши/клавиатуры.
  Без него работают только приложения, опрашивающие состояние клавиш (игры).

Кнопки перепутаны местами? Поменяй строчки местами и `logimap restart`.
Пример конфига записать: `logimap init-config`.

## Команды

| Команда | Что делает |
|---|---|
| `make run` / `logimap run` | запустить в foreground (Ctrl-C — чистый выход) |
| `make buttons` / `logimap buttons` | калибровка: показывает CG-номера нажимаемых кнопок |
| `make doctor` / `logimap doctor` | права, конфиг, состояние |
| `logimap restart` | перезапустить агента |
| `logimap stop` | остановить экземпляр/агента |
| `make uninstall` | удалить агент и приложение |

Лог агента: `~/Library/Logs/logimap.log`.

## Как это работает

```
otherMouseDown(btn) ──▶ BindEngine.buttonDown ──▶ synthetic flagsChanged(⌥ down, с меткой)
       │                                                        │
       └─ кнопка замаплена ⇒ событие проглатывается             ▼
   («назад/вперёд» больше не срабатывает)      inject-тап: пока ⌥ активен,
                                               добавляет флаг в клики/клавиши/скролл
```

- `Sources/logimap/Engine.swift` — чистая логика (рефкаунты, флаги) — покрыта тестами.
- `Sources/logimap/TapController.swift` — CGEventTap'ы, метки, storm-detector.
- `Sources/logimap/Config.swift` — конфиг.
- `Sources/logimap/Commands.swift` — CLI.

## Troubleshooting

- **Кнопки как раньше «назад/вперёд»** → `make doctor`: скорее всего нет
  Accessibility у Logimap.app (или агент не запущен).
- **⌥+клик не работает в конкретном приложении, а в меню работает** → приложение
  читает флаги из собственных событий; попробуй `injectFlags: true` (если был false)
  — и проверь, не сидит ли приложение в полноэкранном защищённом режиме (Secure Input).
- **Совсем сломалось** → `logimap stop` / `make uninstall`; модификаторы
  отпускаются при остановке. Hammerspoon больше не используется.
