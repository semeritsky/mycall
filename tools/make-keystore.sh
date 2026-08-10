#!/usr/bin/env bash
# Создаёт постоянный ключ подписи APK.
#
# Зачем: без него каждая сборка подписывается новым случайным ключом, и
# обновление не встанет поверх установленного приложения — придётся удалять
# и терять переписку. Ключ создаётся один раз и хранится вечно.
set -euo pipefail

if ! command -v keytool >/dev/null; then
  echo "keytool не найден. Установите Java: apt install -y openjdk-17-jre-headless" >&2
  exit 1
fi

OUT=${1:-debug.keystore}
mkdir -p "$(dirname "$OUT")"
if [[ -e "$OUT" ]]; then
  echo "$OUT уже существует — не перезатираю. Удалите вручную, если нужен новый ключ." >&2
  exit 1
fi

# Пароли фиксированы: это тот же формат, что у стандартного отладочного ключа
# Android, и Flutter подписывает им release-сборку без правки Gradle.
keytool -genkeypair -v \
  -keystore "$OUT" -storetype JKS \
  -storepass android -keypass android \
  -alias androiddebugkey \
  -keyalg RSA -keysize 2048 -validity 10950 \
  -dname "CN=MyCall, OU=MyCall, O=MyCall, C=RU"

base64 -w0 "$OUT" > "$OUT.base64"

echo
echo "Готово."
echo "  $OUT         — храните в надёжном месте, без него не выпустить обновление"
echo "  $OUT.base64  — содержимое положите в GitHub → Settings → Secrets →"
echo "                 Actions → New secret, имя DEBUG_KEYSTORE_BASE64"
