#!/usr/bin/env python3
"""Materialize IOS_APP under RUNNER_TEMP without printing credential values."""

import base64
import json
import os
import re
from pathlib import Path


def json_object(value: str):
    try:
        parsed = json.loads(value)
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        return None


def mappings(value, depth=0):
    if depth > 4 or not isinstance(value, dict):
        return
    yield value
    for nested in value.values():
        if isinstance(nested, dict):
            yield from mappings(nested, depth + 1)
        elif isinstance(nested, str):
            parsed = json_object(nested)
            if parsed:
                yield from mappings(parsed, depth + 1)


def normalize(mapping):
    result = {}
    for name, value in mapping.items():
        if not isinstance(name, str):
            continue
        if isinstance(value, dict):
            value = next((value.get(key) for key in ("value", "content", "secret", "id") if isinstance(value.get(key), str)), None)
        elif isinstance(value, list) and all(isinstance(item, str) for item in value):
            value = "\n".join(value)
        if isinstance(value, str) and value.strip():
            result[re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")] = value.strip()
    return result


def main():
    raw = os.environ.get("IOS_APP_CREDENTIAL", "").strip()
    if not raw:
        raise SystemExit("Missing GitHub Environment secret IOS_APP")

    candidates = [raw]
    try:
        candidates.append(base64.b64decode(raw, validate=True).decode("utf-8"))
    except Exception:
        pass

    document = next((parsed for candidate in candidates if (parsed := json_object(candidate))), None)
    if document is None:
        dotenv = {}
        for line in raw.splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.split("=", 1)
                dotenv[name.strip()] = value.strip().strip('"').strip("'")
        document = dotenv or None
    begin_marker = "-----BEGIN " + "PRIVATE KEY-----"
    end_marker = "-----END " + "PRIVATE KEY-----"
    if document is None and begin_marker in raw:
        pem = re.search(re.escape(begin_marker) + r".*?" + re.escape(end_marker), raw, re.DOTALL)
        key_id = re.search(r"(?i)(?:key[_ -]?id)\s*[:=]\s*[\"']?((?:AuthKey_)?[A-Za-z0-9._-]+)", raw)
        issuer = re.search(r"(?i)(?:issuer[_ -]?id)\s*[:=]\s*[\"']?([0-9a-f-]{36})", raw)
        document = {
            "key_id": key_id.group(1) if key_id else "",
            "issuer_id": issuer.group(1) if issuer else "",
            "private_key": pem.group(0) if pem else "",
        }
    if document is None:
        raise SystemExit("IOS_APP is not a supported JSON, base64 JSON, dotenv, or annotated p8 format")

    aliases = {
        "key": ("key_id", "keyid", "app_store_connect_key_id", "appstoreconnectkeyid"),
        "issuer": ("issuer_id", "issuerid", "app_store_connect_issuer_id", "appstoreconnectissuerid"),
        "private": ("private_key", "privatekey", "private_key_p8", "p8", "key", "app_store_connect_private_key"),
    }
    extracted = []
    for mapping in mappings(document):
        values = normalize(mapping)
        extracted.append(tuple(next((values[name] for name in names if name in values), None) for names in aliases.values()))
    key_id, issuer_id, private_key = max(extracted, key=lambda item: sum(value is not None for value in item))
    missing = [label for label, value in (("Key ID", key_id), ("Issuer ID", issuer_id), ("private p8", private_key)) if not value]
    if missing:
        raise SystemExit("IOS_APP missing component(s): " + ", ".join(missing))

    private_key = private_key.replace("\\n", "\n")
    if begin_marker not in private_key:
        try:
            private_key = base64.b64decode(private_key, validate=True).decode("utf-8")
        except Exception:
            pass
    filename = re.fullmatch(r"AuthKey_(.+)\.p8", key_id, re.IGNORECASE)
    key_id = filename.group(1) if filename else key_id
    if not re.fullmatch(r"[!-~]{1,128}", key_id):
        raise SystemExit("IOS_APP Key ID format is invalid")
    if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", issuer_id):
        raise SystemExit("IOS_APP Issuer ID format is invalid")
    if begin_marker not in private_key or end_marker not in private_key:
        raise SystemExit("IOS_APP private p8 format is invalid")

    target = Path(os.environ["IOS_CREDENTIAL_DIR"])
    target.mkdir(parents=True, exist_ok=True)
    for name, value in (("AuthKey.p8", private_key.rstrip() + "\n"), ("key-id", key_id), ("issuer-id", issuer_id)):
        path = target / name
        path.write_text(value, encoding="utf-8")
        path.chmod(0o600)
    print("IOS_APP_STRUCTURE=PASS")


if __name__ == "__main__":
    main()
