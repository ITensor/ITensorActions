#!/usr/bin/env python3

# Tag missing versions of a subdir package at the commit recorded in each
# version's General-registry PR.
#
# Replaces JuliaRegistries/TagBot's subdir handling. Upstream TagBot resolves
# version -> commit by walking `git log` in reverse-chronological order and
# keeping the first commit whose subdir tree matches the registered tree.
# When later commits on the trunk leave the subdir untouched, that fast path
# picks a non-registered commit; the slow path that reads `Commit:` from the
# registry PR body never runs because the fast path has already returned.
#
# This script always uses the commit recorded in the registry PR, with a
# sanity check that the subdir tree at that commit matches the registered
# `git-tree-sha1`.
#
# Idempotent: existing tags are never modified. Versions whose tag already
# points at the registered commit are skipped silently. Versions whose tag
# points at the wrong commit are skipped and reported (correction is a
# separate, deliberate operation, not a side-effect of every TagBot run).
#
# Inputs (env):
#   TAG_REPO          owner/name of the package repo (default: GITHUB_REPOSITORY)
#   TAG_SUBDIR        subdir name within the repo (e.g. "NDTensors")
#   TAG_PACKAGE_NAME  registered package name (default: TAG_SUBDIR)
#   TAG_DRY_RUN       "true" to log without mutating
#   GH_TOKEN          token for `gh api`

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass

GENERAL = "JuliaRegistries/General"


@dataclass
class GhResult:
    code: int
    stdout: str
    stderr: str


def gh(*args: str, check: bool = True) -> GhResult:
    res = subprocess.run(
        ["gh", "api", *args], capture_output=True, text=True
    )
    if check and res.returncode != 0:
        sys.stderr.write(res.stdout)
        sys.stderr.write(res.stderr)
        raise SystemExit(f"gh api failed: {' '.join(args)}")
    return GhResult(res.returncode, res.stdout, res.stderr)


def gh_json(*args: str):
    return json.loads(gh(*args).stdout)


def get_or_none_404(*args: str):
    res = gh(*args, check=False)
    if res.code == 0:
        return json.loads(res.stdout)
    if "HTTP 404" in res.stderr or "Not Found" in res.stderr:
        return None
    sys.stderr.write(res.stdout)
    sys.stderr.write(res.stderr)
    raise SystemExit(f"gh api failed: {' '.join(args)}")


# ---- General registry helpers ----


def registry_dir(name: str) -> str:
    if not name or not name[0].isalpha():
        raise SystemExit(f"package name {name!r} has no alpha first character; can't locate in General")
    return f"{name[0].upper()}/{name}"


def registry_file(name: str, filename: str) -> str:
    path = f"{registry_dir(name)}/{filename}"
    obj = gh_json(f"repos/{GENERAL}/contents/{path}")
    return base64.b64decode(obj["content"]).decode()


# Versions.toml is `["VERSION"]` headers with a `git-tree-sha1 = "..."` line each.
# Pure regex parser keeps this script free of TOML dependencies and is exact for
# the documented format. Lines starting with `#` (comments) and other keys are
# ignored; only the version header and tree-sha1 are read.
_VERSION_HEADER = re.compile(r'^\["([^"]+)"\]\s*$', re.M)
_TREE_SHA = re.compile(r'^\s*git-tree-sha1\s*=\s*"([0-9a-f]{40})"\s*$', re.M)


