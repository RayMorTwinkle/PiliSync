import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WtTimeSync deterministic offline', () {
    test('adopts offset 5 from start100/end102/server106', () {
      final sync = WtTimeSync();
      sync.updateIfNeeded(106.0, 100.0, 102.0);
      expect(sync.hasValidSample, isTrue);
      expect(sync.minTrip, 2.0);
      // server - midpoint(101) = 5
      expect(sync.offset, closeTo(5.0, 0.0001));
    });

    test('slow sample does not replace min-RTT sample', () {
      final sync = WtTimeSync();
      sync.updateIfNeeded(106.0, 100.0, 102.0);
      // slower trip (10) with a wildly different offset
      sync.updateIfNeeded(300.0, 100.0, 110.0);
      expect(sync.minTrip, 2.0);
      expect(sync.offset, closeTo(5.0, 0.0001));
    });

    test('faster sample replaces offset and minTrip', () {
      final sync = WtTimeSync();
      sync.updateIfNeeded(106.0, 100.0, 102.0);
      // faster trip (1): midpoint 100.5, offset = 110 - 100.5 = 9.5
      sync.updateIfNeeded(110.0, 100.0, 101.0);
      expect(sync.minTrip, 1.0);
      expect(sync.offset, closeTo(9.5, 0.0001));
    });

    test('negative trip does not pollute existing samples', () {
      final sync = WtTimeSync();
      sync.updateIfNeeded(106.0, 100.0, 102.0);
      sync.updateIfNeeded(999.0, 200.0, 100.0); // trip = -100, ignored
      expect(sync.hasValidSample, isTrue);
      expect(sync.minTrip, 2.0);
      expect(sync.offset, closeTo(5.0, 0.0001));
    });

    test('after reset a slow sample is accepted again', () {
      final sync = WtTimeSync();
      sync.updateIfNeeded(106.0, 100.0, 102.0);
      sync.reset();
      expect(sync.hasValidSample, isFalse);
      expect(sync.offset, 0);
      expect(sync.minTrip, double.infinity);
      // new (slower) sample becomes the baseline after reset
      sync.updateIfNeeded(300.0, 100.0, 110.0);
      expect(sync.hasValidSample, isTrue);
      expect(sync.minTrip, 10.0);
      expect(sync.offset, closeTo(195.0, 0.0001));
    });
  });
}
