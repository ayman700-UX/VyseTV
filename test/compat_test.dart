// The older framework calls the app uses so that one source builds on both Flutter versions
// (lib/core/compat.dart): they have to behave as the newer ones did.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/compat.dart';

void main() {
  group('reorderTo', () {
    List<int> moved(int from, int droppedAt) {
      final list = [0, 1, 2, 3, 4];
      reorderTo((a, b) => list.insert(b, list.removeAt(a)))(from, droppedAt);
      return list;
    }

    test('a row moved down lands where it was dropped, not one further', () {
      // dropped between 3 and 4: the list still counts the row, so the framework says 4
      expect(moved(1, 4), [0, 2, 3, 1, 4]);
      // dropped after the last row
      expect(moved(0, 5), [1, 2, 3, 4, 0]);
    });

    test('a row moved up lands where it was dropped', () {
      expect(moved(3, 1), [0, 3, 1, 2, 4]);
      expect(moved(4, 0), [4, 0, 1, 2, 3]);
    });

    test('a row put back where it was moves nothing', () {
      var calls = 0;
      final onReorder = reorderTo((_, _) => calls++);
      onReorder(2, 2); // dropped on its own place
      onReorder(2, 3); // dropped just under itself: the same place once it is taken out
      expect(calls, 0);
    });
  });

  testWidgets('tickersOn follows TickerMode', (tester) async {
    late bool on;
    Widget probe(bool enabled) => TickerMode(
      enabled: enabled,
      child: Builder(
        builder: (context) {
          on = tickersOn(context);
          return const SizedBox();
        },
      ),
    );
    await tester.pumpWidget(probe(true));
    expect(on, isTrue);
    await tester.pumpWidget(probe(false));
    expect(on, isFalse);
  });

  testWidgets('a reorderable list dragged with reorderTo ends in the order shown', (tester) async {
    final rows = ['a', 'b', 'c', 'd'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            // the app's lists are built this way: no handles of the framework's, each row its own
            builder: (context, setState) => ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: rows.length,
              // ignore: deprecated_member_use
              onReorder: reorderTo((from, to) => setState(() => rows.insert(to, rows.removeAt(from)))),
              itemBuilder: (context, i) => ReorderableDragStartListener(
                key: ValueKey(rows[i]),
                index: i,
                child: SizedBox(height: 50, child: Text(rows[i])),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> drag(String row, double by) async {
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(ValueKey(row))));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(Offset(0, by), timeStamp: const Duration(milliseconds: 200));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    // a nudge that passes no row: nothing moves
    await drag('a', 10);
    expect(rows, ['a', 'b', 'c', 'd']);
    // the first row dragged past the end is the last one, not out of range
    await drag('a', 400);
    expect(rows, ['b', 'c', 'd', 'a']);
    // and dragged back above the first
    await drag('a', -400);
    expect(rows, ['a', 'b', 'c', 'd']);
  });
}
