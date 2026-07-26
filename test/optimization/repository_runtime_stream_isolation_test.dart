import 'dart:async';

import 'package:alembic/core/repository_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';

class _WorkObservation {
  final List<String> messages;
  final List<RepositoryWorkKind> kinds;
  final List<double?> progress;

  const _WorkObservation({
    required this.messages,
    required this.kinds,
    required this.progress,
  });

  factory _WorkObservation.fromEntries(List<RepositoryWork> entries) =>
      _WorkObservation(
        messages: <String>[
          for (RepositoryWork entry in entries) entry.message,
        ],
        kinds: <RepositoryWorkKind>[
          for (RepositoryWork entry in entries) entry.kind,
        ],
        progress: <double?>[
          for (RepositoryWork entry in entries) entry.progress,
        ],
      );
}

class _AsyncTest {
  const _AsyncTest._();

  static Future<void> flushEvents() => Future<void>.delayed(Duration.zero);
}

void main() {
  test('repository work streams emit only matching repository updates',
      () async {
    RepositoryRuntime runtime = RepositoryRuntime();
    Repository alpha = Repository(
      name: 'alpha',
      fullName: 'VolmitSoftware/alpha',
    );
    Repository alphaAlias = Repository(
      name: 'alpha',
      fullName: 'volmitsoftware/ALPHA',
    );
    Repository beta = Repository(
      name: 'beta',
      fullName: 'VolmitSoftware/beta',
    );
    List<_WorkObservation> observations = <_WorkObservation>[];
    StreamSubscription<List<RepositoryWork>> subscription =
        runtime.streamWorkEntries(alpha).listen(
              (entries) => observations.add(
                _WorkObservation.fromEntries(entries),
              ),
            );
    addTearDown(runtime.dispose);
    addTearDown(subscription.cancel);

    await _AsyncTest.flushEvents();
    expect(observations, hasLength(1));
    expect(observations.single.messages, isEmpty);

    RepositoryWork alphaWork = runtime.beginWork(
      alphaAlias,
      'Cloning',
      kind: RepositoryWorkKind.clone,
      progress: 0.1,
    );
    await _AsyncTest.flushEvents();
    expect(observations, hasLength(2));
    expect(observations.last.messages, <String>['Cloning']);
    expect(
      observations.last.kinds,
      <RepositoryWorkKind>[RepositoryWorkKind.clone],
    );
    expect(observations.last.progress, <double?>[0.1]);

    RepositoryWork betaWork = runtime.beginWork(beta, 'Pulling');
    runtime.updateWork(betaWork, message: 'Resolving', progress: 0.5);
    runtime.endWork(betaWork);
    await _AsyncTest.flushEvents();
    expect(observations, hasLength(2));

    runtime.updateWork(
      alphaWork,
      message: 'Receiving objects',
      progress: 0.75,
    );
    await _AsyncTest.flushEvents();
    expect(observations, hasLength(3));
    expect(observations.last.messages, <String>['Receiving objects']);
    expect(observations.last.progress, <double?>[0.75]);

    RepositoryWork secondAlphaWork = runtime.beginWork(alpha, 'Checking out');
    await _AsyncTest.flushEvents();
    expect(observations, hasLength(4));
    expect(
      observations.last.messages,
      <String>['Receiving objects', 'Checking out'],
    );

    runtime.updateWork(alphaWork, clearProgress: true);
    await _AsyncTest.flushEvents();
    expect(observations, hasLength(5));
    expect(observations.last.progress, <double?>[null, null]);

    runtime.endWork(alphaWork);
    runtime.endWork(secondAlphaWork);
    await _AsyncTest.flushEvents();
    expect(observations, hasLength(7));
    expect(observations.last.messages, isEmpty);
  });
}
