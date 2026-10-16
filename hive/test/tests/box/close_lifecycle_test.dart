@TestOn('vm')
import 'dart:async';
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:hive/src/backend/vm/storage_backend_vm.dart';
import 'package:hive/src/box/box_base_impl.dart';
import 'package:test/test.dart';

void main() {
  for (final lazy in [false, true]) {
    for (final external in [false, true]) {
      test('lazy=$lazy external=$external close waits for native shutdown',
          () async {
        final fixture = await _Fixture.open(lazy);
        addTearDown(fixture.dispose);
        for (var round = 0; round < 3; round++) {
          await fixture.put('persisted');
          await fixture.box.compact();
        }
        fixture.trackHandles();
        final lock = fixture.files['lock']!;
        lock.blockClose();
        final first = external ? Hive.close() : fixture.box.close();
        fixture.observe(first);
        await _wait(lock.entered.future);
        expect(fixture.box.isOpen, isFalse);
        var completed = false;
        final second = fixture.box.close().then((_) { completed = true; });
        fixture.observe(second);
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse,
            reason: 'A second close must join the first native close.');
        expect(lock.closed, isFalse);
        lock.release.complete();
        await _wait(Future.wait([first, second]));
        expect(fixture.files.values.every((file) => file.successfulCloses == 1),
            isTrue);
        final fresh = await fixture.reopen();
        expect(await _get(fresh), 'persisted');
        await fixture.box.close();
        expect(Hive.isBoxOpen('lifecycle'), isTrue,
            reason: 'A late old peer cannot unregister the new box.');
        expect(await fixture.lockFile.exists(), isTrue);
        await fresh.close();
        await fresh.deleteFromDisk();
        expect(await Hive.boxExists('lifecycle'), isFalse);
      });
    }

    for (final failedHandle in ['read', 'write', 'lock']) {
      for (final failures in [1, 2]) {
        test('lazy=$lazy $failedHandle close fails $failures time(s), '
            'cleans peers and retries', () async {
          final fixture = await _Fixture.open(lazy);
          addTearDown(fixture.dispose);
          fixture.trackHandles();
          final fault = fixture.files[failedHandle]!;
          fault.failuresLeft = failures;
          for (var attempt = 0; attempt < failures; attempt++) {
            fault.blockClose();
            final first = fixture.box.close();
            final firstResult = _capture(first);
            fixture.observe(first);
            await _wait(fault.entered.future);
            final second = fixture.box.close();
            final secondResult = _capture(second);
            expect(identical(first, second), isTrue);
            fault.release.complete();
            final results =
                await _wait(Future.wait([firstResult, secondResult]));
            for (final result in results) {
              expect(result!.error, same(fault.failure));
              expect(result.stack.toString(), contains('_TrackedFile.close'));
            }
            expect(fault.closed, isFalse,
                reason: 'The failure happens before the actual file close.');
            expect(await fault.delegate.position(), isA<int>());
            for (final entry in fixture.files.entries) {
              if (entry.key != failedHandle) {
                expect(entry.value.closed, isTrue,
                    reason: 'A failed handle must not skip its peers.');
                await expectLater(entry.value.delegate.position(),
                    throwsA(isA<FileSystemException>()));
              }
            }
            expect(await fixture.lockFile.exists(), isTrue);
          }
          await fixture.box.close();
          expect(
              fixture.files.values.every((file) => file.successfulCloses == 1),
              isTrue);
          expect(await fixture.lockFile.exists(), isFalse);
          final fresh = await fixture.reopen();
          expect(await _get(fresh), 'persisted');
          await fixture.box.close();
          expect(await fixture.lockFile.exists(), isTrue);
          await fresh.close();
        });
      }
    }

    for (final phase in ['write-close', 'rename']) {
      test('lazy=$lazy failed compaction at $phase '
          'does not double-close handles', () async {
        final fixture = await _Fixture.open(lazy);
        addTearDown(fixture.dispose);
        await fixture.put('persisted');
        fixture.trackHandles();
        final failure = FileSystemException('injected compaction failure');
        if (phase == 'write-close') {
          final write = fixture.files['write']!..failuresLeft = 1;
          write.blockClose();
          final compacting = _capture(fixture.box.compact());
          await _wait(write.entered.future);
          expect(fixture.files['read']!.closed, isTrue);
          write.release.complete();
          expect((await _wait(compacting))!.error, same(write.failure));
        } else {
          final nativeZone = Zone.current;
          final compacting = IOOverrides.runZoned(fixture.box.compact,
              createFile: (path) {
            final file = nativeZone.run(() => File(path));
            return path.endsWith('.hivec')
                ? _RenameFailureFile(file, failure) : file;
          });
          expect((await _wait(_capture(compacting)))!.error, same(failure));
          expect(fixture.files['read']!.closed, isTrue);
          expect(fixture.files['write']!.closed, isTrue);
        }
        await fixture.box.close();
        expect(fixture.files.values.every((file) => file.successfulCloses == 1),
            isTrue);
        expect(await fixture.lockFile.exists(), isFalse);
        final fresh = await fixture.reopen();
        expect(await _get(fresh), 'persisted');
        await fresh.close();
      });
    }
  }

  for (final openedFiles in [false, true]) {
    test('partially initialized backend openedFiles=$openedFiles '
        'releases available files', () async {
      final directory =
          await Directory.systemTemp.createTemp('hive-partial-close-');
      final file = File('${directory.path}/partial.hive');
      final lock = File('${directory.path}/partial.lock');
      final backend = StorageBackendVm(file, lock, true, null);
      RandomAccessFile? read;
      RandomAccessFile? write;
      addTearDown(() async {
        for (final handle in [read, write].whereType<RandomAccessFile>()) {
          try { await handle.close(); } catch (_) {}
        }
        await directory.delete(recursive: true);
      });
      if (openedFiles) {
        await file.create();
        await backend.open();
        read = backend.readRaf;
        write = backend.writeRaf;
      }
      await backend.close();
      if (read != null) {
        await expectLater(read.position(), throwsA(isA<FileSystemException>()));
      }
      if (write != null) {
        await expectLater(
            write.position(), throwsA(isA<FileSystemException>()));
      }
      expect(await lock.exists(), isFalse);
    });
  }
}

