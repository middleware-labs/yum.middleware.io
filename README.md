# yum.middleware.io
Middleware YUM Repo Home

`<arch>/Packages/` holds the mw-agent rpms; the mw-agent release workflow
pushes each new release here. `<arch>/repodata/` is the yum index of those
packages. The [Rebuild repodata](.github/workflows/rebuild-repodata.yml)
workflow rebuilds it on every push to `Packages/`, so don't edit it by hand.

To rebuild it locally (needs `createrepo_c`, `git` and `python3`):

    .github/scripts/rebuild-repodata.sh
