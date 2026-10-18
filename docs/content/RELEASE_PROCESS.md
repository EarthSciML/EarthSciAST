# Release Process

The steps a maintainer takes to cut a release:

1. In one commit, bump the version at all nine version sites listed in
   [`RELEASING.md`](https://github.com/EarthSciML/EarthSciAST/blob/main/RELEASING.md#cutting-a-release).
   `./scripts/check-version-sync.sh` confirms they agree.
2. For a breaking release (any 0.x minor bump), add
   `release-notes/v<version>.md` describing what broke and how to upgrade.
3. Merge to `main`. The automation in [`RELEASE_PIPELINE.md`](RELEASE_PIPELINE.md)
   registers the Julia package, and once the General registry accepts it, tags
   the release and publishes every other binding and the command-line tools.

Do not push a `v*` tag by hand: tags come from TagBot after the Julia
registration is accepted, and the publish workflow refuses a tag whose commit
General did not register. If the registration is refused or publishing fails
partway, `RELEASING.md` describes how to recover.
