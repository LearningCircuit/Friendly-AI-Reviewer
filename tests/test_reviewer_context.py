"""Exercise the real reviewer request with local GitHub/OpenRouter substitutes.

Run with: python3 -m unittest discover -s tests -v
No network requests or model calls are made.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ai-reviewer.sh"
HEADER = "## AI Code Review"
MARKER = "<!-- ai-code-review:sticky -->"
FOOTER = (
    "---\n*Review by [Friendly AI Reviewer]"
    "(https://github.com/LearningCircuit/Friendly-AI-Reviewer) - made with ❤️*"
)
CLEAN_REVIEW = {
    "review": f"{HEADER}\n\nNo actionable findings.\n\n✅ Approved\n\n{FOOTER}",
    "fail_pass_workflow": "pass",
    "labels_added": ["tests"],
}


def comment(body, login="reviewer[bot]", user_type="Bot"):
    return {
        "body": body,
        "user": {"login": login, "type": user_type},
        "created_at": "2026-09-12T10:00:00Z",
    }


def pull_commit(sha, message, login=None, name=None, merge=False):
    parents = [{"sha": f"{sha}-parent-1"}, {"sha": f"{sha}-parent-2"}] if merge else [{"sha": f"{sha}-parent-1"}]
    return {
        "sha": sha,
        "parents": parents,
        "author": {"login": login} if login is not None else None,
        "commit": {"author": {"name": name or login or "unknown"}, "message": message},
    }


class ReviewerRequestTests(unittest.TestCase):
    def run_reviewer(
        self,
        comments=(),
        *,
        previous=True,
        human=True,
        response=None,
        config=None,
        pull_commits=None,
        commit_stats=None,
        check_runs=None,
        labels=None,
        pr=None,
        fail_comments=False,
        fail_commits=False,
    ):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "comments.json").write_text(json.dumps(comments))
            (path / "pull-commits.json").write_text(
                json.dumps(pull_commits if pull_commits is not None else [])
            )
            (path / "commit-stats.json").write_text(json.dumps(commit_stats or {}))
            (path / "pr.json").write_text(json.dumps(
                pr if pr is not None else {"number": 123, "head": {"sha": "abc"}}
            ))
            if fail_comments:
                (path / "fail-comments").write_text("")
            if fail_commits:
                (path / "fail-commits").write_text("")
            (path / "check-runs.json").write_text(json.dumps(
                {"total_count": len(check_runs or []), "check_runs": check_runs or []}
            ))
            (path / "labels.json").write_text(json.dumps(labels or []))
            expected = response if response is not None else CLEAN_REVIEW
            (path / "response.json").write_text(json.dumps({
                "choices": [{
                    "message": {"content": json.dumps(expected)},
                    "finish_reason": "stop",
                }],
            }))
            stubs = {
                "gh": '''import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == "api", args
path = Path(os.environ["FIXTURE_DIR"])
with (path / "gh-calls.jsonl").open("a") as calls:
    calls.write(json.dumps(args) + "\\n")
parts = args[1].split("?")[0].split("/")[3:]
if parts == ["issues", "123", "comments"]:
    assert args[2:] == ["--paginate"], args
    comments = json.loads((path / "comments.json").read_text())
    # Emulate gh api --paginate: one JSON array per page, GitHub's default
    # page size of 30, oldest first.
    for start in range(0, len(comments), 30):
        sys.stdout.write(json.dumps(comments[start:start + 30]))
    # A mid-stream failure flag: pages already written, then gh exits 1 —
    # the partial-payload scenario the fetch discipline must reject.
    if (path / "fail-comments").exists():
        sys.exit(1)
    sys.exit(0)
if parts == ["pulls", "123", "commits"]:
    assert args[2:] == ["--paginate"], args
    if (path / "fail-commits").exists():
        sys.exit(1)
    sys.stdout.write((path / "pull-commits.json").read_text())
    sys.exit(0)
if parts == ["pulls", "123"]:
    assert len(args) == 2, args
    sys.stdout.write((path / "pr.json").read_text())
    sys.exit(0)
if parts == ["commits", "abc", "check-runs"]:
    assert args[2:] == ["--paginate"], args
    document = json.loads((path / "check-runs.json").read_text())
    runs = document["check_runs"]
    for start in range(0, len(runs), 30):
        sys.stdout.write(json.dumps(
            {"total_count": len(runs), "check_runs": runs[start:start + 30]}
        ))
    sys.exit(0)
if parts == ["labels"]:
    assert args[2:] == ["--paginate"], args
    sys.stdout.write((path / "labels.json").read_text())
    sys.exit(0)
if len(parts) == 2 and parts[0] == "commits":
    assert args[2] == "--jq" and len(args) == 4, args
    stats = json.loads((path / "commit-stats.json").read_text())
    assert parts[1] in stats, parts[1]
    result = subprocess.run(["jq", "-r", args[3]],
                            input=json.dumps(stats[parts[1]]), text=True)
    sys.exit(result.returncode)
sys.exit(f"unexpected gh api call: {args}")
''',
                "curl": '''import os, sys
from pathlib import Path
assert "https://openrouter.ai/api/v1/chat/completions" in sys.argv
assert sys.argv[-2:] == ["--data-binary", "@-"]
path = Path(os.environ["FIXTURE_DIR"])
(path / "request.json").write_text(sys.stdin.read())
print((path / "response.json").read_text())
''',
            }
            for name, source in stubs.items():
                stub = path / name
                stub.write_text(f"#!{sys.executable}\n{source}")
                stub.chmod(0o755)
            # Do not inherit real credentials or unrelated reviewer configuration.
            environment = {
                "PATH": f"{path}{os.pathsep}{os.defpath}",
                "FIXTURE_DIR": str(path),
                "OPENROUTER_API_KEY": "fake-openrouter-key",
                "GITHUB_TOKEN": "fake-github-token",
                "PR_NUMBER": "123",
                "REPO_FULL_NAME": "example/repo",
                "INCLUDE_PREVIOUS_REVIEWS": str(previous).lower(),
                "INCLUDE_HUMAN_COMMENTS": str(human).lower(),
                "INCLUDE_CHECK_RUNS": "false",
                "INCLUDE_LABELS": "false",
                "INCLUDE_PR_DESCRIPTION": "false",
                "INCLUDE_COMMIT_MESSAGES": "false",
                "INCLUDE_COMMIT_SUMMARY": "false",
            }
            environment.update(config or {})
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                input="diff --git a/file.py b/file.py\n+print('example')\n",
                text=True, capture_output=True, env=environment, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), expected)
            calls_file = path / "gh-calls.jsonl"
            calls = calls_file.read_text().splitlines() if calls_file.exists() else []
            self.gh_calls = [json.loads(call) for call in calls]
            # Every call must belong to a known context feature, and the
            # comment list is fetched exactly once (shared by the previous-
            # review and human-comment features) whenever either is enabled.
            categorized = (self.comment_calls() + self.commit_calls()
                           + self.check_calls() + self.label_calls())
            self.assertEqual(len(self.gh_calls), len(categorized))
            self.assertEqual(len(self.comment_calls()), int(bool(previous or human)))
            return json.loads((path / "request.json").read_text())

    def comment_calls(self):
        """GitHub API calls made for comment context."""
        return [
            call for call in getattr(self, "gh_calls", [])
            if "/issues/123/comments" in call[1]
        ]

    def commit_calls(self):
        """GitHub API calls made for the commit history features."""
        return [
            call for call in getattr(self, "gh_calls", [])
            if "pulls/123/commits" in call[1]
            or ("/commits/" in call[1] and "check-runs" not in call[1])
        ]

    def check_calls(self):
        """GitHub API calls made for the check-runs context."""
        return [
            call for call in getattr(self, "gh_calls", [])
            if call[1].endswith("/pulls/123") or call[1].endswith("/check-runs")
        ]

    def label_calls(self):
        """GitHub API calls made for the label context."""
        return [
            call for call in getattr(self, "gh_calls", [])
            if call[1].endswith("/labels")
        ]

    def test_concise_instructions_preserve_review_depth_and_protocol(self):
        request = self.run_reviewer(previous=False, human=False)
        prompt = request["messages"][0]["content"]
        self.assertIn("Analyze this code diff thoroughly", prompt)
        self.assertIn("omit praise, change summaries, empty sections", prompt)
        for tag in ("must fix", "should fix", "nit"):
            self.assertIn(f'"{tag}"', prompt)
        self.assertIn("order findings must fix first, then should fix, then nits", prompt)
        self.assertIn('label every inference explicitly as "Inference (not verified):', prompt)
        self.assertIn('add it to a final "Should be checked" section', prompt)
        self.assertIn("omit the section entirely when there is nothing meaningful to check", prompt)
        self.assertIn("file and line location, concrete failure scenario, impact", prompt)
        self.assertIn('write only "No actionable findings." before the verdict', prompt)
        self.assertNotIn("Always include a", prompt)
        self.assertNotIn("short overall feedback summary", prompt)
        self.assertIn(HEADER, prompt)
        self.assertIn(FOOTER.replace("\n", "\\n"), prompt)
        for verdict in (
            "✅ Approved", "✅ Approved with recommendations", "❌ Request changes"
        ):
            self.assertIn(verdict, prompt)
        schema = request["response_format"]["json_schema"]["schema"]
        self.assertEqual(set(schema["required"]), set(CLEAN_REVIEW))
        self.assertEqual(schema["properties"]["fail_pass_workflow"]["enum"],
                         ["pass", "fail", "uncertain"])
        self.assertEqual(request["max_tokens"], 64000)
        self.assertEqual(request["temperature"], 0.1)
        self.assertEqual(request["model"], "z-ai/glm-5.3")

    def test_sticky_review_is_only_previous_ai_context(self):
        body = f"{MARKER}\n## Review results\nSticky AI review content"
        request = self.run_reviewer([comment(body), comment("Human feedback", "alice", "User")])
        prompt = request["messages"][0]["content"]
        self.assertIn("Previous AI Review (for context", prompt)
        human_context, previous_context = prompt.split("Previous AI Review (for context", 1)
        self.assertIn("Human feedback", human_context)
        self.assertNotIn(body, human_context)
        self.assertIn(body, previous_context)
        self.assertEqual(prompt.count(body), 1)

    def test_only_latest_legacy_bot_review_is_included(self):
        old = f"{HEADER}\nOld AI review"
        latest = f"{HEADER}\nLatest AI review"
        request = self.run_reviewer([comment(old), comment(latest)])
        prompt = request["messages"][0]["content"]
        self.assertNotIn(old, prompt)
        self.assertIn(latest, prompt)
        self.assertNotIn("Human Comments on this PR:", prompt)

    def test_humans_quoting_review_identifiers_remain_human(self):
        bodies = [f"{HEADER}\nA human uses the header", f"Quoted {MARKER} in feedback"]
        request = self.run_reviewer([
            comment(body, f"human-{index}", "User")
            for index, body in enumerate(bodies)
        ])
        prompt = request["messages"][0]["content"]
        self.assertIn("Human Comments on this PR (newest first):", prompt)
        self.assertNotIn("Previous AI Review (for context", prompt)
        for body in bodies:
            self.assertEqual(prompt.count(body), 1)

    def test_bot_identity_is_detected_by_type_or_login(self):
        for login, user_type in [("app-name", "Bot"), ("app-name[bot]", None)]:
            with self.subTest(login=login, user_type=user_type):
                body = f"{MARKER}\nIdentified bot review"
                request = self.run_reviewer([comment(body, login, user_type)])
                prompt = request["messages"][0]["content"]
                self.assertIn(body, prompt)
                self.assertIn("Previous AI Review (for context", prompt)
                self.assertNotIn("Human Comments on this PR:", prompt)

    def test_other_bot_comments_are_not_human_or_previous_review_context(self):
        request = self.run_reviewer([
            comment("Unrelated bot status"), comment(None),
            comment("Human feedback", "alice", "User"),
        ])
        prompt = request["messages"][0]["content"]
        self.assertNotIn("Unrelated bot status", prompt)
        self.assertNotIn("Previous AI Review (for context", prompt)
        self.assertIn("Human feedback", prompt)

    def test_disabling_previous_reviews_does_not_leak_them_into_human_context(self):
        body = f"{MARKER}\nDisabled previous AI review"
        request = self.run_reviewer([
            comment(body), comment("Human feedback", "alice", "User")
        ], previous=False)
        prompt = request["messages"][0]["content"]
        self.assertNotIn(body, prompt)
        self.assertIn("Human feedback", prompt)

    def test_disabling_human_context_keeps_previous_review(self):
        body = f"{MARKER}\nPrevious AI review"
        request = self.run_reviewer([
            comment(body), comment("Human feedback", "alice", "User")
        ], human=False)
        prompt = request["messages"][0]["content"]
        self.assertIn(body, prompt)
        self.assertNotIn("Human feedback", prompt)

    def test_actionable_output_and_custom_budget_are_preserved(self):
        findings = {
            "review": (
                f"{HEADER}\n\n- **must fix** — file.py:12: Passing an empty list "
                "raises IndexError, failing the request. Check the list before "
                "indexing.\n- **nit** — file.py:40: \"Inference (not verified): \" "
                "the loop could early-exit.\n\nShould be checked:\n- Cannot verify "
                "the migration is reversible from diff - please confirm a "
                f"downgrade path exists.\n\n❌ Request changes\n\n{FOOTER}"
            ),
            "fail_pass_workflow": "fail",
            "labels_added": ["bug", "tests"],
        }
        request = self.run_reviewer(
            previous=False, human=False, response=findings,
            config={"AI_MAX_TOKENS": "12345", "STRUCTURED_OUTPUT": "false"},
        )
        self.assertEqual(request["max_tokens"], 12345)
        self.assertNotIn("response_format", request)

    def commit_fixture(self):
        commits = [
            # A subject starting with "Merge" on a single-parent commit: the
            # exact parents-based predicate must count it.
            pull_commit("a0", "MergeableHashMap: fix iteration", login="dana"),
            pull_commit("a1", "feat: first", login="alice"),
            pull_commit("a2", "feat: second", login="alice"),
            pull_commit("a3", "fix: bob fix", name="Bob B"),
            pull_commit("a4", "Merge branch 'x' into main", login="alice", merge=True),
            pull_commit("a5", "feat: third", login="carol"),
        ]
        stats = {
            "a0": {"stats": {"additions": 6, "deletions": 2}},
            "a1": {"stats": {"additions": 10, "deletions": 2}},
            "a2": {"stats": {"additions": 20, "deletions": 3}},
            "a3": {"stats": {"additions": 5, "deletions": 8}},
            "a5": {"stats": {"additions": 1, "deletions": 1}},
        }
        return commits, stats

    def test_commit_summary_counts_authors_and_lines(self):
        commits, stats = self.commit_fixture()
        request = self.run_reviewer(
            previous=False, human=False,
            pull_commits=commits, commit_stats=stats,
            config={"INCLUDE_COMMIT_SUMMARY": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn(
            "There are 5 commits already on this PR (excluding 1 merge commit(s))",
            prompt,
        )
        self.assertIn("across all 5 commits", prompt)
        self.assertIn("- **alice**: 2 commits, +30/-5 lines", prompt)
        self.assertIn("- **Bob B**: 1 commit, +5/-8 lines", prompt)
        self.assertIn("- **carol**: 1 commit, +1/-1 lines", prompt)
        # The merge-sounding subject is counted, not skipped.
        self.assertIn("- **dana**: 1 commit, +6/-2 lines", prompt)
        # Bullet order follows added lines, so the biggest author leads.
        self.assertLess(
            prompt.index("- **alice**"), prompt.index("- **carol**"),
        )
        # Line stats are fetched per listed non-merge commit only.
        stats_urls = [call[1] for call in self.commit_calls() if "/pulls/" not in call[1]]
        self.assertEqual(len(stats_urls), 5)
        self.assertFalse(any("a4" in url for url in stats_urls), stats_urls)
        # Only the summary block is present when messages are disabled.
        self.assertNotIn("Commit History (showing development journey):", prompt)

    def test_commit_summary_limit_is_independent_of_message_limit(self):
        commits, stats = self.commit_fixture()
        request = self.run_reviewer(
            previous=False, human=False,
            pull_commits=commits, commit_stats=stats,
            config={
                "INCLUDE_COMMIT_SUMMARY": "true",
                "INCLUDE_COMMIT_MESSAGES": "true",
                "MAX_SUMMARY_COMMITS": "1",
            },
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("across the 1 most recent of 5 commits", prompt)
        self.assertIn("- **carol**: 1 commit, +1/-1 lines", prompt)
        self.assertNotIn("- **alice**:", prompt)
        # The message list keeps its own default cap (3) and still shows
        # recent history beyond the overview's single-commit scope.
        self.assertIn("- feat: second", prompt)
        self.assertNotIn("- feat: first", prompt)
        stats_urls = [call[1] for call in self.commit_calls() if "/pulls/" not in call[1]]
        self.assertEqual(len(stats_urls), 1)

    def test_commit_message_limit_is_configurable(self):
        commits, stats = self.commit_fixture()
        request = self.run_reviewer(
            previous=False, human=False,
            pull_commits=commits, commit_stats=stats,
            config={"INCLUDE_COMMIT_MESSAGES": "true", "MAX_COMMIT_MESSAGES": "2"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("Commit History (showing development journey):", prompt)
        self.assertIn("- feat: third", prompt)
        self.assertIn("- fix: bob fix", prompt)
        self.assertNotIn("- feat: first", prompt)
        self.assertNotIn("- feat: second", prompt)
        self.assertNotIn("Commit Summary:", prompt)
        # No per-commit stats calls when the summary is disabled.
        stats_urls = [call[1] for call in self.commit_calls() if "/pulls/" not in call[1]]
        self.assertEqual(stats_urls, [])

    def test_commit_summary_zero_reads_no_individual_commits(self):
        commits, stats = self.commit_fixture()
        request = self.run_reviewer(
            previous=False, human=False,
            pull_commits=commits, commit_stats=stats,
            config={"INCLUDE_COMMIT_SUMMARY": "true", "MAX_SUMMARY_COMMITS": "0"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("There are 5 commits already on this PR", prompt)
        self.assertNotIn("Per-author", prompt)
        # One list call only: zero individual commit reads.
        urls = [call[1] for call in self.commit_calls()]
        self.assertEqual(len(urls), 1)
        self.assertIn("pulls/123/commits", urls[0])

    def test_commit_summary_singular_count_and_fallback_author(self):
        commits = [pull_commit("solo", "fix: solo commit", name="Dana D")]
        request = self.run_reviewer(
            previous=False, human=False,
            pull_commits=commits, commit_stats={"solo": {"stats": {"additions": 4, "deletions": 1}}},
            config={"INCLUDE_COMMIT_SUMMARY": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("There is 1 commit already on this PR", prompt)
        self.assertIn("- **Dana D**: 1 commit, +4/-1 lines", prompt)

    def test_check_runs_summarize_successes_and_list_non_passing(self):
        request = self.run_reviewer(
            previous=False, human=False,
            check_runs=[
                {"name": "lint", "status": "completed", "conclusion": "success"},
                {"name": "unit-tests (3/8)", "status": "completed", "conclusion": "success"},
                {"name": "e2e-playwright", "status": "completed", "conclusion": "failure"},
                {"name": "ui-shard-2", "status": "completed", "conclusion": "skipped"},
                {"name": "docker-build", "status": "in_progress"},
            ],
            config={"INCLUDE_CHECK_RUNS": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("2 of 5 checks passed. Non-passing checks:", prompt)
        self.assertIn("- **e2e-playwright**: completed (failure)", prompt)
        self.assertIn("- **ui-shard-2**: completed (skipped)", prompt)
        self.assertIn("- **docker-build**: in_progress", prompt)
        # Successful runs (including matrix shards) collapse into the count.
        self.assertNotIn("- **lint**", prompt)
        self.assertNotIn("- **unit-tests", prompt)
        self.assertEqual(len(self.check_calls()), 2)

    def test_check_runs_all_passed_collapses_to_one_line(self):
        request = self.run_reviewer(
            previous=False, human=False,
            check_runs=[
                {"name": "lint", "status": "completed", "conclusion": "success"},
                {"name": "unit-tests", "status": "completed", "conclusion": "success"},
            ],
            config={"INCLUDE_CHECK_RUNS": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("All 2 checks passed.", prompt)
        self.assertNotIn("Non-passing", prompt)
        self.assertNotIn("- **lint**", prompt)

    def test_labels_instruction_and_list_stay_complete(self):
        request = self.run_reviewer(
            previous=False, human=False,
            labels=[
                {"name": "bug", "description": "Something is broken", "color": "d73a4a"},
                {"name": "ui", "description": "Touches the web stack", "color": "0366d6"},
            ],
            config={"INCLUDE_LABELS": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("Only apply labels that are genuinely useful", prompt)
        self.assertIn("add none rather than stretching a label to fit", prompt)
        # The label list itself stays complete — no trimming of data.
        self.assertIn("- **bug**: Something is broken (color: #d73a4a)", prompt)
        self.assertIn("- **ui**: Touches the web stack (color: #0366d6)", prompt)

    def test_human_comments_keep_newest_within_count_cap(self):
        comments = [
            comment("older feedback that must drop", "alice", "User"),
            comment("newest feedback that must survive", "bob", "User"),
        ]
        request = self.run_reviewer(comments, previous=False,
                                    config={"MAX_HUMAN_COMMENTS": "1"})
        prompt = request["messages"][0]["content"]
        self.assertIn("Human Comments on this PR (newest first):", prompt)
        self.assertIn("newest feedback that must survive", prompt)
        self.assertNotIn("older feedback that must drop", prompt)

    def test_human_comment_length_cap_marks_truncation(self):
        body = "x" * 30
        request = self.run_reviewer(
            [comment(body, "alice", "User")], previous=False,
            config={"MAX_HUMAN_COMMENT_LENGTH": "10"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("x" * 10 + " […truncated]", prompt)
        self.assertNotIn("x" * 11, prompt)

    def test_human_comments_total_budget_marks_truncation(self):
        request = self.run_reviewer(
            [comment("y" * 60, "alice", "User")], previous=False,
            config={"MAX_HUMAN_COMMENTS_TOTAL": "50"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("[…truncated at 50 bytes]", prompt)

    def test_multibyte_comment_survives_a_byte_boundary_clip(self):
        # The budget lands mid-emoji. Without stripping the partial UTF-8
        # sequence, jq 1.7 substitutes U+FFFD (verified: it exits 0 and
        # silently corrupts the clipped text; older jq rejects outright) —
        # the assertNotIn below is what pins the guard, since the request
        # otherwise builds fine. The header is 34 bytes, so a 39-byte
        # budget keeps one complete 4-byte emoji and cuts one byte into
        # the next.
        request = self.run_reviewer(
            [comment("😀" * 20, "alice", "User")], previous=False,
            config={"MAX_HUMAN_COMMENTS_TOTAL": "39"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("😀", prompt)
        self.assertIn("[…truncated at 39 bytes]", prompt)
        self.assertNotIn("\ufffd", prompt)

    def test_partial_comment_fetch_failure_drops_context(self):
        # gh fails after emitting valid pages (mid-pagination rate limit):
        # the emitted prefix must be discarded, not posing as the full list.
        request = self.run_reviewer(
            [comment("latest human feedback", "alice", "User")],
            previous=False, fail_comments=True,
        )
        prompt = request["messages"][0]["content"]
        self.assertNotIn("Human Comments on this PR", prompt)
        self.assertNotIn("latest human feedback", prompt)

    def test_commits_fetch_failure_skips_history_context(self):
        commits, stats = self.commit_fixture()
        request = self.run_reviewer(
            previous=False, human=False, pull_commits=commits, commit_stats=stats,
            fail_commits=True,
            config={"INCLUDE_COMMIT_MESSAGES": "true", "INCLUDE_COMMIT_SUMMARY": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertNotIn("Commit Summary:", prompt)
        self.assertNotIn("Commit History", prompt)

    def test_previous_review_multibyte_clip_is_clean(self):
        # "### Previous AI Review (ts):\n" + the marker line + 9900 r's put
        # the 10000-byte cut 21 bytes into the emoji run: five complete
        # emoji survive, the sixth is cut mid-sequence and stripped.
        sticky = comment(f"{MARKER}\n" + "r" * 9900 + "😀" * 10 + "\n\n✅ Approved")
        request = self.run_reviewer([sticky], human=False)
        prompt = request["messages"][0]["content"]
        self.assertIn("Previous AI Review (for context", prompt)
        self.assertIn("[…truncated at 10000 bytes]", prompt)
        self.assertIn("😀", prompt)
        self.assertNotIn("\ufffd", prompt)

    def test_per_comment_clip_slices_by_character_not_byte(self):
        # jq slices by codepoints: a mixed multibyte body clips at a
        # character boundary, never mid-sequence.
        request = self.run_reviewer(
            [comment("αβγ😀ϵζη", "alice", "User")], previous=False,
            config={"MAX_HUMAN_COMMENT_LENGTH": "5"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("αβγ😀ϵ […truncated]", prompt)
        self.assertNotIn("ζη", prompt)
        self.assertNotIn("\ufffd", prompt)

    def test_no_pr_fetch_when_no_feature_needs_it(self):
        self.run_reviewer(previous=False, human=False)
        pulls_calls = [call for call in self.gh_calls if call[1].endswith("/pulls/123")]
        self.assertEqual(pulls_calls, [])

    def test_commit_message_body_is_indented_under_subject(self):
        commits = [pull_commit("c1", "subject line\n\nbody paragraph", login="alice")]
        request = self.run_reviewer(
            previous=False, human=False, pull_commits=commits,
            config={"INCLUDE_COMMIT_MESSAGES": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("- subject line\n  body paragraph", prompt)

    def test_pr_description_clip_is_marked(self):
        request = self.run_reviewer(
            previous=False, human=False,
            pr={"number": 123, "head": {"sha": "abc"},
                "title": "A change", "body": "d" * 3000},
            config={"INCLUDE_PR_DESCRIPTION": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("**PR Title**: A change", prompt)
        self.assertIn("[…truncated at 2000 bytes]", prompt)

    def test_pr_object_fetched_once_for_description_and_check_runs(self):
        request = self.run_reviewer(
            previous=False, human=False,
            check_runs=[{"name": "lint", "status": "completed", "conclusion": "success"}],
            pr={"number": 123, "head": {"sha": "abc"}, "title": "T", "body": "B"},
            config={"INCLUDE_CHECK_RUNS": "true", "INCLUDE_PR_DESCRIPTION": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("**PR Title**: T", prompt)
        self.assertIn("All 1 checks passed.", prompt)
        pulls_calls = [call for call in self.gh_calls if call[1].endswith("/pulls/123")]
        self.assertEqual(len(pulls_calls), 1, pulls_calls)

    def test_non_passing_check_list_is_capped(self):
        request = self.run_reviewer(
            previous=False, human=False,
            check_runs=[
                {"name": f"fail-{index}", "status": "completed", "conclusion": "failure"}
                for index in range(25)
            ],
            config={"INCLUDE_CHECK_RUNS": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("0 of 25 checks passed. Non-passing checks:", prompt)
        self.assertIn("- **fail-19**:", prompt)
        self.assertIn("+ 5 more non-passing run(s) not listed", prompt)
        self.assertNotIn("- **fail-20**", prompt)

    def test_human_comments_exactly_filling_budget_are_not_marked(self):
        # "**alice** (2026-09-12T10:00:00Z):\n" is 34 characters; a 16-char
        # body makes the block exactly 50 — no clip, so no marker.
        request = self.run_reviewer(
            [comment("z" * 16, "alice", "User")], previous=False,
            config={"MAX_HUMAN_COMMENTS_TOTAL": "50"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("z" * 16, prompt)
        self.assertNotIn("[…truncated", prompt)

    def test_human_comments_clipped_after_trailing_newlines_still_marked(self):
        # The comment body ends in blank lines: command substitution strips
        # them from the clipped result, which must not hide the cut.
        request = self.run_reviewer(
            [comment("w" * 60 + "\n\n\n", "alice", "User")], previous=False,
            config={"MAX_HUMAN_COMMENTS_TOTAL": "50"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("[…truncated at 50 bytes]", prompt)

    def test_human_comments_reach_beyond_the_first_page(self):
        # GitHub's default page holds 30 comments, oldest first. The newest
        # comments live on later pages; the selection must span all of them.
        many = [comment(f"feedback number {index}", f"user-{index}", "User")
                for index in range(1, 41)]
        request = self.run_reviewer(many, previous=False,
                                    config={"MAX_HUMAN_COMMENTS": "10"})
        prompt = request["messages"][0]["content"]
        self.assertIn("feedback number 40", prompt)
        self.assertIn("feedback number 31", prompt)
        self.assertNotIn("feedback number 30", prompt)
        self.assertNotIn("feedback number 1", prompt)
        # One shared paginated fetch, not one call per page or per feature.
        self.assertEqual(len(self.comment_calls()), 1)
        self.assertEqual(self.comment_calls()[0][2:], ["--paginate"])

    def test_previous_review_found_beyond_the_first_page(self):
        many = [comment(f"noise {index}", f"user-{index}", "User")
                for index in range(35)]
        sticky = comment(f"{MARKER}\nLatest AI review beyond page one")
        request = self.run_reviewer(many + [sticky], human=False)
        prompt = request["messages"][0]["content"]
        self.assertIn("Latest AI review beyond page one", prompt)
        self.assertNotIn("noise 0", prompt)

    def test_commit_messages_clip_is_marked(self):
        commits = [
            pull_commit(f"c{i}", f"feat: {i}\n\n" + "m" * 1100, login="alice")
            for i in range(3)
        ]
        request = self.run_reviewer(
            previous=False, human=False, pull_commits=commits,
            config={"INCLUDE_COMMIT_MESSAGES": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("[…truncated at 2500 bytes]", prompt)

    def test_check_run_summary_spans_all_pages(self):
        request = self.run_reviewer(
            previous=False, human=False,
            check_runs=[
                {"name": f"shard-{index}", "status": "completed", "conclusion": "success"}
                for index in range(35)
            ] + [{"name": "e2e", "status": "completed", "conclusion": "failure"}],
            config={"INCLUDE_CHECK_RUNS": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn("35 of 36 checks passed. Non-passing checks:", prompt)
        self.assertIn("- **e2e**: completed (failure)", prompt)
        self.assertNotIn("- **shard-0**", prompt)

    def test_previous_review_clip_is_marked(self):
        sticky = comment(f"{MARKER}\n" + "r" * 11000 + "\n\n✅ Approved")
        request = self.run_reviewer([sticky], human=False)
        prompt = request["messages"][0]["content"]
        self.assertIn("Previous AI Review (for context", prompt)
        self.assertIn("[…truncated at 10000 bytes]", prompt)

    def test_commit_summary_reports_unavailable_line_stats(self):
        commits = [
            pull_commit("ok1", "feat: one", login="alice"),
            pull_commit("bad1", "feat: two", login="alice"),
        ]
        # Only ok1 has stats; the fetch for bad1 fails (the stub rejects
        # unknown shas), which must be reported instead of reading as +0/-0.
        request = self.run_reviewer(
            previous=False, human=False,
            pull_commits=commits,
            commit_stats={"ok1": {"stats": {"additions": 7, "deletions": 2}}},
            config={"INCLUDE_COMMIT_SUMMARY": "true"},
        )
        prompt = request["messages"][0]["content"]
        self.assertIn(
            "There are 2 commits already on this PR "
            "(line stats unavailable for 1 commit(s))",
            prompt,
        )

    def test_workflow_forwards_every_configurable_script_knob(self):
        root = Path(__file__).resolve().parents[1]
        script = (root / "ai-reviewer.sh").read_text()
        workflow = (root / ".github" / "workflows" / "ai-code-reviewer.yml").read_text()
        # Every ${VAR:-default} knob in the script must have a forwarding
        # line in the workflow, derived from the script itself so a new knob
        # fails this test until it is forwarded. Per-run values that come
        # from the event (not repository variables) are excluded.
        knobs = sorted(set(re.findall(r"\$\{([A-Z][A-Z_]+):-", script)))
        self.assertIn("AI_MODEL", knobs)
        self.assertIn("MAX_HUMAN_COMMENTS_TOTAL", knobs)
        not_repository_variables = {"REPO_FULL_NAME"}
        for name in knobs:
            if name in not_repository_variables:
                continue
            self.assertIn(name + ": ${{ vars." + name, workflow, name)


if __name__ == "__main__":
    unittest.main()
