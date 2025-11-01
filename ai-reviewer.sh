#!/bin/bash

# AI Code Reviewer Script - Simple Comment Version
# Usage: OPENROUTER_API_KEY=xxx AI_MODEL=model AI_TEMPERATURE=0.1 AI_MAX_TOKENS=2000 echo "DIFF_CONTENT" | ./ai-reviewer.sh

set -e

# Get API key from environment variable
API_KEY="${OPENROUTER_API_KEY}"

if [ -z "$API_KEY" ]; then
    echo "## 🤖 AI Code Review

❌ **Error**: Missing OPENROUTER_API_KEY environment variable"
    exit 1
fi

# Configuration with defaults
AI_MODEL="${AI_MODEL:-z-ai/glm-4.6}"
AI_TEMPERATURE="${AI_TEMPERATURE:-0.1}"
AI_MAX_TOKENS="${AI_MAX_TOKENS:-2000}"
MAX_DIFF_SIZE="${MAX_DIFF_SIZE:-800000}"  # 800KB default limit (~200K tokens, matching model context size)

# Read diff content from stdin
DIFF_CONTENT=$(cat)

if [ -z "$DIFF_CONTENT" ]; then
    echo "## 🤖 AI Code Review

❌ **Error**: No diff content to analyze"
    exit 1
fi

