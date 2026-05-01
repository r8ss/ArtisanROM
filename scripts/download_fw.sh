#!/usr/bin/env bash
#
# Copyright (C) 2025 Salvo Giangreco
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#

# [
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1
source "$TOOLS_DIR/venv/bin/activate" || exit 1

FORCE=false

FIRMWARES=()
MODEL=""
CSC=""
IMEI=""
SERIAL_NO=""
LATEST_FIRMWARE=""
ZIP_FILE=""

PREPARE_SCRIPT()
{
    local EXTRA_FIRMWARES=()
    local IGNORE_SOURCE=false
    local IGNORE_TARGET=false

    while [ "$#" != 0 ]; do
        if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
            FORCE=true
        elif [[ "$1" == "--ignore-source" ]]; then
            IGNORE_SOURCE=true
        elif [[ "$1" == "--ignore-target" ]]; then
            IGNORE_TARGET=true
        elif [[ "$1" == "-"* ]]; then
            LOGE "Unknown option: $1"
            PRINT_USAGE
            exit 1
        else
            EXTRA_FIRMWARES+=("$1")
        fi

        shift
    done

    if ! $IGNORE_SOURCE; then
        _CHECK_NON_EMPTY_PARAM "SOURCE_FIRMWARE" "$SOURCE_FIRMWARE" || exit 1
        FIRMWARES+=("$SOURCE_FIRMWARE")
        IFS=':' read -r -a SOURCE_EXTRA_FIRMWARES <<< "$SOURCE_EXTRA_FIRMWARES"
        if [ "${#SOURCE_EXTRA_FIRMWARES[@]}" -ge 1 ]; then
            FIRMWARES+=("${SOURCE_EXTRA_FIRMWARES[@]}")
        fi
    fi

    if ! $IGNORE_TARGET; then
        _CHECK_NON_EMPTY_PARAM "TARGET_FIRMWARE" "$TARGET_FIRMWARE" || exit 1
        FIRMWARES+=("$TARGET_FIRMWARE")
        IFS=':' read -r -a TARGET_EXTRA_FIRMWARES <<< "$TARGET_EXTRA_FIRMWARES"
        if [ "${#TARGET_EXTRA_FIRMWARES[@]}" -ge 1 ]; then
            FIRMWARES+=("${TARGET_EXTRA_FIRMWARES[@]}")
        fi
    fi

    if [ "${#EXTRA_FIRMWARES[@]}" -ge 1 ]; then
        FIRMWARES+=("${EXTRA_FIRMWARES[@]}")
    fi
}

PRINT_USAGE()
{
    echo "Usage: download_fw [options] <firmware>" >&2
    echo " --ignore-source : Skip parsing source firmware flags" >&2
    echo " --ignore-target : Skip parsing target firmware flags" >&2
    echo " -f, --force : Force firmware download" >&2
}

VERIFY_ODIN_PACKAGES()
{
    local FILE_NAME
    local LENGTH
    local STORED_HASH
    local CALCULATED_HASH

    while IFS= read -r f; do
        FILE_NAME="$(basename "$f")"
        LOG_STEP_IN "- Verifying $FILE_NAME..."

        FILE_NAME="${FILE_NAME%.md5}"

        LENGTH="32" 
        LENGTH="$((LENGTH + 2))" 
        LENGTH="$((LENGTH + ${#FILE_NAME}))" 
        LENGTH="$((LENGTH + 1))" 

        STORED_HASH="$(tail -c "$LENGTH" "$f" | cut -d " " -f 1 -s)"
        if [ ! "$STORED_HASH" ] || [[ "${#STORED_HASH}" != "32" ]]; then
            LOG "\033[0;31m! Expected hash could not be parsed\033[0m"
            exit 1
        fi

        CALCULATED_HASH="$(head -c-$LENGTH "$f" | md5sum | cut -d " " -f 1 -s)"

        if [[ "$STORED_HASH" != "$CALCULATED_HASH" ]]; then
            LOG "\033[0;31m! File is damaged\033[0m"
            exit 1
        fi

        LOG_STEP_OUT
    done < <(find "$ODIN_DIR/${MODEL}_${CSC}" -type f -name "*.md5")
}
# ]

