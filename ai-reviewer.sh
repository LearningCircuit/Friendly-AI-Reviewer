#!/bin/bash

# AI Code Reviewer Script - Simple Comment Version
# Usage: OPENROUTER_API_KEY=xxx AI_MODEL=model AI_TEMPERATURE=0.1 AI_MAX_TOKENS=2000 echo "DIFF_CONTENT" | ./ai-reviewer.sh

set -e

# Constants
REVIEW_HEADER="## AI Code Review"
REVIEW_FOOTER="---\n*Review by [Friendly AI Reviewer](https://github.com/LearningCircuit/Friendly-AI-Reviewer) - made with ❤️*"

# Temp file tracking for cleanup
TEMP_FILES=()

# Helper function to generate error response JSON
generate_error_response() {
    local error_msg="$1"
    echo "{\"review\":\"$REVIEW_HEADER\n\n❌ **Error**: $error_msg\n\n$REVIEW_FOOTER\",\"fail_pass_workflow\":\"uncertain\",\"labels_added\":[]}"
}

# Debug logging helper
log_debug() {
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "$1" >&2
    fi
}

# Create a temp file and track it for cleanup
create_temp_file() {
    local tf
    tf=$(mktemp) || { echo "Failed to create temporary file"; exit 1; }
    chmod 600 "$tf"
    TEMP_FILES+=("$tf")
    echo "$tf"
}

# Cleanup all tracked temp files
cleanup_all() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}

# Set up trap for cleanup
trap cleanup_all EXIT

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

# Multi-model configuration
AI_MODELS="${AI_MODELS:-}"
AI_AGGREGATOR_MODEL="${AI_AGGREGATOR_MODEL:-}"
AI_AGGREGATOR_TEMPERATURE="${AI_AGGREGATOR_TEMPERATURE:-0.1}"
AI_AGGREGATOR_MAX_TOKENS="${AI_AGGREGATOR_MAX_TOKENS:-64000}"

# Context inclusion options (set to 'false' to disable, reduces token usage)
INCLUDE_PREVIOUS_REVIEWS="${INCLUDE_PREVIOUS_REVIEWS:-true}"
INCLUDE_HUMAN_COMMENTS="${INCLUDE_HUMAN_COMMENTS:-true}"
INCLUDE_CHECK_RUNS="${INCLUDE_CHECK_RUNS:-true}"
INCLUDE_LABELS="${INCLUDE_LABELS:-true}"
INCLUDE_PR_DESCRIPTION="${INCLUDE_PR_DESCRIPTION:-true}"
INCLUDE_COMMIT_MESSAGES="${INCLUDE_COMMIT_MESSAGES:-true}"

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