# Validate diff size to prevent excessive API usage
DIFF_SIZE=${#DIFF_CONTENT}
if [ "$DIFF_SIZE" -gt "$MAX_DIFF_SIZE" ]; then
    echo "## 🤖 AI Code Review

❌ **Error**: Diff is too large ($DIFF_SIZE bytes, max: $MAX_DIFF_SIZE bytes)
Please split this PR into smaller changes for review."
    exit 1
fi

# Fetch previous AI review comments for context (if PR_NUMBER and REPO_FULL_NAME are set)
PREVIOUS_REVIEWS=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Fetch comments that start with "## 🤖 AI Code Review"
    PREVIOUS_REVIEWS=$(gh api "repos/$REPO_FULL_NAME/issues/$PR_NUMBER/comments" \
        --jq '.[] | select(.body | startswith("## 🤖 AI Code Review")) | "### Previous Review (" + .created_at + "):\n" + .body + "\n---\n"' 2>/dev/null | head -c 50000 || echo "")
fi

# Fetch GitHub Actions check runs status (if PR_NUMBER and REPO_FULL_NAME are set)
CHECK_RUNS_STATUS=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    # Get the head SHA of the PR
    HEAD_SHA=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER" --jq '.head.sha' 2>/dev/null || echo "")

    if [ -n "$HEAD_SHA" ]; then
        # Fetch check runs for this commit
        CHECK_RUNS_STATUS=$(gh api "repos/$REPO_FULL_NAME/commits/$HEAD_SHA/check-runs" \
            --jq '.check_runs[] | "- **\(.name)**: \(.status)\(if .conclusion then " (\(.conclusion))" else "" end)"' 2>/dev/null || echo "")
    fi
fi

# Create the JSON request with proper escaping using jq
# Write diff to temporary file to avoid "Argument list too long" error
DIFF_FILE=$(mktemp)
echo "$DIFF_CONTENT" > "$DIFF_FILE"

# Build the user prompt using the diff file
PROMPT_PREFIX="Please analyze this code diff and provide a comprehensive review in markdown format:

Focus Areas:
- Security: Look for hardcoded secrets, SQL injection, XSS, authentication issues, input validation problems
- Performance: Check for inefficient algorithms, N+1 queries, missing indexes, memory issues, blocking operations
- Code Quality: Evaluate readability, maintainability, proper error handling, naming conventions, documentation
- Best Practices: Ensure adherence to coding standards, proper patterns, type safety, dead code removal
"

# Add GitHub Actions check status if available
if [ -n "$CHECK_RUNS_STATUS" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
GitHub Actions Check Status:
$CHECK_RUNS_STATUS

Please consider any failed or pending checks in your review. If tests are failing, investigate whether the code changes might be the cause.
"
fi

# Add previous reviews context if available
if [ -n "$PREVIOUS_REVIEWS" ]; then
    PROMPT_PREFIX="${PROMPT_PREFIX}
Previous AI Reviews (for context on what was already reviewed):
$PREVIOUS_REVIEWS
"
fi

PROMPT_PREFIX="${PROMPT_PREFIX}
Code diff to analyze:

"

# Create the request JSON by combining parts
jq -n \
  --arg model "$AI_MODEL" \
  --argjson temperature "$AI_TEMPERATURE" \
  --argjson max_tokens "$AI_MAX_TOKENS" \
  --arg system_content "You are a helpful code reviewer analyzing pull requests. Provide a comprehensive review covering security, performance, code quality, and best practices.

IMPORTANT: Respond with valid JSON only. No other text before or after the JSON.

Use this exact structure:
{
  "review": "Human-readable review content with markdown formatting. Include detailed analysis, action items checklist, and clear recommendation.",
  "fail_pass_workflow": "pass",
  "labels_added": ["bug", "security", "performance"]
}

Guidelines:
- 'review' field: Detailed review in markdown format covering important issues only (ignore trivial nitpicks). Include action items checklist and clear recommendation with ✅ **Approve**, 🔄 **Request Changes**, or ❓ **Uncertain**.
- 'fail_pass_workflow' field: Use "pass" for ✅ **Approve**, "fail" for 🔄 **Request Changes**, "uncertain" for ❓ **Uncertain**
- 'labels_added' field: Array of standard GitHub labels describing the PR type. Common labels: bug, feature, enhancement, documentation, refactor, performance, security, test, ci, dependencies. Add other relevant labels as needed.

Example:
{
  "review": "## 🤖 AI Code Review\n\n### Security Analysis\nFound potential SQL injection vulnerability.\n\n### Performance Review\nDatabase query needs optimization.\n\n## Action Items Checklist\n- [ ] Fix SQL injection vulnerability\n- [ ] Add database index\n\n## Recommendation\n🔄 **Request Changes**",
  "fail_pass_workflow": "fail",
  "labels_added": ["security", "performance", "bug"]
}

Respond with valid JSON only." \
  --arg prompt_prefix "$PROMPT_PREFIX" \
  --rawfile diff_content "$DIFF_FILE" \
  '{
    "model": $model,
    "messages": [
      {
        "role": "system",
        "content": $system_content
      },
      {
        "role": "user",
        "content": ($prompt_prefix + $diff_content)
      }
    ],
    "temperature": $temperature,
    "max_tokens": $max_tokens
  }' > request.json

# Clean up diff file
rm -f "$DIFF_FILE"

# Make API call to OpenRouter
# Use generic or repo-specific referer
REFERER_URL="https://github.com/${REPO_FULL_NAME:-unknown/repo}"
RESPONSE=$(curl -s -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -H "HTTP-Referer: $REFERER_URL" \
    -d @request.json)

# Debug: Save API response for troubleshooting
echo "DEBUG: API Response:" >&2
echo "$RESPONSE" >&2
echo "DEBUG: End API Response" >&2

# Clean up temporary file
rm -f request.json

# Check if API call was successful
if [ -z "$RESPONSE" ]; then
    echo '{"review":"## 🤖 AI Code Review\n\n❌ **Error**: API call failed - no response received","fail_pass_workflow":"uncertain","labels_added":[]}'
    exit 1
fi

# Check if response is valid JSON
if ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
    echo '{"review":"## 🤖 AI Code Review\n\n❌ **Error**: Invalid JSON response from API","fail_pass_workflow":"uncertain","labels_added":[]}'
    exit 1
fi

# Extract the content
CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "error"')

if [ "$CONTENT" = "error" ]; then
    # Try to extract error details from the API response
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "Invalid API response format"')
    ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error.code // ""')

    # Return error as JSON
    ERROR_CONTENT="## 🤖 AI Code Review\n\n❌ **Error**: $ERROR_MSG"
    if [ -n "$ERROR_CODE" ]; then
        ERROR_CONTENT="$ERROR_CONTENT\n\nError code: \`$ERROR_CODE\`"
    fi
    ERROR_CONTENT="$ERROR_CONTENT\n\n---\n*Review by [FAIR](https://github.com/LearningCircuit/Friendly-AI-Reviewer) - needs human verification*"

    echo "{\"review\":\"$ERROR_CONTENT\",\"fail_pass_workflow\":\"uncertain\",\"labels_added\":[]}"

    # Log full response for debugging (will appear in GitHub Actions logs)
    echo "Full API response: $RESPONSE" >&2
    exit 1
fi

# Validate that CONTENT is valid JSON
if ! echo "$CONTENT" | jq . >/dev/null 2>&1; then
    # If not JSON, wrap it in JSON structure
    JSON_CONTENT="{\"review\":\"## 🤖 AI Code Review\n\n$CONTENT\n\n---\n*Review by [FAIR](https://github.com/LearningCircuit/Friendly-AI-Reviewer) - needs human verification*\",\"fail_pass_workflow\":\"uncertain\",\"labels_added\":[]}"
    echo "$JSON_CONTENT"
else
    # If already JSON, return as-is
    echo "$CONTENT"
fi
