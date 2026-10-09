import 'package:alembic/util/extensions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

void main() {
  test('editor launch reports failure after exhausting installed candidates',
      () async {
    final _Runner runner = _Runner(<int>[127, 127]);
    await expectLater(
      ApplicationTool.vscode
          .launch('/workspace/repo', commandRunner: runner.call),
      throwsA(isA<Exception>()),
    );
    expect(runner.commands.take(2), <String>['code', 'code.cmd']);
  });

  test('Git client launch stops at the first successful candidate', () async {
    final _Runner runner = _Runner(<int>[127, 0, 127]);
    await GitTool.githubDesktop
        .launch('/workspace/repo', commandRunner: runner.call);
    expect(runner.commands, <String>['github', 'github-desktop']);
    expect(
        runner.arguments
            .every((List<String> args) => args.single == '/workspace/repo'),
        isTrue);
  });
}

class _Runner {
  final List<int> exits;
  final List<String> commands = <String>[];
  final List<List<String>> arguments = <List<String>>[];

  _Runner(this.exits);

  Future<int> call(
    String command,
    List<String> args, {
    BehaviorSubject<String>? stdout,
    BehaviorSubject<String>? stderr,
    String? workingDirectory,
    Map<String, String>? environment,
    bool redactOutput = true,
  }) async {
    commands.add(command);
    arguments.add(args);
    return exits.isEmpty ? 127 : exits.removeAt(0);
  }
}
