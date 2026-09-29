#!/bin/sh
# Emits two JSON lines and echoes an environment variable so tests can see what reached it.
echo '{"timestamp": "2026-09-29T10:00:00Z", "message": "door opened", "id": "e1"}'
echo "{\"timestamp\": \"2026-09-29T10:05:00Z\", \"message\": \"token=$AUDIT_TEST_TOKEN\", \"id\": \"e2\"}"
