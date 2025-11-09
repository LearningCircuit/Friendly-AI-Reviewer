# Friendly AI Reviewer Setup Guide

- Creates highly-customizable AI Reviews as PR comments.
- Installation: Just 2 files copied to your repo and an OpenRouter API Key in your secrets.
- Costs: $0.01 - $0.05 per review (even for large PRs with full context)
- **Example output**: https://github.com/LearningCircuit/local-deep-research/pull/1034#issuecomment-3508864021
  - **Why this example is great**: This PR shows the AI reviewer's iterative improvement process catching critical bugs and quality issues:
    - **Critical Bug Caught**: MODEL variable syntax error that would have silently failed in production
    - **Architecture Improvements**: Pushed from GPU-base → CPU-base pattern and eliminated 130 lines of duplication
    - **High-Priority Fixes**: Breaking change warnings, curl overwrite warnings, platform-specific gaps, nvidia-smi verification
    - **Quality Enhancements**: Consistent formatting, better documentation, removed outdated comments
    - **Final Approval**: After addressing all issues, the AI gave full approval - showing it doesn't infinitely continue
    - **Real Value**: Saved shipping a critical bug and forced better architecture decisions

This guide explains how to set up the automated AI PR review system using OpenRouter to analyze pull requests with your choice of AI model.

## What's New

**Latest Updates:**
- **Thinking Model Support**: Now supports advanced reasoning models like Kimi K2 that use `<thinking>` tags
- **Rich Context**: Includes PR descriptions, commit messages, and human comments for comprehensive reviews
- **Higher Token Limits**: Default 64k tokens for complete reviews without truncation
- **Smart Context Management**: Only fetches most recent AI review to save tokens
- **Enhanced Error Handling**: Robust parsing of various AI response formats

## Overview

The AI Code Reviewer provides automated, comprehensive code reviews covering:
- **Security** 🔒 - Hardcoded secrets, SQL injection, XSS, authentication issues, input validation
- **Performance** ⚡ - Inefficient algorithms, N+1 queries, memory issues, blocking operations
- **Code Quality** 🎨 - Readability, maintainability, error handling, naming conventions
- **Best Practices** 📋 - Coding standards, proper patterns, type safety, dead code

### Smart Label Integration 🏷️
The AI reviewer automatically fetches existing repository labels and provides them to the LLM for context:
- **Prefers existing labels** over creating new ones
- **Maintains labeling consistency** across pull requests
- **Reduces label clutter** by avoiding duplicates
- **Preserves repository conventions** for better organization

The review is posted as a single comprehensive comment on your pull request with appropriate labels automatically added.

## Setup Instructions

### 1. Get OpenRouter API Key

