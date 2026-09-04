# Spack version pinned for this deployment

- Tag: `v1.2.2` (latest stable release as of 2026-09-04; CLAUDE.md mentions
  v1.2.0, but 1.2.2 is a patch release on the same line and is newer, so we
  use it per "尽量用最新的").
- Commit: `3e19345b6e12f5ff1b874f4059622fc6a1fd804a`
- Upstream: https://github.com/spack/spack.git

The `spack/` directory itself is git-ignored (see `.gitignore`) - it's an
upstream tool, not project config. To (re)provision it, on this machine or
on the cluster:

```
git clone --branch v1.2.2 https://github.com/spack/spack.git spack
```

If the cluster is air-gapped, transfer this repo via `git bundle` as
described in CLAUDE.md, and transfer the Spack clone separately (e.g. its
own bundle, or a tarball of the same tagged checkout) since it is not part
of this repo's history.
