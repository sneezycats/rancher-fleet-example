#!/usr/bin/env python3
"""Look up a Rancher cloud-credential secret by its UI name.

Usage:
  kubectl -n cattle-global-data get secrets -o json | python3 cc-lookup.py [NAME]

Rancher materializes each cloud credential as an opaque Secret in the
management cluster's cattle-global-data namespace, named cc-<id>. The
friendly name shown in the Rancher UI is stored in the secret's
field.cattle.io/name annotation — that is the stable join key.

With NAME: prints the secret name (cc-<id>) whose annotation matches.
Without: prints a table of all credential secrets (name -> UI name).
"""
import json
import sys

want = sys.argv[1] if len(sys.argv) > 1 else None
data = json.load(sys.stdin)
rows = []
for s in data.get("items", []):
    name = s["metadata"]["name"]
    if not name.startswith("cc-"):
        continue
    ann = s["metadata"].get("annotations", {})
    ui = ann.get("field.cattle.io/name")
    rows.append((name, ui))
rows.sort()
if want:
    for name, ui in rows:
        if ui == want:
            print(name)
            sys.exit(0)
    print(f"no cloud credential named {want!r} (known: "
          f"{', '.join(u for _, u in rows)})", file=sys.stderr)
    sys.exit(1)
for name, ui in rows:
    print(f"{name}\t{ui}")