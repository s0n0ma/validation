#!/bin/bash

# Три директивы оболочки bash
# -e / errexit выход из скрипта при первой же ошибке команды
# -u / nounset ошибка при обращении к незаданной переменной
# -o / pipefail пайп `cmd1 | cmd2` считается ошибочным, если упала **любая** его часть, а не только последняя
set -euo pipefail

# _debug станет 0, если не задана
: "${_debug:=0}"
# 0 для РЕЛИЗА (по умолчанию), но можно переопределить: _debug=1 ./mem-validation.sh
export _debug

# <<<<< Функционал управления таймаутом sudo

# Полный путь к временному файлу с настройками sudo
# Соответствует имени запускаемого скрипта без расширения,
# как это принято в системных конфигурациях
# (SUDO TeMPorary TimeOut FILE)
sudo_tmp_to_file="/etc/sudoers.d/$(basename "$0" | sed 's/\.[^.]*$//')"

# Функция проверки текущего таймаута sudo
_sudo_check_timeout() {
  if (( _debug )); then
    echo
    echo "Текущие настройки sudo (значение параметра 'timestamp_timeout'):"
    sudo grep -r "timestamp_timeout" /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo "Явным образом не задан (по умолчанию он равен 15 мин)."
  fi
}

# Функция установки времени действия sudo (в минутах)
# Передача значения "-1" отключает повторный запрос пароля
#  до конца сессии или до перезагрузки
# Пример вызова функции: _sudo_set_timeout "-1"
_sudo_set_timeout() {
  local new_to=$1
  (( _debug )) && { echo; echo "Устанавливаем timestamp_timeout=${new_to}..."; }

  # Записываем новое значение и выставляем безопасные права (440)
  echo "Defaults timestamp_timeout=${new_to}" | sudo tee "${sudo_tmp_to_file}" > /dev/null
  sudo chmod 440 "${sudo_tmp_to_file}"

  # Проверяем синтаксис, чтобы не сломать систему sudo
  if sudo visudo -c > /dev/null 2>&1; then
    (( _debug )) && echo "✓ Значение timestamp_timeout успешно установлено."
  else
    echo "✗ ОШИБКА: Проблема с синтаксисом sudoers. Отмена изменений."
    sudo rm -f "${sudo_tmp_to_file}"
    exit 1
  fi

  # Показываем результат
  _sudo_check_timeout
}

# Функция восстановления стандартного времени действия sudo
# (удаляет созданный временный файл)
_sudo_restore_timeout() {
  if [[ -f "${sudo_tmp_to_file}" ]]; then
    (( _debug )) && echo "Восстанавливаем стандартные настройки sudo (удаляем временный файл)..."
    sudo rm -f "${sudo_tmp_to_file}"
    (( _debug )) && echo "✓ Done"
    _sudo_check_timeout
  fi
  # Если файла нет, выходим молча (не засоряем вывод при повторном вызове через trap)
}

# Проверяем текущее состояние и отключаем таймаут (значение -1)
_sudo_check_timeout
_sudo_set_timeout "-1"

# ГАРАНТИЯ ВОССТАНОВЛЕНИЯ: Добавляем ловушку (trap),
# чтобы настройки sudo восстановились даже если скрипт завершится по ошибке (Ctrl+C, exit 1 и т.д.)
trap _sudo_restore_timeout EXIT

# <<<<< Формируем дату
# %Y   year
# %m   month (01..12)
# day of month (e.g., 01)
_date=$(date +%Y%m%d)

### <<<<< Собираем данные о памяти через dmidecode
# ВАЖНО: dmidecode запускаем один раз и сохраняем вывод в переменную,
# чтобы обойтись одним запросом и после вынимать из него необходимое
# Obsidian -> code_0001
_dmi="$(sudo dmidecode --type 17 2>/dev/null || true)"

# <<<<< Объём установленной памяти
# Obsidian -> code_0002
_volume="$(awk -F': *' '
    /^Memory Device$/  { in_dev=1; next }
    /^$/               { in_dev=0 }
    in_dev && $1 ~ /^[[:space:]]+Size$/ {
        v=$2; split(v, a, " ")
        n=a[1]; u=a[2]
        if (n ~ /^[0-9]+$/) {
            if (u=="GB") mb=n*1024
            else if (u=="MB") mb=n
            else if (u=="TB") mb=n*1024*1024
            else if (u=="KB") mb=n/1024
            else next
            total+=mb
        }
    }
    END { printf "%.0fGB\n", total/1024 }' <<< "$_dmi")"

# <<<<< Тип памяти: DDR4/DDR5/...
_ddrX="$(awk '/^[[:space:]]+Type: / { print $2; exit }' <<< "$_dmi")"

