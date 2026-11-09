"""Keep the newest ten release builds and every build referenced by the channel."""
import json
import os
import re
import subprocess
from urllib.parse import unquote, urlsplit


ASSET = re.compile(r"sympp-runtime-([0-9a-fA-F]{40})-[a-z0-9]+-[a-z0-9]+\.(?:zip|manifest\.json)")


def referenced_builds(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "source_revision" and isinstance(item, str):
                yield item.lower()
            yield from referenced_builds(item)
    elif isinstance(value, list):
        for item in value:
            yield from referenced_builds(item)
    elif isinstance(value, str):
        match = ASSET.fullmatch(unquote(urlsplit(value).path.rsplit("/", 1)[-1]))
        if match:
            yield match[1].lower()


def select_deletions(assets, manifest, publishing_revision):
    builds = {}
    for asset in assets:
        match = ASSET.fullmatch(asset["name"])
        if match:
            builds.setdefault(match[1].lower(), []).append(asset)
    newest = sorted(builds, key=lambda sha: (max(a["created_at"] for a in builds[sha]), sha), reverse=True)
    keep = set(newest[:10]) | set(referenced_builds(manifest)) | {publishing_revision.lower()}
    return [asset for sha, group in builds.items() if sha not in keep for asset in group]


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    tag = os.environ["RELEASE_TAG"]
    channel_name = f'sympp-runtime-artifacts-{os.environ["RELEASE_CHANNEL"]}.json'
    release = json.loads(gh("api", f"repos/{repo}/releases/tags/{tag}"))
    pages = json.loads(gh("api", "--paginate", "--slurp",
                          f'repos/{repo}/releases/{release["id"]}/assets?per_page=100'))
    assets = [asset for page in pages for asset in page]
    # If a published channel exists, failure to read it must stop pruning.
    manifest = json.loads(gh("release", "download", tag, "--repo", repo,
                             "--pattern", channel_name, "--output", "-")) if any(
                                 a["name"] == channel_name for a in assets) else {}
    for asset in select_deletions(assets, manifest, os.environ["GITHUB_SHA"]):
        print(f'Deleting {asset["name"]} (asset {asset["id"]})', flush=True)
        subprocess.run(["gh", "api", "--method", "DELETE",
                        f'repos/{repo}/releases/assets/{asset["id"]}'], check=True)


if __name__ == "__main__":
    main()
