import 'package:flutter_test/flutter_test.dart';

import '../../docs/evals/artifacts/member/replay.dart' as fixtures;

void main() {
  test(
    'member playback remains scoped to the current session and player',
    () async {
      await fixtures.replayMemberCases((name, expected, observed) {
        expect(observed, expected, reason: name);
      });
    },
  );
}
