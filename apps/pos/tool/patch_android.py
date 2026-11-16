"""Adjust the Android files that `flutter create` generates in CI.

Run from apps/pos after `flutter create`:  python3 tool/patch_android.py
"""
import re
from pathlib import Path

manifest = Path("android/app/src/main/AndroidManifest.xml")
xml = manifest.read_text()

xml = xml.replace('android:label="kwikerp_pos"', 'android:label="KwikERP POS"')

permissions = [
    '<uses-permission android:name="android.permission.INTERNET"/>',
    # Bluetooth receipt printer. Android 12+ needs BLUETOOTH_CONNECT only (paired devices, no scanning).
    '<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>',
    '<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>',
    '<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>',
]
missing = [p for p in permissions if re.search(r'android:name="[^"]+"', p).group(0) not in xml]
if missing:
    xml = xml.replace("<application", "\n    ".join(missing) + "\n    <application", 1)

# Lets the app open the update download in the browser (Android 11+ package visibility).
if 'android:scheme="https"' not in xml:
    xml = xml.replace("<application", (
        '<queries>\n'
        '        <intent>\n'
        '            <action android:name="android.intent.action.VIEW"/>\n'
        '            <data android:scheme="https"/>\n'
        '        </intent>\n'
        '    </queries>\n    <application'), 1)

manifest.write_text(xml)
print("AndroidManifest.xml patched:", ", ".join(re.findall(r'permission\.(\w+)', xml)))

# The release build runs Android lint over every plugin; its checker crashed on
# url_launcher_android (a lint bug, not ours). Lint is a build-time check only.
root_gradle = Path("android/build.gradle.kts")
if root_gradle.exists():
    g = root_gradle.read_text()
    marker = "// kwikerp: no lintVital"
    if marker not in g:
        g += (
            "\n" + marker + "\n"
            "subprojects {\n"
            "    tasks.matching { it.name.startsWith(\"lintVital\") }.configureEach { enabled = false }\n"
            "}\n"
        )
        root_gradle.write_text(g)
        print("build.gradle.kts: release lint check turned off")

