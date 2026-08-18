# Releasing

How a version of this SDK reaches the two package managers that can install it.

Read this before your first release. Two things about it are counter-intuitive
and neither is guessable from the workflow files: **the git tag is the entire
SPM release**, and **pushing that tag does not publish to CocoaPods**.

## The one thing to understand first

Neither package manager stores your code. Both fetch it from GitHub at a tag.

```
SwiftPM     app ─────────────────────────────► GitHub, tag v0.1.1 ──► source
CocoaPods   app ──► trunk index (~1 kB JSON) ─► GitHub, tag v0.1.1 ──► source
```

CocoaPods trunk holds only a recipe. Here is the whole of what it stores about
where the code lives:

```json
"source": { "git": "https://github.com/intempt/intempt-swift.git", "tag": "v0.1.1" }
```

Three consequences:

- **The tag is load-bearing.** Delete or move it and both package managers break
  for everyone, because step "clone at tag" fails. Never move a released tag.
- **The repo must stay public.** Trunk publishes fine against a private repo and
  then fails for every consumer at the clone.
- **Trunk is write-once in practice.** `pod trunk delete` exists and is
  discouraged; it breaks anyone who already resolved that version. This is why
  publishing is a manual workflow and never fires on a push.

## What actually ships

The podspec ships one glob:

```ruby
s.source_files = 'Sources/Intempt/**/*.swift'
```

So `Tests/`, `scripts/`, `.github/`, `README.md` and `CHANGELOG.md` are in the
repository but never in the package. A PR can change hundreds of lines and
change the shipped SDK by nothing. Before releasing, check what consumers
actually get:

```sh
git diff v0.1.0..HEAD -- Sources/
```

An empty diff means the release contains no behaviour change. That is a
legitimate release (to keep `sdkVersion` in step with a tag) but say so in the
changelog rather than implying consumers got a fix.

## The version lives in three places

CocoaPods resolves them independently, so they drift silently:

| Where | What |
| --- | --- |
| `Intempt.podspec` | `s.version` |
| `Sources/Intempt/Intempt.swift` | `Intempt.sdkVersion` |
| git | the `v<version>` tag `s.source[:tag]` points at |

`scripts/check-version-sync.sh` fails CI when the first two disagree. It
deliberately does **not** fail on a missing tag — the bump lands before the tag
exists — so it reports `NOT YET CREATED` and passes.

## Steps

### 1. Bump, on a branch, merged to main

Edit both version sources and add a `CHANGELOG.md` section. Verify locally:

```sh
./scripts/check-version-sync.sh
```

Merge to `main` before tagging. A tag pointing at a commit that never landed on
`main` is how a release becomes unreproducible.

CI's `podspec` job picks its linter based on whether the tag exists yet, so a
bump PR is green before the tag is cut. `pod lib lint` validates the working
tree; once `v<version>` exists, the job switches to `pod spec lint`, which
clones the remote at the tag and proves what CocoaPods will actually resolve.
Running spec lint on a bump PR fails with `Remote branch v0.1.1 not found in
upstream origin` — expected, not a defect, and the reason for the split.

### 2. Tag — this *is* the SPM release

```sh
git checkout main && git pull
git tag v0.1.1
git push origin v0.1.1
```

**SPM consumers can resolve the new version the moment this lands.** There is no
workflow, no deploy step, no registry — SPM lists your tags and picks one. This
is also why `main` can run far ahead of what anyone consumes: SPM ignores
branches entirely.

### 3. Publish to CocoaPods — manual, and only after the tag exists

GitHub → **Actions** → **Publish to CocoaPods** → **Run workflow** → enter the
version without the `v` (e.g. `0.1.1`).

The workflow checks the input matches `s.version`, checks `v<version>` exists,
runs `pod lib lint`, pushes to trunk, then polls trunk for up to five minutes to
confirm the pod really resolves.

Requirements, both easy to trip over:

- **`COCOAPODS_TRUNK_TOKEN` must be in repo secrets.** Get one with
  `pod trunk register <email>` and click the confirmation link.
- **This cannot be run from a laptop.** `pod trunk push` validates by *building*
  the pod, which needs an iOS simulator runtime. Without one it fails with
  "Could not find a `ios` simulator" regardless of `--skip` flags. That is why
  it is a `macos-15` CI job.

### 4. Update the wrapper pins

`intempt-reactnative`'s podspec pins this pod **exactly**:

```ruby
s.dependency 'Intempt', '0.1.1'
```

Exact, not `~> 0.1`, so React Native stays on the old version until someone
edits that line. This is a separate repo and a separate PR. Forgetting it is
silent — nothing fails, RN simply never picks up the release.

## The asymmetry that will bite you

Step 2 publishes to SPM automatically. Step 3 does not. So:

> Tag and forget, and SPM users get 0.1.1 while `pod install` still hands people
> 0.1.0 — with `main`'s podspec claiming 0.1.1 the whole time.

Nothing in CI currently catches that gap. If releases become frequent, add a
tag-triggered job that checks whether trunk serves the version and fails loudly
if not after a grace period. Keep the publish itself manual — the irreversibility
above is the reason it is manual.

## Verifying a release for real

Do not trust the workflow's own output alone. Trunk's index is a plain file:

```sh
# shard = first 3 hex chars of md5 of the pod name; "Intempt" -> 66c
curl -s https://cdn.cocoapods.org/all_pods_versions_6_6_c.txt | grep '^Intempt/'

# and what trunk actually serves back
curl -sL https://cdn.cocoapods.org/Specs/6/6/c/Intempt/0.1.1/Intempt.podspec.json
```

For SPM, that the tag resolves is enough:

```sh
git ls-remote --tags https://github.com/intempt/intempt-swift.git
```

## If something goes wrong

**Version already exists on trunk.** `pod trunk push` rejects duplicates. There
is no fix but a new version number — bump and start again.

**Tag pushed at the wrong commit, nothing published yet.** Delete and re-push it
(`git push --delete origin v0.1.1`) *only* if no one has resolved it. Once it is
on trunk, the tag is frozen: trunk points at it forever.

**Published a broken version.** Do not `pod trunk delete`. Publish a fixed
patch version; anyone who resolved the broken one keeps working, and everyone
else moves forward.