# <<<<< Форм-фактор памяти: DIMM (UDIMM) / SODIMM
# <<<<< Ищем форм-фактор первого установленного модуля,
# где Size не "No Module Installed" и не 0, и забираем
# его Form Factor (будь то DIMM, SODIMM, Unknown или кастомное значение)
# Obsidian -> code_0002
_ff="$(awk '
/^Memory Device$/ {
    # Если в прошлом блоке память была и мы еще не сохранили результат
    if (populated && !found) {
        found = 1
        res = ff
    }
    # Сбрасываем состояние для нового блока
    populated = 0
    ff = ""
    next
}
/^[[:space:]]+Size:/ {
    sz = $0
    sub(/^[[:space:]]+Size:[[:space:]]*/, "", sz)
    sub(/[[:space:]]+$/, "", sz)
    # Слот считается занятым, если там не "No Module Installed", не пусто и не начинается с 0
    if (sz != "No Module Installed" && sz != "" && sz !~ /^0/) {
        populated = 1
    }
}
/^[[:space:]]+Form Factor:/ {
    ff = $0
    sub(/^[[:space:]]+Form Factor:[[:space:]]*/, "", ff)
    sub(/[[:space:]]+$/, "", ff)
}
END {
    # Обработка случая, когда первый (и единственный) модуль находится в самом конце вывода
    if (populated && !found) {
        res = ff
    }
    print res
}' <<< "$_dmi")"

# <<<<< Ранг модуля
_rank="$(awk '/^[[:space:]]+Rank: / { print $2; exit }' <<< "$_dmi")"

# <<<<< Скорость памяти по спецификации
_speed_by_spec="$(awk '/^[[:space:]]+Speed: / { print $2; exit }' <<< "$_dmi")"
# <<<<< Скорость памяти сконфигурированная
_speed_configured="$(awk '/^[[:space:]]+Configured Memory Speed: / { print $4; exit }' <<< "$_dmi")"

# <<<<< Производитель памяти
_vendor="$(awk '/^[[:space:]]+Manufacturer: / { print $2; exit }' <<< "$_dmi")"

# <<<<< Получаем абсолютный путь к директории, где физически находится скрипт
# readlink -f разрешает все симлинки, поэтому путь будет корректным
# независимо от того, как был запущен скрипт и на каком он диске.
_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
(( _debug )) && { echo; echo "Директория скрипта: $_script_dir"; }

# <<<<< Проверяем, что все значения найдены
# Иначе получим папку вида "data-20261109---" — что есть бесполезно
missing=()
[[ -z "$_date" ]] && missing+=("Date")
[[ -z "$_volume" ]] && missing+=("Volume")
[[ -z "$_ddrX" ]] && missing+=("DDRX")
[[ -z "$_ff" ]] && missing+=("Form Factor")
[[ -z "$_rank" ]] && missing+=("Rank")
[[ -z "$_speed_by_spec" ]] && missing+=("Speed by Specification")
[[ -z "$_speed_configured" ]] && missing+=("Configured Speed")
[[ -z "$_vendor" ]] && missing+=("Vendor")

if (( ${#missing[@]} > 0 )); then
    echo "Ошибка: не удалось получить из dmidecode: ${missing[*]}" >&2
    echo "Проверьте, что модули памяти установлены и dmidecode работает:" >&2
    echo "    sudo dmidecode --type 17" >&2
    exit 1
fi

# <<<<< Санитизация значений для имени папки
# В Manufacturer может встретиться пробел (например, "SK Hynix"),
# а также слэш или другие символы, недопустимые в имени файла.
# Заменяем всё, что не буква/цифра/точка/дефис/подчёркивание, на "_".
sanitize() {
    local s="$1"
    s="${s//[[:space:]]/_}"          # пробелы -> _
    s="${s//[^A-Za-z0-9._-]/_}"      # остальные небезопасные -> _
    s="${s##_}"                      # убрать ведущие _
    s="${s%%_}"                      # убрать хвостовые _
    printf '%s' "$s"
}

_date="$(sanitize "$_date")"
_volume="$(sanitize "$_volume")"
_ddrX="$(sanitize "$_ddrX")"
_ff="$(sanitize "$_ff")"
_rank="$(sanitize "$_rank")"
_speed_by_spec="$(sanitize "$_speed_by_spec")"
_speed_configured="$(sanitize "$_speed_configured")"
_vendor="$(sanitize "$_vendor")"

# <<<<< Формируем имя папки, для сохранения результатов
_folder_name="${_date}-${_volume}-${_ddrX}-${_ff}-R${_rank}-${_speed_by_spec}_${_speed_configured}-${_vendor}"
# Формируем ПОЛНЫЙ путь: директория скрипта + имя папки
_target_dir="${_script_dir}/${_folder_name}"

#(( _debug )) && { echo; echo "${_folder_name}"; }
#(( _debug )) && { echo "${_target_dir}"; echo; }

# <<<<< Создаём папку
# Ключ -p (parents) делает команду идемпотентной: 
# она не выдаст ошибку, если папка уже существует, и создаст всю цепочку, если нет.
if mkdir -p "${_target_dir}"; then
    (( _debug )) && { echo; echo "✓ Папка для результатов успешно создана:"; }
    (( _debug )) && { echo "  ${_target_dir}"; }
else
    echo "✗ ОШИБКА: Не удалось создать папку '${_target_dir}'. Проверьте права доступа или место на диске." >&2
    exit 1
fi

# <<<<< Установка необходимых пакетов
install_pkg() {
    local pkg="$1"
    (( _debug )) && printf "\n### Установка пакета <%s>\n" "$pkg"
    sudo apt install -y "$pkg" || { echo "✗ ОШИБКА УСТАНОВКИ: $pkg" >&2; exit 1; }
}

echo
sudo apt update || { echo "✗ ОШИБКА ВЫПОЛНЕНИЕ: 'sudo apt update'"; exit 1; }
install_pkg i2c-tools
install_pkg stressapptest
printf "\n"

exit 0