PREPARE_SCRIPT "$@"

for i in "${FIRMWARES[@]}"; do
    PARSE_FIRMWARE_STRING "$i" || exit 1

    LATEST_FIRMWARE="$(GET_LATEST_FIRMWARE "$MODEL" "$CSC")"
    if [ ! "$LATEST_FIRMWARE" ]; then
        LOGW "Latest available firmware could not be fetched"
    fi

    LOG_STEP_IN "- Processing $MODEL firmware with $CSC CSC"
    LOG "- Downloaded firmware: $(cat "$ODIN_DIR/${MODEL}_${CSC}/.downloaded" 2> /dev/null)"
    LOG "- Extracted firmware: $(cat "$FW_DIR/${MODEL}_${CSC}/.extracted" 2> /dev/null)"
    LOG "- Latest available firmware: $LATEST_FIRMWARE"

    LOG_STEP_IN

    if ! $FORCE; then
        if [ -f "$FW_DIR/${MODEL}_${CSC}/.extracted" ]; then
            if COMPARE_SEC_BUILD_VERSION "$(cat "$FW_DIR/${MODEL}_${CSC}/.extracted")" "$LATEST_FIRMWARE"; then
                LOG "\033[0;33m! This firmware has already been extracted, skipping\033[0m"
                LOG_STEP_OUT; LOG_STEP_OUT
                continue
            fi
        fi

        if [ -f "$ODIN_DIR/${MODEL}_${CSC}/.downloaded" ]; then
            if ! COMPARE_SEC_BUILD_VERSION "$(cat "$ODIN_DIR/${MODEL}_${CSC}/.downloaded")" "$LATEST_FIRMWARE"; then
                LOG "\033[0;33m! A newer firmware is available for download, use --force flag\033[0m"
            else
                LOG "\033[0;33m! This firmware has already been downloaded\033[0m"
            fi
            LOG_STEP_OUT; LOG_STEP_OUT
            continue
        fi
    fi

    LOG "- Downloading firmware..."
    [ -d "$ODIN_DIR/${MODEL}_${CSC}" ] && rm -rf "$ODIN_DIR/${MODEL}_${CSC}"
    mkdir -p "$ODIN_DIR/${MODEL}_${CSC}"

    COUNT=1
    while true; do
        (
        cd "$OUT_DIR"
        # Alteração: Removido hardcode da versão. Samloader detecta AZCH automaticamente.
        # Adicionado fallback: tenta com IMEI/Serial, se falhar tenta modo genérico.
        if ! samloader -m "$MODEL" -r "$CSC" -i "$IMEI" -s "$SERIAL_NO" download -O "$ODIN_DIR/${MODEL}_${CSC}"; then
            LOGW "Falha com identificador, tentando download genérico..."
            samloader -m "$MODEL" -r "$CSC" download -O "$ODIN_DIR/${MODEL}_${CSC}" || exit 1
        fi
        )

        ZIP_FILE="$(find "$ODIN_DIR/${MODEL}_${CSC}" -name "*.zip" | sort -r | head -n 1)"
        if [ ! "$ZIP_FILE" ] || [ ! -f "$ZIP_FILE" ]; then
            if [ $COUNT -gt 10 ]; then
                LOGW "\033[0;31m! Download failed, check your network or device info!\033[0m"
                exit 1
            fi

            LOGW "\033[0;31m! [Attempt: $COUNT] Download failed, retrying in 5 seconds...\033[0m"
            sleep 5
            ((COUNT++))
        else
            break
        fi
    done

    LOG "- Extracting $(basename "$ZIP_FILE")..."
    unzip -o "$ZIP_FILE" -d "$ODIN_DIR/${MODEL}_${CSC}" && rm -rf "$ZIP_FILE" || exit 1

    VERIFY_ODIN_PACKAGES

    echo -n "$LATEST_FIRMWARE" > "$ODIN_DIR/${MODEL}_${CSC}/.downloaded"

    LOG_STEP_OUT; LOG_STEP_OUT
done

deactivate

exit 0
