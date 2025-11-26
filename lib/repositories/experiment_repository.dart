import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import '../models/experiment.dart';
import '../models/topic.dart';
import '../models/data_entry.dart';
import '../models/session.dart';

class ExperimentRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  // Experiment CRUD operations
  Future<int> createExperiment(Experiment experiment) async {
    final db = await _dbHelper.database;
    return await db.insert('experiments', experiment.toMap());
  }

  Future<List<Experiment>> getAllExperiments() async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'experiments',
      orderBy: 'created_at DESC',
    );
    return List.generate(maps.length, (i) => Experiment.fromMap(maps[i]));
  }

  Future<Experiment?> getExperimentById(int id) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'experiments',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return Experiment.fromMap(maps.first);
  }

  Future<int> updateExperiment(Experiment experiment) async {
    final db = await _dbHelper.database;
    return await db.update(
      'experiments',
      experiment.toMap(),
      where: 'id = ?',
      whereArgs: [experiment.id],
    );
  }

  Future<int> deleteExperiment(int id) async {
    final db = await _dbHelper.database;
    // Enable foreign keys to ensure CASCADE works
    try {
      await db.execute('PRAGMA foreign_keys = ON');
    } catch (e) {
      print('Warning: Could not enable foreign keys: $e');
    }

    // Topics and data entries will be deleted via CASCADE
    final result = await db.delete(
      'experiments',
      where: 'id = ?',
      whereArgs: [id],
    );

    // Clean up any orphaned entries (in case CASCADE didn't work)
    await cleanupOrphanedEntries();

    return result;
  }

  // Topic management
  Future<int> createTopic(Topic topic) async {
    final db = await _dbHelper.database;
    return await db.insert('topics', topic.toMap());
  }

  Future<List<Topic>> getTopicsByExperimentId(int experimentId) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'topics',
      where: 'experiment_id = ?',
      whereArgs: [experimentId],
      orderBy: 'name ASC',
    );
    return List.generate(maps.length, (i) => Topic.fromMap(maps[i]));
  }

  Future<Topic?> getTopicById(int id) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'topics',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return Topic.fromMap(maps.first);
  }

  Future<int> updateTopic(Topic topic) async {
    final db = await _dbHelper.database;
    return await db.update(
      'topics',
      topic.toMap(),
      where: 'id = ?',
      whereArgs: [topic.id],
    );
  }

  Future<int> deleteTopic(int id) async {
    final db = await _dbHelper.database;
    return await db.delete('topics', where: 'id = ?', whereArgs: [id]);
  }

  // Data entry operations
  Future<int> insertDataEntry(DataEntry entry) async {
    final db = await _dbHelper.database;
    int retries = 3;
    int delay = 100; // milliseconds

    while (retries > 0) {
      try {
        // Use insert with conflictAlgorithm to handle duplicates gracefully
        return await db.insert(
          'data_entries',
          entry.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (e) {
        final errorStr = e.toString().toLowerCase();
        if ((errorStr.contains('database is locked') ||
                errorStr.contains('locked')) &&
            retries > 1) {
          retries--;
          await Future.delayed(Duration(milliseconds: delay));
          delay *= 2; // Exponential backoff
          continue;
        }
        print('Database insert error: $e');
        rethrow;
      }
    }
    throw Exception('Failed to insert data entry after retries');
  }

  // Get total count of data entries (only for existing experiments)
  Future<int> getTotalDataEntriesCount() async {
    final db = await _dbHelper.database;
    try {
      // Only count entries that belong to existing experiments
      final result = await db.rawQuery(
        '''SELECT COUNT(*) as count FROM data_entries 
           WHERE experiment_id IN (SELECT id FROM experiments)''',
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      print('Error getting total entries count: $e');
      return 0;
    }
  }

  // Clean up orphaned data entries (entries without valid experiments)
  Future<int> cleanupOrphanedEntries() async {
    final db = await _dbHelper.database;
    try {
      final result = await db.delete(
        'data_entries',
        where: 'experiment_id NOT IN (SELECT id FROM experiments)',
      );
      print('Cleaned up $result orphaned data entries');
      return result;
    } catch (e) {
      print('Error cleaning up orphaned entries: $e');
      return 0;
    }
  }

  // Get total count of data entries for an experiment
  Future<int> getExperimentDataEntriesCount(int experimentId) async {
    final db = await _dbHelper.database;
    try {
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM data_entries WHERE experiment_id = ?',
        [experimentId],
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      print('Error getting experiment entries count: $e');
      return 0;
    }
  }

  // Get storage size estimation (in bytes) - only for existing experiments
  Future<int> getStorageSizeEstimate() async {
    try {
      // Use a simpler approach: estimate based on row count
      // Only count entries for existing experiments
      final count = await getTotalDataEntriesCount();
      // Rough estimate: ~500 bytes per entry (timestamp + topic + JSON data)
      // For more accuracy, we can query the actual data size later if needed
      return count * 500;
    } catch (e) {
      print('Error getting storage size: $e');
      // Fallback: return 0 if we can't estimate
      return 0;
    }
  }

  Future<int> batchInsertDataEntries(List<DataEntry> entries) async {
    if (entries.isEmpty) return 0;

    final db = await _dbHelper.database;
    int retries = 3;
    int delay = 100; // milliseconds

    while (retries > 0) {
      try {
        // Use transaction for better performance and atomicity
        return await db.transaction((txn) async {
          final batch = txn.batch();
          for (var entry in entries) {
            batch.insert(
              'data_entries',
              entry.toMap(),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await batch.commit(noResult: false);
          return entries.length;
        });
      } catch (e) {
        final errorStr = e.toString().toLowerCase();
        if ((errorStr.contains('database is locked') ||
                errorStr.contains('locked')) &&
            retries > 1) {
          retries--;
          await Future.delayed(Duration(milliseconds: delay));
          delay *= 2; // Exponential backoff
          continue;
        }
        print('Database batch insert error: $e');
        rethrow;
      }
    }
    throw Exception('Failed to batch insert data entries after retries');
  }

  Future<List<DataEntry>> getDataEntriesByTopic(
    String topicName, {
    int? limit,
    int? offset,
    int? experimentId, // Filter by experiment if provided
  }) async {
    final db = await _dbHelper.database;
    String whereClause;
    List<dynamic> whereArgs;

    if (experimentId != null) {
      whereClause = 'topic_name = ? AND experiment_id = ?';
      whereArgs = [topicName, experimentId];
    } else {
      whereClause = 'topic_name = ?';
      whereArgs = [topicName];
    }

    final List<Map<String, dynamic>> maps = await db.query(
      'data_entries',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => DataEntry.fromMap(maps[i]));
  }

  Future<List<DataEntry>> getLatestDataEntriesByTopic(
    String topicName,
    int count,
  ) async {
    return await getDataEntriesByTopic(topicName, limit: count);
  }

  Future<List<DataEntry>> getDataEntriesByExperiment(
    int experimentId, {
    int? limit,
    int? offset,
  }) async {
    final db = await _dbHelper.database;
    // Query directly by experiment_id (much more efficient and correct)
    final List<Map<String, dynamic>> maps = await db.query(
      'data_entries',
      where: 'experiment_id = ?',
      whereArgs: [experimentId],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => DataEntry.fromMap(maps[i]));
  }

  // Get data entries for a specific session
  Future<List<DataEntry>> getDataEntriesBySessionId(int sessionId) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'data_entries',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp DESC',
    );
    return List.generate(maps.length, (i) => DataEntry.fromMap(maps[i]));
  }

  // Export/Import functions
  Future<Map<String, dynamic>> exportExperiment(
    int experimentId, {
    int? sessionLimit,
  }) async {
    final experiment = await getExperimentById(experimentId);
    if (experiment == null) {
      throw Exception('Experiment not found');
    }

    final topics = await getTopicsByExperimentId(experimentId);

    // Get sessions for this experiment
    final sessions = await getSessionsByExperimentId(experimentId);

    // If sessionLimit is provided, only export recent sessions
    final sessionsToExport =
        sessionLimit != null && sessions.length > sessionLimit
        ? sessions.take(sessionLimit).toList()
        : sessions;

    // Get data entries (limit to 5000 entries max to avoid huge JSON files)
    // For large datasets, consider exporting by session separately
    List<DataEntry> dataEntries = await getDataEntriesByExperiment(
      experimentId,
      limit: 5000,
    );

    // If there are many entries, sort by timestamp and take most recent
    if (dataEntries.length >= 5000) {
      dataEntries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      dataEntries = dataEntries.take(5000).toList();
    }

    return {
      'experiment': experiment.toJson(),
      'topics': topics.map((t) => t.toJson()).toList(),
      'sessions': sessionsToExport.map((s) => s.toJson()).toList(),
      'data_entries': dataEntries.map((e) => e.toJson()).toList(),
      'export_info': {
        'exported_at': DateTime.now().millisecondsSinceEpoch,
        'total_sessions': sessions.length,
        'exported_sessions': sessionsToExport.length,
        'total_entries': dataEntries.length,
      },
    };
  }

  Future<void> importExperiment(Map<String, dynamic> jsonData) async {
    final experimentJson = jsonData['experiment'] as Map<String, dynamic>;
    final topicsJson = jsonData['topics'] as List<dynamic>;
    final dataEntriesJson = jsonData['data_entries'] as List<dynamic>;

    // Create experiment (without id to get new auto-increment id)
    final experiment = Experiment.fromJson(experimentJson);
    final newExperimentId = await createExperiment(
      Experiment(
        name: experiment.name,
        createdAt: experiment.createdAt,
        isActive: false, // Imported experiments are inactive by default
      ),
    );

    // Create topics
    for (var topicJson in topicsJson) {
      final topic = Topic.fromJson(topicJson as Map<String, dynamic>);
      await createTopic(
        Topic(
          experimentId: newExperimentId,
          name: topic.name,
          enabled: topic.enabled,
          samplingRate: topic.samplingRate,
        ),
      );
    }

    // Create data entries
    final dataEntries = dataEntriesJson
        .map((e) => DataEntry.fromJson(e as Map<String, dynamic>))
        .toList();

    if (dataEntries.isNotEmpty) {
      await batchInsertDataEntries(
        dataEntries
            .map(
              (e) => DataEntry(
                timestamp: e.timestamp,
                topicName: e.topicName,
                experimentId: newExperimentId, // Use the new experiment ID
                sessionId: e.sessionId, // Preserve session ID if present
                data: e.data,
              ),
            )
            .toList(),
      );
    }
  }

  Future<void> exportExperimentToFile(int experimentId, String filePath) async {
    final experiment = await getExperimentById(experimentId);
    if (experiment == null) {
      throw Exception('Experiment not found');
    }

    final sessions = await getSessionsByExperimentId(experimentId);
    final topics = await getTopicsByExperimentId(experimentId);

    // Create ZIP archive with per-session JSON files
    final archive = Archive();

    // Add experiment metadata
    final experimentJson = jsonEncode({
      'experiment': experiment.toJson(),
      'topics': topics.map((t) => t.toJson()).toList(),
      'total_sessions': sessions.length,
    });
    archive.addFile(
      ArchiveFile(
        'experiment_metadata.json',
        experimentJson.length,
        experimentJson.codeUnits,
      ),
    );

    // Add each session as a separate JSON file
    for (var session in sessions) {
      try {
        final sessionData = await exportSession(session.id!);
        final sessionJson = jsonEncode(sessionData);
        final sessionFilename =
            'session_${session.sessionNumber}_${session.id}.json';
        archive.addFile(
          ArchiveFile(
            sessionFilename,
            sessionJson.length,
            sessionJson.codeUnits,
          ),
        );
      } catch (e) {
        print('Error exporting session ${session.id}: $e');
        // Continue with other sessions
      }
    }

    // Write ZIP file
    final zipEncoder = ZipEncoder();
    final zipData = zipEncoder.encode(archive);

    final file = File(filePath);
    await file.writeAsBytes(zipData);
  }

  // Export single session to file
  Future<void> exportSessionToFile(int sessionId, String filePath) async {
    if (sessionId == 0) {
      throw Exception('Invalid session ID');
    }
    final exportData = await exportSession(sessionId);
    final jsonString = jsonEncode(exportData);
    final file = File(filePath);
    await file.writeAsString(jsonString);
  }

  Future<void> importExperimentFromFile(String filePath) async {
    final file = File(filePath);
    final jsonString = await file.readAsString();
    final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
    await importExperiment(jsonData);
  }

  // Get export directory path
  // Uses Downloads folder on Android (accessible via file managers)
  // Uses Documents folder on iOS (accessible via Files app)
  Future<String> getExportDirectory() async {
    if (Platform.isAndroid) {
      // Try to get Downloads folder - accessible via file managers
      // Common paths: /storage/emulated/0/Download or /sdcard/Download
      final List<String> possiblePaths = [
        '/storage/emulated/0/Download/BP_Mobile',
        '/sdcard/Download/BP_Mobile',
        '/storage/emulated/0/Download',
        '/sdcard/Download',
      ];

      // Try each path and use the first one that exists or can be created
      for (var path in possiblePaths) {
        try {
          final directory = Directory(path);
          if (await directory.exists()) {
            return directory.path;
          }
          // Try to create the directory
          await directory.create(recursive: true);
          if (await directory.exists()) {
            return directory.path;
          }
        } catch (e) {
          // Continue to next path
          continue;
        }
      }

      // Fallback: try to get external storage and navigate to Downloads
      try {
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          // Navigate up from Android/data/... to Downloads
          final parent = externalDir.parent.parent.parent.parent;
          final downloadsPath = '${parent.path}/Download/BP_Mobile';
          final downloadsDir = Directory(downloadsPath);
          if (await downloadsDir.exists()) {
            return downloadsDir.path;
          }
          // Try to create the directory
          await downloadsDir.create(recursive: true);
          if (await downloadsDir.exists()) {
            return downloadsDir.path;
          }
        }
      } catch (e) {
        // Fall through to last resort
      }

      // Last resort: use external storage directory
      final directory = await getExternalStorageDirectory();
      return directory?.path ?? '';
    } else if (Platform.isIOS) {
      // iOS: Use Documents directory (accessible via Files app)
      final directory = await getApplicationDocumentsDirectory();
      return directory.path;
    }
    return '';
  }

  // Session management
  Future<int> createSession(Session session) async {
    final db = await _dbHelper.database;
    return await db.insert('sessions', session.toMap());
  }

  Future<Session?> getSessionById(int id) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return Session.fromMap(maps.first);
  }

  Future<List<Session>> getSessionsByExperimentId(int experimentId) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'sessions',
      where: 'experiment_id = ?',
      whereArgs: [experimentId],
      orderBy: 'session_number DESC',
    );
    return List.generate(maps.length, (i) => Session.fromMap(maps[i]));
  }

  Future<int> getNextSessionNumber(int experimentId) async {
    final db = await _dbHelper.database;
    try {
      final result = await db.rawQuery(
        'SELECT MAX(session_number) as max FROM sessions WHERE experiment_id = ?',
        [experimentId],
      );
      final max = Sqflite.firstIntValue(result);
      return (max ?? 0) + 1;
    } catch (e) {
      // If sessions table doesn't exist, return 1
      print('Warning: Could not get next session number: $e');
      return 1;
    }
  }

  // Get storage size for a specific experiment
  Future<int> getExperimentStorageSize(int experimentId) async {
    final db = await _dbHelper.database;
    try {
      // Count entries for this experiment directly by experiment_id
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM data_entries WHERE experiment_id = ?',
        [experimentId],
      );
      final count = Sqflite.firstIntValue(result) ?? 0;

      // Estimate: ~500 bytes per entry
      return count * 500;
    } catch (e) {
      print('Error getting experiment storage size: $e');
      return 0;
    }
  }

  // Export a single session
  Future<Map<String, dynamic>> exportSession(int sessionId) async {
    final session = await getSessionById(sessionId);
    if (session == null) {
      throw Exception('Session not found');
    }

    final experiment = await getExperimentById(session.experimentId);
    if (experiment == null) {
      throw Exception('Experiment not found');
    }

    final topics = await getTopicsByExperimentId(session.experimentId);
    final dataEntries = await getDataEntriesBySessionId(sessionId);

    return {
      'session': session.toJson(),
      'experiment': experiment.toJson(),
      'experiment_id': session.experimentId, // Include experiment ID explicitly
      'topics': topics.map((t) => t.toJson()).toList(),
      'data_entries': dataEntries.map((e) => e.toJson()).toList(),
      'export_info': {
        'exported_at': DateTime.now().millisecondsSinceEpoch,
        'total_entries': dataEntries.length,
      },
    };
  }

  // Get session-specific storage size
  Future<int> getSessionStorageSize(int sessionId) async {
    final db = await _dbHelper.database;
    try {
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM data_entries WHERE session_id = ?',
        [sessionId],
      );
      final count = Sqflite.firstIntValue(result) ?? 0;
      return count * 500; // Estimate: ~500 bytes per entry
    } catch (e) {
      print('Error getting session storage size: $e');
      return 0;
    }
  }

  // Get session-specific entry count
  Future<int> getSessionEntryCount(int sessionId) async {
    final db = await _dbHelper.database;
    try {
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM data_entries WHERE session_id = ?',
        [sessionId],
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      print('Error getting session entry count: $e');
      return 0;
    }
  }

  Future<int> updateSession(Session session) async {
    final db = await _dbHelper.database;
    return await db.update(
      'sessions',
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }

  Future<int> deleteSession(int id) async {
    final db = await _dbHelper.database;
    return await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }
}
