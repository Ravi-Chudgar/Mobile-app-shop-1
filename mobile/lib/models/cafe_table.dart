/// A cafe table: occupancy plus optional floor-map layout.
///
/// Layout fields are percent-of-canvas (0-100) and entirely optional —
/// tables saved before the floor map (or never arranged) report null and the
/// UI falls back to [fallbackRect]'s grid arrangement.
class CafeTable {
  final String number;
  final String status; // "empty" | "occupied"
  final String? orderId;
  final String? takenBy; // staff member serving this table, if occupied

  // ---- Floor map layout (all optional) ----
  final String zone; // e.g. "main", "terrace"
  final int? x; // left edge, percent of canvas (0-100)
  final int? y; // top edge, percent of canvas (0-100)
  final int? w; // width, percent of canvas (1-100)
  final int? h; // height, percent of canvas (1-100)
  final String shape; // "rect" | "round"

  const CafeTable({
    required this.number,
    required this.status,
    required this.orderId,
    required this.takenBy,
    this.zone = 'main',
    this.x,
    this.y,
    this.w,
    this.h,
    this.shape = 'rect',
  });

  bool get isOccupied => status == 'occupied';

  bool get isRound => shape == 'round';

  /// True when the owner has saved explicit floor coordinates.
  bool get hasLayout => x != null && y != null && w != null && h != null;

  factory CafeTable.fromJson(Map<String, dynamic> json) => CafeTable(
        number: json['number'].toString(),
        status: (json['status'] ?? 'empty') as String,
        orderId: json['order_id'] as String?,
        takenBy: json['taken_by'] as String?,
        zone: (json['zone'] as String?) ?? 'main',
        x: _toInt(json['x']),
        y: _toInt(json['y']),
        w: _toInt(json['w']),
        h: _toInt(json['h']),
        shape: (json['shape'] as String?) ?? 'rect',
      );

  CafeTable copyWith({
    String? zone,
    int? x,
    int? y,
    int? w,
    int? h,
    String? shape,
  }) =>
      CafeTable(
        number: number,
        status: status,
        orderId: orderId,
        takenBy: takenBy,
        zone: zone ?? this.zone,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        shape: shape ?? this.shape,
      );

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// Percent-of-canvas rectangle used to position a table on the floor map.
class TableRect {
  final int x;
  final int y;
  final int w;
  final int h;
  const TableRect(this.x, this.y, this.w, this.h);
}

/// Grid fallback for tables without saved coordinates: always fits [total]
/// tables inside the 0-100 canvas (4 columns max, shrinking cells as needed).
TableRect fallbackRect(int index, {int total = 1, int cols = 4}) {
  final n = total < 1 ? 1 : total;
  final useCols = n < cols ? n : cols;
  final rows = (n + useCols - 1) ~/ useCols;
  const gap = 3;
  final col = index % useCols;
  final row = index ~/ useCols;
  final w = (100 - gap * (useCols + 1)) ~/ useCols;
  final h = (100 - gap * (rows + 1)) ~/ rows;
  return TableRect(gap + col * (w + gap), gap + row * (h + gap), w, h);
}
