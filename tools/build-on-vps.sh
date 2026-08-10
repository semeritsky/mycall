#!/usr/bin/env bash
# Ставит Flutter и Android SDK на этот же сервер и собирает APK.
#
# Нужно: Ubuntu, ~12 ГБ свободного диска, минимум 2 ГБ памяти.
# Первый запуск занимает 20–40 минут (в основном скачивание), повторные — 3–5 минут.
# Альтернатива без всего этого — сборка через GitHub Actions, см. DEPLOY.md.
set -euo pipefail

FLUTTER_DIR=$HOME/flutter
SDK_DIR=$HOME/android-sdk
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

echo "── Проверки"
FREE_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
if (( FREE_GB < 12 )); then
  echo "На диске всего ${FREE_GB} ГБ. Нужно хотя бы 12." >&2
  exit 1
fi

# Gradle без swap на 2 ГБ памяти падает по OOM
MEM_MB=$(( $(grep MemTotal /proc/meminfo | tr -dc '0-9') / 1024 ))
if (( MEM_MB < 3000 )) && ! swapon --show | grep -q .; then
  echo "── Памяти ${MEM_MB} МБ, добавляю 4 ГБ swap"
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "── Пакеты"
apt-get update -qq
apt-get install -y -qq git curl unzip xz-utils zip openjdk-17-jdk-headless

echo "── Flutter"
if [[ ! -d "$FLUTTER_DIR" ]]; then
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi
export PATH="$FLUTTER_DIR/bin:$PATH"
git config --global --add safe.directory "$FLUTTER_DIR"

echo "── Android SDK"
if [[ ! -d "$SDK_DIR/cmdline-tools/latest" ]]; then
  mkdir -p "$SDK_DIR/cmdline-tools"
  # Если ссылка отдаёт 404, возьмите свежую здесь:
  # https://developer.android.com/studio#command-line-tools-only
  curl -fsSL "$CMDLINE_TOOLS_URL" -o /tmp/cmdline-tools.zip
  unzip -q /tmp/cmdline-tools.zip -d "$SDK_DIR/cmdline-tools"
  mv "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  rm /tmp/cmdline-tools.zip
fi
export ANDROID_HOME="$SDK_DIR"
export PATH="$SDK_DIR/cmdline-tools/latest/bin:$PATH"

yes | sdkmanager --licenses >/dev/null
sdkmanager --install "platform-tools" "platforms;android-35" "build-tools;35.0.0" >/dev/null

flutter config --android-sdk "$SDK_DIR" --no-analytics >/dev/null
flutter doctor -v | grep -A3 -i android || true

echo "── Сборка"
bash "$(dirname "$0")/prepare.sh"
cd "$(dirname "$0")/../app"
flutter build apk --release

APK=$(pwd)/build/app/outputs/flutter-apk/app-release.apk
echo
echo "Готово: $APK"
echo "Размер: $(du -h "$APK" | cut -f1)"
echo
echo "Забрать на свой компьютер:"
echo "  scp root@\$(curl -fsS https://api.ipify.org):$APK ."
