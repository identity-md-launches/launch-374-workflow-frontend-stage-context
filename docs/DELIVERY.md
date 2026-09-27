# Committed source delivery

The workspace's `.git` directory is read-only. Staging failed with
`Unable to create .git/index.lock: Read-only file system`. No attempt was made to
change its permissions or protected configuration.

`receipts-frontend.bundle` is a self-contained Git bundle created from an isolated
copy in disposable `test/scratch/`. Its `frontend-delivery` branch commits the exact
frontend source, lockfile, final `dist/` export and validation documents/evidence.
Its parent is the pinned deployment source commit. The bundle excludes itself and
the separately generated `evidence/package.json` size report to avoid recursion.

In a writable clone, the publisher can inspect/import it with:

```sh
git bundle verify docs/receipts-frontend.bundle
git fetch docs/receipts-frontend.bundle frontend-delivery
git show --stat FETCH_HEAD
```

Only `web/`, `dist/` and `docs/` change relative to the pinned source. The original
workspace contains those same files for normal assignment collection; its `.git`
metadata is unchanged. No node_modules, cache, registry archive, test/scratch file
or submodule is included. The ignore-file allocation is exactly `web/.gitignore`.

`evidence/package.json` records the delivery commit, bundle size, conservative total
file bytes and the full collected Git bundle size including this transport bundle.
The complete collected submission must remain below 8,388,608 bytes. Site publication
and live transaction broadcasts are not performed by this delivery.
