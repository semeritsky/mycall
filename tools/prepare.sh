#!/usr/bin/env bash
# Достраивает Flutter-проект вокруг наших исходников.
#
# В репозитории лежит только то, что написано руками: lib/, pubspec.yaml и
# AndroidManifest.xml. Всё остальное (android/, gradle, иконки) генерирует
# flutter create — так проект не тащит за собой сотню служебных файлов и не
# ломается при обновлении Flutter.
set -euo pipefail

cd "$(dirname "$0")/../app"
ORG=${APP_ORG:-com.mycall}

STASH=$(mktemp -d)
cp -r lib "$STASH/lib"
cp pubspec.yaml "$STASH/pubspec.yaml"
cp android/app/src/main/AndroidManifest.xml "$STASH/AndroidManifest.xml"

flutter create --platforms=android --org "$ORG" --project-name mycall .

# flutter create мог перезаписать наши файлы — возвращаем их на место
rm -rf lib
cp -r "$STASH/lib" lib
cp "$STASH/pubspec.yaml" pubspec.yaml
cp "$STASH/AndroidManifest.xml" android/app/src/main/AndroidManifest.xml
rm -rf "$STASH"

# flutter_webrtc требует minSdk 24, шаблон Flutter ставит меньше
for f in android/app/build.gradle android/app/build.gradle.kts; do
  [[ -f "$f" ]] || continue
  sed -i 's/minSdkVersion *flutter\.minSdkVersion/minSdk = 24/' "$f"
  sed -i 's/minSdk *= *flutter\.minSdkVersion/minSdk = 24/' "$f"
done

# Ограничиваем аппетит Gradle — иначе сборка на VPS с 2 ГБ падает по памяти
if ! grep -q "org.gradle.jvmargs" android/gradle.properties 2>/dev/null; then
  echo "org.gradle.jvmargs=-Xmx1536m" >> android/gradle.properties
fi

# Страховка от плагинов, которые собираются против устаревшего Android SDK.
# Симптом: checkReleaseAarMetadata падает со списком androidx-библиотек,
# «requires ... compile against version 34 or later». Свой compileSdk плагин
# задаёт сам, поэтому поднимаем его снаружи для всех подпроектов.
if [[ -f android/build.gradle.kts ]] && ! grep -q "MyCall compileSdk" android/build.gradle.kts; then
  cat >> android/build.gradle.kts <<'GRADLE'

// MyCall compileSdk override — добавлено tools/prepare.sh
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            runCatching {
                ext.javaClass
                    .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(ext, 35)
            }
        }
    }
}
GRADLE
elif [[ -f android/build.gradle ]] && ! grep -q "MyCall compileSdk" android/build.gradle; then
  cat >> android/build.gradle <<'GRADLE'

// MyCall compileSdk override — добавлено tools/prepare.sh
subprojects {
    afterEvaluate { p ->
        if (p.hasProperty("android")) {
            p.android.compileSdkVersion 35
        }
    }
}
GRADLE
fi

flutter pub get
echo "Проект готов к сборке: flutter build apk --release"
