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

    # 1. Always get the full file summary (including deleted files and binaries)
    STAT=$(git show HEAD --stat --format="Original Subject: %s%n")

    # 2. Get patch ONLY for added/modified files (skipping deleted files),
    #    excluding noisy lockfiles/minified assets, capped at 12,000 chars.
    #    (Git automatically omits binary data unless --binary is passed)
    PATCH=$(git show HEAD -p --diff-filter=ACMR --unified=1 \
        -- . \
        ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' \
        ':!go.sum' ':!Cargo.lock' ':!*.min.js' ':!*.min.css' ':!*.svg' |
        head -c 12000)

    DIFF="${STAT}"$'\n\n'"--- Diff Patch (Truncated if large) ---"$'\n'"${PATCH}"

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

    # Pipe DIFF via stdin to avoid ARG_MAX limits, right-sized context window
    RAW_RESPONSE=$(printf "/no_think \%s" "$DIFF" | jq -R -s \
        --arg system "$SYSTEM_PROMPT" \
        --arg model "$MODEL" \
        '{
            model: $model,
            system: $system,
            prompt: .,
            stream: false,
            think: false,
            keep_alive: "10m",
            options: {
                num_predict: 350,
                num_ctx: 8192,
                temperature: 0.2
            }
        }' | curl -s "$OLLAMA_URL" -d @- | jq -r '.response')

    # Cleaning: Remove potential <think> tags or markdown backticks
    NEW_MSG=$(echo "$RAW_RESPONSE" | sed -E 's/<think>.*<\/think>//g' | sed 's/^```.*//g' | sed 's/```$//g')

    if [ -n "$NEW_MSG" ] && [ "$NEW_MSG" != "null" ]; then
        echo -e "\n=== 🤖 New Commit Generated ==="
        echo "$NEW_MSG"
        echo "==============================="
        for _ in {1..10}; do [ ! -f .git/index.lock ] && break; sleep 0.1; done
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
    UPSTREAM_RANGE=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1 && echo "@{u}..HEAD" || echo "HEAD")
    OLDEST_WIP=$(git log $UPSTREAM_RANGE -i --grep="^wip" --format="%H" | tail -n 1)

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
HISTORY=$(git log --reverse --format="Commit: %h%nMessage: %s" --name-status $LOG_RANGE)

SYSTEM_PROMPT="You are a git rebase automation tool. Your job is to group adjacent related commits together based on the files they modify or their features.
I will provide a chronological list of commits and the files they touch.
You must output a git interactive rebase todo list.

Rules:
1. Group adjacent related commits together (e.g., consecutive commits touching the same files or features).
2. For each group, 'pick' the first commit, and 'squash' the rest in that group.
3. Preserve the exact chronological order of commits. Reordering commits is strictly forbidden.
4. Immediately after the last 'squash' (or 'pick' if it's a standalone commit) of EACH group, add this exact line:
   exec $SCRIPT_PATH --rewrite
5. Output ONLY the valid git rebase commands. No explanations, no markdown blocks.
6. CRITICAL: You must use the EXACT commit hashes provided in the input. Do not alter, misspell, or truncate the hashes.
7. Never drop a commit.
8. Only squash commits that are small or clearly part of the same work-in-progress.

EXAMPLE OUTPUT FORMAT:
pick 1a2b3c4
squash 5d6e7f8
exec $SCRIPT_PATH --rewrite
pick 9a0b1c2
exec $SCRIPT_PATH --rewrite"

echo "Asking Ollama to cluster your commits..."
RESPONSE=$(printf "/no_think \%s" "$HISTORY" | jq -R -s \
    --arg system "$SYSTEM_PROMPT" \
    --arg model "$MODEL" \
    '{
        model: $model,
        system: $system,
        prompt: .,
        stream: false,
        think: false,
        keep_alive: "10m",
        options: {
            num_predict: 1024,
            num_ctx: 16384,
            temperature: 0.1
        }
    }' | curl -s "$OLLAMA_URL" -d @- | jq -r '.response')

# Guardrail: Strip accidental reasoning blocks, markdown fences, and keep only rebase commands
CLEAN_TODO=$(echo "$RESPONSE" | sed -E 's/<think>.*<\/think>//g' | sed 's/```.*//g' | grep -E '^(pick|squash|exec|p|s) ' | while read -r cmd arg rest; do
    if [ "$cmd" = "exec" ] || git rev-parse --verify -q "${arg}^{commit}" >/dev/null 2>&1; then
        echo "$cmd $arg${rest:+ $rest}"
    fi
done)

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
