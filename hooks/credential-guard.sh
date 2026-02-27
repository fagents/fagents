#!/bin/bash

# credential-guard.sh — PreToolUse hook
# Blocks reads of files that likely contain credentials.
# Prevents credential leaks into Anthropic's logs.
#
# Trigger: PreToolUse (matcher: Read|Bash)
# Mechanism: exit 2 + stderr = block tool call (per Claude Code docs)

INPUT=$(cat)

TOOL_NAME=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" <<< "$INPUT" 2>/dev/null)

# Sensitive filename patterns (basename match)
SENSITIVE_NAMES='^\.(env|env\..+)$|^agents\.json$|^tokens\.json$|^\.mcp\.json$|^id_rsa|^id_ed25519$|^id_ecdsa$|\.pem$|\.key$'
# Sensitive path patterns (full path match)
SENSITIVE_PATHS='start-agent\.sh'

block() {
    echo "$1" >&2
    exit 2
}

if [[ "$TOOL_NAME" == "Read" ]]; then
    FILE_PATH=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" <<< "$INPUT" 2>/dev/null)
    BASENAME=$(basename "$FILE_PATH")

    if echo "$BASENAME" | grep -qEi "$SENSITIVE_NAMES"; then
        block "BLOCKED: $BASENAME likely contains credentials. Reading it leaks secrets into Anthropic's logs. Test the endpoint or check file existence instead."
    fi
    if echo "$FILE_PATH" | grep -qE "$SENSITIVE_PATHS"; then
        block "BLOCKED: $BASENAME likely contains credentials. Reading it leaks secrets into Anthropic's logs. Test the endpoint or check file existence instead."
    fi
fi

if [[ "$TOOL_NAME" == "Bash" ]]; then
    COMMAND=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" <<< "$INPUT" 2>/dev/null)

    # Block commands that read sensitive files
    if echo "$COMMAND" | grep -qEi "(cat|head|tail|less|more|bat|source|\.)\s+\S*(\.env|agents\.json|tokens\.json|\.mcp\.json|start-agent\.sh|id_rsa|id_ed25519|id_ecdsa|\.pem$|\.key)"; then
        block "BLOCKED: This command reads a file containing credentials. Reading credentials leaks them into Anthropic's logs. Test the endpoint or check file existence instead."
    fi
fi

exit 0
