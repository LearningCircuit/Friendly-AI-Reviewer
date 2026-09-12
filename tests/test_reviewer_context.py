"""Exercise the real reviewer request with local GitHub/OpenRouter substitutes.

Run with: python3 -m unittest discover -s tests -v
No network requests or model calls are made.
"""

import json
import os
from pathlib import Path
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


class ReviewerRequestTests(unittest.TestCase):
    def run_reviewer(
        self, comments=(), *, previous=True, human=True, response=None, config=None
    ):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "comments.json").write_text(json.dumps(comments))
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
assert args[:2] == ["api", "repos/example/repo/issues/123/comments"], args
assert args[2] == "--jq" and len(args) == 4, args
path = Path(os.environ["FIXTURE_DIR"])
with (path / "gh-calls.jsonl").open("a") as calls:
    calls.write(json.dumps(args) + "\\n")
result = subprocess.run(["jq", "-r", args[3]],
                        input=(path / "comments.json").read_text(), text=True)
sys.exit(result.returncode)
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
            self.assertEqual(len(calls), int(previous) + int(human))
            return json.loads((path / "request.json").read_text())

    def test_concise_instructions_preserve_review_depth_and_protocol(self):
        request = self.run_reviewer(previous=False, human=False)
        prompt = request["messages"][0]["content"]
        self.assertIn("Analyze this code diff thoroughly", prompt)
        self.assertIn("omit praise, change summaries, empty sections", prompt)
        self.assertIn("ordered by severity", prompt)
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
        self.assertEqual(request["model"], "minimax/minimax-m2.5")

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
        self.assertIn("Human Comments on this PR:", prompt)
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
                f"{HEADER}\n\n- [High] file.py:12: Passing an empty list raises "
                "IndexError, failing the request. Check the list before indexing."
                f"\n\n❌ Request changes\n\n{FOOTER}"
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


if __name__ == "__main__":
    unittest.main()
