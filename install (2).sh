#!/bin/sh
# NaïveProxy Installer/Updater for OpenWrt (aarch64)
# Source: https://github.com/bishara-di/naive-owrt-install

set -e

# Проверка прав root
if [ "$(id -u)" != "0" ]; then
    echo "Ошибка: скрипт должен запускаться с правами root." >&2
    exit 1
fi

# Функция получения URL последнего релиза для aarch64
get_latest_url() {
    wget -qO- https://api.github.com/repos/klzgrad/naiveproxy/releases/latest \
        | grep "browser_download_url" \
        | grep "openwrt-aarch64" \
        | cut -d '"' -f 4
}

# Установка зависимостей
install_deps() {
    echo "Обновление списка пакетов..."
    opkg update
    echo "Установка необходимых утилит..."
    opkg install nano curl tar xz wget-ssl ca-bundle ca-certificates
}

# Скачивание и установка бинарника
download_and_install_binary() {
    cd /tmp
    echo "Получение ссылки на последнюю версию..."
    URL=$(get_latest_url)
    if [ -z "$URL" ]; then
        echo "Ошибка: не удалось получить URL для скачивания. Проверьте интернет." >&2
        exit 1
    fi
    echo "Скачивание $URL ..."
    wget -O naiveproxy-latest.tar.xz "$URL"
    if [ ! -s naiveproxy-latest.tar.xz ]; then
        echo "Ошибка: файл пуст или не скачан." >&2
        exit 1
    fi
    echo "Распаковка..."
    tar -xf naiveproxy-latest.tar.xz
    BIN_DIR=$(find . -maxdepth 1 -type d -name "naiveproxy-*" | head -1)
    if [ -z "$BIN_DIR" ]; then
        echo "Ошибка: не найдена директория после распаковки." >&2
        exit 1
    fi
    mv "$BIN_DIR/naive" /usr/bin/naive
    chmod +x /usr/bin/naive
    cd /
    rm -rf /tmp/naiveproxy-* /tmp/naiveproxy-latest.tar.xz
    echo "Бинарник установлен в /usr/bin/naive"
}

# Создание конфигурационного файла
create_config() {
    mkdir -p /etc/naiveproxy
    echo "Введите логин (username):"
    read username
    echo "Введите пароль (без спецсимволов, влияющих на URL):"
    read password
    echo "Введите адрес сервера (домен или IP):"
    read server
    echo "Введите порт (по умолчанию 443):"
    read port
    [ -z "$port" ] && port=443

    echo "Параметр concurrency (количество одновременных соединений)."
    echo "Моё мнение: значение >1 может снижать маскировку, т.к. создаёт больше параллельных потоков,"
    echo "что нехарактерно для обычного браузера. Рекомендую не указывать (использовать значение по умолчанию 1)"
    echo "или явно задать 1."
    echo "Хотите добавить параметр concurrency? (y/n)"
    read use_concurrency
    conc=""
    if [ "$use_concurrency" = "y" ] || [ "$use_concurrency" = "Y" ]; then
        echo "Введите значение (например, 1, 2, 4):"
        read conc_val
        if [ -n "$conc_val" ]; then
            conc=",\n  \"concurrency\": $conc_val"
        fi
    fi

    cat > /etc/naiveproxy/config.json <<EOF
{
  "listen": "socks://127.0.0.1:10800",
  "proxy": "https://$username:$password@$server:$port",
  "log": ""$conc
}
EOF
    echo "Конфиг создан: /etc/naiveproxy/config.json"
}

# Создание init-скрипта
create_init_script() {
    cat > /etc/init.d/naiveproxy <<'EOF'
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
    /etc/init.d/naiveproxy enable
    echo "Init-скрипт создан, добавлен в автозагрузку."
}

# Запуск и проверка
start_and_check() {
    echo "Запуск службы..."
    /etc/init.d/naiveproxy start
    sleep 2

    # Проверка через ss или netstat
    if command -v ss >/dev/null 2>&1; then
        echo "Проверка порта через ss:"
        ss -tulpn | grep naive || echo "Процесс не найден в ss."
    elif command -v netstat >/dev/null 2>&1; then
        echo "Проверка порта через netstat:"
        netstat -tulpn | grep naive || echo "Процесс не найден в netstat."
    else
        echo "Утилиты ss/netstat не найдены, пропускаем проверку порта."
    fi

    if pgrep -f "naive /etc/naiveproxy/config.json" >/dev/null; then
        echo "✅ NaïveProxy успешно запущен."
    else
        echo "❌ Процесс NaïveProxy не обнаружен. Проверьте логи." >&2
    fi
}

# ===== Основной блок =====
echo "=== Установка / Обновление NaïveProxy для OpenWrt (aarch64) ==="
echo "Что вы хотите сделать? (install / update)"
read action

case "$action" in
    install|Install|INSTALL|i|I)
        echo "Запуск установки..."
        if [ -f /usr/bin/naive ] || [ -f /etc/init.d/naiveproxy ]; then
            echo "Обнаружена существующая установка. Переустановить? (y/n)"
            read proceed
            [ "$proceed" != "y" ] && [ "$proceed" != "Y" ] && exit 0
            # Останавливаем службу, если она есть
            /etc/init.d/naiveproxy stop 2>/dev/null || true
        fi
        install_deps
        download_and_install_binary
        create_config
        create_init_script
        start_and_check
        echo "✅ Установка завершена."
        ;;
    update|Update|UPDATE|u|U)
        echo "Запуск обновления..."
        if [ ! -f /usr/bin/naive ]; then
            echo "❌ NaïveProxy не установлен. Сначала выполните установку." >&2
            exit 1
        fi
        # Останавливаем службу
        /etc/init.d/naiveproxy stop 2>/dev/null || true
        download_and_install_binary
        /etc/init.d/naiveproxy start
        start_and_check
        echo "✅ Обновление завершено."
        ;;
    *)
        echo "❌ Неизвестное действие. Используйте install или update." >&2
        exit 1
        ;;
esac