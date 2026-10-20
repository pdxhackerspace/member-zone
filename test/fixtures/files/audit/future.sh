#!/bin/sh
# One entry with a far-future timestamp and one with an epoch in milliseconds.
echo '{"message": "from the future", "id": "x1", "timestamp": "2099-01-01T00:00:00Z"}'
echo '{"message": "epoch in millis", "id": "x2", "ts": 4102444800000}'
