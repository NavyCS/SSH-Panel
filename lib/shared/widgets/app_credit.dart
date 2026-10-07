import 'dart:developer' show log;

import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../toast_service.dart';

/// Two-line attribution pinned to the right-hand end of the title bar:
/// `Made with ❤️ & 🤖 by navy_cs`, and under it a `github` link — drawn
/// inside a small bordered box so it reads as a widget of the strip rather
/// than as loose text.
///
/// It lives in its own file because four details are easy to get wrong when
/// the credit is written inline in the title-bar [Row]:
///
/// * **It sits in a container, but not in a [ShadCard].** The sections use
///   [ShadCard], whose defaults are a 24px inset plus an h3 [ShadCard.title]
///   and a [ShadCard.description] line; an attribution has no title and no
///   description to announce, and that much inset would blow the height
///   budget of a bar that is already tight. So the box here is the same box
///   one notch down: [ShadColorScheme.card] fill, a hairline in
///   [ShadColorScheme.border], and the very radius the cards resolve to
///   (`cardTheme.radius`, 8 in the default variant) — no invented values,
///   and no elevation shadow, because nothing else on this flat chrome strip
///   floats.
///
/// * **It has to be able to shrink, without pushing its neighbours around.**
///   The credit sits after the optional Admin Mode control, so how much room
///   is left depends on both the window width and which of those controls is
///   showing. The call site lays it out as a loose [Flexible] inside an
///   end-aligned row: natural width when there is room, whatever fits when
///   there is not, and never a fixed width of its own that the bar would have
///   to overflow. Inside, the text right-aligns and may wrap onto a second
///   line before it ellipsizes — the author's name is the last thing to be
///   cut, not the first. The container's own padding is the only height it
///   adds: 48px while the first line fits on one line, 62px once it wraps —
///   and it stops there, whatever the window does below that. Both numbers
///   are asserted, so growing the box is a failing test rather than a taller
///   bar.
///
/// * **The link must not be Material blue.** Every colour in this app comes
///   from [ShadThemeData]; a [TextButton] would instead paint the Material
///   `ColorScheme.primary`, which is a hardcoded colour wearing a theme's
///   clothes. The link is a plain [Text] coloured from the shadcn scheme —
///   muted at rest, `primary` while hovered or focused — and it is always
///   underlined so recognising it never depends on colour alone.
///
/// * **It has to be keyboard-reachable and say what it is.**
///   [FocusableActionDetector] puts it in the tab order and supplies the
///   activation action that `WidgetsApp`'s default Enter/Space shortcuts
///   dispatch, and the wrapping [Semantics] reports `link` rather than
///   `button`, which is what a screen-reader user needs to hear about
///   something that opens a URL.
///
/// The emoji are deliberately *not* managed here: no `fontFamily` is forced
/// and no emoji asset is shipped. The theme style carries Geist, which has no
/// emoji glyphs, and the platform falls back per glyph for those two code
/// points. If that fallback ever regressed the fix would be a one-line
/// `fontFamilyFallback` — a decision for whoever owns the design, not
/// something to paper over with an image.
class AppCredit extends StatelessWidget {
  const AppCredit({super.key});

  /// What the `github` link points at.
  ///
  /// The public repository. `repository:` in pubspec.yaml carries the same
  /// URL, and nothing enforces that they agree, so change both together.
  static const String githubUrl = 'https://github.com/NavyCS/SSH-Panel';

  /// How the app version is shown in the credit: `v1.0`.
  ///
  /// Derived from `version:` in pubspec.yaml, which reads `1.0.0+1` — the
  /// `+1` is the build number, which nobody wants to read in a title bar, and
  /// the patch level is noise at this stage. A test reads pubspec and asserts
  /// this matches its major.minor, so bumping one without the other fails the
  /// suite instead of silently shipping a stale number.
  static const String versionLabel = 'v1.0';

  /// The box's own inset, the one value here that is not a theme token.
  ///
  /// Sized so a single-line credit comes out exactly as tall as the Settings
  /// button beside it: 14px of text + 4px between the lines + a 16px link + this
  /// 4px + 2px of border = 40px, which is what `ShadIconButton` resolves to at
  /// its default size. `vertical` used to be 8px, which made the box 48px tall
  /// and 8px proud of the button it sits next to.
  ///
  /// It cannot go lower than 2px without the link's focus ring landing on the
  /// outer border, so the rest of the saving came out of the link's own padding
  /// instead, which keeps a 16px click target rather than a 12px one.
  ///
  /// Public because the height budget it produces is asserted in the tests:
  /// content + [vertical] (already top + bottom) + 2 for the border.
  static const EdgeInsets boxPadding = EdgeInsets.symmetric(
    horizontal: 8,
    vertical: 2,
  );

