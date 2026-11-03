#!/bin/sh
# Prints its arguments, an environment variable and the payload so tests can see what reached it.
echo "args: $*"
echo "token: $ANNOUNCER_TEST_TOKEN name: $ANNOUNCER_NAME"
cat