Future<T> _wait<T>(Future<T> future) =>
    future.timeout(const Duration(seconds: 5));

Future<dynamic> _get(BoxBase box) async =>
    box is LazyBox ? await box.get('value') : (box as Box).get('value');

class _Failure {
  _Failure(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

Future<_Failure?> _capture(Future<void> future) =>
    future.then<_Failure?>((_) => null, onError: _Failure.new);

class _Fixture {
  _Fixture(this.directory, this.box, this.lazy);
  final Directory directory;
  final BoxBase box;
  final bool lazy;
  final files = <String, _TrackedFile>{};
  final pending = <Future<void>>[];

  static Future<_Fixture> open(bool lazy) async {
    final directory =
        await Directory.systemTemp.createTemp('hive-close-lifecycle-');
    Hive.init(directory.path);
    final BoxBase box = lazy
        ? await Hive.openLazyBox('lifecycle',
            compactionStrategy: (_, __) => false)
        : await Hive.openBox('lifecycle', compactionStrategy: (_, __) => false);
    final fixture = _Fixture(directory, box, lazy);
    await fixture.put('persisted');
    return fixture;
  }

  File get lockFile => File('${directory.path}/lifecycle.lock');

  Future<void> put(String value) async {
    if (box is LazyBox) { await (box as LazyBox).put('value', value); }
    else { await (box as Box).put('value', value); }
  }

  Future<BoxBase> reopen() async => lazy
      ? await Hive.openLazyBox('lifecycle') : await Hive.openBox('lifecycle');

  void trackHandles() {
    // ignore: invalid_use_of_protected_member
    final backend = (box as BoxBaseImpl).backend as StorageBackendVm;
    files.addAll({
      'read': _TrackedFile(backend.readRaf),
      'write': _TrackedFile(backend.writeRaf),
      'lock': _TrackedFile(backend.lockRaf),
    });
    backend.readRaf = files['read']!;
    backend.writeRaf = files['write']!;
    backend.lockRaf = files['lock']!;
  }

  void observe(Future<void> future) {
    pending.add(future.then<void>((_) {},
        onError: (Object error, StackTrace stack) {}));
  }

  Future<void> dispose() async {
    for (final file in files.values) {
      file.failuresLeft = 0;
      if (!file.release.isCompleted) file.release.complete();
    }
    await Future.wait(pending);
    try { await box.close(); } catch (_) {}
    try { await Hive.close(); } catch (_) {}
    // Cleanup after assertions also supports the unpatched baseline.
    for (final file in files.values) {
      if (!file.closed) { try { await file.close(); } catch (_) {} }
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class _TrackedFile implements RandomAccessFile {
  _TrackedFile(this.delegate);
  final RandomAccessFile delegate;
  final failure =
      FileSystemException('injected failure before native file close');
  var entered = Completer<void>();
  var release = Completer<void>()..complete();
  bool closed = false;
  int successfulCloses = 0;
  int failuresLeft = 0;

  void blockClose() {
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<void> close() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    if (failuresLeft > 0) { failuresLeft--; throw failure; }
    await delegate.close();
    closed = true;
    successfulCloses++;
  }

  @override
  Future<int> position() => delegate.position();
  @override
  Future<int> length() => delegate.length();
  @override
  Future<RandomAccessFile> setPosition(int position) =>
      delegate.setPosition(position);
  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) =>
      delegate.readInto(buffer, start, end);
  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer,
      [int start = 0, int? end]) => delegate.writeFrom(buffer, start, end);
  @override
  Future<RandomAccessFile> flush() => delegate.flush();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RenameFailureFile implements File {
  _RenameFailureFile(this.delegate, this.failure);
  final File delegate;
  final FileSystemException failure;
  @override
  String get path => delegate.path;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      delegate.open(mode: mode);
  @override
  Future<File> rename(String path) async => throw failure;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
