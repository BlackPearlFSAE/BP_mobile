class HistorySession {
  final String id;
  final String driverName;
  final String runId; // Kept for other purposes
  final int sessionNumber; // Auto-incrementing number (1, 2, 3...)
  final int? experimentId; // Linked Experiment ID
  final DateTime date;
  final List<String> logs;

  HistorySession({
    required this.id,
    required this.driverName,
    required this.runId,
    required this.sessionNumber,
    this.experimentId,
    required this.date,
    required this.logs,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'driverName': driverName,
    'runId': runId,
    'sessionNumber': sessionNumber,
    'experimentId': experimentId,
    'date': date.toIso8601String(),
    'logs': logs,
  };

  factory HistorySession.fromJson(Map<String, dynamic> json) => HistorySession(
    id: json['id'],
    driverName: json['driverName'],
    runId: json['runId'],
    sessionNumber: json['sessionNumber'] ?? 1,
    experimentId: json['experimentId'],
    date: DateTime.parse(json['date']),
    logs: List<String>.from(json['logs']),
  );
}
