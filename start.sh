#!/bin/sh

echo "========================================="
echo "Starting application"
echo "========================================="
env | sort

if [ -z "$TZ" ]; then
    export TZ="Europe/Madrid"
fi

export JAR_PATH=$APP_DIR/$APP_NAME

exec java $JAVA_HEAP $JAVA_OPTS_EXT -jar "$JAR_PATH" $JAVA_PARAMETERS