1. Go to [OpenRouter.ai](https://openrouter.ai/)
2. Sign up or log in
3. Navigate to API Keys section
4. Create a new API key
5. Copy the key (it starts with `sk-or-v1-...`)

### 2. Add API Key to GitHub Secrets

1. Go to your GitHub repository
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Name it: `OPENROUTER_API_KEY`
5. Paste your OpenRouter API key
6. Click **Add secret**

### 3. Configure Workflow (Optional)

The workflow is pre-configured with sensible defaults, but you can customize it by setting repository variables in **Settings** → **Secrets and variables** → **Actions** → **Variables**:

- **AI_MODEL**: Change the AI model (default: `moonshotai/kimi-k2-thinking`)
  - See [OpenRouter models](https://openrouter.ai/models) for options
  - Recommended: Models with reasoning capabilities (Kimi K2, o1, etc.)
- **AI_TEMPERATURE**: Adjust randomness (default: `0.1` for consistent reviews)
- **AI_MAX_TOKENS**: Maximum response length (default: `64000`)
  - High limit ensures comprehensive reviews without truncation
  - For large PRs with thinking models, this prevents cut-off responses
  - Adjust lower for cost savings on smaller PRs
- **MAX_DIFF_SIZE**: Maximum diff size in bytes (default: `800000` / 800KB)
- **DEBUG_MODE**: Enable debug logging (default: `false`)
  - ⚠️ Warning: Exposes code diff in workflow logs when enabled
  - Only enable temporarily for troubleshooting

## Usage

### Triggering AI Reviews

To trigger an AI review on a PR:

1. Go to the PR page
2. Click **Labels**
3. Add the label: `ai_code_review`

The review will automatically start and post results as a comment when complete.

### Re-running Reviews

To re-run the AI review after making changes:

1. Remove the `ai_code_review` label
2. Add the `ai_code_review` label again

This will generate a fresh review of the current PR state.

## Review Results

The AI posts a comprehensive comment analyzing your code across all focus areas. The review is meant to assist human reviewers, not replace them.

## Cost Estimation

Costs with the default Kimi K2 thinking model are very affordable. Based on real usage data:

**Typical Costs:**
- Small PR (< 1000 lines): $0.01 - $0.02
- Medium PR (1000-3000 lines): $0.02 - $0.04
- Large PR (3000+ lines): $0.04 - $0.06

**Example from a 20-commit PR with full context:**
- Input: ~5,000-9,000 tokens (diff + PR description + commits + human comments)
- Output: ~2,000-6,000 tokens (comprehensive review)
- **Total cost: $0.01 - $0.05 per review**

**Why So Affordable:**
- Kimi K2 has competitive pricing (~$0.001-$0.003 per 1k tokens)
- Smart context management (only most recent AI review, limited commit history)
- Most PRs are smaller than you think in token count
- The 64k token limit is a ceiling, not typical usage

**Cost varies based on:**
- PR size (larger diffs = more input tokens)
- Review complexity (detailed reviews = more output tokens)
- Number of human comments and commit messages included
- OpenRouter provider routing (prices vary slightly by provider)

Check [OpenRouter pricing](https://openrouter.ai/models) for current Kimi K2 rates.

## Customization

### Changing the Review Focus

Edit `ai-reviewer.sh` to modify the review prompt. The current focus areas are:
- Security (secrets, injection attacks, authentication)
- Performance (algorithms, queries, memory)
- Code Quality (readability, maintainability, error handling)
- Best Practices (standards, patterns, type safety)

You can adjust these to match your team's priorities.

## Troubleshooting

### Reviews Not Running

- Ensure the `ai_code_review` label is added (not just present)
- Check that `OPENROUTER_API_KEY` secret is correctly configured
- Verify GitHub Actions permissions are properly set

### API Errors

- Check OpenRouter API key validity
- Verify OpenRouter account has sufficient credits
- Review GitHub Actions logs for specific error messages

### Diff Too Large Error

If you get a "Diff is too large" error:
- Split your PR into smaller, focused changes
- Or increase `MAX_DIFF_SIZE` in the workflow file
- Default limit is 800KB (~200K tokens)

## Security Considerations

### ⚠️ **Important Privacy Notice for Private Repositories**

**This system sends the following data to external AI services:**
- **Complete code diffs** from your pull requests
- **Repository labels** (names, descriptions, colors)
- **GitHub Actions status** and previous AI review comments
- **Repository metadata** (name, PR numbers, etc.)

**For Private Repositories:**
- Your **proprietary code will be sent to OpenRouter/AI providers**
- Review the **data retention policies** of your chosen AI provider
- Consider whether this complies with your **company's security policies**
- Some organizations may require **self-hosted AI models** instead

### Data Flow Details

The workflow fetches and sends these repository elements to the AI:
1. **Code Changes**: Full diff of modified files
2. **PR Description**: Title and description text from the pull request
3. **Commit Messages**: Up to 15 most recent commit messages (excluding merges)
4. **Human Comments**: All comments from human reviewers on the PR
5. **Labels**: All repository labels with descriptions and colors
6. **Previous AI Review**: Most recent AI review comment only (limited to 10k chars)
7. **CI/CD Status**: GitHub Actions check runs and build statuses
8. **PR Metadata**: Pull request details, head SHA, repository information
9. **Files**: May include sensitive configuration files, keys, or credentials

### Recommended Mitigations

- **Review AI Provider Policies**: Check OpenRouter/data processor privacy policies
- **Use Environment Variables**: Ensure sensitive configs are excluded from diffs
- **Consider Self-Hosted**: For highly sensitive code, use local AI models
- **Team Approval**: Get security team approval for private repository use
- **Audit Trail**: Monitor which PRs trigger AI reviews

### General Security

- API keys are stored securely in GitHub Secrets and passed via environment variables
- Reviews only run when the `ai_code_review` label is manually added
- All API calls are made through secure HTTPS connections
- The workflow has minimal permissions (read contents, write PR comments)

## Support

For issues with:
- **OpenRouter API**: Check [OpenRouter documentation](https://openrouter.ai/docs)
- **GitHub Actions**: Check [GitHub Actions documentation](https://docs.github.com/en/actions)
- **Workflow issues**: Review the GitHub Actions logs for specific error details
