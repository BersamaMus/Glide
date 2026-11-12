part of 'places.dart';

/// The pictures of days gone by, as in Google Photos' memories: at the top,
/// those taken on this day in years before ("3 years ago today"); below,
/// every other day of the year that has pictures from more than one year,
/// from 1 January to 31 December, each year's pictures of it in turn (1
/// January 2018, 1 January 2019, 1 January 2021, then 2 January...).
///
/// The pictures are [from]'s: on a PC, the Pictures folder and every
/// drive inside it (a picture on both shown once); on a phone, the gallery.
/// While they're still being looked through, what's been found so far is
/// shown, and filled in as more is.
class Memories extends Location {
  Memories(this.from);

  /// Where its pictures are from: the Pictures tab's first, so with no
  /// access to them (on a phone), it says so as the gallery would.
  final List<Location> from;

  Location get _first => from.first;

  /// Today, as of the last listing: what "today" and "years ago" are from.
  var _today = now();

  /// What today is: the clock's, or a stand-in in tests.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  @override
  String get title => 'Memories';

  @override
  String get subtitle => 'On this day, and every other, in years gone by';

  /// With no access to the pictures (on a phone), why, and what to do: as
  /// the gallery says it.
  @override
  String get emptyText => _first.emptyAction != null
      ? _first.emptyText
      : 'No memories yet.\nPictures taken on the same day in different years will show here.';

  @override
  EmptyAction? get emptyAction => _first.emptyAction;

  @override
  IconData get chipIcon => Icons.auto_awesome_rounded;

  @override
  void forget({Iterable<String> gone = const [], Iterable<String> added = const []}) =>
      _forgetIn(from, gone: gone, added: added);

  @override
  Future<Listing> list() async {
    final listing = await _listAll(from);
    final today = _today = now();
    // Each day of the year's pictures, by month * 100 + day: 101 for 1
    // January.
    final days = <int, List<(DateTime, Picture)>>{};
    final seen = <String>{};
    for (final picture in listing.pictures) {
      // In Pictures, and found on its drive too (Windows' paths are the same
      // whatever their case).
      if (!seen.add(Platform.isWindows ? picture.id.toLowerCase() : picture.id)) continue;
      final date = picture.date;
      if (date == null) continue;
      final local = localDate(date);
      days.putIfAbsent(local.month * 100 + local.day, () => []).add((local, picture));
    }
    int chronological((DateTime, Picture) a, (DateTime, Picture) b) {
      final byDate = a.$1.compareTo(b.$1);
      return byDate != 0 ? byDate : _byName(a.$2.name, b.$2.name);
    }

    // Today's, from the years before this one: the latest year first, as
    // the fewest years ago.
    final todays = [
      for (final entry in days[today.month * 100 + today.day] ?? const <(DateTime, Picture)>[])
        if (entry.$1.year < today.year) entry,
    ]..sort((a, b) => a.$1.year != b.$1.year ? b.$1.year.compareTo(a.$1.year) : chronological(a, b));
    final others = [
      for (final day in days.keys.toList()..sort())
        if (day != today.month * 100 + today.day && days[day]!.map((entry) => entry.$1.year).toSet().length > 1)
          ...(days[day]!..sort(chronological)),
    ];
    return Listing(
      [
        for (final (_, picture) in [...todays, ...others]) picture,
      ],
      pending: listing.pending,
      work: listing.work,
      progress: listing.progress,
    );
  }

  /// Today's pictures from [year] are under -[year]; another day's, under
  /// (month * 100 + day) * 10000 + year.
  @override
  int group(Picture picture) {
    final date = picture.date;
    if (date == null) return 0;
    final local = localDate(date);
    if (local.month == _today.month && local.day == _today.day) return -local.year;
    return (local.month * 100 + local.day) * 10000 + local.year;
  }

  /// "3 years ago today · 22 October 2023", or "1 January 2018".
  @override
  String groupLabel(int group) {
    if (group < 0) {
      final year = -group;
      final ago = _today.year - year;
      return '${ago == 1 ? '1 year' : '$ago years'} ago today  ·  ${_today.day} ${monthNames[_today.month - 1]} $year';
    }
    final (day, year) = (group ~/ 10000, group % 10000);
    return '${day % 100} ${monthNames[day ~/ 100 - 1]} $year';
  }

  @override
  bool operator ==(Object other) => other is Memories && listEquals(other.from, from);

  @override
  int get hashCode => Object.hash(Memories, Object.hashAll(from));
}

/// Every source's listing as one: what each has found so far, listed again
/// once any of them finds more. Still looking while any is, then sorting as
/// far as the furthest behind. A drive that can't be read is left out,
/// unless none can.
///
/// The first source's (the Pictures tab's) on its own until it's found and
/// sorted all its pictures: quick, as it's small, and its dates are then
/// known when its drive's looked through, rather than read twice over at
/// once, with thumbnails waiting behind. If the first can't be listed, it's
/// not tried again straight away: the others are listed without it.
Future<Listing> _listAll(List<Location> from) async {
  final first = from.first;
  Future<Listing?> tryList(Location source) =>
      source.list().then<Listing?>((listing) => listing, onError: (Object _) => null);
  final Listing? firstListing = await tryList(first);
  if (from.length > 1 && firstListing != null && firstListing.work != null) return firstListing;
  final results = [firstListing, ...await Future.wait([for (final source in from.skip(1)) tryList(source)])];
  final listings = results.nonNulls.toList();
  if (listings.isEmpty) return first.list();
  if (listings.length == 1) return listings.single;
  // One that fails is listed again (and left out) with the rest.
  final pending = [for (final listing in listings) ?listing.pending?.then((_) {}, onError: (Object _) {})];
  final looking = listings.any((listing) => listing.work == Work.looking);
  final sorting = [
    for (final listing in listings)
      if (listing.work == Work.sorting) listing.progress ?? 0,
  ];
  return Listing(
    [for (final listing in listings) ...listing.pictures],
    pending: pending.isEmpty ? null : Future.any(pending),
    work: looking ? Work.looking : (sorting.isEmpty ? null : Work.sorting),
    progress: looking || sorting.isEmpty ? null : sorting.reduce(min),
  );
}

/// Tells each of [from] what the app changed, but a folder or drive only of
/// what's been added to it: a copy saved in Pictures isn't on another drive.
void _forgetIn(List<Location> from, {Iterable<String> gone = const [], Iterable<String> added = const []}) {
  for (final source in from) {
    source.forget(
      gone: gone,
      added: switch (source) {
        PhotoLibrary(:final path) => [
          for (final file in added)
            if (p.isWithin(path, file)) file,
        ],
        _ => added,
      },
    );
  }
}
