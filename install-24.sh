#!/bin/sh

# ==============================================================================
# NaïveProxy Universal Installer/Updater for OpenWrt (aarch64)
# Поддерживает OpenWrt 19..24 (opkg) И OpenWrt 25+ (apk)
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}  NaïveProxy Universal Installer/Updater (OpenWrt aarch64)${NC}"
echo -e "${CYAN}========================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# 1. Подготовка системы и универсальная установка пакетов (opkg / apk)
# ------------------------------------------------------------------------------
prepare_env() {
    echo -e "${YELLOW}[1/4] Проверка окружения и пакетного менеджера...${NC}"
    
    # Синхронизация системного времени
    if [ -x /usr/sbin/ntpd ]; then
        echo -e "      Синхронизация системного времени..."
        ntpd -q -p time.google.com >/dev/null 2>&1 || true
    fi

    # Детект пакетного менеджера: apk (OpenWrt 25+) или opkg (OpenWrt <= 24)
    if command -v apk >/dev/null 2>&1; then
        echo -e "      Обнаружен новый пакетный менеджер ${CYAN}apk${NC} (OpenWrt 25+)"
        echo -e "      Обновление индексов и установка утилит..."
        apk update >/dev/null 2>&1
        apk add --no-cache curl tar xz ca-certificates >/dev/null 2>&1
    elif command -v opkg >/dev/null 2>&1; then
        echo -e "      Обнаружен классический пакетный менеджер ${CYAN}opkg${NC} (OpenWrt <= 24)"
        NEED_UPDATE=0
        for pkg in curl tar xz ca-bundle ca-certificates; do
            if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
                NEED_UPDATE=1
                break
            fi
        done

        if [ "$NEED_UPDATE" -eq 1 ]; then
            echo -e "      Обновление индексов и установка утилит..."
            rm -f /var/opkg-lists/* >/dev/null 2>&1
            opkg update >/dev/null 2>&1
            opkg install curl tar xz ca-bundle ca-certificates >/dev/null 2>&1
        fi
    else
        echo -e "      ${YELLOW}Внимание: Не найдены ни opkg, ни apk. Пропускаем установку зависимостей...${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 2. Загрузка последнего релиза с GitHub (Статический бинарник)
# ------------------------------------------------------------------------------
download_latest_naive() {
    echo -e "${YELLOW}[2/4] Загрузка актуального релиза NaïveProxy с GitHub...${NC}"
    cd /tmp
    rm -rf /tmp/naiveproxy-* /tmp/naiveproxy-latest.tar.xz

    echo -e "      Определение версии последнего релиза..."
    TAG=$(curl -sSI -H "User-Agent: Mozilla/5.0" https://github.com/klzgrad/naiveproxy/releases/latest | grep -i "^location:" | sed 's/.*tag\///' | tr -d '\r\n')

    if [ -z "$TAG" ]; then
        echo -e "      ${RED}ОШИБКА: Не удалось определить номер версии с GitHub!${NC}"
        echo -e "      Проверьте интернет-соединение или системное время (команда 'date')."
        exit 1
    fi

    echo -e "      Актуальная версия: ${CYAN}${TAG}${NC}"

    # Цепочка фолбэков (начинаем со статического generic, работающего на любых релизах)
    SUCCESS_DOWNLOAD=0
    for TARGET_ARCH in "aarch64_generic-static" "aarch64_cortex-a53-static" "aarch64_cortex-a53" "aarch64_generic"; do
        ARCHIVE_NAME="naiveproxy-${TAG}-openwrt-${TARGET_ARCH}.tar.xz"
        URL="https://github.com/klzgrad/naiveproxy/releases/download/${TAG}/${ARCHIVE_NAME}"

        echo -e "      Пробуем сборку: ${CYAN}${TARGET_ARCH}${NC}..."
        curl -sSL -H "User-Agent: Mozilla/5.0" -o naiveproxy-latest.tar.xz "$URL"

        if xz -t naiveproxy-latest.tar.xz >/dev/null 2>&1; then
            echo -e "      ${GREEN}Успешно скачан валидный архив: ${ARCHIVE_NAME}${NC}"
            SUCCESS_DOWNLOAD=1
            break
        else
            rm -f naiveproxy-latest.tar.xz
        fi
    done

    if [ "$SUCCESS_DOWNLOAD" -eq 0 ]; then
        echo -e "      ${RED}ОШИБКА: Не удалось скачать ни один валидный архив под aarch64!${NC}"
        exit 1
    fi

    echo -e "      Распаковка и установка бинарника..."
    tar -xf naiveproxy-latest.tar.xz
    
    NAIVE_BIN=$(find /tmp -type f -name "naive" | head -n 1)

    if [ -n "$NAIVE_BIN" ] && [ -f "$NAIVE_BIN" ]; then
        mv "$NAIVE_BIN" /usr/bin/naive
        chmod +x /usr/bin/naive
        rm -rf /tmp/naiveproxy-* /tmp/naiveproxy-latest.tar.xz
        
        # Валидация запускаемости
        if /usr/bin/naive --version >/dev/null 2>&1; then
            echo -e "      ${GREEN}Исполняемый файл /usr/bin/naive успешно проверен и готов к работе!${NC}"
        else
            echo -e "      ${RED}ОШИБКА: Скачанный бинарник не запускается в вашей ОС!${NC}"
            exit 1
        fi
    else
        echo -e "      ${RED}ОШИБКА: Файл 'naive' не найден внутри архива!${NC}"
        rm -rf /tmp/naiveproxy-* /tmp/naiveproxy-latest.tar.xz
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 3. Настройка конфигурации и службы procd
# ------------------------------------------------------------------------------
setup_config_and_service() {
    echo -e "${YELLOW}[3/4] Настройка конфигурации и службы автозапуска...${NC}"
    mkdir -p /etc/naiveproxy

    echo ""
    echo -e "${CYAN}--- Введите данные вашего сервера NaïveProxy ---${NC}"
    
    read -p "Адрес сервера (домен или IP): " NAV_HOST
    while [ -z "$NAV_HOST" ]; do
        echo -e "${RED}Адрес сервера не может быть пустым!${NC}"
        read -p "Адрес сервера: " NAV_HOST
    done

    read -p "Порт сервера [по умолчанию: 443]: " NAV_PORT
    NAV_PORT=${NAV_PORT:-443}

    read -p "Логин (Username): " NAV_USER
    while [ -z "$NAV_USER" ]; do
        echo -e "${RED}Логин не может быть пустым!${NC}"
        read -p "Логин (Username): " NAV_USER
    done

    read -p "Пароль (Password): " NAV_PASS
    while [ -z "$NAV_PASS" ]; do
        echo -e "${RED}Пароль не может быть пустым!${NC}"
        read -p "Пароль (Password): " NAV_PASS
    done

    read -p "Локальный SOCKS5 порт роутера [по умолчанию: 10800]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-10800}

    echo ""
    echo -e "${YELLOW}Опция Concurrency (Количество параллельных туннелей):${NC}"
    echo "1 — Стандартный режим (Рекомендуется! Максимальная маскировка под Chrome)."
    echo "4 — Мульти-туннелирование (Выше скорость при потерях пакетов, но выше риск детекта DPI)."
    read -p "Включить мульти-туннелирование concurrency=4? (y/N) [по умолчанию: N]: " USE_CONC

    case "$USE_CONC" in
        [yY][eE][sS]|[yY])
            CONCURRENCY_VAL=4
            echo -e "      Установлено значение: ${YELLOW}concurrency = 4${NC}"
            ;;
        *)
            CONCURRENCY_VAL=1
            echo -e "      Установлено значение: ${GREEN}concurrency = 1 (Безопасный режим)${NC}"
            ;;
    esac

    cat << EOF > /etc/naiveproxy/config.json
{
  "listen": "socks://127.0.0.1:${LOCAL_PORT}",
  "proxy": "https://${NAV_USER}:${NAV_PASS}@${NAV_HOST}:${NAV_PORT}",
  "log": "",
  "concurrency": ${CONCURRENCY_VAL}
}
EOF
    echo -e "      Конфигурация /etc/naiveproxy/config.json создана."

    cat << 'EOF' > /etc/init.d/naiveproxy
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/naive /etc/naiveproxy/config.json
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/naiveproxy
    /etc/init.d/naiveproxy enable >/dev/null 2>&1
    echo -e "      Служба /etc/init.d/naiveproxy добавлена в автозапуск."
}

# ------------------------------------------------------------------------------
# 4. Диагностика и проверка статуса
# ------------------------------------------------------------------------------
check_status() {
    echo -e "${YELLOW}[4/4] Запуск и проверка статуса службы...${NC}"
    /etc/init.d/naiveproxy restart >/dev/null 2>&1
    sleep 2

    echo ""
    echo -e "${CYAN}================ РЕЗУЛЬТАТЫ ПРОВЕРКИ ================${NC}"

    PID=$(pgrep -f "/usr/bin/naive")
    if [ -n "$PID" ]; then
        VER=$(/usr/bin/naive --version 2>&1)
        echo -e "1. Процесс NaïveProxy:  ${GREEN}РАБОТАЕТ${NC} (PID: $PID)"
        echo -e "   Установленная версия: ${GREEN}$VER${NC}"
    else
        echo -e "1. Процесс NaïveProxy:  ${RED}НЕ НАЙДЕН / ОШИБКА ЗАПУСКА${NC}"
        echo -e "   Проверьте правильность конфига в /etc/naiveproxy/config.json"
        exit 1
    fi

    LISTEN_PORT=$(grep '"listen"' /etc/naiveproxy/config.json 2>/dev/null | awk -F':' '{print $3}' | tr -d '", ')
    LISTEN_PORT=${LISTEN_PORT:-10800}

    PORT_CHECK=$(netstat -tulpn 2>/dev/null | grep "$LISTEN_PORT" || ss -tulpn 2>/dev/null | grep "$LISTEN_PORT")
    
    if [ -z "$PORT_CHECK" ] && [ -f /proc/net/tcp ]; then
        HEX_PORT=$(printf '%04X' "$LISTEN_PORT")
        PORT_CHECK=$(grep -i ":$HEX_PORT " /proc/net/tcp)
    fi

    if [ -n "$PORT_CHECK" ]; then
        echo -e "2. Локальный SOCKS5 порт ${LISTEN_PORT}: ${GREEN}ПОДНЯТ И СЛУШАЕТ ВХОДЯЩИЕ ПОДКЛЮЧЕНИЯ${NC}"
    else
        echo -e "2. Локальный SOCKS5 порт ${LISTEN_PORT}: ${RED}НЕ ПРОСЛУШИВАЕТСЯ${NC}"
    fi
    echo -e "${CYAN}========================================================${NC}"
}

# ------------------------------------------------------------------------------
# Главное меню
# ------------------------------------------------------------------------------
echo "Выберите действие:"
echo "1) Чистая установка (Загрузка бинарника + ввод данных + создание конфигов)"
echo "2) Обновление бинарника (Сохраняет текущий конфиг и обновляет только NaïveProxy)"
echo ""
read -p "Введите номер (1 или 2) [по умолчанию: 1]: " ACTION
ACTION=${ACTION:-1}

case "$ACTION" in
    2)
        echo -e "${GREEN}--- Выбран режим ОБНОВЛЕНИЯ ---${NC}"
        prepare_env
        download_latest_naive
        check_status
        ;;
    *)
        echo -e "${GREEN}--- Выбран режим ЧИСТОЙ УСТАНОВКИ ---${NC}"
        prepare_env
        download_latest_naive
        setup_config_and_service
        check_status
        ;;
esac

echo ""
echo -e "${GREEN}Операция успешно завершена!${NC}"
