#!/bin/bash

# Проверяем, запущен ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт от имени root."
  exit 1
fi

# Функция для создания резервных копий
backup_file() {
  local file=$1
  if [[ -f "$file" ]]; then
    cp "$file" "${file}.bak"
    echo "Резервная копия создана: ${file}.bak"
  else
    echo "Файл $file не существует, резервная копия не создана."
  fi
}

# Функция для создания нового пользователя
create_user() {
  read -p "Введите имя нового пользователя: " username

  # Проверка, существует ли пользователь
  if id "$username" &>/dev/null; then
    echo "Пользователь $username уже существует!"
    # Выдаем новому пользователю права sudo
    if usermod -aG sudo "$username"; then
      echo "Пользователю $username успешно выданы права sudo."
    else
      echo "Ошибка при назначении прав sudo пользователю $username."
      exit 1
    fi
  else
    # Создаем нового пользователя
    if adduser "$username"; then
      echo "Пользователь $username успешно создан."
      # Выдаем новому пользователю права sudo
      if usermod -aG sudo "$username"; then
        echo "Пользователю $username успешно выданы права sudo."
      else
        echo "Ошибка при назначении прав sudo пользователю $username."
        exit 1
      fi
    else
      echo "Ошибка при создании пользователя $username."
      exit 1
    fi
  fi
}

# Функция для настройки SSH-ключа
setup_ssh_key() {
  # Путь к вашему публичному SSH-ключу
  KEY_PATH="/root/.ssh/authorized_keys"

  # Путь к папке назначения (например, в .ssh)
  USER_KEY_PATH="/home/$username/.ssh/"
  # Создаем папку ssh
  mkdir -p "$USER_KEY_PATH"
  chmod 700 "$USER_KEY_PATH"
  chown $username:$username "$USER_KEY_PATH"

  # Проверка, существует ли публичный ключ
  if [[ ! -f "$KEY_PATH" ]]; then
    echo "Публичный SSH ключ не найден: $KEY_PATH"
    # Добавление ключа вручную 
    echo "Вставьте свой публичный SSH ключ, нажмите Ctrl + X, затем Y и Enter для сохранения."
    read -p "Нажмите Enter для редактирования файла SSH ключа..."
    nano "$USER_KEY_PATH"/authorized_keys
    chmod 600 "$USER_KEY_PATH"/authorized_keys
    chown $username:$username "$USER_KEY_PATH"/authorized_keys
    echo "Публичный SSH ключ успешно добавлен в: $USER_KEY_PATH"
  else
    # Проверка, существует ли публичный ключ в папке пользователя
    if [[ ! -f "$USER_KEY_PATH"/authorized_keys ]]; then
      # Копируем публичный ключ в папку назначения
      if cp -f "$KEY_PATH" "$USER_KEY_PATH"; then
        chmod 600 "$USER_KEY_PATH"/authorized_keys
        chown $username:$username "$USER_KEY_PATH"/authorized_keys
        echo "Публичный SSH ключ успешно скопирован в: $USER_KEY_PATH"
      else
        echo "Ошибка при копировании публичного SSH ключа."
        exit 1
      fi
    else
      echo ""
      read -p "Публичный ключ в папке $USER_KEY_PATH уже существует, заменить его ? (y/n): " answer
      if [[ "$answer" == "y" ]]; then
        # Копируем публичный ключ в папку назначения
        if cp -f "$KEY_PATH" "$USER_KEY_PATH"; then
          chmod 600 "$USER_KEY_PATH"/authorized_keys
          chown $username:$username "$USER_KEY_PATH"/authorized_keys
          echo "Публичный SSH ключ успешно скопирован в: $USER_KEY_PATH"
        else
          echo "Ошибка при копировании публичного SSH ключа."
          exit 1
        fi
      fi
    fi
  fi
}