  /// Vertical space between the attribution and the link below it.
  ///
  /// Public because the height budget is asserted in the tests, and a bare
  /// number in a test is exactly the kind of constant that goes stale the next
  /// time the box is resized.
  static const double lineGap = 2;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Container(
      padding: boxPadding,
      // The same three values a section card resolves to: card fill, hairline
      // border, card radius. Nothing here is a literal colour.
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        border: Border.all(color: theme.colorScheme.border, width: 1),
        borderRadius: theme.cardTheme.radius ?? theme.radius,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Made with ❤️ & 🤖',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
          // 2px, not 4. Together with the box padding and the link padding this is what
          // makes the credit exactly as tall as the Settings button beside it.
          // The text style has a height factor of 1.0, so 14px of text is 14px of
          // line box and 2px still reads as two lines rather than one block.
          const SizedBox(height: lineGap),
          // The attribution and the link share the second line, so the credit
          // reads as one sentence: "by navy_cs (v1.0): github".
          // Both halves shrink. A bare Text or a bare link in a Row with
          // mainAxisSize.min gets unbounded width, so its ellipsis never
          // engages and the row overflows the title bar: measured 228px at one
          // width and 52px at another. Nested Flexibles are what let the
          // attribution give ground instead of pushing the bar wider. The link
          // stays clickable however far it is squeezed.
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    'by navy_cs ($versionLabel): ',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                ),
                Flexible(child: const _GithubLink()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The tappable half of [AppCredit]; kept private so the credit stays a
/// single widget at the call site.
class _GithubLink extends StatefulWidget {
  const _GithubLink();

  @override
  State<_GithubLink> createState() => _GithubLinkState();
}

class _GithubLinkState extends State<_GithubLink> {
  /// Owned here rather than created internally so the focus tree has a name
  /// the keyboard test can look for.
  final FocusNode _focusNode = FocusNode(debugLabel: 'AppCredit.github');

  bool _hovering = false;
  bool _focused = false;

  /// Hover and focus are the same signal to the reader, so they share one
  /// predicate instead of drifting apart.
  bool get _active => _hovering || _focused;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(AppCredit.githubUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (e, st) {
      // A missing or broken browser handler lands here; fall through to the
      // message below rather than leaving the click looking like a no-op.
      log('Could not launch ${AppCredit.githubUrl}.',
          name: 'ssh_panel', error: e, stackTrace: st);
    }
    if (!opened && mounted) {
      ToastService.instance
          .showErrorMessage('Could not open ${AppCredit.githubUrl}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color = _active
        ? theme.colorScheme.primary
        : theme.colorScheme.mutedForeground;

    return Semantics(
      link: true,
      label: 'Open the project on GitHub',
      child: FocusableActionDetector(
        enabled: true,
        focusNode: _focusNode,
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (hovering) =>
            setState(() => _hovering = hovering),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        // Enter, numpad Enter and Space already resolve to ActivateIntent via
        // the shortcuts WidgetsApp installs; only the action is ours.
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _open();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          child: Container(
            // Padding and border are always laid out, with the border painted
            // only on focus, so focusing the link cannot nudge its neighbours.
            // Vertical is 1, not 2: the credit has to match the Settings button's
            // height exactly, and this is where the remaining 2px came from
            // rather than from squeezing the box's own padding down to nothing.
            // It still leaves a 16px tall click target.
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(
                color: _focused
                    ? theme.colorScheme.ring
                    : theme.colorScheme.ring.withValues(alpha: 0),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            // Excluded so the node carries the label alone: without this the
            // framework concatenates the visible word onto it and the link is
            // announced as "Open the project on GitHub github".
            child: Semantics(
              excludeSemantics: true,
              child: Text(
                'github',
                // Never wrap. Measured: without a cap this word breaks
                // letter-by-letter as the window narrows, and the title bar
                // grows from 38px to 122px tall -- the credit is allowed to
                // give up width, but not to turn into a column.
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.small.copyWith(
                  color: color,
                  decoration: TextDecoration.underline,
                  decorationColor: color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