# ---------------------------------------------------------------------------
# Function: fetch_github_context
# Fetches PR description, commits, comments, checks, labels, previous reviews
# Sets global variables: PREVIOUS_REVIEWS, HUMAN_COMMENTS, CHECK_RUNS_STATUS,
#                        AVAILABLE_LABELS, PR_DESCRIPTION, COMMIT_MESSAGES
# ---------------------------------------------------------------------------
fetch_github_context() {
    # Fetch previous AI review (only the most recent one) for context
    PREVIOUS_REVIEWS=""
    if [ "$INCLUDE_PREVIOUS_REVIEWS" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
        # Fetch only the most recent AI review comment
        PREVIOUS_REVIEWS=$(gh api "repos/$REPO_FULL_NAME/issues/$PR_NUMBER/comments" \
            --jq '[.[] | select(.body | startswith("## AI Code Review"))] | last | if . then "### Previous AI Review (" + .created_at + "):\n" + .body + "\n---\n" else "" end' 2>/dev/null | head -c 10000 || echo "")
    fi

    # Fetch human comments for context
    HUMAN_COMMENTS=""
    if [ "$INCLUDE_HUMAN_COMMENTS" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
        # Fetch comments from humans (not the bot)
        HUMAN_COMMENTS=$(gh api "repos/$REPO_FULL_NAME/issues/$PR_NUMBER/comments" \
            --jq '[.[] | select(.body | startswith("## AI Code Review") | not)] | map("**" + .user.login + "** (" + .created_at + "):\n" + .body) | join("\n\n---\n\n")' 2>/dev/null | head -c 20000 || echo "")
    fi

    # Fetch GitHub Actions check runs status (if PR_NUMBER and REPO_FULL_NAME are set)
    CHECK_RUNS_STATUS=""
    if [ "$INCLUDE_CHECK_RUNS" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
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
    if [ "$INCLUDE_LABELS" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
        # Fetch all labels from the repository
        log_debug "🔍 Fetching available labels from repository..."
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
        log_debug "🔍 Fetching PR title and description..."
        PR_DESCRIPTION=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER" \
            --jq '"**PR Title**: " + .title + "\n\n**Description**:\n" + (.body // "No description provided")' 2>/dev/null | head -c 2000 || echo "")

        if [ "$DEBUG_MODE" = "true" ] && [ -n "$PR_DESCRIPTION" ]; then
            echo "✅ Successfully fetched PR description" >&2
        fi
    fi

    # Fetch commit messages (limit to 15 most recent, exclude merges)
    COMMIT_MESSAGES=""
    if [ "$INCLUDE_COMMIT_MESSAGES" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_FULL_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
        log_debug "🔍 Fetching commit messages..."
        COMMIT_MESSAGES=$(gh api "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER/commits" --paginate \
            --jq '[.[] | select(.commit.message | startswith("Merge") | not)] | .[-15:] | .[] | "- " + (.commit.message | split("\n")[0]) + (if (.commit.message | split("\n\n")[1]) then "\n  " + (.commit.message | split("\n\n")[1]) else "" end)' 2>/dev/null | head -c 2500 || echo "")

        if [ "$DEBUG_MODE" = "true" ] && [ -n "$COMMIT_MESSAGES" ]; then
            COMMIT_COUNT=$(echo "$COMMIT_MESSAGES" | grep -c "^- " || echo "0")
            echo "✅ Successfully fetched $COMMIT_COUNT commit messages" >&2
        fi
    fi
}

# ---------------------------------------------------------------------------
# Function: build_reviewer_prompt
# Builds the reviewer prompt text and writes it to PROMPT_FILE
# Uses globals: CHECK_RUNS_STATUS, AVAILABLE_LABELS, PR_DESCRIPTION,
#               COMMIT_MESSAGES, HUMAN_COMMENTS, PREVIOUS_REVIEWS, DIFF_CONTENT
# ---------------------------------------------------------------------------
build_reviewer_prompt() {
    # Build the user prompt using the diff file
    local PROMPT_PREFIX="Please analyze this code diff and provide a comprehensive review in markdown format.

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

    # Simple text prompt requesting JSON response
    PROMPT="You are an expert code reviewer. Please analyze this code diff and provide a comprehensive review.

Focus on security, performance, code quality, and best practices.

Focus on high-value issues. Style suggestions are welcome if impactful, but not minor optimizations. Be concise and dense - use bullet points for clear structure. Avoid repetition - in summary sections, only repeat critical issues (security, bugs, breaking changes). Important: Focus on issues directly visible in the diff. If you cannot verify something from the diff alone (e.g., missing context, unclear defaults, code not shown):
- Default: Skip the issue to avoid spam
- Only ask for clarification if it's critical (security vulnerabilities, breaking bugs, data loss risks): \"Cannot verify [X] from diff - please confirm [specific question]\"
- If making an inference about non-critical issues, explicitly label it: \"Inference (not verified): [observation]\"

Review Structure:
1. Start with a short overall feedback summary (1-2 sentences)
2. Always include a \"🔒 Security\" section. If no security concerns found, state \"No security concerns identified\"
3. Then provide other detailed findings (performance, code quality, best practices, etc.)
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

    PROMPT_FILE=$(create_temp_file)
    echo "$PROMPT" > "$PROMPT_FILE" || { echo "Failed to write prompt to temporary file"; exit 1; }
}

# ---------------------------------------------------------------------------
# Function: call_openrouter_api
# Args: model, prompt_file, response_file, max_tokens, temperature
# Calls OpenRouter API and writes raw response to response_file
# Uses global: API_KEY, REPO_FULL_NAME
# ---------------------------------------------------------------------------
call_openrouter_api() {
    local model="$1"
    local prompt_file="$2"
    local response_file="$3"
    local max_tokens="$4"
    local temperature="$5"

    # Use generic or repo-specific referer
    REFERER_URL="https://github.com/${REPO_FULL_NAME:-unknown/repo}"

    # Build JSON payload using jq with prompt file
    local json_payload
    json_payload=$(jq -n \
        --arg model "$model" \
        --rawfile content "$prompt_file" \
        --argjson temperature "$temperature" \
        --argjson max_tokens "$max_tokens" \
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
        }')

    echo "$json_payload" | curl -s -X POST "https://openrouter.ai/api/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -H "HTTP-Referer: $REFERER_URL" \
        --data-binary @- > "$response_file"
}

# ---------------------------------------------------------------------------
# Function: process_api_response
# Args: response_file, model_name
# Validates the API response, strips thinking tags, extracts JSON.
# Outputs the final JSON to stdout.
# ---------------------------------------------------------------------------
process_api_response() {
    local response_file="$1"
    local model_name="$2"

    local response
    response=$(cat "$response_file")

    # Check if API call was successful
    if [ -z "$response" ]; then
        generate_error_response "API call failed - no response received"
        return 1
    fi

    # Check if response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        echo "=== API DEBUG: Raw response from $model_name ===" >&2
        echo "$response" >&2
        echo "=== END API DEBUG ===" >&2
        generate_error_response "Invalid JSON response from API"
        return 1
    fi

    # Log the API response structure for debugging thinking models (if debug mode enabled)
    log_debug "=== API STRUCTURE DEBUG from $model_name ==="
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "Response keys: $(echo "$response" | jq -r 'keys | join(", ")')" >&2
        echo "Choices count: $(echo "$response" | jq '.choices | length')" >&2
        echo "First choice keys: $(echo "$response" | jq -r '.choices[0] | keys | join(", ")')" >&2
        echo "Content type: $(echo "$response" | jq -r '.choices[0].message | type')" >&2
        echo "=== END API STRUCTURE DEBUG ===" >&2
    fi

    # Extract the content
    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // "error"')

    # Log the extracted content from thinking model (if debug mode enabled)
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "=== CONTENT DEBUG: Extracted from $model_name ===" >&2
        echo "Content length: $(echo "$content" | wc -c)" >&2
        echo "Full content:" >&2
        echo "$content" >&2
        echo "=== END CONTENT DEBUG ===" >&2
    fi

    if [ "$content" = "error" ]; then
        # Try to extract error details from the API response
        local error_msg error_code
        error_msg=$(echo "$response" | jq -r '.error.message // "Invalid API response format"')
        error_code=$(echo "$response" | jq -r '.error.code // ""')

        # Return error as JSON
        local error_content="$REVIEW_HEADER\n\n❌ **Error**: $error_msg"
        if [ -n "$error_code" ]; then
            error_content="$error_content\n\nError code: \`$error_code\`"
        fi
        error_content="$error_content\n\n$REVIEW_FOOTER"

        echo "{\"review\":\"$error_content\",\"fail_pass_workflow\":\"uncertain\",\"labels_added\":[]}"

        # Don't log full response as it may contain sensitive API data
        # Only log error code for debugging
        if [ -n "$error_code" ]; then
            echo "API Error code: $error_code" >&2
        fi
        return 1
    fi

    # Ensure CONTENT is not empty
    if [ -z "$content" ]; then
        generate_error_response "AI returned empty response"
        return 0
    fi

    # Remove thinking tags and content - everything between <thinking> and </thinking>
    # Use perl for proper multiline and inline handling
    content=$(echo "$content" | perl -0pe 's/<thinking>.*?<\/thinking>\s*//gs')

    # Remove markdown code blocks if present (check for actual backticks at line start)
    if echo "$content" | grep -qE '^\s*```json'; then
        log_debug "=== REMOVING MARKDOWN CODE BLOCKS ==="
        # Remove the opening ```json and closing ``` lines, keep the content
        content=$(echo "$content" | perl -0pe 's/^\s*```json\s*\n//g; s/\n```\s*$//g')
    fi

    # Trim leading and trailing whitespace
    content=$(echo "$content" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Enhanced empty check (catches whitespace-only content)
    if [ -z "$content" ] || [ -z "$(echo "$content" | tr -d '[:space:]')" ]; then
        generate_error_response "AI returned empty response after processing"
        return 0
    fi

    # Validate that CONTENT is valid JSON
    if ! echo "$content" | jq . >/dev/null 2>&1; then
        log_debug "=== JSON VALIDATION FAILED ==="
        if [ "$DEBUG_MODE" = "true" ]; then
            echo "Content is not valid JSON" >&2
            echo "=== RAW CONTENT FOR DEBUG ===" >&2
            echo "$content" >&2
            echo "=== END DEBUG ===" >&2
        fi

        # Fallback to error response
        generate_error_response "Invalid JSON response from AI model"
    else
        log_debug "=== CONTENT IS VALID JSON ==="
        # Validate it has the required structure
        if ! echo "$content" | jq -e '.review' >/dev/null 2>&1; then
            log_debug "JSON missing required 'review' field"
            generate_error_response "AI response missing required review field"
        else
            log_debug "JSON has required structure, using as-is"
            echo "$content"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Function: run_single_reviewer
# Args: model, prompt_file, result_file
# Runs a single reviewer model and writes validated JSON to result_file.
# Designed to run in background (&) — no shared mutable state.
# ---------------------------------------------------------------------------
run_single_reviewer() {
    local model="$1"
    local prompt_file="$2"
    local result_file="$3"

    local response_file
    response_file=$(create_temp_file)

    log_debug "Starting review with model: $model"

    # Call the API
    call_openrouter_api "$model" "$prompt_file" "$response_file" "$AI_MAX_TOKENS" "$AI_TEMPERATURE" || true

    # Process the response and write to result file
    local result
    result=$(process_api_response "$response_file" "$model" 2>/dev/null || true)

    if [ -n "$result" ] && echo "$result" | jq -e '.review' >/dev/null 2>&1; then
        # Tag the result with the model name for later identification
        echo "$result" | jq --arg m "$model" '. + {model: $m}' > "$result_file"
        log_debug "Review completed successfully for model: $model"
    else
        # Write error marker
        echo "{\"error\":true,\"model\":\"$model\"}" > "$result_file"
        log_debug "Review failed for model: $model"
    fi
}

# ---------------------------------------------------------------------------
# Function: build_aggregator_prompt
# Args: output_file, review_files... (remaining args are review result files)
# Builds the aggregator prompt containing diff + individual reviews + PR context.
# ---------------------------------------------------------------------------
build_aggregator_prompt() {
    local output_file="$1"
    shift
    local review_files=("$@")

    local individual_reviews=""

    for rf in "${review_files[@]}"; do
        local model_name review_text verdict labels_str
        model_name=$(jq -r '.model // "unknown"' "$rf")
        review_text=$(jq -r '.review // ""' "$rf")
        verdict=$(jq -r '.fail_pass_workflow // "uncertain"' "$rf")
        labels_str=$(jq -r '.labels_added // [] | join(", ")' "$rf")

        individual_reviews="${individual_reviews}

---

### Review from ${model_name}
**Verdict**: ${verdict}
**Labels**: ${labels_str}

${review_text}

"
    done

    # Build PR context section
    local pr_context=""
    if [ -n "$PR_DESCRIPTION" ]; then
        pr_context="${pr_context}
Pull Request Context:
$PR_DESCRIPTION

"
    fi
    if [ -n "$CHECK_RUNS_STATUS" ]; then
        pr_context="${pr_context}
GitHub Actions Check Status:
$CHECK_RUNS_STATUS

"
    fi

    local aggregator_prompt="You are an expert code reviewer acting as an aggregator. Multiple AI models have independently reviewed the same code diff. Your job is to synthesize their reviews into a single, comprehensive, and non-redundant review.

## Instructions

1. Read the code diff below and form your own understanding
2. Read each individual model's review
3. Synthesize into a single review that:
   - Deduplicates overlapping findings
   - Resolves contradictions (prefer findings supported by multiple reviewers or directly visible in the diff)
   - Preserves unique insights from individual reviewers
   - Takes the most conservative verdict among the reviews (if any reviewer says \"Request changes\", use that)
   - Merges labels from all reviews, preferring existing repository labels

## Review Structure
1. Start with a short overall feedback summary (1-2 sentences)
2. Always include a \"🔒 Security\" section. If no security concerns found, state \"No security concerns identified\"
3. Then provide other detailed findings (performance, code quality, best practices, etc.)
4. End with one of these verdicts ONLY:
   - \"✅ Approved\" (no issues found)
   - \"✅ Approved with recommendations\" (minor improvements suggested, but not blocking)
   - \"❌ Request changes\" (critical issues that must be fixed before merge)

## Required JSON format
{
  \"review\": \"## AI Code Review\\n\\n[Your synthesized review in markdown format]\\n\\n---\\n*Review by [Friendly AI Reviewer](https://github.com/LearningCircuit/Friendly-AI-Reviewer) - made with ❤️*\",
  \"fail_pass_workflow\": \"pass\",
  \"labels_added\": [\"bug\", \"feature\", \"enhancement\"]
}

## Rules
1. Respond with a single valid JSON object
2. Include the Friendly AI Reviewer footer with heart emoji at the end of the review field
3. For labels_added, prefer existing repository labels when possible
4. Always end your review with one of the three verdict options listed above before the footer
5. Do NOT mention individual model names in your synthesized review

${pr_context}
## Individual Reviews (${#review_files[@]} reviews)
${individual_reviews}

## Code Diff

${DIFF_CONTENT}"

    echo "$aggregator_prompt" > "$output_file"
}

# ---------------------------------------------------------------------------
# Function: inject_collapsible_sections
# Args: aggregator_json, review_files...
# Takes the aggregator's JSON output and injects collapsible <details> sections
# for each individual model review.
# Outputs final JSON to stdout.
# ---------------------------------------------------------------------------
inject_collapsible_sections() {
    local aggregator_json="$1"
    shift
    local review_files=("$@")

    local total_count=${#review_files[@]}
    local success_count=0
    local failed_models=()
    local success_models=()

    # Categorize reviews
    for rf in "${review_files[@]}"; do
        local model_name has_error
        model_name=$(echo "$aggregator_json" | jq -r '.model // empty' 2>/dev/null)  # not from aggregator
        model_name=$(jq -r '.model // "unknown"' "$rf")
        has_error=$(jq -r '.error // false' "$rf")
        if [ "$has_error" = "true" ]; then
            failed_models+=("$model_name")
        else
            success_models+=("$model_name")
            success_count=$((success_count + 1))
        fi
    done

    # Extract the aggregator's review content
    local review_content
    review_content=$(echo "$aggregator_json" | jq -r '.review')

    # Build the collapsible section header
    local collapsible="

---

<details>
<summary><strong>Individual Model Reviews</strong> (${success_count} of ${total_count} succeeded)</summary>"

    for rf in "${review_files[@]}"; do
        local model_name has_error review_text
        model_name=$(jq -r '.model // "unknown"' "$rf")
        has_error=$(jq -r '.error // false' "$rf")

        if [ "$has_error" = "true" ]; then
            collapsible="${collapsible}

<details>
<summary>${model_name} (failed)</summary>

*This model failed to produce a review.*

</details>"
        else
            review_text=$(jq -r '.review // ""' "$rf")
            # Remove the footer from individual reviews in the collapsible section
            review_text=$(echo "$review_text" | sed '/^\*Review by \[Friendly AI Reviewer\]/d' | sed '/^---$/,$ { /^---$/d; /^\*Review by \[Friendly AI Reviewer\]/d; }')
            collapsible="${collapsible}

<details>
<summary>${model_name}</summary>

${review_text}

</details>"
        fi
    done

    collapsible="${collapsible}

</details>"

    # Split the review at the final "---" separator and insert collapsible block
    # The review ends with: ... content \n\n---\n*Review by ...
    # We want to insert before the final ---
    local footer_line="*Review by [Friendly AI Reviewer](https://github.com/LearningCircuit/Friendly-AI-Reviewer) - made with ❤️*"
    local final_separator="---"

    # Check if the review ends with the standard footer pattern
    if echo "$review_content" | grep -qF "$footer_line"; then
        # Find the last occurrence of the separator line before the footer
        # Split into body and footer
        local body footer
        # Extract everything before the final "---\n*Review by..." pattern
        body=$(echo "$review_content" | sed ':a;N;$!ba;s/\n---\n\*Review by \[Friendly AI Reviewer\].*$//')
        footer="${final_separator}
${footer_line}"

        local new_review="${body}${collapsible}

${footer}"
        # Return the updated JSON
        echo "$aggregator_json" | jq --arg r "$new_review" '.review = $r'
    else
        # No standard footer found — just append collapsible section
        local new_review="${review_content}${collapsible}"
        echo "$aggregator_json" | jq --arg r "$new_review" '.review = $r'
    fi
}

# ---------------------------------------------------------------------------
# Function: run_multi_model_review
# Orchestrates multi-model review: fan-out, fan-in, aggregate.
# ---------------------------------------------------------------------------
run_multi_model_review() {
    # Parse AI_MODELS into array
    IFS=',' read -ra MODEL_ARRAY <<< "$AI_MODELS"

    local model_count=${#MODEL_ARRAY[@]}
    log_debug "Multi-model review: $model_count models configured"

    if [ "$model_count" -eq 0 ]; then
        generate_error_response "AI_MODELS is set but empty"
        return 1
    fi

    # Build the reviewer prompt (shared across all models)
    build_reviewer_prompt

    # Fan-out: launch each model in background
    local pids=()
    local result_files=()

    for model in "${MODEL_ARRAY[@]}"; do
        # Trim whitespace
        model=$(echo "$model" | xargs)
        [ -z "$model" ] && continue

        local result_file
        result_file=$(create_temp_file)
        result_files+=("$result_file")

        log_debug "Launching background review for: $model"
        run_single_reviewer "$model" "$PROMPT_FILE" "$result_file" &
        pids+=($!)
    done

    # Wait for all background jobs
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    log_debug "All reviewer models completed"

    # Collect successful results
    local successful_files=()
    local failed_count=0

    for rf in "${result_files[@]}"; do
        if [ -f "$rf" ] && jq -e '.review' "$rf" >/dev/null 2>&1; then
            successful_files+=("$rf")
        else
            failed_count=$((failed_count + 1))
        fi
    done

    local success_count=${#successful_files[@]}
    log_debug "Reviews: $success_count succeeded, $failed_count failed"

    # If all failed, return error
    if [ "$success_count" -eq 0 ]; then
        generate_error_response "All reviewer models failed to produce reviews"
        return 1
    fi

    # Determine aggregator model
    local agg_model="${AI_AGGREGATOR_MODEL}"
    if [ -z "$agg_model" ]; then
        # Use first model from the list
        agg_model=$(echo "${MODEL_ARRAY[0]}" | xargs)
    fi
    log_debug "Using aggregator model: $agg_model"

    # Build aggregator prompt
    local agg_prompt_file
    agg_prompt_file=$(create_temp_file)
    build_aggregator_prompt "$agg_prompt_file" "${successful_files[@]}"

    # Call aggregator
    local agg_response_file
    agg_response_file=$(create_temp_file)

    call_openrouter_api "$agg_model" "$agg_prompt_file" "$agg_response_file" "$AI_AGGREGATOR_MAX_TOKENS" "$AI_AGGREGATOR_TEMPERATURE" || true

    local agg_result
    agg_result=$(process_api_response "$agg_response_file" "$agg_model (aggregator)" 2>/dev/null || true)

    local final_json

    if [ -n "$agg_result" ] && echo "$agg_result" | jq -e '.review' >/dev/null 2>&1; then
        log_debug "Aggregator completed successfully"
        # Inject collapsible sections for ALL models (including failed ones)
        final_json=$(inject_collapsible_sections "$agg_result" "${result_files[@]}")
    else
        # Aggregator failed — fall back to first successful individual review
        log_debug "Aggregator failed, falling back to first successful individual review"
        local fallback_file="${successful_files[0]}"
        local fallback_json
        fallback_json=$(cat "$fallback_file")
        # Inject collapsible sections and remove model tag
        final_json=$(inject_collapsible_sections "$fallback_json" "${result_files[@]}" | jq 'del(.model)')
    fi

    # Remove internal model tag from final output
    echo "$final_json" | jq 'del(.model)'
}

# ===========================================================================
# Main execution
# ===========================================================================

# Fetch GitHub context (PR description, commits, comments, checks, labels)
fetch_github_context

# Dispatch based on single-model vs multi-model
if [ -n "$AI_MODELS" ]; then
    run_multi_model_review
else
    # Single-model path — identical to original behavior
    # Write diff to temporary file
    DIFF_FILE=$(create_temp_file)
    echo "$DIFF_CONTENT" > "$DIFF_FILE" || { echo "Failed to write diff to temporary file"; exit 1; }

    build_reviewer_prompt

    RESPONSE_FILE=$(create_temp_file)
    call_openrouter_api "$AI_MODEL" "$PROMPT_FILE" "$RESPONSE_FILE" "$AI_MAX_TOKENS" "$AI_TEMPERATURE"
    process_api_response "$RESPONSE_FILE" "$AI_MODEL"
fi
