import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from enum import Enum, auto
import json
from pathlib import Path
import re
import subprocess
import time


VERSION = r"(0|[1-9][0-9]*)\.([0-9])\.([0-9])"
PUBSPEC_VERSION = re.compile(
    rf"^version:[ \t]+{VERSION}\+(0|[1-9][0-9]*)[ \t]*(?:#[^\r\n]*)?\r?$", re.M
)
MAX_SECONDS = 600
MAX_COMMAND_SECONDS = 20
BRANCH_REF = "refs/heads/master"


def release_version(tag):
    match = re.fullmatch(rf"v{VERSION}", tag)
    if not match:
        raise ValueError(f"Invalid release tag: {tag!r}")
    major, minor, patch = map(int, match.groups())
    return major, minor, patch, major * 100 + minor * 10 + patch


def pubspec_version(body):
    matches = PUBSPEC_VERSION.findall(body)
    if len(matches) != 1:
        raise ValueError("Expected one full version in pubspec.yaml")
    return tuple(map(int, matches[0]))


def version_text(version):
    return "{}.{}.{}+{}".format(*version) if version else "unavailable"


class RefreshError(Exception):
    pass


class DeadlineExceeded(RefreshError):
    pass


class MasterUpdate(Enum):
    SUPERSEDED = auto()
    UNCHANGED = auto()
    ADVANCED = auto()


class Budget:
    def __init__(self, seconds=MAX_SECONDS):
        self.deadline = time.monotonic() + seconds

    def remaining(self):
        seconds = self.deadline - time.monotonic()
        if seconds <= 0:
            raise DeadlineExceeded("10-minute verification deadline reached")
        return seconds

    def sleep(self, seconds):
        time.sleep(min(seconds, self.remaining()))

    def run(self, command, *, cwd=None, timeout=MAX_COMMAND_SECONDS):
        return subprocess.run(
            command, cwd=cwd, text=True, encoding="utf-8", errors="replace",
            capture_output=True, timeout=min(timeout, self.remaining()),
        )


def update_master(repo, tag, expected, budget):
    def run(*command, allow_failure=False):
        try:
            result = budget.run(command, cwd=repo)
        except subprocess.TimeoutExpired as error:
            if allow_failure:
                print("Git push timed out. Checking master before retrying", flush=True)
                return
            raise RefreshError(f"{' '.join(command[:2])} timed out") from error
        if result.returncode and not allow_failure:
            raise RefreshError(result.stderr.strip() or f"{command[0]} failed")
        if result.returncode:
            print(f"Git push failed: {result.stderr.strip()}", flush=True)
        return result.stdout

    # Each commit uses the newly fetched head as its parent. A regular push
    # rejects a concurrent head change, and the next fetch rechecks the version.
    for attempt in range(5):
        for delay in (2, 4, None):
            try:
                run("git", "fetch", "--no-tags", "--depth=1", "origin", BRANCH_REF)
                break
            except DeadlineExceeded:
                raise
            except RefreshError as error:
                if delay is None:
                    raise
                print(f"Git fetch failed. Retrying in {delay}s: {error}", flush=True)
                budget.sleep(delay)
        current = pubspec_version(run("git", "show", "FETCH_HEAD:pubspec.yaml"))
        if current[:3] > expected[:3]:
            print(f"Master has newer version {version_text(current)}. Skipping {tag}")
            return MasterUpdate.SUPERSEDED
        if current == expected:
            print(f"Confirmed master has {version_text(current)}")
            return MasterUpdate.ADVANCED if attempt else MasterUpdate.UNCHANGED
        if current > expected:
            raise RefreshError(
                f"Master has {version_text(current)} for {tag}. "
                f"Expected {version_text(expected)}. Refusing to lower the build number"
            )
        if attempt == 4:
            raise RefreshError(
                f"Could not advance master after four pushes. Master has {version_text(current)}"
            )

        run("git", "checkout", "--detach", "--force", "FETCH_HEAD")
        run("bash", ".github/scripts/set_version.sh", tag)
        if pubspec_version((repo / "pubspec.yaml").read_text(encoding="utf-8")) != expected:
            raise RefreshError("set_version.sh generated an unexpected version")
        run(
            "git", "-c", "user.name=github-actions[bot]",
            "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
            "commit", "-am", f"chore: version {tag[1:]}",
        )
        run("git", "push", "origin", f"HEAD:{BRANCH_REF}", allow_failure=True)
        # A push timeout may have happened after GitHub received the commit.
        # Always verify the actual remote head before any CDN request.
    raise AssertionError("Unreachable")


@dataclass(frozen=True)
class Response:
    status: str
    body: str = ""
    retry_after: str = ""

    def version(self):
        if self.status == "HTTP 200":
            try:
                return pubspec_version(self.body)
            except ValueError:
                pass
        return None


def request(url, budget):
    try:
        result = budget.run([
            "curl", "-q", "--silent", "--show-error",
            "--max-time", str(min(MAX_COMMAND_SECONDS, budget.remaining())),
            "--write-out", "\n%{http_code}\t%header{retry-after}", url,
        ])
    except subprocess.TimeoutExpired:
        return Response("timeout")
    if result.returncode == 28:
        return Response("timeout")
    if result.returncode:
        return Response(f"curl exit {result.returncode}")
    body, metadata = result.stdout.rsplit("\n", 1)
    status, retry_after = metadata.split("\t", 1)
    return Response(f"HTTP {status}", body, retry_after.strip())


