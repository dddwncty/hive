# Hive 2.2.3 lifecycle maintenance

Base: upstream `v2.2.3`, commit `470473ffc1ba39f6c90f31ababe0ee63b76b69fe`.
The upstream Apache-2.0 license and history are preserved.

Only `lib/src/box/box_base_impl.dart` and
`lib/src/backend/vm/storage_backend_vm.dart` change runtime behavior:

- Concurrent `Box` and `LazyBox` close calls share completion through native
  file and lock shutdown, including a close started by `Hive.close()`.
- A failed close can be explicitly retried. Successfully closed resources are
  not closed again, including resources already closed during compaction.
- Native shutdown attempts every available handle and preserves the first
  error and stack. The lock pathname is removed only after all handles close.
- Partial initialization cleans available read/write handles before a lock
  handle exists. Compaction replaces historical handle tracking records.

The package remains version `2.2.3`. Storage encoding, adapters, encryption,
filenames, and platform selection are unchanged. The SDK constraint is
`>=2.16.0 <4.0.0`; Dart 2.16 provides `Error.throwWithStackTrace`.

This patch does not serialize arbitrary `Hive.openBox()` calls against a close.
Consumers must retain the original close Future or join it with `box.close()`
and wait for successful cleanup before opening a replacement with the same name.
It also does not add multi-isolate coordination.

## Validation

`test/tests/box/close_lifecycle_test.dart` uses real native files and controlled
close/compaction faults. It covers `Box` and `LazyBox`, external close, repeated
failure before actual handle release, cleanup of peer handles, retry, compaction
failure, partial initialization, persisted values, and late old-owner release.
Cleanup fallbacks run after assertions and do not establish success.

Run from `hive/`:

```sh
dart pub get
dart test --platform vm
dart test --platform chrome
```

The dedicated lifecycle workflow runs VM tests on Linux, macOS, and Windows
with Dart 3.11.0, and browser tests on Linux. The historical repository workflows
retain their behavior on other branches; the lifecycle branch uses this matrix.

Applications should reference the complete verified commit SHA with a Git
dependency whose package path is `hive`, and commit their application lockfile.
Application-specific ownership and restart tests remain in their consuming
repositories. Remove this dependency override only after an upstream release
provides equivalent lifecycle guarantees and those regressions pass.
