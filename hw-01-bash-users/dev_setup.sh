#!/bin/bash

# Путь к лог-файлу — рядом со скриптом
LOG_FILE="$(dirname "$0")/dev_setup.log"

# Функция логирования: пишет сообщение и в терминал, и в файл
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message"
    echo "$message" >> "$LOG_FILE"
}

# Проверяем что скрипт запущен от root, иначе ничего не сработает
if [ "$EUID" -ne 0 ]; then
    echo "Запусти скрипт с sudo!"
    exit 1
fi

# Разбираем аргументы командной строки
# getopts — стандартный способ читать ключи
BASE_DIR=""
while getopts "d:" opt; do
    case $opt in
        d) BASE_DIR="$OPTARG" ;;
        *) echo "Использование: $0 [-d путь]"; exit 1 ;;
    esac
done

# Если ключ -d не передали — спрашиваем путь у пользователя
if [ -z "$BASE_DIR" ]; then
    read -rp "Введите путь для рабочих директорий: " BASE_DIR
fi

# Если всё равно пусто — выходим
if [ -z "$BASE_DIR" ]; then
    log "ОШИБКА: путь не задан"
    exit 1
fi

log "Рабочие директории будут созданы в: $BASE_DIR"

#  Шаг 1: создаём группу dev

# getent group проверяет есть ли уже такая группа
if getent group dev > /dev/null 2>&1; then
    log "Группа dev уже существует, пропускаем"
else
    groupadd dev
    log "Группа dev создана"
fi

# Шаг 2: даём группе dev sudo без пароля

SUDOERS_FILE="/etc/sudoers.d/dev_nopasswd"

if [ -f "$SUDOERS_FILE" ]; then
    log "Правило sudo для dev уже есть, пропускаем"
else
    echo "%dev ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    # Файл sudoers обязательно должен быть с правами 440, иначе sudo его игнорирует
    chmod 440 "$SUDOERS_FILE"
    log "Права sudo без пароля для группы dev настроены"
fi

# Шаг 3: создаём базовую директорию если её нет

if [ ! -d "$BASE_DIR" ]; then
    mkdir -p "$BASE_DIR"
    log "Создана базовая директория $BASE_DIR"
fi

# Шаг 4: обрабатываем каждого не системного пользователя

# Не системные пользователи — те у кого UID >= 1000
# Читаем /etc/passwd, разделитель полей ":", берём имя (поле 1) и uid (поле 3)
while IFS=: read -r username _ uid _; do
    # Пропускаем системных пользователей
    if [ "$uid" -lt 1000 ] || [ "$uid" -gt 60000 ]; then
        continue
    fi

    log "Обрабатываем пользователя: $username"

    # Добавляем в группу dev если ещё не там
    if id -nG "$username" | grep -qw dev; then
        log "  $username уже в группе dev, пропускаем"
    else
        usermod -aG dev "$username"
        log "  $username добавлен в группу dev"
    fi

    # Создаём рабочую директорию для пользователя
    WORKDIR="$BASE_DIR/${username}_workdir"

    if [ -d "$WORKDIR" ]; then
        log "  Директория $WORKDIR уже существует, пропускаем"
    else
        mkdir -p "$WORKDIR"
        log "  Создана директория $WORKDIR"
    fi

    # Узнаём первичную группу пользователя
    USER_GROUP=$(id -gn "$username")

    # Ставим владельца и права
    chown "$username:$USER_GROUP" "$WORKDIR"
    chmod 660 "$WORKDIR"
    log "  Права 660, владелец $username:$USER_GROUP"

    # Даём группе dev право на чтение через ACL
    # ACL позволяет добавить доступ третьей группе не меняя основные права
    if command -v setfacl > /dev/null 2>&1; then
        setfacl -m g:dev:rx "$WORKDIR"
        log "  Группе dev выдано чтение для $WORKDIR"
    else
        log "  ПРЕДУПРЕЖДЕНИЕ: setfacl не найден, установи пакет acl"
    fi

done < /etc/passwd

log "Готово! Лог сохранён в $LOG_FILE"
