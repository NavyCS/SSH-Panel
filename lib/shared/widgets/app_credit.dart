import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../toast_service.dart';

/// Two-line attribution pinned to the right-hand end of the title bar:
/// `Made with ❤️ & 🤖 by navy_cs`, and under it a `github` link.
///
/// It lives in its own file because three details are easy to get wrong when
/// the credit is written inline in the title-bar [Row]:
///
/// * **It has to be able to shrink, without pushing its neighbours around.**
///   The credit sits after the optional Admin Mode control, so how much room
///   is left depends on both the window width and which of those controls is
///   showing. The call site lays it out as a loose [Flexible] inside an
///   end-aligned row: natural width when there is room, whatever fits when
///   there is not, and never a fixed width of its own that the bar would have
///   to overflow. Inside, the text right-aligns and may wrap onto a second
///   line before it ellipsizes — the author's name is the last thing to be
///   cut, not the first.
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
  /// The repository has not been published yet, so this is the plain GitHub
  /// homepage. When the project lands the URL changes here and nowhere else.
  static const String githubUrl = 'https://github.com';

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'Made with ❤️ & 🤖 by navy_cs',
          textAlign: TextAlign.right,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.small.copyWith(
            color: theme.colorScheme.mutedForeground,
          ),
        ),
        const SizedBox(height: 4),
        const _GithubLink(),
      ],
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
    } catch (_) {
      // A missing or broken browser handler lands here; fall through to the
      // message below rather than leaving the click looking like a no-op.
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
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
