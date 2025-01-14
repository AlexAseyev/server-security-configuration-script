#!/bin/bash

# Проверяем, запущен ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт от имени root."
  exit 1
fi

echo ""

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

# Создаем нового пользователя
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

echo ""

# Копирование публичного ключа SSH в папку пользователя
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

# Проверка SSH соединения для нового пользователя
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

# Путь к файлу конфигурации SSH
SSH_CONFIG="/etc/ssh/sshd_config"

# Создаем резервную копию конфигурации SSH
backup_file "$SSH_CONFIG"

# Изменение порта SSH
sed -i "s/^#Port 22/Port $NEW_PORT/" $SSH_CONFIG
sed -i "s/^Port 22/Port $NEW_PORT/" $SSH_CONFIG

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

# Установка и настройка Fail2Ban
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

# Настройка iptables для защиты от DDoS
echo "Настройка iptables для защиты от DDoS-атак..."

# Очистка старых правил
iptables -F
iptables -X

# Базовые правила
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Разрешение SSH на новом порту
iptables -A INPUT -p tcp --dport $NEW_PORT -j ACCEPT

# Ограничение количества соединений для защиты от DDoS
iptables -A INPUT -p tcp --dport $NEW_PORT -m conntrack --ctstate NEW -m limit --limit 60/min --limit-burst 100 -j ACCEPT
iptables -A INPUT -p tcp --dport $NEW_PORT -m conntrack --ctstate NEW -j DROP

# Запрет всех остальных входящих соединений
iptables -A INPUT -j DROP

# Сохранение правил iptables
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

# Установка пакета для автоматической загрузки правил iptables после перезагрузки
apt-get install -y iptables-persistent

echo "Настройка iptables завершена. Порт $NEW_PORT добавлен в список разрешенных."

# Перезагрузка службы SSH
systemctl restart ssh

echo ""

echo ===========================================================
echo "1. Создан новый пользователь $username"
echo "2. Конфигурация SSH успешно изменена, порт изменен на $NEW_PORT. Используйте его при следующем подключении к серверу."
echo "3. Fail2Ban настроен для защиты от перебора паролей."
echo "4. Настроена защита от DDoS с помощью iptables. Порт $NEW_PORT добавлен в список разрешенных."
echo "   Настройка завершена, сервер теперь в безопасности!"
echo "   Чтобы изменения вступили в силу, нужно перезагрузить сервер командой «reboot»."
echo ===========================================================