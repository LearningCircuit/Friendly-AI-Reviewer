#!/bin/bash

# AI Code Reviewer Script - Simple Comment Version
# Usage: OPENROUTER_API_KEY=xxx AI_MODEL=model AI_TEMPERATURE=0.1 AI_MAX_TOKENS=2000 echo "DIFF_CONTENT" | ./ai-reviewer.sh

set -e

# Constants
REVIEW_HEADER="## AI Code Review"
REVIEW_FOOTER="---\n*Review by [Friendly AI Reviewer](https://github.com/LearningCircuit/Friendly-AI-Reviewer) - made with ❤️*"

# Helper function to generate error response JSON
generate_error_response() {
    local error_msg="$1"
    echo "{\"review\":\"$REVIEW_HEADER\n\n❌ **Error**: $error_msg\n\n$REVIEW_FOOTER\",\"fail_pass_workflow\":\"uncertain\",\"labels_added\":[]}"
}

# Get API key from environment variable
API_KEY="${OPENROUTER_API_KEY}"

if [ -z "$API_KEY" ]; then
    echo "$REVIEW_HEADER

❌ **Error**: Missing OPENROUTER_API_KEY environment variable"
    exit 1
fi

# Configuration with defaults
AI_MODEL="${AI_MODEL:-minimax/minimax-m2.5}"
AI_TEMPERATURE="${AI_TEMPERATURE:-0.1}"
AI_MAX_TOKENS="${AI_MAX_TOKENS:-64000}"
MAX_DIFF_SIZE="${MAX_DIFF_SIZE:-5000000}"  # 5MB default limit (allows large PRs while preventing excessive API usage)
EXCLUDE_FILE_PATTERNS="${EXCLUDE_FILE_PATTERNS:-*.lock,*.min.js,*.min.css,package-lock.json,yarn.lock}"

# Ask OpenRouter to enforce a JSON Schema on the model's output (structured
# outputs). This makes the *provider* emit valid, correctly-escaped JSON rather
# than the model hand-writing a JSON string around a large markdown blob — the
# main source of "Invalid JSON response from AI model" failures. Supported by
# modern models (kimi-k2-*, minimax-m2.5, gpt-*, etc.); set to "false" only for
# a model/provider that does not support response_format json_schema.
STRUCTURED_OUTPUT="${STRUCTURED_OUTPUT:-true}"

# Context inclusion options (set to 'false' to disable, reduces token usage)
INCLUDE_PREVIOUS_REVIEWS="${INCLUDE_PREVIOUS_REVIEWS:-true}"
INCLUDE_HUMAN_COMMENTS="${INCLUDE_HUMAN_COMMENTS:-true}"
INCLUDE_CHECK_RUNS="${INCLUDE_CHECK_RUNS:-true}"
INCLUDE_LABELS="${INCLUDE_LABELS:-true}"
INCLUDE_PR_DESCRIPTION="${INCLUDE_PR_DESCRIPTION:-true}"
INCLUDE_COMMIT_MESSAGES="${INCLUDE_COMMIT_MESSAGES:-true}"

# Commit-history context is split by cost: the overview statistic (how many
# commits are on the PR, who made them, added/removed line totals) is cheap in
# tokens and read for many commits, while the fully quoted commit messages are
# token-heavy and therefore capped separately.
# - MAX_SUMMARY_COMMITS: how many past commits the overview statistic reads
#   (per-commit line stats cost one GitHub API call each). 0 keeps the count/
#   author line only.
# - MAX_COMMIT_MESSAGES: how many commit messages are fully quoted in the
#   prompt. 0 lists no messages.
# Non-numeric values fall back to the defaults.
MAX_SUMMARY_COMMITS="${MAX_SUMMARY_COMMITS:-15}"
MAX_COMMIT_MESSAGES="${MAX_COMMIT_MESSAGES:-3}"
if ! [[ "$MAX_SUMMARY_COMMITS" =~ ^[0-9]+$ ]]; then
    MAX_SUMMARY_COMMITS=15
fi
if ! [[ "$MAX_COMMIT_MESSAGES" =~ ^[0-9]+$ ]]; then
    MAX_COMMIT_MESSAGES=3
fi

