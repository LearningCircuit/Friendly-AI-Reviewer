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
AI_MODEL="${AI_MODEL:-moonshotai/kimi-k2-thinking}"
AI_TEMPERATURE="${AI_TEMPERATURE:-0.1}"
AI_MAX_TOKENS="${AI_MAX_TOKENS:-64000}"
MAX_DIFF_SIZE="${MAX_DIFF_SIZE:-800000}"  # 800KB default limit (~200K tokens, matching model context size)
EXCLUDE_FILE_PATTERNS="${EXCLUDE_FILE_PATTERNS:-*.lock,*.min.js,*.min.css,package-lock.json,yarn.lock}"

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

# Fetch previous AI review (only the most recent one) for context
PREVIOUS_REVIEWS=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Fetch only the most recent AI review comment
    PREVIOUS_REVIEWS=$(gh api "repos/$REPO_FULL_NAME/issues/$PR_NUMBER/comments" \
        --jq '[.[] | select(.body | startswith("## AI Code Review"))] | last | if . then "### Previous AI Review (" + .created_at + "):\n" + .body + "\n---\n" else "" end' 2>/dev/null | head -c 10000 || echo "")
fi

# Fetch human comments for context
HUMAN_COMMENTS=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Fetch comments from humans (not the bot)
    HUMAN_COMMENTS=$(gh api "repos/$REPO_FULL_NAME/issues/$PR_NUMBER/comments" \
        --jq '[.[] | select(.body | startswith("## AI Code Review") | not)] | map("**" + .user.login + "** (" + .created_at + "):\n" + .body) | join("\n\n---\n\n")' 2>/dev/null | head -c 20000 || echo "")
fi

# Fetch GitHub Actions check runs status (if PR_NUMBER and REPO_FULL_NAME are set)
CHECK_RUNS_STATUS=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Get the head SHA of the PR
    HEAD_SHA=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER" --jq '.head.sha' 2>/dev/null || echo "")

    if [ -n "$HEAD_SHA" ]; then
        # Fetch check runs for this commit
        CHECK_RUNS_STATUS=$(gh api "repos/$REPO_FULL_NAME/commits/$HEAD_SHA/check-runs" \
            --jq '.check_runs // [] | .[] | "- **\(.name)**: \(.status)\(if .conclusion then " (\(.conclusion))" else "" end)"' 2>/dev/null || echo "")
    fi
fi

# Fetch available repository labels (if PR_NUMBER and REPO_FULL_NAME are set)
AVAILABLE_LABELS=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Fetch all labels from the repository
    echo "🔍 Fetching available labels from repository..." >&2
    AVAILABLE_LABELS=$(gh api "repos/$REPO_FULL_NAME/labels" --paginate 2>/dev/null \
        --jq '.[] | "- **\(.name)**: \(.description // "No description") (color: #\(.color))"' || echo "")

    if [ -n "$AVAILABLE_LABELS" ]; then
        LABEL_COUNT=$(echo "$AVAILABLE_LABELS" | wc -l)
        echo "✅ Successfully fetched $LABEL_COUNT labels from repository" >&2
    else
        echo "ℹ️  No existing labels found in repository or API call failed" >&2
    fi
fi

# Fetch PR title and description
PR_DESCRIPTION=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    echo "🔍 Fetching PR title and description..." >&2
    PR_DESCRIPTION=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER" \
        --jq '"**PR Title**: " + .title + "\n\n**Description**:\n" + (.body // "No description provided")' 2>/dev/null | head -c 2000 || echo "")

    if [ -n "$PR_DESCRIPTION" ]; then
        echo "✅ Successfully fetched PR description" >&2
    fi
fi

# Fetch commit messages (limit to 15 most recent, exclude merges)
COMMIT_MESSAGES=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    echo "🔍 Fetching commit messages..." >&2
    COMMIT_MESSAGES=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER/commits" --paginate \
        --jq '[.[] | select(.commit.message | startswith("Merge") | not)] | .[-15:] | .[] | "- " + (.commit.message | split("\n")[0]) + (if (.commit.message | split("\n\n")[1]) then "\n  " + (.commit.message | split("\n\n")[1]) else "" end)' 2>/dev/null | head -c 2500 || echo "")

    if [ -n "$COMMIT_MESSAGES" ]; then
        COMMIT_COUNT=$(echo "$COMMIT_MESSAGES" | grep -c "^- " || echo "0")
        echo "✅ Successfully fetched $COMMIT_COUNT commit messages" >&2
    fi
fi

# Create the JSON request with proper escaping using jq
# Write diff to temporary file to avoid "Argument list too long" error
DIFF_FILE=$(mktemp)
echo "$DIFF_CONTENT" > "$DIFF_FILE"

# Build the user prompt using the diff file
PROMPT_PREFIX="Please analyze this code diff and provide a comprehensive review in markdown format.

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
Please prefer using existing labels from this list over creating new ones:
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
Human Comments on this PR:
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
PROMPT="You are an expert code reviewer. Please analyze this code diff and provide a comprehensive review.

Focus on security, performance, code quality, and best practices.

Focus on high-value issues. Style suggestions are welcome if impactful, but not minor optimizations. Be concise and dense - use bullet points for clear structure. Avoid repetition - in summary sections, only repeat critical issues (security, bugs, breaking changes). Important: Focus on issues directly visible in the diff. If you cannot verify something from the diff alone (e.g., missing context, unclear defaults, code not shown):
- Default: Skip the issue to avoid spam
- Only ask for clarification if it's critical (security vulnerabilities, breaking bugs, data loss risks): \"Cannot verify [X] from diff - please confirm [specific question]\"
- If making an inference about non-critical issues, explicitly label it: \"Inference (not verified): [observation]\"

Review Structure:
1. Start with a short overall feedback summary (1-2 sentences)
2. Then provide detailed findings
3. End with one of these verdicts ONLY:
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


# Clean up diff file
rm -f "$DIFF_FILE"

# Make API call to OpenRouter with simple JSON
# Use generic or repo-specific referer
REFERER_URL="https://github.com/${REPO_FULL_NAME:-unknown/repo}"
RESPONSE=$(curl -s -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -H "HTTP-Referer: $REFERER_URL" \
    -d "{
      \"model\": \"$AI_MODEL\",
      \"messages\": [
        {
          \"role\": \"user\",
          \"content\": $(echo "$PROMPT" | jq -Rs .)
        }
      ],
      \"temperature\": $AI_TEMPERATURE,
      \"max_tokens\": $AI_MAX_TOKENS
    }")

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
