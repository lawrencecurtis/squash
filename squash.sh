#!/usr/bin/env bash
set -e

# Configuration
MODEL="gemma4:12b-mlx"
OLLAMA_URL="http://localhost:11434/api/generate"

# ==============================================================================
# PHASE 1: REWRITE MODE (Invoked by git rebase via the 'exec' command)
# ==============================================================================
if [ "$1" = "--rewrite" ]; then
    echo "Drafting new commit message..."
    DIFF=$(git show HEAD --stat -p)

    SYSTEM_PROMPT="You are an expert at writing Git commits.
Your job is to write a short clear commit message that summarizes the changes.
Only use the body when it is providing *useful* information.
Don't repeat information from the subject line in the message body.
Only return the commit message in your response.
Do not include any additional meta-commentary about the task.
Do not include the raw diff output in the commit message.

Follow good Git style:
- Separate the subject from the body with a blank line
- Try to limit the subject line to 50 characters
- Capitalize the subject line
- Do not end the subject line with any punctuation
- Use the imperative mood in the subject line
- Wrap the body at 72 characters
- Use emoji in the subject line
- Keep the body short and concise
- Include a markdown dashed list overview of the changes at the top of the body
- Do not repeat things from the markdown list in the body"

    # Optimization: 'think: false', capped output tokens, right-sized context window
    PAYLOAD=$(jq -n \
        --arg diff "/no_think $DIFF" \
        --arg system "$SYSTEM_PROMPT" \
        --arg model "$MODEL" \
        '{
            model: $model,
            system: $system,
            prompt: $diff,
            stream: false,
            think: false,
            options: {
                num_predict: 512,
                num_ctx: 16384,
                temperature: 0.2
            }
        }')

    RAW_RESPONSE=$(curl -s $OLLAMA_URL -d "$PAYLOAD" | jq -r '.response')

    # Cleaning: Remove potential <think> tags or markdown backticks
    NEW_MSG=$(echo "$RAW_RESPONSE" | sed -E 's/<think>.*<\/think>//g' | sed 's/^```.*//g' | sed 's/```$//g')

    if [ -n "$NEW_MSG" ]; then
        echo -e "\n=== 🤖 New Commit Generated ==="
        echo "$NEW_MSG"
        echo "==============================="
        git commit --amend -m "$NEW_MSG"
    else
        echo "Failed to generate commit message."
    fi
    exit 0
fi

# ==============================================================================
# PHASE 2: ORCHESTRATOR MODE (Finds base commit and builds rebase plan)
# ==============================================================================
SCRIPT_PATH=$(realpath "$0")
BASE_COMMIT=""
LOG_RANGE=""

# 1. Determine Base Commit based on arguments or TUI
if [ "$1" = "--wip" ] || [ "$1" = "auto" ]; then
    # Find the OLDEST commit starting with "wip" or "WIP"
    OLDEST_WIP=$(git log -i --grep="^wip" --format="%H" | tail -n 1)

    if [ -n "$OLDEST_WIP" ]; then
        if git rev-parse --verify "${OLDEST_WIP}~1" >/dev/null 2>&1; then
            BASE_COMMIT="${OLDEST_WIP}~1"
            LOG_RANGE="${BASE_COMMIT}..HEAD"
            echo "Auto-detected earliest WIP commit. Using parent $BASE_COMMIT as base."
        else
            BASE_COMMIT="--root"
            LOG_RANGE="HEAD"
            echo "Auto-detected earliest WIP commit as the repository root. Using --root."
        fi
    else
        echo "No 'WIP' commits found in history."
        exit 1
    fi
elif [ -n "$1" ]; then
    # User passed a specific commit hash (e.g., HEAD~5)
    BASE_COMMIT=$1
    LOG_RANGE="${BASE_COMMIT}..HEAD"
else
    # TUI Selection via fzf
    if ! command -v fzf &>/dev/null; then
        echo "Error: 'fzf' is not installed. Install it, or pass a base commit manually."
        exit 1
    fi
    echo "Select the base commit (the commit BEFORE your changes):"
    BASE_COMMIT=$(git log --color=always --format="%C(auto)%h%d %s %C(black)%C(bold)%cr" |
        fzf --ansi --prompt="Select Base Commit> " |
        awk '{print $1}')

    if [ -z "$BASE_COMMIT" ]; then
        echo "Aborted."
        exit 0
    fi
    LOG_RANGE="${BASE_COMMIT}..HEAD"
fi

# 2. Gather History and Generate Rebase Plan
echo "Gathering commit history..."
HISTORY=$(git log --reverse --format="Commit: \%h\%nMessage: \%s" --name-status $LOG_RANGE)

SYSTEM_PROMPT="You are a git rebase automation tool. Your job is to group related commits together based on the files they modify or their features.
I will provide a chronological list of commits and the files they touch.
You must output a git interactive rebase todo list.

Rules:
1. Group related commits together (e.g., commits touching the same files or features).
2. For each group, 'pick' the first commit, and 'squash' the rest in that group.
3. Order the groups logically.
4. Immediately after the last 'squash' (or 'pick' if it's a standalone commit) of EACH group, add this exact line:
   exec $SCRIPT_PATH --rewrite
5. Output ONLY the valid git rebase commands. No explanations, no markdown blocks.
6. CRITICAL: You must use the EXACT commit hashes provided in the input. Do not alter, misspell, or truncate the hashes.

EXAMPLE OUTPUT FORMAT:
pick 1a2b3c4
squash 5d6e7f8
exec $SCRIPT_PATH --rewrite
pick 9a0b1c2
exec $SCRIPT_PATH --rewrite"

# Optimization: 'think: false', fast deterministic sampling
PAYLOAD=$(jq -n \
    --arg history "/no_think $HISTORY" \
    --arg system "$SYSTEM_PROMPT" \
    --arg model "$MODEL" \
    '{
        model: $model,
        system: $system,
        prompt: $history,
        stream: false,
        think: false,
        options: {
            num_predict: 1024,
            num_ctx: 32768,
            temperature: 0.1
        }
    }')

echo "Asking Ollama to cluster your commits..."
RESPONSE=$(curl -s $OLLAMA_URL -d "$PAYLOAD" | jq -r '.response')

# Guardrail: Strip accidental reasoning blocks, markdown fences, and keep only rebase commands
CLEAN_TODO=$(echo "$RESPONSE" | sed -E 's/<think>.*<\/think>//g' | sed 's/```.*//g' | grep -E '^(pick|squash|exec|p|s) ')

if [ -z "$CLEAN_TODO" ]; then
    echo "Error: Ollama didn't return a valid rebase plan. Raw output:"
    echo "$RESPONSE"
    exit 1
fi

echo "--- Generated Rebase Plan ---"
echo "$CLEAN_TODO"
echo "-----------------------------"

# 3. Execute the Rebase
TODO_FILE=$(mktemp)
echo "$CLEAN_TODO" >"$TODO_FILE"

echo "Starting automated rebase..."
GIT_SEQUENCE_EDITOR="cp $TODO_FILE" GIT_EDITOR=true git rebase -i "$BASE_COMMIT"

rm "$TODO_FILE"
echo "Rebase complete!"
