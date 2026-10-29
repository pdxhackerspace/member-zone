#!/usr/bin/env python3
import json
import os

print(json.dumps({"timestamp": "2026-09-29T11:00:00Z", "message": "python says hello", "id": "p1"}))
print(json.dumps({"ts": 1790679900, "msg": "epoch stamped", "extra": os.environ.get("AUDIT_LOG_SOURCE")}))
