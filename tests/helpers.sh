#!/usr/bin/env bash

assert() {
    local TEST_RESULT=$?
    local TEST_NAME="${1?You must specify the test name as the first argument}"

    if [[ $TEST_RESULT -eq 0 ]]; then
        echo "  ✅  $TEST_NAME"
    else
        echo "  ❌  $TEST_NAME"
        exit 1
    fi
}

assert_file_exists() {
    local FILE_PATH="${1?You must specify the file path as the first argument}"
    local TEST_NAME="${2?You must specify the test name as the second argument}"

    if [[ -f "$FILE_PATH" ]]; then
        echo "  ✅  $TEST_NAME"
    else
        echo "  ❌  $TEST_NAME"
        echo "    File does not exist: $FILE_PATH"
        exit 1
    fi
}

assert_eq() {
    local ACTUAL_OUTPUT="${1?You must specify the actual output first argument}"
    local EXPECTED_OUTPUT="${2?You must specify the expected output as the second argument}"
    local TEST_NAME="${3?You must specify the test name as the third argument}"

    if [ "$ACTUAL_OUTPUT" = "$EXPECTED_OUTPUT" ]; then
        echo "  ✅  $TEST_NAME"
    else
        echo "  ❌  $TEST_NAME"
        echo "    Expected: $EXPECTED_OUTPUT"
        echo "    Actual:   $ACTUAL_OUTPUT"
        echo ""
        exit 1
    fi
}

assert_contains() {
    local ACTUAL_OUTPUT="${1?You must specify the actual output first argument}"
    local EXPECTED_OUTPUT="${2?You must specify the expected output as the second argument}"
    local TEST_NAME="${3?You must specify the test name as the third argument}"


    if (echo "$ACTUAL_OUTPUT" | grep -qe "$EXPECTED_OUTPUT"); then
        echo "  ✅  $TEST_NAME"
    else
        echo "  ❌  $TEST_NAME"
        echo "    Should Contain: $EXPECTED_OUTPUT"
        echo "    Actual:         $ACTUAL_OUTPUT"
        echo ""
        exit 1
    fi
}

assert_not_contains() {
    local ACTUAL_OUTPUT="${1?You must specify the actual output first argument}"
    local EXPECTED_OUTPUT="${2?You must specify the expected output as the second argument}"
    local TEST_NAME="${3?You must specify the test name as the third argument}"

    if (echo "$ACTUAL_OUTPUT" | grep -qe "$EXPECTED_OUTPUT"); then
        echo "  ❌  $TEST_NAME"
        echo "    Should Not Contain: $EXPECTED_OUTPUT"
        echo "    Actual:             $ACTUAL_OUTPUT"
        echo ""
        exit 1
    else
        echo "  ✅  $TEST_NAME"
    fi
}

mock() {
    local MOCK_PATH="${1?You must specify the path to the mock file as the first argument}"
    local OUTPUT="${2-mocked output}"
    local EXIT_CODE="${3-0}"

    tee "$MOCK_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
echo "\${@}" >> "${MOCK_PATH}.args"

if [ -n "$OUTPUT" ]; then
    echo "$OUTPUT"
fi

exit $EXIT_CODE
EOF

    chmod +x "$MOCK_PATH"
}

reset_mock() {
    local MOCK_PATH="${1?You must specify the path to the mock file as the first argument}"

    rm -f "${MOCK_PATH}.args"
}