# Include a short "X commits already on this PR" overview in the prompt, with
# per-author commit counts and added/deleted line totals (see
# MAX_SUMMARY_COMMITS for how many commits those cover).
INCLUDE_COMMIT_SUMMARY="${INCLUDE_COMMIT_SUMMARY:-true}"

# Human comments are high-value context, so these caps are deliberately
# generous and each is configurable: how many of the newest comments are
# kept, how long each may be, and the overall character budget for the
# block. When a cap clips, the oldest of the selected comments go first and
# the clip is marked so the model knows context was cut.
MAX_HUMAN_COMMENTS="${MAX_HUMAN_COMMENTS:-100}"
MAX_HUMAN_COMMENT_LENGTH="${MAX_HUMAN_COMMENT_LENGTH:-4000}"
MAX_HUMAN_COMMENTS_TOTAL="${MAX_HUMAN_COMMENTS_TOTAL:-20000}"
if ! [[ "$MAX_HUMAN_COMMENTS" =~ ^[0-9]+$ ]]; then
    MAX_HUMAN_COMMENTS=100
fi
if ! [[ "$MAX_HUMAN_COMMENT_LENGTH" =~ ^[0-9]+$ ]]; then
    MAX_HUMAN_COMMENT_LENGTH=4000
fi
if ! [[ "$MAX_HUMAN_COMMENTS_TOTAL" =~ ^[0-9]+$ ]]; then
    MAX_HUMAN_COMMENTS_TOTAL=20000
fi

# Read diff content from stdin
DIFF_CONTENT=$(cat)

if [ -z "$DIFF_CONTENT" ]; then
    echo "$REVIEW_HEADER

❌ **Error**: No diff content to analyze"
    exit 1
fi

# Simple exclude file patterns filter
if [ -n "$EXCLUDE_FILE_PATTERNS" ]; then
    FILTERED_DIFF=$(mktemp)
    echo "$DIFF_CONTENT" | grep -v -E "diff --git a/($(echo "$EXCLUDE_FILE_PATTERNS" | sed 's/,/|/g' | sed 's/\*/\\*/g')) b/" > "$FILTERED_DIFF" 2>/dev/null || true
    if [ -s "$FILTERED_DIFF" ]; then
        DIFF_CONTENT=$(cat "$FILTERED_DIFF")
    fi
    rm -f "$FILTERED_DIFF"
fi

