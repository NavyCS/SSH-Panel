/// Tests for the title bar.
///
/// Extracted from `main.dart` mostly so it could be measured: the title and the
/// right-hand controls used to overlap at the minimum window width, and that was
/// only findable by driving the running app, because it appears nowhere in the
/// test suite at a comfortable width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_panel/shared/widgets/app_credit.dart';
import 'package:ssh_panel/shared/widgets/title_bar.dart';

Widget bar(double width, {bool showRestart = false, bool admin = false}) =>
    ShadApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            child: TitleBar(
              isAdminMode: admin,
              showRestartInAdminMode: showRestart,
              onSettingsPressed: () {},
              onRestartElevated: () {},
            ),
          ),
        ),
      ),
    );

void main() {
  group('TitleBar does not let its halves collide', () {
    // The app's minimum window is 800x600 physical (windows/runner/main.cpp:
    // SetMinimumSize). At 125% display scaling that is 640 logical pixels, which
    // is the width the overlap was actually reported at -- so that is the floor
    // worth testing, not an arbitrary small number that no user can reach.
    for (final width in [1280.0, 1024.0, 900.0, 800.0, 768.0, 700.0, 640.0]) {
      testWidgets('no overflow and no overlap at ${width.round()} px', (t) async {
        await t.pumpWidget(bar(width, showRestart: true));
        expect(t.takeException(), isNull, reason: 'overflow at $width px');

        final title = t.getRect(find.text('SSH Panel'));
        final control = t.getRect(find.text('Restart elevated'));

        expect(
          title.right,
          lessThanOrEqualTo(control.left + 0.5),
          reason: 'the app name and the control overlapped at $width px: '
              'title right=${title.right}, control left=${control.left}',
        );
      });
    }

    testWidgets('no overflow with the Admin Mode badge', (t) async {
      await t.pumpWidget(bar(640.0, admin: true));

      expect(t.takeException(), isNull);
      final title = t.getRect(find.text('SSH Panel'));
      final badge = t.getRect(find.text('Admin Mode'));
      expect(title.right, lessThanOrEqualTo(badge.left + 0.5));
    });

    testWidgets('the minimum window is the tightest case worth testing',
        (t) async {
      // 640 logical px is the app's floor at 125% scaling. Below it the user
      // cannot reach the layout, so what matters is that this width survives.
      await t.pumpWidget(bar(640.0, showRestart: true));

      expect(t.takeException(), isNull);
      final title = t.getSize(find.text('SSH Panel'));
      expect(
        title.width,
        greaterThan(0),
        reason: 'the name should be ellipsised, not collapsed to nothing',
      );
    });
  });

  group('TitleBar keeps the app name readable when there is room', () {
    testWidgets('shows the name in full on a wide bar', (t) async {
      await t.pumpWidget(bar(1200.0));

      final text = t.widget<Text>(find.text('SSH Panel'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.softWrap, isFalse);
    });

    testWidgets('the right-hand group stays flush with the right edge',
        (t) async {
      await t.pumpWidget(bar(1200.0));

      // 20px horizontal padding on the bar's own Container.
      final barRect = t.getRect(find.byType(TitleBar));
      final credit = t.getRect(find.byType(AppCredit));
      expect(credit.right, closeTo(barRect.right - 20, 0.5));
    });
  });

  group('TitleBar centres the credit', () {
    testWidgets('both credit lines share a centre line', (t) async {
      await t.pumpWidget(bar(900.0));

      final first = t.getRect(find.text('Made with ❤️ & 🤖'));
      final prefix = t.getRect(
        find.text('by navy_cs (${AppCredit.versionLabel}): '),
      );
      final link = t.getRect(find.text('github'));
      final box = t.getRect(find.byType(AppCredit));

      // Measured against the credit's own box, which is what "centred" means
      // here: the widest line defines the box and the others sit centred inside
      // it. Comparing the two lines against each other directly needs a slack
      // of a couple of pixels, because the link carries 4px of horizontal
      // padding and a 1px border that the bare text does not.
      final secondCentre = (prefix.left + link.right) / 2;

      expect(
        first.center.dx,
        closeTo(box.center.dx, 0.5),
        reason: 'the first line must sit on the box centre line',
      );
      expect(
        secondCentre,
        closeTo(box.center.dx, 3.0),
        reason: 'the second line must too, within the link\'s own padding',
      );
    });

    testWidgets('the credit stays centred once it wraps', (t) async {
      // Narrow enough that the attribution takes two lines: centring has to hold
      // in the wrapped case too, not just when everything fits on one.
      await t.pumpWidget(bar(700.0));

      expect(t.takeException(), isNull);
      final first = t.getRect(find.text('Made with ❤️ & 🤖'));
      final credit = t.getRect(find.byType(AppCredit));
      // The widest line centres inside the box; the box hugs the content, so
      // the two agree and neither is pinned to an edge.
      expect(first.center.dx, closeTo(credit.center.dx, 0.5));
    });
  });
}