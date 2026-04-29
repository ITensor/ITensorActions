#!/usr/bin/env python3

# Tag missing versions of a subdir Julia package at the commit recorded in
# each version's General-registry PR. Replaces JuliaRegistries/TagBot's
# subdir handling, which uses a tree-hash fast-path that picks a later
# same-subtree commit instead of the registered one.
#
# Idempotent: existing tags are never modified.
#
# Inputs (env):
#   TAG_REPO          owner/name of the package repo (default: GITHUB_REPOSITORY)
#   TAG_SUBDIR        subdir name within the repo (e.g. "NDTensors")
#   TAG_PACKAGE_NAME  registered package name (default: TAG_SUBDIR)
#   TAG_DRY_RUN       "true" to log without mutating
#   GH_TOKEN          token for `gh api`

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tomllib

GENERAL = "JuliaRegistries/General"


def gh(*args, allow_404=False):
    res = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if res.returncode == 0:
        return json.loads(res.stdout) if res.stdout.strip() else None
    if allow_404 and ("HTTP 404" in res.stderr or "Not Found" in res.stderr):
        return None
    sys.stderr.write(res.stdout + res.stderr)
    sys.exit(f"gh api failed: {' '.join(args)}")


def fetch_registry_toml(name, filename):
    obj = gh(f"repos/{GENERAL}/contents/{name[0].upper()}/{name}/{filename}")
    return tomllib.loads(base64.b64decode(obj["content"]).decode())


def registrator_branch(name, uuid, version, url):
    # Mirrors RegistryTools.jl `registration_branch`. URL hash is sha256, not sha1.
    h = hashlib.sha256(url.encode()).hexdigest()[:10]
    return f"registrator-{name.lower()}-{uuid[:8]}-v{version}-{h}"


_COMMIT_LINE = re.compile(r"^\s*[-*]\s*Commit:\s*([0-9a-f]{40})\s*$", re.M)


def find_registered_commit(name, uuid, version, url):
    branch = registrator_branch(name, uuid, version, url)
    prs = gh(
        f"repos/{GENERAL}/pulls",
        "-X", "GET",
        "-f", "state=all",
        "-f", f"head=JuliaRegistries:{branch}",
        "-f", "per_page=1",
    )
    if not prs:
        return None
    m = _COMMIT_LINE.search(prs[0].get("body") or "")
    return m.group(1) if m else None


def subdir_tree_sha(repo, commit, subdir):
    # `git/trees/{sha}` accepts a commit SHA and returns its root tree directly.
    tree = gh(f"repos/{repo}/git/trees/{commit}", allow_404=True)
    if tree is None:
        return None
    for entry in tree["tree"]:
        if entry["path"] == subdir and entry["type"] == "tree":
            return entry["sha"]
    return None


def deref_tag(repo, tag):
    # Singular `git/ref/...` does an exact lookup; the plural endpoint does
    # prefix matching (e.g. `NDTensors-v0.1.3` matches `v0.1.30`, `v0.1.31`, ...).
    ref = gh(f"repos/{repo}/git/ref/tags/{tag}", allow_404=True)
    if ref is None:
        return None
    obj = ref["object"]
    if obj["type"] == "commit":
        return obj["sha"]
    if obj["type"] == "tag":
        return gh(f"repos/{repo}/git/tags/{obj['sha']}")["object"]["sha"]
    sys.exit(f"unexpected tag object type: {obj['type']!r}")


def create_tag_and_release(repo, tag, commit, message):
    obj = gh(
        f"repos/{repo}/git/tags",
        "-X", "POST",
        "-f", f"tag={tag}",
        "-f", f"message={message}",
        "-f", f"object={commit}",
        "-f", "type=commit",
    )
    gh(
        f"repos/{repo}/git/refs",
        "-X", "POST",
        "-f", f"ref=refs/tags/{tag}",
        "-f", f"sha={obj['sha']}",
    )
    gh(
        f"repos/{repo}/releases",
        "-X", "POST",
        "-f", f"tag_name={tag}",
        "-f", f"name={tag}",
        "-F", "generate_release_notes=true",
    )


def version_key(version):
    base = version.split("-", 1)[0]
    return tuple(int(p) for p in base.split("."))


def main():
    repo = os.environ.get("TAG_REPO") or os.environ["GITHUB_REPOSITORY"]
    subdir = os.environ["TAG_SUBDIR"]
    name = os.environ.get("TAG_PACKAGE_NAME") or subdir
    dry_run = os.environ.get("TAG_DRY_RUN", "false").lower() == "true"

    print(f"::group::tag-subdir: {name} (subdir={subdir}) in {repo}")
    print(f"  mode: {'dry-run' if dry_run else 'live'}")

    pkg = fetch_registry_toml(name, "Package.toml")
    versions = fetch_registry_toml(name, "Versions.toml")
    print(f"  registered versions: {len(versions)}")

    correct = old_correct = wrong = no_pr_no_tag = tagged = failed = 0

    for version in sorted(versions, key=version_key):
        tag_name = f"{name}-v{version}"
        registered_tree = versions[version]["git-tree-sha1"]
        existing = deref_tag(repo, tag_name)
        registered = find_registered_commit(name, pkg["uuid"], version, pkg["repo"])

        if existing and registered:
            if existing == registered:
                correct += 1
            else:
                wrong += 1
                print(
                    f"  WRONG-COMMIT  {tag_name}: tag at {existing[:7]} != "
                    f"registered {registered[:7]}; not auto-correcting"
                )
        elif existing:
            # Pre-Registrator versions: best we can do is verify subtree.
            if subdir_tree_sha(repo, existing, subdir) == registered_tree:
                old_correct += 1
            else:
                failed += 1
                print(
                    f"  WRONG-SUBTREE {tag_name}: tag at {existing[:7]}, no PR found, "
                    f"subdir tree != registered tree {registered_tree[:7]}"
                )
        elif registered:
            actual = subdir_tree_sha(repo, registered, subdir)
            if actual != registered_tree:
                failed += 1
                print(
                    f"  TREE-MISMATCH {tag_name}: subdir tree at {registered[:7]} != "
                    f"registered tree {registered_tree[:7]}; refusing to tag"
                )
                continue
            print(f"  TAG           {tag_name} -> {registered[:7]}")
            if not dry_run:
                create_tag_and_release(repo, tag_name, registered, f"{name} v{version}")
            tagged += 1
        else:
            no_pr_no_tag += 1

    print(
        f"  summary: correct={correct} old-correct={old_correct} "
        f"wrong-commit={wrong} no-pr-no-tag={no_pr_no_tag} "
        f"tagged={tagged} failed={failed}"
    )
    print("::endgroup::")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
