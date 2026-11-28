from contextlib import redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import refresh_release_version as refresh


REPOSITORY = "gallhall/venera-v"
PATH = f"/gh/{REPOSITORY}@master/pubspec.yaml"
CDN = f"https://cdn.jsdelivr.net{PATH}"
PURGE = f"https://purge.jsdelivr.net{PATH}"
UPSTREAM = f"https://raw.githubusercontent.com/{REPOSITORY}/master/pubspec.yaml"
TAG = "v3.2.0"
EXPECTED = (3, 2, 0, 320)


def file_response(version):
    return refresh.Response("HTTP 200", f"name: venera\nversion: {version}\n")


CURRENT = file_response("3.2.0+320")
STALE = file_response("3.1.1+311")
HTTP_REQUEST = refresh.request


def purge_response(*, providers=None, status="finished", throttled=False):
    return refresh.Response("HTTP 200", json.dumps({
        "status": status,
        "paths": {PATH: {
            "throttled": throttled,
            "providers": {"CF": True, "FY": True} if providers is None else providers,
        }},
    }))


class CdnTest(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.calls = []
        self.output = StringIO()
        self.upstream = [CURRENT]
        self.cdn = [STALE]
        self.purge = [purge_response()]
        for context in (
            patch.object(refresh.time, "monotonic", lambda: self.now),
            patch.object(refresh.time, "sleep", self.advance),
            patch.object(refresh, "request", self.request),
            redirect_stdout(self.output),
        ):
            self.enterContext(context)

    def advance(self, seconds):
        self.now += seconds

    def request(self, url, budget):
        budget.remaining()
        self.calls.append((url, self.now))
        responses = {UPSTREAM: self.upstream, CDN: self.cdn, PURGE: self.purge}[url]
        return responses.pop(0) if len(responses) > 1 else responses[0]

    def run_refresh(self, *, master_advanced=False):
        refresh.refresh_cdn(
            REPOSITORY, EXPECTED, refresh.Budget(), master_advanced=master_advanced,
        )

    def purge_times(self):
        return [when for url, when in self.calls if url == PURGE]

    def test_verifies_the_exact_client_url_after_purge(self):
        self.cdn = [STALE, CURRENT]
        self.run_refresh()
        self.assertEqual([url for url, _ in self.calls], [UPSTREAM, CDN, PURGE, CDN])
        self.assertIn("Verified jsDelivr serves 3.2.0+320", self.output.getvalue())

    def test_already_current_needs_no_purge(self):
        self.cdn = [CURRENT]
        self.run_refresh()
        self.assertEqual([url for url, _ in self.calls], [UPSTREAM, CDN])

    def test_master_advance_requires_purge_even_if_first_read_is_current(self):
        self.cdn = [CURRENT]
        self.run_refresh(master_advanced=True)
        self.assertEqual([url for url, _ in self.calls], [UPSTREAM, CDN, PURGE, CDN])

    def test_waits_for_github_and_checks_full_build_number(self):
        self.upstream = [STALE, file_response("3.2.0+321"), CURRENT]
        self.cdn = [file_response("3.2.0+319"), file_response("3.2.0+321"), CURRENT]
        self.run_refresh()
        self.assertEqual(
            self.calls, [(UPSTREAM, 0), (UPSTREAM, 15), (UPSTREAM, 45),
                         (CDN, 45), (PURGE, 45), (CDN, 45), (CDN, 60)],
        )

    def test_successful_purge_with_stale_content_fails_at_deadline(self):
        with self.assertRaisesRegex(
            refresh.RefreshError,
            r"10-minute.*Expected=3\.2\.0\+320.*last CDN version=3\.1\.1\+311 "
            r"\(HTTP 200, reads=\d+\).*purges=3.*last purge=HTTP 200",
        ):
            self.run_refresh()
        self.assertEqual(self.now, 600)
        first, second, third = self.purge_times()
        self.assertGreaterEqual(second - first, 120)
        self.assertGreaterEqual(third - second, 240)

    def test_stale_after_purge_can_converge_before_next_purge(self):
        self.cdn = [STALE, STALE, CURRENT]
        self.run_refresh()
        self.assertEqual(self.purge_times(), [0])
        self.assertEqual(self.now, 15)

    def test_invalid_cached_pubspec_can_be_purged(self):
        self.cdn = [refresh.Response("HTTP 200", "incomplete response"), CURRENT]
        self.run_refresh()
        self.assertEqual(self.purge_times(), [0])

    def test_honors_retry_after_for_rate_limit_and_converges(self):
        self.purge = [refresh.Response("HTTP 429", retry_after="400"), purge_response()]
        self.cdn = [STALE]
        request = self.request

        def read(url, budget):
            if url == CDN and len(self.purge_times()) == 2:
                self.cdn = [CURRENT]
            return request(url, budget)

        with patch.object(refresh, "request", read):
            self.run_refresh()
        first, second = self.purge_times()
        self.assertGreaterEqual(second - first, 400)
        self.assertIn("HTTP 429", self.output.getvalue())

    def test_http_200_throttled_preserves_cooldown(self):
        self.purge = [purge_response(throttled=True)]
        with self.assertRaises(refresh.RefreshError):
            self.run_refresh()
        self.assertEqual(len(self.purge_times()), 2)
        self.assertGreaterEqual(self.purge_times()[1], 300)
        self.assertIn("throttled=True", self.output.getvalue())

    def test_http_200_body_failures_are_not_accepted(self):
        for response in (
            purge_response(status="running"),
            purge_response(providers={"CF": True, "FY": False}),
            purge_response(providers={}),
            purge_response(providers={"CF": 1}),
            refresh.Response("HTTP 200", '{"status":"finished","paths":{}}'),
            refresh.Response("HTTP 200", "<html>bad gateway</html>"),
        ):
            with self.subTest(response=response):
                self.assertFalse(refresh.check_purge(response, PATH)[0])
        self.purge = [purge_response(providers={"CF": True, "FY": False})]
        with self.assertRaisesRegex(refresh.RefreshError, r"last purge=.*'FY': False"):
            self.run_refresh()
        self.assertIn("::warning::jsDelivr purge", self.output.getvalue())

    def test_current_cdn_content_does_not_mask_failed_purge(self):
        self.cdn = [STALE, CURRENT]
        self.purge = [purge_response(providers={"CF": True, "FY": False})]
        with self.assertRaisesRegex(refresh.RefreshError, r"last purge=.*'FY': False"):
            self.run_refresh()

    def test_timeout_is_retried_and_reported_if_it_persists(self):
        self.cdn = [refresh.Response("timeout"), STALE, refresh.Response("timeout"), CURRENT]
        self.run_refresh()
        self.assertEqual(len(self.purge_times()), 1)

        self.cdn = [STALE, refresh.Response("timeout")]
        with self.assertRaisesRegex(
            refresh.RefreshError, r"last CDN version=3\.1\.1\+311 \(timeout, reads=\d+\)"
        ):
            self.run_refresh()

    def test_never_purges_if_upstream_version_cannot_be_verified(self):
        self.upstream = [STALE]
        with self.assertRaisesRegex(refresh.RefreshError, r"GitHub=3\.1\.1\+311 \(HTTP 200"):
            self.run_refresh()
        self.assertTrue(all(url == UPSTREAM for url, _ in self.calls))

    def test_newer_release_visible_before_next_purge(self):
        self.upstream = [CURRENT, file_response("3.2.1+321")]
        self.run_refresh()
        self.assertEqual(self.purge_times(), [0])

    def test_curl_enforces_timeout_and_preserves_retry_after(self):
        budget = refresh.Budget()
        with patch.object(budget, "run", side_effect=subprocess.TimeoutExpired("curl", 20)):
            self.assertEqual(HTTP_REQUEST(CDN, budget).status, "timeout")
        result = subprocess.CompletedProcess("curl", 0, "message\n429\t120", "")
        with patch.object(budget, "run", return_value=result) as run:
            self.assertEqual(HTTP_REQUEST(PURGE, budget), refresh.Response("HTTP 429", "message", "120"))
            self.assertIn("--max-time", run.call_args.args[0])


class GitTest(unittest.TestCase):
    def setUp(self):
        temp = self.enterContext(TemporaryDirectory())
        root = Path(temp)
        remote = root / "origin.git"
        seed = root / "seed"
        seed.mkdir()
        self.git(root, "init", "--bare", "--initial-branch=master", str(remote))
        self.git(seed, "init", "--initial-branch=master")
        self.git(seed, "config", "user.name", "Release fixture")
        self.git(seed, "config", "user.email", "test@example.invalid")
        (seed / ".github/scripts").mkdir(parents=True)
        (seed / "lib/foundation").mkdir(parents=True)
        script = Path(refresh.__file__).with_name("set_version.sh")
        (seed / ".github/scripts/set_version.sh").write_text(
            script.read_text(encoding="utf-8"), encoding="utf-8", newline="\n"
        )
        self.set_version(seed, "3.1.1", 311)
        self.commit(seed)
        self.git(seed, "remote", "add", "origin", remote.as_uri())
        self.git(seed, "push", "origin", "master")
        self.repo, self.rival = root / "repo", root / "rival"
        for checkout in (self.repo, self.rival):
            self.git(root, "clone", "--depth=1", "-c", "core.autocrlf=false",
                     remote.as_uri(), str(checkout))
        self.budget = refresh.Budget()
        self.enterContext(redirect_stdout(StringIO()))

    def git(self, repo, *args):
        result = subprocess.run(
            ("git", *args), cwd=repo, capture_output=True, text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def set_version(self, repo, version, build):
        (repo / "pubspec.yaml").write_text(f"version: {version}+{build}\n", encoding="utf-8")
        (repo / "lib/foundation/app.dart").write_text(
            f'final version = "{version}";\n', encoding="utf-8"
        )

    def commit(self, repo):
        self.git(repo, "add", ".")
        self.git(repo, "-c", "user.name=Fixture", "-c", "user.email=test@example.invalid",
                 "commit", "-m", "Fixture commit")

    def version_on_master(self):
        self.git(self.rival, "fetch", "origin", refresh.BRANCH_REF)
        return refresh.pubspec_version(self.git(self.rival, "show", "FETCH_HEAD:pubspec.yaml"))

    def update(self, tag=TAG, expected=EXPECTED):
        return refresh.update_master(self.repo, tag, expected, self.budget)

    def test_pushes_and_verifies_master_then_skips_an_older_rerun(self):
        self.assertIs(self.update(), refresh.MasterUpdate.ADVANCED)
        self.assertEqual(self.version_on_master(), EXPECTED)
        self.assertIs(self.update(), refresh.MasterUpdate.UNCHANGED)
        self.assertIs(
            self.update("v3.1.1", (3, 1, 1, 311)), refresh.MasterUpdate.SUPERSEDED,
        )
        self.assertEqual(self.version_on_master(), EXPECTED)

    def test_same_release_with_wrong_higher_build_is_not_a_successful_skip(self):
        self.set_version(self.rival, "3.2.0", 321)
        self.commit(self.rival)
        self.git(self.rival, "push", "origin", "master")
        with self.assertRaisesRegex(refresh.RefreshError, "Refusing to lower the build number"):
            self.update()
        self.assertEqual(self.version_on_master(), (3, 2, 0, 321))

    def test_retries_fetch_timeout_after_push(self):
        run = self.budget.run
        fetches = 0

        def timeout_once(command, **kwargs):
            nonlocal fetches
            if command[:2] == ("git", "fetch"):
                fetches += 1
                if fetches == 2:
                    raise subprocess.TimeoutExpired(command, 20)
            return run(command, **kwargs)

        with patch.object(self.budget, "run", timeout_once), patch.object(self.budget, "sleep"):
            self.assertIs(self.update(), refresh.MasterUpdate.ADVANCED)
        self.assertEqual(fetches, 3)
        self.assertEqual(self.version_on_master(), EXPECTED)

    def test_legacy_release_cannot_downgrade_its_master_checkout(self):
        self.set_version(self.repo, "3.2.0", 320)
        command = ("bash", ".github/scripts/set_version.sh", "v3.1.1")
        result = subprocess.run(
            command, cwd=self.repo, env={**os.environ, "GITHUB_JOB": "Release"},
            capture_output=True, text=True, timeout=20,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace master version 3.2.0+320 with 3.1.1+311", result.stderr)
        self.assertEqual(refresh.pubspec_version((self.repo / "pubspec.yaml").read_text()), EXPECTED)

        result = subprocess.run(
            command, cwd=self.repo, env={**os.environ, "GITHUB_JOB": "Build_Android"},
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(refresh.pubspec_version((self.repo / "pubspec.yaml").read_text()), (3, 1, 1, 311))

    def interleave_pushes(self, rival_update):
        run = self.budget.run
        pushes = []

        def interleave(command, **kwargs):
            if command[:2] == ("git", "push"):
                pushes.append(command)
                if len(pushes) == 1:
                    rival_update()
                    self.commit(self.rival)
                    self.git(self.rival, "push", "origin", "master")
            return run(command, **kwargs)

        return pushes, patch.object(self.budget, "run", interleave)

    def test_concurrent_newer_release_cannot_be_rolled_back(self):
        pushes, interleave = self.interleave_pushes(lambda: self.set_version(self.rival, "3.2.1", 321))
        with interleave:
            self.assertIs(self.update(), refresh.MasterUpdate.SUPERSEDED)
        self.assertEqual(len(pushes), 1)
        self.assertEqual(self.version_on_master(), (3, 2, 1, 321))

    def test_concurrent_unrelated_change_is_preserved_on_retry(self):
        pushes, interleave = self.interleave_pushes(
            lambda: (self.rival / "README.md").write_text("Concurrent edit\n", encoding="utf-8")
        )
        with interleave:
            self.assertIs(self.update(), refresh.MasterUpdate.ADVANCED)
        self.assertEqual(len(pushes), 2)
        self.assertEqual(self.version_on_master(), EXPECTED)
        self.assertEqual(self.git(self.rival, "show", "FETCH_HEAD:README.md"), "Concurrent edit")


if __name__ == "__main__":
    unittest.main()
