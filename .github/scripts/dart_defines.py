"""Writes dart_defines.json for `flutter build --dart-define-from-file`.

The values come from repository secrets passed as environment variables;
missing secrets leave them empty, and the app then asks for its own.
"""
import json
import os

KEYS = ["DANDANPLAY_APP_ID", "DANDANPLAY_APP_SECRET"]

with open("dart_defines.json", "w", encoding="utf-8") as f:
    json.dump({key: os.environ.get(key, "") for key in KEYS}, f)
