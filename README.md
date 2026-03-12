# Lighthouse Tool (Audit + Auto Fix)

Инструмент для проверки и автооптимизации лендингов через Lighthouse в условиях, близких к продакшену (локальный nginx в Docker, gzip, HTTPS).

Подходит для новичков: положил проект в папку, запустил `.bat`, получил отчеты.

## Что умеет

- `run.bat` / `audit.ps1`: только аудит Lighthouse
- `fix.bat` / `fix.ps1`: автофиксы + аудит "до/после" + diff-отчет
- Поддержка Chrome/Edge, desktop/mobile пресеты

## Требования

Перед первым запуском установите:

1. Docker Desktop (и запущенный Docker Engine)
2. Node.js LTS (вместе с `npm`)
3. Lighthouse CLI: `npm i -g lighthouse`
4. Google Chrome и/или Microsoft Edge
5. FFmpeg + FFprobe (опционально, для оптимизации GIF)

Примечания:
- Если `ffmpeg` не установлен, GIF-оптимизация пропускается.
- Для GIF можно использовать Docker fallback: запуск с флагом `-UseDocker`.
- При первом запуске `fix.ps1` может доустановить npm-пакеты (`sharp`, `terser`, `clean-css-cli`, `purgecss`).

## Быстрый старт (рекомендуется)

1. Скачайте репозиторий и откройте папку проекта.
2. Убедитесь, что Docker Desktop запущен.
3. Положите каждый лендинг в отдельную подпапку внутри `projects/`.
4. В каждой папке лендинга должен быть `index.php` (по умолчанию).
5. Для автооптимизации запустите `fix.bat`.
6. Дождитесь завершения и откройте отчеты в `reports/`.

## Как запускать

### Вариант 1: 

- `fix.bat` - автофиксы + аудит до/после (рекомендуется)
- `run.bat` - только аудит

### Вариант 2: через PowerShell (гибкие параметры)

```powershell
# Только аудит всех проектов в ./projects
.\audit.ps1

# Аудит одного проекта
.\audit.ps1 -ProjectName "my-landing"

# Аудит с кастомными настройками
.\audit.ps1 -Runs 5 -Browsers "chrome,edge" -Presets "desktop,mobile"

# Автофиксы + аудит до/после (по умолчанию: Runs=1, Browsers=chrome)
.\fix.ps1

# Автофиксы только для одного проекта
.\fix.ps1 -ProjectName "my-landing"

# Если нет локального ffmpeg, но есть Docker
.\fix.ps1 -UseDocker
```

## Основные параметры

### `audit.ps1`

| Параметр | По умолчанию | Описание |
|---|---|---|
| `-ProjectsDir` | `.\projects` | Папка с лендингами |
| `-ReportsDir` | `.\reports\<timestamp>` | Куда сохранять отчеты |
| `-BasePort` | `9100` | Стартовый порт Docker/nginx |
| `-Runs` | `3` | Количество прогонов Lighthouse |
| `-Browsers` | `chrome,edge` | Браузеры для проверки |
| `-Presets` | `desktop,mobile` | Пресеты аудита |
| `-HtmlFile` | `index.php` | Входной HTML/PHP файл |
| `-ProjectName` | пусто | Запуск только для одного проекта |

### `fix.ps1`

| Параметр | По умолчанию | Описание |
|---|---|---|
| `-ProjectsDir` | `.\projects` | Папка с лендингами |
| `-ReportsDir` | `.\reports\fix-<timestamp>` | Папка отчетов фикса |
| `-BasePort` | `9100` | Стартовый порт Docker/nginx |
| `-Runs` | `1` | Количество прогонов для before/after |
| `-Browsers` | `chrome` | Браузеры для проверки |
| `-Presets` | `desktop,mobile` | Пресеты аудита |
| `-HtmlFile` | `index.php` | Входной файл проекта |
| `-ProjectName` | пусто | Обработка одного проекта |
| `-UseDocker` | выключен | Docker fallback для GIF (ffmpeg) |

## Структура проекта

```text
lighthouse-tool-master/
  projects/          # Сюда кладете папки лендингов
  reports/           # Сюда сохраняются отчеты
  run.bat            # Быстрый запуск аудита
  fix.bat            # Быстрый запуск автофиксов
  audit.ps1          # Скрипт аудита
  fix.ps1            # Скрипт автофиксов
  docker/            # Конфигурация локального nginx
  stubs/             # Заглушки для токенов/ресурсов
```

## Где смотреть результат

После `fix.bat`:

- `reports/fix-YYYYMMDD-HHMMSS/<project>/fix-changelog.md` - какие правки применены
- `reports/fix-YYYYMMDD-HHMMSS/<project>/diff-report.md` - сравнение before/after
- рядом лежат Lighthouse JSON/HTML отчеты

После `run.bat`:

- `reports/YYYYMMDD-HHMMSS/batch-summary.md` - общий summary
- `reports/YYYYMMDD-HHMMSS/<project>/lighthouse-summary.md` - summary по проекту

## Частые проблемы

### 1) `ERROR: Docker is not running`

Запустите Docker Desktop и дождитесь статуса `Engine running`, потом повторите запуск.

### 2) `Lighthouse not found`

Установите Lighthouse:

```bash
npm i -g lighthouse
```

### 3) `ffmpeg not found`

Варианты:

- установить FFmpeg/FFprobe в `PATH`
- или запускать `fix.ps1 -UseDocker`

### 4) Не находится Chrome/Edge

Установите хотя бы один браузер (Chrome или Edge).

## Лицензия

Добавьте нужную лицензию при публикации репозитория (если требуется).