# Validate diff size to prevent excessive API usage
DIFF_SIZE=${#DIFF_CONTENT}
if [ "$DIFF_SIZE" -gt "$MAX_DIFF_SIZE" ]; then
    echo "$REVIEW_HEADER

❌ **Error**: Diff is too large ($DIFF_SIZE bytes, max: $MAX_DIFF_SIZE bytes)
Please split this PR into smaller changes for review."
    exit 1
fi

# Identify bot authors separately from review text: human comments may quote a
# review header or sticky marker and must remain human context.
COMMENT_CLASSIFIERS='
def is_bot:
    .user.type == "Bot" or ((.user.login // "") | endswith("[bot]"));
def is_ai_review:
    is_bot and ((.body // "") |
        startswith("## AI Code Review") or contains("<!-- ai-code-review:sticky -->"));
'

# Fetch previous AI review (only the most recent one) for context
PREVIOUS_REVIEWS=""
if [ "$INCLUDE_PREVIOUS_REVIEWS" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Fetch only the most recent AI review comment
    PREVIOUS_REVIEWS=$(gh api "repos/$REPO_FULL_NAME/issues/$PR_NUMBER/comments" \
        --jq "$COMMENT_CLASSIFIERS"'[.[] | select(is_ai_review)] | last | if . then "### Previous AI Review (" + .created_at + "):\n" + .body + "\n---\n" else "" end' 2>/dev/null | head -c 10000 || echo "")
fi

# Fetch human comments for context. Human comments are valuable, so the
# defaults are generous and configurable (see MAX_HUMAN_COMMENTS et al.):
# the newest MAX_HUMAN_COMMENTS comments are kept, presented newest-first so
# an overall-budget clip drops the oldest of the selected — never the latest
# feedback. Per-comment and overall clipping are marked as truncated.
# Exclude all bot comments; previous AI reviews have their own context block.
HUMAN_COMMENTS=""
if [ "$INCLUDE_HUMAN_COMMENTS" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ] && [ "$MAX_HUMAN_COMMENTS" -gt 0 ] && [ "$MAX_HUMAN_COMMENTS_TOTAL" -gt 0 ]; then
    # A count cap of 0 selects nothing; jq's .[-0:] would mean "everything",
    # so build the slice expression explicitly.
    if [ "$MAX_HUMAN_COMMENTS" -gt 0 ]; then
        COMMENT_SLICE=".[-$MAX_HUMAN_COMMENTS:]"
    else
        COMMENT_SLICE="[]"
    fi
    HUMAN_COMMENTS_FULL=$(gh api "repos/$REPO_FULL_NAME/issues/$PR_NUMBER/comments" \
        --jq "$COMMENT_CLASSIFIERS"'[.[] | select(is_bot | not)]
            | '"$COMMENT_SLICE"' | reverse
            | map("**" + (.user.login // "unknown") + "** (" + .created_at + "):\n"
                 + (if ((.body // "") | length) > '"$MAX_HUMAN_COMMENT_LENGTH"'
                    then ((.body // "")[0:'"$MAX_HUMAN_COMMENT_LENGTH"'] + " […truncated]")
                    else (.body // "") end))
            | join("\n\n---\n\n")' 2>/dev/null || echo "")
    HUMAN_COMMENTS=$(printf '%s' "$HUMAN_COMMENTS_FULL" | head -c "$MAX_HUMAN_COMMENTS_TOTAL")
    if [ "$(printf '%s' "$HUMAN_COMMENTS" | wc -c)" -eq "$MAX_HUMAN_COMMENTS_TOTAL" ]; then
        HUMAN_COMMENTS="$HUMAN_COMMENTS
[…truncated at $MAX_HUMAN_COMMENTS_TOTAL characters]"
    fi
fi

# Fetch GitHub Actions check runs status (if PR_NUMBER and REPO_FULL_NAME are set).
# Successful checks are collapsed into a one-line count; every non-passing run
# (failure, skipped, cancelled, timed out, still running) is listed
# individually — green matrix shards must not flood the prompt, but skipped
# runs can matter, so they stay visible.
CHECK_RUNS_STATUS=""
if [ "$INCLUDE_CHECK_RUNS" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Get the head SHA of the PR
    HEAD_SHA=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER" --jq '.head.sha' 2>/dev/null || echo "")

    if [ -n "$HEAD_SHA" ]; then
        CHECK_RUNS_SUMMARY=$(gh api "repos/$REPO_FULL_NAME/commits/$HEAD_SHA/check-runs" \
            --jq '(.check_runs // [])
                  | {total: length,
                     passed: [.[] | select(.conclusion == "success")] | length,
                     other: [.[] | select(.conclusion != "success")
                             | "- **\(.name)**: \(.status)\(if .conclusion then " (\(.conclusion))" else "" end)"]}' 2>/dev/null || echo "")

        if [ -n "$CHECK_RUNS_SUMMARY" ] && [ "$CHECK_RUNS_SUMMARY" != "null" ]; then
            TOTAL_CHECKS=$(echo "$CHECK_RUNS_SUMMARY" | jq -r '.total // 0')
            PASSED_CHECKS=$(echo "$CHECK_RUNS_SUMMARY" | jq -r '.passed // 0')
            OTHER_CHECKS=$(echo "$CHECK_RUNS_SUMMARY" | jq -r 'if .other then .other | join("\n") else "" end')

            if [ "$TOTAL_CHECKS" -gt 0 ]; then
                if [ -n "$OTHER_CHECKS" ]; then
                    CHECK_RUNS_STATUS="$PASSED_CHECKS of $TOTAL_CHECKS checks passed. Non-passing checks:
$OTHER_CHECKS"
                else
                    CHECK_RUNS_STATUS="All $TOTAL_CHECKS checks passed."
                fi
            fi
        fi
    fi
fi

# Fetch available repository labels (if PR_NUMBER and REPO_FULL_NAME are set)
AVAILABLE_LABELS=""
if [ "$INCLUDE_LABELS" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Fetch all labels from the repository
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "🔍 Fetching available labels from repository..." >&2
    fi
    AVAILABLE_LABELS=$(gh api "repos/$REPO_FULL_NAME/labels" --paginate 2>/dev/null \
        --jq '.[] | "- **\(.name)**: \(.description // "No description") (color: #\(.color))"' || echo "")

    if [ "$DEBUG_MODE" = "true" ]; then
        if [ -n "$AVAILABLE_LABELS" ]; then
            LABEL_COUNT=$(echo "$AVAILABLE_LABELS" | wc -l)
            echo "✅ Successfully fetched $LABEL_COUNT labels from repository" >&2
        else
            echo "ℹ️  No existing labels found in repository or API call failed" >&2
        fi
    fi
fi

# Fetch PR title and description
PR_DESCRIPTION=""
if [ "$INCLUDE_PR_DESCRIPTION" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "🔍 Fetching PR title and description..." >&2
    fi
    PR_DESCRIPTION=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER" \
        --jq '"**PR Title**: " + .title + "\n\n**Description**:\n" + (.body // "No description provided")' 2>/dev/null | head -c 2000 || echo "")

    if [ "$DEBUG_MODE" = "true" ] && [ -n "$PR_DESCRIPTION" ]; then
        echo "✅ Successfully fetched PR description" >&2
    fi
fi

# Fetch the PR's commit list once, shared by the commit-message list and the
# commit summary. --paginate emits one JSON array per page back to back, so
# slurp with jq -s and 'add' to merge the pages into a single array (this also
# makes the "most recent N" truncation global instead of per-page).
COMMITS_JSON="[]"
if { [ "$INCLUDE_COMMIT_MESSAGES" = "true" ] || [ "$INCLUDE_COMMIT_SUMMARY" = "true" ]; } && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "🔍 Fetching PR commits..." >&2
    fi
    COMMITS_JSON=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER/commits" --paginate 2>/dev/null | jq -s 'add // []' || echo "[]")

    if [ "$DEBUG_MODE" = "true" ]; then
        echo "✅ Fetched $(echo "$COMMITS_JSON" | jq 'length') commit(s) from the PR" >&2
    fi
fi

# Format the commit-message list from the cached commit JSON (limit to the
# MAX_COMMIT_MESSAGES most recent, exclude merges). Fully quoted messages are
# the token-expensive part of the history context, hence the separate, smaller
# cap compared to the overview statistic.
COMMIT_MESSAGES=""
if [ "$INCLUDE_COMMIT_MESSAGES" = "true" ] && [ "$COMMITS_JSON" != "[]" ] && [ "$COMMITS_JSON" != "" ]; then
    COMMIT_MESSAGES=$(echo "$COMMITS_JSON" | jq -r --argjson n "$MAX_COMMIT_MESSAGES" \
        '[.[] | select(.commit.message | startswith("Merge") | not)]
         | if $n > 0 then .[-$n:] else [] end
         | .[] | "- " + (.commit.message | split("\n")[0]) + (if (.commit.message | split("\n\n")[1]) then "\n  " + (.commit.message | split("\n\n")[1]) else "" end)' 2>/dev/null | head -c 2500 || echo "")

    if [ "$DEBUG_MODE" = "true" ] && [ -n "$COMMIT_MESSAGES" ]; then
        COMMIT_COUNT=$(echo "$COMMIT_MESSAGES" | grep -c "^- " || echo "0")
        echo "✅ Kept $COMMIT_COUNT commit message(s) (limit $MAX_COMMIT_MESSAGES)" >&2
    fi
fi

# Build the commit overview: how many commits are already on the PR, who made
# them, and how many lines each author added/removed. The total comes from the
# cached list; per-commit line stats are NOT part of that list response, so
# each summarized commit costs one extra API call. MAX_SUMMARY_COMMITS bounds
# that cost (0 skips the per-commit calls entirely). The overview is cheap in
# tokens — a handful of numbers — so it may cover many more commits than the
# fully quoted message list (MAX_COMMIT_MESSAGES).
COMMIT_SUMMARY=""
if [ "$INCLUDE_COMMIT_SUMMARY" = "true" ] && [ -n "$COMMITS_JSON" ] && [ "$COMMITS_JSON" != "[]" ]; then
    NONMERGE_COUNT=$(echo "$COMMITS_JSON" | jq '[.[] | select(.commit.message | startswith("Merge") | not)] | length')
    MERGE_COUNT=$(echo "$COMMITS_JSON" | jq 'length' )
    MERGE_COUNT=$(( MERGE_COUNT - NONMERGE_COUNT ))

    AUTHOR_LINES=""
    if [ "$MAX_SUMMARY_COMMITS" -gt 0 ] && [ "$NONMERGE_COUNT" -gt 0 ]; then
        STATS_FILE=$(mktemp) || { echo "Failed to create temporary file for commit stats"; exit 1; }
        chmod 600 "$STATS_FILE"
        # One "author<TAB>additions<TAB>deletions" row per listed commit;
        # a failed stats fetch counts as zero rather than aborting the review.
        while IFS=$'\t' read -r author sha; do
            [ -n "$sha" ] || continue
            line_stats=$(gh api "repos/$REPO_FULL_NAME/commits/$sha" \
                --jq '"\(.stats.additions // 0)\t\(.stats.deletions // 0)"' 2>/dev/null || printf '0\t0')
            printf '%s\t%s\n' "$author" "$line_stats" >> "$STATS_FILE"
        done < <(echo "$COMMITS_JSON" | jq -r --argjson n "$MAX_SUMMARY_COMMITS" \
            '[.[] | select(.commit.message | startswith("Merge") | not)]
             | if $n > 0 then .[-$n:] else [] end
             | .[] | [(.author.login // .commit.author.name), .sha] | @tsv')
        # Aggregate per author; sort by added lines, then removed, then name.
        AUTHOR_LINES=$(awk -F'\t' '{ count[$1]++; add[$1] += $2; del[$1] += $3 }
            END { for (who in count) printf "%s\t%d\t%d\t%d\n", who, count[who], add[who], del[who] }' "$STATS_FILE" \
            | LC_ALL=C sort -t$'\t' -k3,3nr -k4,4nr -k1,1)
        rm -f "$STATS_FILE"
    fi

    if [ "$NONMERGE_COUNT" -gt 0 ]; then
        if [ "$NONMERGE_COUNT" -eq 1 ]; then
            SUMMARY_HEADER="There is 1 commit already on this PR"
            COMMIT_WORD="commit"
        else
            SUMMARY_HEADER="There are $NONMERGE_COUNT commits already on this PR"
            COMMIT_WORD="commits"
        fi
        [ "$MERGE_COUNT" -gt 0 ] && SUMMARY_HEADER="$SUMMARY_HEADER (excluding $MERGE_COUNT merge commit(s))"
        if [ -n "$AUTHOR_LINES" ]; then
            LISTED=$(( MAX_SUMMARY_COMMITS < NONMERGE_COUNT ? MAX_SUMMARY_COMMITS : NONMERGE_COUNT ))
            [ "$LISTED" -eq "$NONMERGE_COUNT" ] \
                && SCOPE="across all $NONMERGE_COUNT $COMMIT_WORD" \
                || SCOPE="across the $LISTED most recent of $NONMERGE_COUNT $COMMIT_WORD"
            SUMMARY_BULLETS=$(printf '%s\n' "$AUTHOR_LINES" | awk -F'\t' \
                '{ word = ($2 == 1 ? "commit" : "commits")
                   print sprintf("- **%s**: %s %s, +%s/-%s lines", $1, $2, word, $3, $4) }')
            COMMIT_SUMMARY="Commit Summary:
$SUMMARY_HEADER. Per-author commit counts and line totals $SCOPE:
$SUMMARY_BULLETS"
        else
            COMMIT_SUMMARY="Commit Summary:
$SUMMARY_HEADER."
        fi

        if [ "$DEBUG_MODE" = "true" ]; then
            echo "✅ Commit summary: $SUMMARY_HEADER" >&2
        fi
    fi
fi

# Create the JSON request with proper escaping using jq
# Write diff to temporary file to avoid "Argument list too long" error
DIFF_FILE=$(mktemp) || { echo "Failed to create temporary file for diff"; exit 1; }
chmod 600 "$DIFF_FILE"
echo "$DIFF_CONTENT" > "$DIFF_FILE" || { echo "Failed to write diff to temporary file"; rm -f "$DIFF_FILE"; exit 1; }

# Set up trap to ensure temp file cleanup on exit/error
trap 'rm -f "$DIFF_FILE"' EXIT

# Build the user prompt using the diff file
PROMPT_PREFIX="Review this code diff thoroughly and report only actionable findings in markdown format.

Focus on security, performance, code quality, and best practices.

Keep the review scannable and grouped by importance. Lead with critical issues if any exist.
"

# Add GitHub Actions check status if available
if [ -n "$CHECK_RUNS_STATUS" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
GitHub Actions Check Status:
$CHECK_RUNS_STATUS

Please consider any failed or pending checks in your review. If tests are failing, investigate whether the code changes might be the cause.
"
fi

# Add available labels context if available
if [ -n "$AVAILABLE_LABELS" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
Available Repository Labels:
Prefer existing labels from this list over creating new ones. Only apply labels that are genuinely useful for these changes — when unsure, add none rather than stretching a label to fit:
$AVAILABLE_LABELS

If none of these labels are appropriate for the changes, you may suggest new ones.
"
fi

# Add PR description if available
if [ -n "$PR_DESCRIPTION" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
Pull Request Context:
$PR_DESCRIPTION

"
fi

# Add commit summary if available
if [ -n "$COMMIT_SUMMARY" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
$COMMIT_SUMMARY

Use the commit summary to gauge the PR's size and authorship; it records what already changed, not what should change.

"
fi

# Add commit messages if available
if [ -n "$COMMIT_MESSAGES" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
Commit History (showing development journey):
$COMMIT_MESSAGES

Please consider the commit history to understand what was tried, what issues were discovered, and how the solution evolved.

"
fi

# Add human comments context if available
if [ -n "$HUMAN_COMMENTS" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
Human Comments on this PR (newest first):
$HUMAN_COMMENTS

Please consider these human comments when reviewing the code.
"
fi

# Add previous AI review context if available (only most recent)
if [ -n "$PREVIOUS_REVIEWS" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
Previous AI Review (for context on what was already reviewed):
$PREVIOUS_REVIEWS
"
fi

PROMPT_PREFIX="${PROMPT_PREFIX}
Code diff to analyze:

"

# Create a simple text prompt
# Read diff content
DIFF_CONTENT=$(cat "$DIFF_FILE")

# Simple text prompt requesting JSON response
PROMPT="You are an expert code reviewer. Analyze this code diff thoroughly and report only actionable findings.

Focus on security, performance, code quality, and best practices.

Focus on high-value issues. Style suggestions are welcome if impactful, but not minor optimizations. Be concise: omit praise, change summaries, empty sections, and repeated conclusions. For each finding, include its file and line location, concrete failure scenario, impact, and suggested fix. Important: Focus on issues directly visible in the diff. If you cannot verify something from the diff alone (e.g., missing context, unclear defaults, code not shown):
- Default: Skip the issue to avoid spam
- Only ask for clarification if it's critical (security vulnerabilities, breaking bugs, data loss risks): \"Cannot verify [X] from diff - please confirm [specific question]\"
- If making an inference about non-critical issues, explicitly label it: \"Inference (not verified): [observation]\"

Review Structure:
1. Start with the \"## AI Code Review\" header
2. List actionable findings as bullet points, ordered by severity; preserve enough detail to understand and fix each issue
3. If there are no actionable findings, write only \"No actionable findings.\" before the verdict; do not add a summary or empty security section
4. End with one of these verdicts ONLY:
   - \"✅ Approved\" (no issues found)
   - \"✅ Approved with recommendations\" (minor improvements suggested, but not blocking)
   - \"❌ Request changes\" (critical issues that must be fixed before merge)

Required JSON format:
{
  \"review\": \"## AI Code Review\\n\\n[Your detailed review in markdown format]\\n\\n---\\n*Review by [Friendly AI Reviewer](https://github.com/LearningCircuit/Friendly-AI-Reviewer) - made with ❤️*\",
  \"fail_pass_workflow\": \"pass\",
  \"labels_added\": [\"bug\", \"feature\", \"enhancement\"]
}

Instructions:
1. Respond with a single valid JSON object
2. Include the Friendly AI Reviewer footer with heart emoji at the end of the review field
3. For labels_added, prefer existing repository labels when possible
4. Always end your review with one of the three verdict options listed above before the footer

Code to review:
$PROMPT_PREFIX

$DIFF_CONTENT"

# Make API call to OpenRouter with simple JSON
# Use generic or repo-specific referer
REFERER_URL="https://github.com/${REPO_FULL_NAME:-unknown/repo}"

# Build JSON payload and pipe to curl to avoid "Argument list too long" error
# Write prompt to temp file to avoid passing large content as command-line argument
PROMPT_FILE=$(mktemp) || { echo "Failed to create temporary file for prompt"; exit 1; }
chmod 600 "$PROMPT_FILE"
echo "$PROMPT" > "$PROMPT_FILE" || { echo "Failed to write prompt to temporary file"; rm -f "$PROMPT_FILE"; exit 1; }

# Update trap to cleanup both temp files
trap 'rm -f "$DIFF_FILE" "$PROMPT_FILE"' EXIT

# When structured output is enabled, constrain the response to our JSON schema.
# require_parameters tells OpenRouter to only route to providers that actually
# honor response_format, so we fail loudly rather than silently get free-form
# text from a non-supporting provider.
RESPONSE_FORMAT_ARG='{}'
if [ "$STRUCTURED_OUTPUT" = "true" ]; then
    RESPONSE_FORMAT_ARG='{
      "response_format": {
        "type": "json_schema",
        "json_schema": {
          "name": "code_review",
          "strict": true,
          "schema": {
            "type": "object",
            "additionalProperties": false,
            "required": ["review", "fail_pass_workflow", "labels_added"],
            "properties": {
              "review": { "type": "string" },
              "fail_pass_workflow": { "type": "string", "enum": ["pass", "fail", "uncertain"] },
              "labels_added": { "type": "array", "items": { "type": "string" } }
            }
          }
        }
      },
      "provider": { "require_parameters": true }
    }'
fi

JSON_PAYLOAD=$(jq -n \
    --arg model "$AI_MODEL" \
    --rawfile content "$PROMPT_FILE" \
    --argjson temperature "$AI_TEMPERATURE" \
    --argjson max_tokens "$AI_MAX_TOKENS" \
    --argjson response_format "$RESPONSE_FORMAT_ARG" \
    '{
      "model": $model,
      "messages": [
        {
          "role": "user",
          "content": $content
        }
      ],
      "temperature": $temperature,
      "max_tokens": $max_tokens
    } + $response_format')

RESPONSE=$(echo "$JSON_PAYLOAD" | curl -s -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -H "HTTP-Referer: $REFERER_URL" \
    --data-binary @-)

# Check if API call was successful
if [ -z "$RESPONSE" ]; then
    generate_error_response "API call failed - no response received"
    exit 1
fi

# Check if response is valid JSON
if ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
    echo "=== API DEBUG: Raw response from $AI_MODEL ===" >&2
    echo "$RESPONSE" >&2
    echo "=== END API DEBUG ===" >&2
    generate_error_response "Invalid JSON response from API"
    exit 1
fi

# Log the API response structure for debugging thinking models (if debug mode enabled)
if [ "$DEBUG_MODE" = "true" ]; then
    echo "=== API STRUCTURE DEBUG from $AI_MODEL ===" >&2
    echo "Response keys: $(echo "$RESPONSE" | jq -r 'keys | join(", ")')" >&2
    echo "Choices count: $(echo "$RESPONSE" | jq '.choices | length')" >&2
    echo "First choice keys: $(echo "$RESPONSE" | jq -r '.choices[0] | keys | join(", ")')" >&2
    echo "Content type: $(echo "$RESPONSE" | jq -r '.choices[0].message | type')" >&2
    echo "=== END API STRUCTURE DEBUG ===" >&2
fi

# Extract the content
CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "error"')

# Capture finish_reason so a truncated completion can be reported distinctly
# from genuinely malformed output (the remedies differ).
FINISH_REASON=$(echo "$RESPONSE" | jq -r '.choices[0].finish_reason // ""')

# Log the extracted content from thinking model (if debug mode enabled)
if [ "$DEBUG_MODE" = "true" ]; then
    echo "=== CONTENT DEBUG: Extracted from $AI_MODEL ===" >&2
    echo "Content length: $(echo "$CONTENT" | wc -c)" >&2
    echo "Full content:" >&2
    echo "$CONTENT" >&2
    echo "=== END CONTENT DEBUG ===" >&2
fi

if [ "$CONTENT" = "error" ]; then
    # Try to extract error details from the API response
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "Invalid API response format"')
    ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error.code // ""')

    # Return error as JSON
    ERROR_CONTENT="$REVIEW_HEADER\n\n❌ **Error**: $ERROR_MSG"
    if [ -n "$ERROR_CODE" ]; then
        ERROR_CONTENT="$ERROR_CONTENT\n\nError code: \`$ERROR_CODE\`"
    fi
    ERROR_CONTENT="$ERROR_CONTENT\n\n$REVIEW_FOOTER"

    echo "{\"review\":\"$ERROR_CONTENT\",\"fail_pass_workflow\":\"uncertain\",\"labels_added\":[]}"

    # Don't log full response as it may contain sensitive API data
    # Only log error code for debugging
    if [ -n "$ERROR_CODE" ]; then
        echo "API Error code: $ERROR_CODE" >&2
    fi
    exit 1
fi

# A truncated completion (model hit max_tokens) leaves incomplete or empty
# content — common with reasoning models whose chain-of-thought consumes the
# token budget on large diffs. Report it specifically: the remedy is to raise
# AI_MAX_TOKENS or shrink the diff, not to re-run the same request.
if [ "$FINISH_REASON" = "length" ]; then
    generate_error_response "AI response was truncated before it finished (finish_reason=length, max_tokens=$AI_MAX_TOKENS). For reasoning models the chain-of-thought can consume the whole budget on large diffs — increase AI_MAX_TOKENS or reduce the diff size."
    exit 0
fi

# Ensure CONTENT is not empty
if [ -z "$CONTENT" ]; then
    generate_error_response "AI returned empty response"
    exit 0
fi

# Remove thinking tags and content - everything between <thinking> and </thinking>
# Use perl for proper multiline and inline handling
CONTENT=$(echo "$CONTENT" | perl -0pe 's/<thinking>.*?<\/thinking>\s*//gs')

# Remove markdown code blocks if present (check for actual backticks at line start)
if echo "$CONTENT" | grep -qE '^\s*```json'; then
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "=== REMOVING MARKDOWN CODE BLOCKS ===" >&2
    fi
    # Remove the opening ```json and closing ``` lines, keep the content
    CONTENT=$(echo "$CONTENT" | perl -0pe 's/^\s*```json\s*\n//g; s/\n```\s*$//g')
fi

# Trim leading and trailing whitespace
CONTENT=$(echo "$CONTENT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# Enhanced empty check (catches whitespace-only content)
if [ -z "$CONTENT" ] || [ -z "$(echo "$CONTENT" | tr -d '[:space:]')" ]; then
    generate_error_response "AI returned empty response after processing"
    exit 0
fi

# Validate that CONTENT is valid JSON
if ! echo "$CONTENT" | jq . >/dev/null 2>&1; then
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "=== JSON VALIDATION FAILED ===" >&2
        echo "Content is not valid JSON" >&2
        echo "=== RAW CONTENT FOR DEBUG ===" >&2
        echo "$CONTENT" >&2
        echo "=== END DEBUG ===" >&2
    fi

    # Fallback to error response
    generate_error_response "Invalid JSON response from AI model"
else
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "=== CONTENT IS VALID JSON ===" >&2
    fi
    # Validate it has the required structure
    if ! echo "$CONTENT" | jq -e '.review' >/dev/null 2>&1; then
        if [ "$DEBUG_MODE" = "true" ]; then
            echo "JSON missing required 'review' field" >&2
        fi
        generate_error_response "AI response missing required review field"
    else
        if [ "$DEBUG_MODE" = "true" ]; then
            echo "JSON has required structure, using as-is" >&2
        fi
        echo "$CONTENT"
    fi
fi