def parse_versions(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    headers = list(_VERSION_HEADER.finditer(text))
    for i, m in enumerate(headers):
        version = m.group(1)
        block_start = m.end()
        block_end = headers[i + 1].start() if i + 1 < len(headers) else len(text)
        sha = _TREE_SHA.search(text, block_start, block_end)
        if not sha:
            raise SystemExit(f"Versions.toml: no git-tree-sha1 for {version!r}")
        out[version] = sha.group(1)
    return out


_REPO_RE = re.compile(r'^\s*repo\s*=\s*"([^"]+)"\s*$', re.M)
_UUID_RE = re.compile(r'^\s*uuid\s*=\s*"([^"]+)"\s*$', re.M)
_NAME_RE = re.compile(r'^\s*name\s*=\s*"([^"]+)"\s*$', re.M)


def parse_package(text: str) -> dict:
    def grab(rx: re.Pattern, label: str) -> str:
        m = rx.search(text)
        if not m:
            raise SystemExit(f"Package.toml: missing {label}")
        return m.group(1)
    return {"name": grab(_NAME_RE, "name"), "uuid": grab(_UUID_RE, "uuid"), "repo": grab(_REPO_RE, "repo")}


# ---- Registry PR ----


def registrator_branch(name: str, uuid: str, version: str, repo_url: str) -> str:
    # Mirrors RegistryTools.jl `registration_branch`:
    # registrator-<lowercase_name>-<uuid[1:8]>-v<version>-<sha256(url)[1:10]>.
    # Note the URL hash is sha256, not sha1.
    h = hashlib.sha256(repo_url.encode()).hexdigest()[:10]
    return f"registrator-{name.lower()}-{uuid[:8]}-v{version}-{h}"


def find_registry_pr(branch: str):
    # Use the deterministic head-branch lookup. JuliaRegistrator pushes the
    # branch into the JuliaRegistries/General repo itself (not a fork), so
    # the head owner is `JuliaRegistries`.
    prs = gh_json(
        f"repos/{GENERAL}/pulls",
        "-X", "GET",
        "-f", "state=all",
        "-f", f"head=JuliaRegistries:{branch}",
        "-f", "per_page=1",
    )
    return prs[0] if prs else None


_COMMIT_LINE = re.compile(r"^\s*[-*]\s*Commit:\s*([0-9a-f]{40})\s*$", re.M)


def parse_commit_from_body(body: str) -> str | None:
    m = _COMMIT_LINE.search(body or "")
    return m.group(1) if m else None


# ---- Package repo helpers ----


def root_tree_of_commit(repo: str, commit: str) -> str | None:
    obj = get_or_none_404(f"repos/{repo}/commits/{commit}")
    return obj["commit"]["tree"]["sha"] if obj else None


def subdir_tree_at_commit(repo: str, commit: str, subdir: str) -> str | None:
    root = root_tree_of_commit(repo, commit)
    if root is None:
        return None
    tree = gh_json(f"repos/{repo}/git/trees/{root}")
    for entry in tree["tree"]:
        if entry["path"] == subdir and entry["type"] == "tree":
            return entry["sha"]
    return None


def deref_tag(repo: str, tag_name: str) -> str | None:
    # Use the singular `git/ref/...` endpoint, which does an exact lookup. The
    # plural `git/refs/...` does prefix matching and returns a list when
    # multiple tags share a prefix (e.g. v0.1.3 matches v0.1.30, v0.1.31, ...).
    ref = get_or_none_404(f"repos/{repo}/git/ref/tags/{tag_name}")
    if ref is None:
        return None
    obj = ref["object"]
    if obj["type"] == "commit":
        return obj["sha"]
    if obj["type"] == "tag":
        annotated = gh_json(f"repos/{repo}/git/tags/{obj['sha']}")
        return annotated["object"]["sha"]
    raise SystemExit(f"unexpected tag object type: {obj['type']!r}")


def create_tag_and_release(repo: str, tag_name: str, commit: str, message: str, dry_run: bool) -> None:
    if dry_run:
        print(f"  [dry-run] would create annotated tag {tag_name} -> {commit[:7]} and a release")
        return
    tag_obj = gh_json(
        f"repos/{repo}/git/tags",
        "-X", "POST",
        "-f", f"tag={tag_name}",
        "-f", f"message={message}",
        "-f", f"object={commit}",
        "-f", "type=commit",
    )
    gh(
        f"repos/{repo}/git/refs",
        "-X", "POST",
        "-f", f"ref=refs/tags/{tag_name}",
        "-f", f"sha={tag_obj['sha']}",
    )
    gh(
        f"repos/{repo}/releases",
        "-X", "POST",
        "-f", f"tag_name={tag_name}",
        "-f", f"name={tag_name}",
        "-F", "generate_release_notes=true",
    )
    print(f"  created tag {tag_name} -> {commit[:7]} and release")


# ---- Main ----


def env(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None or val == "":
        raise SystemExit(f"required env var {name} is unset")
    return val


def main() -> int:
    repo = env("TAG_REPO", os.environ.get("GITHUB_REPOSITORY"))
    subdir = env("TAG_SUBDIR")
    name = os.environ.get("TAG_PACKAGE_NAME") or subdir
    dry_run = os.environ.get("TAG_DRY_RUN", "false").lower() == "true"

    print(f"::group::tag-subdir: {name} (subdir={subdir}) in {repo}")
    print(f"  mode: {'dry-run' if dry_run else 'live'}")

    pkg = parse_package(registry_file(name, "Package.toml"))
    if pkg["name"] != name:
        raise SystemExit(f"name mismatch: registry says {pkg['name']!r}, expected {name!r}")
    pkg_repo_url = pkg["repo"]

    # Sanity-check the package belongs to this repo. The General Package.toml
    # `repo` is e.g. https://github.com/ITensor/ITensors.jl.git; we need to
    # match against the runner's GITHUB_REPOSITORY (owner/name).
    expected_path = f"/{repo}.git"
    if not pkg_repo_url.endswith(expected_path) and not pkg_repo_url.endswith(f"/{repo}"):
        raise SystemExit(
            f"registered repo URL {pkg_repo_url!r} does not match TAG_REPO={repo!r}"
        )

    versions = parse_versions(registry_file(name, "Versions.toml"))
    print(f"  registered versions: {len(versions)}")

    counts = {
        "correct": 0,        # tag at registered commit
        "old-correct": 0,    # tag exists, no PR found, subtree matches (pre-Registrator-era versions)
        "wrong-commit": 0,   # tag at non-registered commit (Phase 2 backfill territory)
        "wrong-subtree": 0,  # tag at commit whose subtree doesn't even match (very surprising)
        "tagged": 0,         # newly tagged this run (or would-be in dry-run)
        "no-pr-no-tag": 0,   # untagged and no PR: cannot auto-tag (e.g. ancient versions)
        "tree-mismatch": 0,  # registry PR commit's subtree != registered tree (refuse)
        "no-commit": 0,      # registry PR body has no `Commit:` line (refuse)
    }

    for version, registered_tree in sorted(
        versions.items(), key=version_key
    ):
        tag_name = f"{name}-v{version}"
        existing = deref_tag(repo, tag_name)
        registered_commit = lookup_registered_commit(name, pkg["uuid"], version, pkg_repo_url)

        if existing is not None and registered_commit is not None:
            if existing == registered_commit:
                counts["correct"] += 1
            else:
                counts["wrong-commit"] += 1
                print(
                    f"  WRONG-COMMIT  {tag_name}: tag at {existing[:7]} != registered "
                    f"{registered_commit[:7]}; not auto-correcting"
                )
            continue

        if existing is not None and registered_commit is None:
            existing_subtree = subdir_tree_at_commit(repo, existing, subdir)
            if existing_subtree == registered_tree:
                counts["old-correct"] += 1
            else:
                counts["wrong-subtree"] += 1
                print(
                    f"  WRONG-SUBTREE {tag_name}: tag at {existing[:7]}, no registry PR "
                    f"found, subdir tree {(existing_subtree or 'missing')[:7]} != "
                    f"registered tree {registered_tree[:7]}"
                )
            continue

        if existing is None and registered_commit is None:
            counts["no-pr-no-tag"] += 1
            continue

        # existing is None and registered_commit is not None: tag.
        actual_tree = subdir_tree_at_commit(repo, registered_commit, subdir)
        if actual_tree != registered_tree:
            counts["tree-mismatch"] += 1
            print(
                f"  TREE-MISMATCH {tag_name}: subdir tree at {registered_commit[:7]} is "
                f"{(actual_tree or 'missing')[:7]}, but registered tree is "
                f"{registered_tree[:7]}; refusing to tag"
            )
            continue

        print(f"  TAG           {tag_name}: -> {registered_commit[:7]}")
        create_tag_and_release(
            repo,
            tag_name,
            registered_commit,
            message=f"{name} v{version}",
            dry_run=dry_run,
        )
        counts["tagged"] += 1

    print("  ----")
    print("  summary: " + " ".join(f"{k}={v}" for k, v in counts.items()))
    print("::endgroup::")

    failed = counts["wrong-subtree"] + counts["tree-mismatch"] + counts["no-commit"]
    return 1 if failed else 0


def version_key(kv):
    """Sort key for SemVer-ish version strings used in Versions.toml.

    Splits on `.` and pads to 3 numeric components; appends an empty
    pre-release tuple so plain releases sort after their pre-releases under
    standard tuple comparison."""
    version = kv[0]
    base = version.split("-", 1)[0]
    parts = base.split(".")
    nums = tuple(int(p) for p in parts) + (0,) * (3 - len(parts))
    return nums + (version,)


def lookup_registered_commit(name, uuid, version, repo_url):
    branch = registrator_branch(name, uuid, version, repo_url)
    pr = find_registry_pr(branch)
    if pr is None:
        return None
    return parse_commit_from_body(pr.get("body") or "")


if __name__ == "__main__":
    sys.exit(main())
