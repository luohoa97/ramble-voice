// SPDX-License-Identifier: GPL-3.0-or-later

String formatClock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String formatBytes(int bytes) {
  if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(2)} GB';
  if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(0)} MB';
  return '${(bytes / 1e3).toStringAsFixed(0)} KB';
}

String two(int n) => n.toString().padLeft(2, '0');

String formatDateTime(DateTime t) {
  final now = DateTime.now();
  final sameDay =
      t.year == now.year && t.month == now.month && t.day == now.day;
  final time = '${two(t.hour)}:${two(t.minute)}';
  if (sameDay) return 'Today, $time';
  final y = now.subtract(const Duration(days: 1));
  if (t.year == y.year && t.month == y.month && t.day == y.day)
    return 'Yesterday, $time';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final year = t.year == now.year ? '' : ' ${t.year}';
  return '${months[t.month - 1]} ${t.day}$year, $time';
}
