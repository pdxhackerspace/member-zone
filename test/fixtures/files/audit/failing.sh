#!/bin/sh
echo '{"message": "got this far", "id": "f1", "timestamp": "2026-09-29T09:00:00Z"}'
echo "something broke" >&2
exit 3
