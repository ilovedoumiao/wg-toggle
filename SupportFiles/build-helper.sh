#!/bin/sh

set -eu

PROJECT_ROOT="${PROJECT_DIR}"
HELPER_SOURCE="${PROJECT_ROOT}/HelperSources/WGToggleHelper/main.swift"
SHARED_SOURCE="${PROJECT_ROOT}/wg-toggle/HelperProtocol.swift"
PLIST_SOURCE="${PROJECT_ROOT}/SupportFiles/com.doumiao.wg-toggle.helper.plist"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
HELPER_OUTPUT_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/MacOS"
HELPER_OUTPUT="${HELPER_OUTPUT_DIR}/wg-toggle-helper"
DAEMON_OUTPUT_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchDaemons"
TEMP_HELPER_DIR="${TARGET_TEMP_DIR}/wg-toggle-helper"

mkdir -p "${HELPER_OUTPUT_DIR}" "${DAEMON_OUTPUT_DIR}" "${TEMP_HELPER_DIR}"

ARCH_COUNT=0
for ARCH in ${ARCHS}; do
	ARCH_COUNT=$((ARCH_COUNT + 1))
	ARCH_BINARY="${TEMP_HELPER_DIR}/wg-toggle-helper-${ARCH}"
	xcrun swiftc \
		-sdk "${SDK_PATH}" \
		-target "${ARCH}-apple-macos${MACOSX_DEPLOYMENT_TARGET}" \
		"${SHARED_SOURCE}" \
		"${HELPER_SOURCE}" \
		-o "${ARCH_BINARY}"
done

if [ "${ARCH_COUNT}" -eq 1 ]; then
	cp "${TEMP_HELPER_DIR}/wg-toggle-helper-${ARCHS}" "${HELPER_OUTPUT}"
else
	INPUTS=""
	for ARCH in ${ARCHS}; do
		INPUTS="${INPUTS} ${TEMP_HELPER_DIR}/wg-toggle-helper-${ARCH}"
	done
	# shellcheck disable=SC2086
	xcrun lipo -create ${INPUTS} -output "${HELPER_OUTPUT}"
fi

chmod 755 "${HELPER_OUTPUT}"
cp "${PLIST_SOURCE}" "${DAEMON_OUTPUT_DIR}/com.doumiao.wg-toggle.helper.plist"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
	/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${HELPER_OUTPUT}"
fi