def retry_delay(value):
    if value.isascii() and value.isdecimal():
        return int(value)
    if value:
        try:
            deadline = parsedate_to_datetime(value)
            if deadline.tzinfo is None:
                deadline = deadline.replace(tzinfo=timezone.utc)
            return max(0, (deadline - datetime.now(timezone.utc)).total_seconds())
        except (ValueError, OverflowError):
            pass
    return 0


def check_purge(response, path):
    if response.status != "HTTP 200":
        return False, response.status == "HTTP 429", response.status
    try:
        body = json.loads(response.body)
        status = body["status"]
        result = body["paths"][path]
        throttled, providers = result["throttled"], result["providers"]
    except (ValueError, KeyError, TypeError):
        return False, False, "HTTP 200 with an invalid purge response or missing path"
    accepted = (
        status == "finished" and throttled is False
        and isinstance(providers, dict) and providers
        and all(value is True for value in providers.values())
    )
    details = f"HTTP 200, status={status!r}, throttled={throttled!r}, providers={providers!r}"
    return bool(accepted), throttled is True, details


def refresh_cdn(repository, expected, budget, *, master_advanced=False):
    upstream_url = f"https://raw.githubusercontent.com/{repository}/master/pubspec.yaml"
    path = f"/gh/{repository}@master/pubspec.yaml"
    cdn_url = f"https://cdn.jsdelivr.net{path}"
    purge_url = f"https://purge.jsdelivr.net{path}"
    upstream, cdn = Response("not requested"), Response("not requested")
    last_cdn_version = None
    purge_ok, purge_status = True, "not requested"
    upstream_checks = cdn_checks = purges = 0
    next_purge = 0
    poll_delay = 15

    def confirm_upstream():
        nonlocal upstream, upstream_checks
        delay = 15
        while True:
            upstream = request(upstream_url, budget)
            upstream_checks += 1
            current = upstream.version()
            print(f"GitHub read {upstream_checks}: {upstream.status}, {version_text(current)}", flush=True)
            if current == expected:
                return True
            if current is not None and current[:3] > expected[:3]:
                print(f"Newer version {version_text(current)} published. Skipping refresh")
                return False
            budget.sleep(max(delay, retry_delay(upstream.retry_after)))
            delay = min(delay * 2, 60)

    try:
        if not confirm_upstream():
            return
        while True:
            cdn = request(cdn_url, budget)
            cdn_checks += 1
            current = cdn.version()
            if current is not None:
                last_cdn_version = current
            print(f"CDN read {cdn_checks}: {cdn.status}, {version_text(current)}", flush=True)
            if current == expected and purge_ok and (not master_advanced or purges > 0):
                budget.remaining()
                print(f"Verified jsDelivr serves {version_text(expected)} at {cdn_url}")
                return
            if current is not None and current[:3] > expected[:3]:
                if not confirm_upstream():
                    return
            purgeable = (
                (master_advanced and purges == 0)
                or cdn.status == "HTTP 404"
                or (cdn.status == "HTTP 200" and (current is None or current[:3] <= expected[:3]))
            )
            if purgeable and purges < 3 and time.monotonic() >= next_purge:
                if purges and not confirm_upstream():
                    return
                purge = request(purge_url, budget)
                purges += 1
                purge_ok, throttled, purge_status = check_purge(purge, path)
                prefix = "" if purge_ok else "::warning::"
                print(f"{prefix}jsDelivr purge {purges}: {purge_status}", flush=True)
                # Poll the client URL independently. Escalate the minimum gap
                # between purge requests and honor any longer server delay.
                cooldown = max(120 * purges, 300 if throttled else 0)
                cooldown = max(cooldown, retry_delay(purge.retry_after))
                next_purge = time.monotonic() + cooldown
                if not purge_ok:
                    print(f"Wait at least {cooldown:.0f}s from this attempt before repeating a purge")
                continue
            budget.sleep(max(poll_delay, retry_delay(cdn.retry_after)))
            poll_delay = min(poll_delay * 2, 60)
    except DeadlineExceeded as error:
        raise RefreshError(
            f"{error}. Expected={version_text(expected)}, "
            f"last CDN version={version_text(last_cdn_version)} ({cdn.status}, reads={cdn_checks}), "
            f"GitHub={version_text(upstream.version())} ({upstream.status}, reads={upstream_checks}), "
            f"purges={purges}, last purge={purge_status}"
        ) from error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", type=Path)
    parser.add_argument("repository")
    parser.add_argument("tag")
    args = parser.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repository, re.ASCII):
        parser.error("Invalid GitHub repository name")

    budget = Budget()
    try:
        expected = release_version(args.tag)
        update = update_master(args.repo, args.tag, expected, budget)
        if update is not MasterUpdate.SUPERSEDED:
            refresh_cdn(
                args.repository, expected, budget,
                master_advanced=update is MasterUpdate.ADVANCED,
            )
    except (RefreshError, ValueError) as error:
        parser.exit(
            1, f"::error::Installers were published. Update metadata failed: {error}\n"
        )


if __name__ == "__main__":
    main()
