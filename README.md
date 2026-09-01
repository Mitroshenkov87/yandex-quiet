# Yandex Quiet

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/Platform-Windows-blue)](https://www.microsoft.com/windows)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Keep **Yandex Browser** installed so you can open it by hand (Russian GOST / national-certificate sites). Stop the updater, SoftLanding ads, autostart, and companion clients from sitting in the background watching you.

Яндекс.Браузер **не удаляется**. Удаляются не закладки и не профиль. Гасится то, что само поднимается в системе.

## English (short)

Some people have to keep Yandex Browser because a government, bank, or “визитка” site only works with Russian certificate stores that other browsers do not ship. The browser then installs an update service, scheduled tasks, SoftLanding (ad/landing) tasks, and often Disk / Telemost / Pin / Alice autostart.

**Yandex Quiet**:

1. Disables those watchers.
2. Writes a snapshot on the **first** Apply.
3. Installs a SYSTEM watchdog (at logon + hourly), because Yandex recreates tasks.
4. `-Restore` rolls back to that snapshot and removes the watchdog.

The real Start Menu shortcut to `browser.exe` is kept. URL landing shortcuts and Startup entries are removed (and backed up for Restore).

## Зачем

Браузер нужен. Фоновые службы, автообновление, лендинги Алисы и клиенты — нет. Они возвращаются после ручного отключения. Поэтому есть сторожок.

## Что делает

| Цель | Действие |
|------|----------|
| `YandexBrowserService` | Stop + Disabled |
| Задачи обновления и `\SoftLanding\` | Disabled |
| Run / RunOnce, папка Автозагрузка | записи Яндекса снимаются |
| Политика `HKLM\SOFTWARE\Policies\YandexBrowser` | автообновление выкл. |
| Диск, Телемост, Pin, Алиса | автозапуск и процессы, **не** деинсталляция |
| Лендинг-ярлыки (URL) | удаляются, копия лежит в снимке |
| Ярлык самого браузера | остаётся |

Процесс `browser.exe` из каталога Яндекса **не** убивается, если вы сами открыли браузер. Для полного гашения сессии: `-KillBrowser`.

## Что не делает

- Не сносит Яндекс.Браузер
- Не трогает профиль, куки, закладки
- Не трогает VPN, Chrome, Edge, Firefox
- Не «лечит» сайты и не ставит российские корневые сертификаты в другие браузеры
- Restore **не** включает апдейтер «с завода», если он уже был выключен в момент первого Apply. Откат — к снимку, не к инсталлятору Яндекса.

## Требования

- Windows 10 / 11
- Windows PowerShell 5.1 (встроенный). PowerShell 7 не нужен
- Запуск от администратора (скрипт сам запросит UAC)

## Установка

Скачайте [последний релиз](https://github.com/Mitroshenkov87/yandex-quiet/releases) или клонируйте:

```powershell
git clone https://github.com/Mitroshenkov87/yandex-quiet.git
cd yandex-quiet
```

Разблокируйте файл, если Windows пометила его как скачанный из сети:

```powershell
Unblock-File -Path .\Yandex-Quiet.ps1
```

## Запуск

Двойной щелчок по `Yandex-Quiet.cmd` или:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Yandex-Quiet.ps1
```

Меню:

1. Состояние
2. Применить и поставить сторожок
3. Применить один раз (без сторожка)
4. Откатить к снимку
5. Снять сторожок
6. Выход

Ключи, без меню:

```powershell
.\Yandex-Quiet.ps1 -Status
.\Yandex-Quiet.ps1 -Apply
.\Yandex-Quiet.ps1 -Apply -Once
.\Yandex-Quiet.ps1 -Apply -KillBrowser
.\Yandex-Quiet.ps1 -Restore
.\Yandex-Quiet.ps1 -InstallWatchdog
.\Yandex-Quiet.ps1 -RemoveWatchdog
.\Yandex-Quiet.ps1 -Apply -WhatIf
```

`-Once` — только этот запуск, сторожок не ставится. Сторожок сам вызывает `-Apply -Once -Quiet`.

## Снимок и откат

Первый успешный Apply пишет:

- `C:\ProgramData\YandexQuiet\snapshot.json`
- копии снятых ярлыков в `C:\ProgramData\YandexQuiet\shortcut-backup\`
- лог `C:\ProgramData\YandexQuiet\yandex-quiet.log`

Повторный Apply **не** перезаписывает снимок. Так Restore всегда возвращает машину к моменту *до первого* Apply.

Чтобы снять новый снимок: удалите `snapshot.json` и снова сделайте Apply.

Restore:

- возвращает тип запуска служб и состояние задач из снимка
- возвращает Run-ключи и политики
- возвращает ярлыки из backup
- снимает сторожок
- оставляет `snapshot.json` — можно снова Apply / Restore

## Сторожок

Имя задачи: `\YandexQuiet\YandexQuiet-Watchdog`

- пользователь `SYSTEM`, высокий уровень
- триггеры: вход в Windows и каждый час
- копия скрипта: `C:\ProgramData\YandexQuiet\Yandex-Quiet.ps1`

Повторный Apply со сторожком обновляет эту копию.

## Как ищем цели

Не по локали Windows. Службы, задачи и процессы считаются яндексовыми, если путь содержит `\Yandex\`, `service_update.exe`, либо задача лежит в `\SoftLanding\`. Свой сторожок не трогаем.

## Лицензия

MIT. См. [LICENSE](LICENSE).
