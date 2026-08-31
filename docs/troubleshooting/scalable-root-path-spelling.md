# Scalable scan root path spelling

## Symptom

Live reconciliation and directory-deletion tests could report an empty scan for
temporary roots even though the same roots were readable. The failure appeared
only when Foundation returned the macOS /private/tmp spelling while the
selected root and catalog used /tmp.

## Root cause

The streaming enumerator mixed standardized URL output with the caller's path
dialect. On macOS, /tmp, /var, and /etc are compatibility aliases. That
produced paths that did not match the catalog's exact root-prefix queries or
the live coordinator's watched-root checks.

## Recovery

The enumerator now keeps the caller's display spelling for emitted catalog
paths and maps only the three explicit system aliases to their real traversal
directories. Arbitrary symlink roots remain rejected, and no-follow identity
checks still govern every child.

## Validation

- SymlinkEscapeTests/testSymlinkIsIndexedButNeverTraversed
- LiveIndexCoordinatorTests/testDirectoryDeletionMarksAllChildrenMissing
- LiveIndexCoordinatorTests/testDirectoryEventReconcilesChildren
- full Swift suite: 157 tests, 0 failures

## Residual gap

This covers deterministic local path spelling. The packaged App Sandbox
bookmark lifecycle still needs the human #44 smoke test because hosted tests
cannot manufacture an OS-granted security-scoped extension.
