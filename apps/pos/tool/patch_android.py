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

manifest.write_text(xml)
print("AndroidManifest.xml patched:", ", ".join(re.findall(r'permission\.(\w+)', xml)))