# Функция для настройки SSH
configure_ssh() {
  echo ""
  echo "Перед тем как продолжить, попробуйте подключиться к серверу под пользователем $username"
  echo ""
  read -p "Получилось ли у вас подключиться по SSH от имени пользователя $username ? (y/n): " answer
  if [[ "$answer" != "y" ]]; then
    echo "Подключение по SSH не удалось. Проверьте настройки и повторите попытку."
    exit 1
  fi

  # Редактируем файлы конфигурации ssh
  # Запрос порта у пользователя
  echo ""
  read -p "Введите желаемый порт SSH (по умолчанию 2222): " NEW_PORT
  NEW_PORT=${NEW_PORT:-2222}  # Используем 2222, если пользователь не ввел ничего

  # Проверка, что порт является числом и находится в допустимом диапазоне
  if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo "Ошибка: порт должен быть числом от 1 до 65535."
    exit 1
  fi

  # Изменение порта SSH в конфигурации
  sed -i "s/^#Port 22/Port $NEW_PORT/" /etc/ssh/sshd_config
  sed -i "s/^Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config

  # Запрет авторизации для root
  sed -i "s/^#PermitRootLogin yes/PermitRootLogin no/" $SSH_CONFIG
  sed -i "s/^PermitRootLogin yes/PermitRootLogin no/" $SSH_CONFIG

  # Запрет авторизации по паролю
  sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication no/" $SSH_CONFIG
  sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/" $SSH_CONFIG
  sed -i "s/^#PermitEmptyPasswords no/PermitEmptyPasswords no/" $SSH_CONFIG

  # Разрешение авторизации по публичному ключу
  sed -i "s/^#PubkeyAuthentication yes/PubkeyAuthentication yes/" $SSH_CONFIG

  echo "Защита SSH-соединения настроена. Порт изменен на $NEW_PORT, вход root-пользователю и вход по паролю запрещены."
}

# Функция для установки и настройки Fail2Ban
setup_fail2ban() {
  echo "Установка Fail2Ban для защиты от перебора паролей..."
  apt-get update
  apt-get install -y fail2ban

  # Настройка Fail2Ban для SSH
  cat <<EOL > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $NEW_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
ignoreip = 127.0.0.1/8
EOL

  # Перезапуск Fail2Ban
  systemctl restart fail2ban
  systemctl enable fail2ban

  echo "Fail2Ban настроен для защиты SSH. После 3 неудачных попыток входа IP будет заблокирован на 1 час."
}

# Функция для настройки iptables
configure_iptables() {
  echo "Настройка iptables для защиты от DDoS-атак..."

  # Очистка старых правил
  iptables -F
  iptables -X

  # Базовые правила для входящих соединений
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Разрешение SSH на новом порту
  iptables -A INPUT -p tcp --dport $NEW_PORT -j ACCEPT

  # Ограничение количества новых соединений для защиты от DDoS
  iptables -A INPUT -p tcp --dport $NEW_PORT -m conntrack --ctstate NEW -m limit --limit 60/min --limit-burst 100 -j ACCEPT
  iptables -A INPUT -p tcp --dport $NEW_PORT -m conntrack --ctstate NEW -j DROP

  # Запрос пользователя: блокировать ли все входящие соединения?
  echo ""
  read -p "Заблокировать все входящие соединения, кроме SSH? (y/n): " BLOCK_ALL_INPUT
  if [[ "$BLOCK_ALL_INPUT" == "y" ]]; then
    iptables -A INPUT -j DROP
    echo "Все входящие соединения, кроме SSH, заблокированы."
  else
    echo "Входящие соединения не заблокированы."
  fi

  # Сохранение правил iptables
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4

  # Установка пакета для автоматической загрузки правил iptables после перезагрузки
  apt-get install -y iptables-persistent

  echo "Настройка iptables завершена. Порт $NEW_PORT добавлен в список разрешенных."
}

# Функция для вывода итогового отчета
show_summary() {
  echo ""
  echo ===========================================================
  echo "1. Создан новый пользователь $username"
  echo "2. Конфигурация SSH успешно изменена, порт изменен на $NEW_PORT. Используйте его при следующем подключении к серверу."
  echo "3. Fail2Ban настроен для защиты от перебора паролей."
  echo "4. Настроена защита от DDoS с помощью iptables. Порт $NEW_PORT добавлен в список разрешенных."
  echo "   Настройка завершена, сервер теперь в безопасности!"
  echo "   Чтобы изменения вступили в силу, нужно перезагрузить сервер командой «reboot»."
  echo ===========================================================
}

# Основной код скрипта
create_user
setup_ssh_key
configure_ssh
setup_fail2ban
configure_iptables
show_summary

# Перезагрузка службы SSH
systemctl restart ssh