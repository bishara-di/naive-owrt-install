#!/bin/sh

# ==============================================================================
# NaïveProxy Installer & Updater for OpenWrt (aarch64)
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}   NaïveProxy Installer & Updater for OpenWrt (aarch64) ${NC}"
echo -e "${CYAN}========================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# 1. Подготовка системы и проверка зависимостей
# ------------------------------------------------------------------------------
prepare_env() {
    echo -e "${YELLOW}[1/4] Проверка и подготовка окружения...${NC}"
    
    # Синхронизация системного времени (критично для валидации TLS GitHub)
    if [ -x /usr/sbin/ntpd ]; then
        echo -e "      Синхронизация системного времени..."
        ntpd -q -p time.google.com >/dev/null 2>&1 || true
    fi

    # Проверка наличия пакетов
    NEED_UPDATE=0
    for pkg in curl tar xz ca-bundle ca-certificates; do
        if ! opkg list-installed | grep -q "^$pkg "; then
            NEED_UPDATE=1
            break
        fi
    done

    if [ "$NEED_UPDATE" -eq 1 ]; then
        echo -e "      Установка недостающих системных утилит (curl, tar, xz, ca-certificates)..."
        rm -f /var/opkg-lists/* >/dev/null 2>&1
        opkg update >/dev/null 2>&1
        opkg install curl tar xz ca-bundle ca-certificates >/dev/null 2>&1
    fi
}

# ------------------------------------------------------------------------------
# 2. Загрузка последнего релиза с GitHub
# ------------------------------------------------------------------------------
download_latest_naive() {
    echo -e "${YELLOW}[2/4] Загрузка актуального релиза NaïveProxy с GitHub...${NC}"
    cd /tmp
    rm -rf /tmp/naiveproxy-* /tmp/naiveproxy-latest.tar.xz

    # Запрашиваем JSON, разбиваем по объектам assets (tr ',' '\n'), находим нужную строку и точно вырезаем URL через sed
    URL=$(curl -sSL -H "User-Agent: Mozilla/5.0" https://api.github.com/repos/klzgrad/naiveproxy/releases/latest | tr ',' '\n' | grep "browser_download_url" | grep "openwrt-aarch64" | grep "\.tar\.xz" | grep -v "static" | head -n 1 | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p')

    if [ -z "$URL" ]; then
        echo -e "      ${RED}ОШИБКА: Не удалось распарсить прямую ссылку на архив c GitHub API!${NC}"
        echo -e "      Проверьте интернет или закомментируйте проверку для отладки."
        exit 1
    fi

    echo -e "      Прямая ссылка получена:"
    echo -e "      ${CYAN}$URL${NC}"
    echo -e "      Скачивание архива..."
    curl -sSL -H "User-Agent: Mozilla/5.0" -o naiveproxy-latest.tar.xz "$URL"

    # Проверка сигнатуры xz перед распаковкой
    if ! xz -t naiveproxy-latest.tar.xz >/dev/null 2>&1; then
        echo -e "      ${RED}ОШИБКА: Скачанный файл поврежден или не является .tar.xz архивом!${NC}"
        rm -f naiveproxy-latest.tar.xz
        exit 1
    fi

    echo -e "      Распаковка архива..."
    tar -xf naiveproxy-latest.tar.xz
    
    # Динамический поиск бинарника
    NAIVE_BIN=$(find /tmp -type f -name "naive" | head -n 1)

    if [ -n "$NAIVE_BIN" ] && [ -f "$NAIVE_BIN" ]; then
        mv "$NAIVE_BIN" /usr/bin/naive
        chmod +x /usr/bin/naive
        rm -rf /tmp/naiveproxy-* /tmp/naiveproxy-latest.tar.xz
        echo -e "      ${GREEN}Исполняемый файл /usr/bin/naive успешно установлен!${NC}"
    else
        echo -e "      ${RED}ОШИБКА: Исполняемый файл 'naive' не найден внутри архива!${NC}"
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
    
    read -p "Адрес сервера (домен или IP) [например: srv-repo.jo3.org]: " NAV_HOST
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

    # Генерация JSON
    cat << EOF > /etc/naiveproxy/config.json
{
  "listen": "socks://127.0.0.1:${LOCAL_PORT}",
  "proxy": "https://${NAV_USER}:${NAV_PASS}@${NAV_HOST}:${NAV_PORT}",
  "log": "",
  "concurrency": ${CONCURRENCY_VAL}
}
EOF
    echo -e "      Конфигурация /etc/naiveproxy/config.json создана."

    # Генерация init-скрипта procd
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
