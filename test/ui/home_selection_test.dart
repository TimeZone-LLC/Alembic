import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const List<String> order = <String>['one', 'two', 'three', 'four'];
  late HomeSelectionController selection;

  setUp(() => selection = HomeSelectionController());
  tearDown(() => selection.dispose());

  test('Shift range uses its original anchor when reversing direction', () {
    selection.select('two', order);
    selection.select('four', order, extend: true);
    expect(selection.count, 3);
    selection.select('one', order, extend: true);
    expect(selection.isSelected('one'), isTrue);
    expect(selection.isSelected('two'), isTrue);
    expect(selection.isSelected('three'), isFalse);
    expect(selection.count, 2);
  });

  test('Command toggling preserves other selected repositories', () {
    selection.select('one', order);
    selection.select('three', order, toggle: true);
    expect(selection.count, 2);
    selection.select('one', order, toggle: true);
    expect(selection.count, 1);
    expect(selection.isSelected('three'), isTrue);
  });

  test('filtered selections discard a hidden anchor and cursor', () {
    selection.select('one', order);
    selection.select('four', order, extend: true);
    selection.prune(<String>{'two', 'three'});
    expect(selection.count, 2);
    expect(selection.cursor, isNull);
    selection.move(<String>['two', 'three'], 1, extend: true);
    expect(selection.cursor, 'two');
    expect(selection.count, 1);
    expect(selection.isSelected('two'), isTrue);
  });

  test('arrows stop at boundaries and select from either end after clearing',
      () {
    selection.move(order, -1);
    expect(selection.cursor, 'four');
    selection.move(order, 1);
    expect(selection.cursor, 'four');
    selection.clear();
    selection.move(order, 1);
    selection.move(order, -1);
    expect(selection.cursor, 'one');
    selection.move(<String>[], 1);
    expect(selection.cursor, 'one');
  });
}
