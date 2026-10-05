/// Formats a count with a correctly pluralised noun.
///
/// Replaces the `'$n file(s)'` pattern that appeared in four card
/// descriptions. It reads wrong for every count -- "1 file(s)" is not English,
/// and "3 file(s)" makes the reader stop and check.
///
/// Uses [plural] for the count of exactly one, which is the case that matters:
/// English pluralises after one, so the singular form is only correct there.
///
/// ```dart
/// plural(1, 'key')        // '1 key'
/// plural(0, 'key')        // '0 keys'
/// plural(3, 'key')        // '3 keys'
/// ```
String plural(int count, String singular, [String? pluralForm]) =>
    '$count ${count == 1 ? singular : (pluralForm ?? '${singular}s')}';