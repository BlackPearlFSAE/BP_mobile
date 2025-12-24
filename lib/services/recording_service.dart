import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/experiment.dart';
import '../models/topic.dart';
import '../models/data_entry.dart';
import '../models/session.dart';
import '../repositories/experiment_repository.dart';
import 'publishers/topic_publisher.dart';
import 'publishers/publisher.dart';
import 'publisher_manager.dart';

/// Recording Service manages recording state, collects data from publishers,
/// and maintains latest 5 entries per topic for console display
class RecordingService {
  final ExperimentRepository _repository = ExperimentRepository();

  Experiment? _activeExperiment;
  List<Topic>? _enabledTopics; // Store enabled topics for re-subscription
  final Map<String, TopicPublisher> _activePublishers = {};
  final Map<String, StreamSubscription> _subscriptions = {};
  final Map<String, StreamSubscription> _enabledStateSubscriptions =
      {}; // Watch publisher enable/disable
  final Map<String, Queue<DataEntry>> _latestEntries = {};
  final StreamController<Map<String, List<DataEntry>>>
  _latestEntriesController =
      StreamController<Map<String, List<DataEntry>>>.broadcast();

  // Storage tracking
  int _sessionStartCount = 0;
  int _sessionEntriesCount = 0;
  final StreamController<int> _totalEntriesController =
      StreamController<int>.broadcast();
  final StreamController<int> _storageSizeController =
      StreamController<int>.broadcast();
  final StreamController<int> _sessionEntriesController =
      StreamController<int>.broadcast();
  final StreamController<int> _sessionStorageController =
      StreamController<int>.broadcast();

  bool _isRecording = false;
  int _sessionNumber = 0; // Per-experiment session number
  Session? _currentSession;

  // Publisher manager (injected via constructor)
  final PublisherManager _publisherManager;

  RecordingService(this._publisherManager);

  /// Stream of latest entries per topic (max 5 per topic)
  Stream<Map<String, List<DataEntry>>> get latestEntriesStream =>
      _latestEntriesController.stream;

  /// Stream of total entries count
  Stream<int> get totalEntriesStream => _totalEntriesController.stream;

  /// Stream of storage size in bytes
  Stream<int> get storageSizeStream => _storageSizeController.stream;

  /// Stream of session-specific entry count
  Stream<int> get sessionEntriesStream => _sessionEntriesController.stream;

  /// Stream of session-specific storage size
  Stream<int> get sessionStorageStream => _sessionStorageController.stream;

  /// Check if currently recording
  bool get isRecording => _isRecording;

  /// Get active experiment
  Experiment? get activeExperiment => _activeExperiment;

  /// Get session number
  int get sessionNumber => _sessionNumber;

  /// Get current session ID
  int? getCurrentSessionId() => _currentSession?.id;

  /// Start recording for an experiment
  Future<void> startRecording(Experiment experiment, List<Topic> topics) async {
    if (_isRecording) {
      throw Exception(
        'Already recording. Please stop the current recording first.',
      );
    }

    try {
      _activeExperiment = experiment;
      _isRecording = true;

      // Get per-experiment session number
      _sessionNumber = await _repository.getNextSessionNumber(experiment.id!);

      // Get initial count and storage size
      _sessionStartCount = await _repository.getTotalDataEntriesCount();
      _sessionEntriesCount = 0;
      final initialStorage = await _repository.getStorageSizeEstimate();
      _totalEntriesController.add(_sessionStartCount);
      _storageSizeController.add(initialStorage);

      // Create session record (with error handling)
      final now = DateTime.now().millisecondsSinceEpoch;
      _currentSession = Session(
        experimentId: experiment.id!,
        sessionNumber: _sessionNumber,
        startTimestamp: now,
        entryCount: 0,
      );
      try {
        final sessionId = await _repository.createSession(_currentSession!);
        _currentSession = _currentSession!.copyWith(
          id: sessionId,
          startEntryId: _sessionStartCount > 0 ? _sessionStartCount : null,
        );
        // Initialize session-specific counters
        _sessionEntriesController.add(0);
        _sessionStorageController.add(0);
      } catch (e) {
        print('Warning: Could not create session record: $e');
        // Continue anyway - session will be created on first data entry
      }

      // Update experiment to active
      await _repository.updateExperiment(experiment.copyWith(isActive: true));

      // Store enabled topics for re-subscription
      _enabledTopics = topics.where((t) => t.enabled).toList();

      // Initialize latest entries for each enabled topic
      _latestEntries.clear();
      for (var topic in topics) {
        if (topic.enabled) {
          _latestEntries[topic.name] = Queue<DataEntry>();
        }
      }

      // Subscribe to publisher enable/disable state changes for fault tolerance
      _subscribeToPublisherStateChanges();

      // Subscribe to publishers for enabled topics
      // Publishers should already be enabled/started via PublisherManager
      for (var topic in topics) {
        if (!topic.enabled) continue;

        // Subscribe to topic with error handling
        await _subscribeToTopic(topic);
      }

      print(
        'Started recording session $_sessionNumber for experiment ${experiment.name}',
      );
    } catch (e) {
      // Clean up on error
      _isRecording = false;
      _activeExperiment = null;
      _currentSession = null;
      print('Error starting recording: $e');
      rethrow;
    }
  }

  /// Stop recording
  Future<void> stopRecording() async {
    if (!_isRecording) return;

    _isRecording = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final endCount = await _repository.getTotalDataEntriesCount();

    // Stop topic publishers (this stops subscriptions, not underlying publishers)
    for (var publisher in _activePublishers.values) {
      await publisher.stop();
    }

    // Cancel all subscriptions
    for (var subscription in _subscriptions.values) {
      await subscription.cancel();
    }

    // Cancel enabled state subscriptions
    for (var subscription in _enabledStateSubscriptions.values) {
      await subscription.cancel();
    }

    _subscriptions.clear();
    _enabledStateSubscriptions.clear();
    _activePublishers.clear();
    _enabledTopics = null;

    // Note: We don't stop the underlying publishers - they're managed by PublisherManager

    // Update session with end time and entry count
    if (_currentSession != null) {
      try {
        // Get actual entry count from database for accuracy
        final actualEntryCount = _currentSession!.id != null
            ? await _repository.getSessionEntryCount(_currentSession!.id!)
            : _sessionEntriesCount;

        final updatedSession = _currentSession!.copyWith(
          endTimestamp: now,
          entryCount: actualEntryCount,
          endEntryId: endCount > 0 ? endCount : null,
        );

        // Ensure session has an ID before updating
        if (updatedSession.id != null) {
          await _repository.updateSession(updatedSession);
          print(
            'Session ${updatedSession.sessionNumber} updated: ${updatedSession.entryCount} entries',
          );
        } else {
          print('Warning: Session has no ID, cannot update');
        }
      } catch (e) {
        print('Error updating session: $e');
        // Try to update with basic info even if there's an error
        try {
          if (_currentSession!.id != null) {
            final basicSession = _currentSession!.copyWith(
              endTimestamp: now,
              entryCount: _sessionEntriesCount,
            );
            await _repository.updateSession(basicSession);
          }
        } catch (e2) {
          print('Error updating session with fallback: $e2');
        }
      }
      _currentSession = null;
    }

    // Update experiment to inactive
    if (_activeExperiment != null) {
      await _repository.updateExperiment(
        _activeExperiment!.copyWith(isActive: false),
      );
    }

    // Note: We don't stop WebSocket server or publishers - they're managed by PublisherManager

    _activeExperiment = null;
    _latestEntries.clear();

    print('Stopped recording session $_sessionNumber');
  }

  /// Subscribe to a topic with error handling
  Future<void> _subscribeToTopic(Topic topic) async {
    if (_activePublishers.containsKey(topic.name)) {
      // Already subscribed, skip
      return;
    }

    try {
      Publisher? publisher;

      // Determine publisher based on topic name
      if (topic.name.startsWith('gps/')) {
        publisher = _publisherManager.gpsPublisher;
      } else if (topic.name.startsWith('imu/')) {
        publisher = _publisherManager.imuPublisher;
      } else if (_isNetworkTopic(topic.name)) {
        // Network topic (format: client_name/topic_tree)
        // Ensure WebSocket server is initialized
        await _publisherManager.getWebSocketServer();
        publisher = _publisherManager.externalPublisher;
      }

      if (publisher == null) {
        print('Warning: No publisher found for topic ${topic.name}');
        return;
      }

      // Check if publisher is enabled (for fault tolerance)
      String publisherName;
      if (topic.name.startsWith('gps/')) {
        publisherName = 'gps';
      } else if (topic.name.startsWith('imu/')) {
        publisherName = 'imu';
      } else if (_isNetworkTopic(topic.name)) {
        publisherName = 'external';
      } else {
        print('Warning: Unknown topic prefix for ${topic.name}');
        return;
      }

      if (!_publisherManager.isPublisherEnabled(publisherName)) {
        print(
          'Warning: Publisher $publisherName is not enabled for topic ${topic.name}',
        );
        // Don't subscribe yet, but don't throw error - will retry when enabled
        return;
      }

      // Get sampling rate from publisher manager for internal publishers,
      // or from topic metadata for network topics
      double samplingRate;
      if (topic.name.startsWith('gps/')) {
        samplingRate = _publisherManager.getSamplingRate('gps');
      } else if (topic.name.startsWith('imu/')) {
        samplingRate = _publisherManager.getSamplingRate('imu');
      } else if (_isNetworkTopic(topic.name)) {
        // Network topics - get sampling rate from metadata
        final metadata = _publisherManager.getTopicMetadata(topic.name);
        samplingRate =
            metadata?['sampling_rate'] as double? ?? topic.samplingRate;
      } else {
        // Fallback to topic rate
        samplingRate = topic.samplingRate;
      }

      // Wrap publisher with sampling rate
      final topicPublisher = TopicPublisher(
        publisher: publisher,
        topicName: topic.name,
        samplingRate: samplingRate,
      );

      _activePublishers[topic.name] = topicPublisher;

      // Start topic publisher (subscribes to underlying publisher)
      // This doesn't start the underlying publisher - it's managed by PublisherManager
      await topicPublisher.start();

      // Subscribe to topic publisher data stream with robust error handling
      final subscription = topicPublisher.dataStream.listen(
        (data) => _handlePublisherData(topic.name, data),
        onError: (error) {
          print('Error in publisher stream for ${topic.name}: $error');
          // Don't cancel subscription - let it recover
          // The error is logged but doesn't stop other topics
        },
        cancelOnError: false, // Don't cancel on error - keep trying
      );

      _subscriptions[topic.name] = subscription;
      print('Subscribed to topic: ${topic.name}');
    } catch (e) {
      print('Error subscribing to topic ${topic.name}: $e');
      // Don't throw - continue with other topics
      // Remove from active publishers if it was added
      _activePublishers.remove(topic.name);
    }
  }

  /// Unsubscribe from a topic gracefully
  Future<void> _unsubscribeFromTopic(String topicName) async {
    try {
      // Cancel subscription
      final subscription = _subscriptions.remove(topicName);
      if (subscription != null) {
        await subscription.cancel();
      }

      // Stop topic publisher
      final topicPublisher = _activePublishers.remove(topicName);
      if (topicPublisher != null) {
        await topicPublisher.stop();
      }

      print('Unsubscribed from topic: $topicName');
    } catch (e) {
      print('Error unsubscribing from topic $topicName: $e');
      // Continue anyway - clean up as much as possible
      _subscriptions.remove(topicName);
      _activePublishers.remove(topicName);
    }
  }

  /// Subscribe to publisher enable/disable state changes for fault tolerance
  void _subscribeToPublisherStateChanges() {
    if (!_isRecording || _enabledTopics == null) return;

    // Subscribe to each publisher's enabled state stream
    for (var topic in _enabledTopics!) {
      String publisherName;
      if (topic.name.startsWith('gps/')) {
        publisherName = 'gps';
      } else if (topic.name.startsWith('imu/')) {
        publisherName = 'imu';
      } else if (_isNetworkTopic(topic.name)) {
        publisherName = 'external';
      } else {
        continue;
      }

      // Cancel existing subscription if any
      _enabledStateSubscriptions[publisherName]?.cancel();

      // Subscribe to enabled state changes
      _enabledStateSubscriptions[publisherName] = _publisherManager
          .getEnabledStream(publisherName)
          .listen(
            (isEnabled) async {
              if (!_isRecording) return;

              // Find all topics for this publisher
              final topicsForPublisher = _enabledTopics!.where((t) {
                if (publisherName == 'gps') return t.name.startsWith('gps/');
                if (publisherName == 'imu') return t.name.startsWith('imu/');
                if (publisherName == 'external') return _isNetworkTopic(t.name);
                return false;
              }).toList();

              if (isEnabled) {
                // Publisher was enabled - subscribe to topics
                print(
                  'Publisher $publisherName enabled, subscribing to topics',
                );
                for (var topic in topicsForPublisher) {
                  if (!_activePublishers.containsKey(topic.name)) {
                    await _subscribeToTopic(topic);
                  }
                }
              } else {
                // Publisher was disabled - unsubscribe from topics gracefully
                print(
                  'Publisher $publisherName disabled, unsubscribing from topics',
                );
                for (var topic in topicsForPublisher) {
                  await _unsubscribeFromTopic(topic.name);
                }
              }
            },
            onError: (error) {
              print('Error in enabled state stream for $publisherName: $error');
              // Don't cancel - keep watching
            },
            cancelOnError: false,
          );
    }
  }

  /// Handle data from publisher
  Future<void> _handlePublisherData(
    String topicName,
    Map<String, dynamic> data,
  ) async {
    if (!_isRecording || _activeExperiment == null) return;

    // Verify experiment still exists before recording
    try {
      final experiment = await _repository.getExperimentById(
        _activeExperiment!.id!,
      );
      if (experiment == null) {
        // Experiment was deleted, stop recording
        print(
          'Experiment ${_activeExperiment!.id} was deleted, stopping recording',
        );
        await stopRecording();
        return;
      }
    } catch (e) {
      print('Error checking experiment existence: $e');
      // Continue anyway to avoid blocking
    }

    // For network topics, extract topic_name from data if available
    // Network topics come with topic_name in format: client_name/topic_tree
    String actualTopicName = topicName;
    if (_isNetworkTopic(topicName) && data.containsKey('topic_name')) {
      actualTopicName = data['topic_name'] as String;
    }

    // For network topics, check if client is still connected (graceful degradation)
    if (_isNetworkTopic(actualTopicName)) {
      final parts = actualTopicName.split('/');
      if (parts.isNotEmpty) {
        final clientName = parts[0];
        final webSocketServer = _publisherManager.webSocketServer;
        if (webSocketServer != null) {
          final client = webSocketServer.getClient(clientName);
          if (client == null || !client.isConnected) {
            print(
              'Warning: Client $clientName disconnected, topic $actualTopicName unavailable',
            );
            // Don't record this entry, but don't stop recording - other topics continue
            return;
          }
        } else {
          // WebSocket server not initialized, skip this entry
          return;
        }
      }
    }

    try {
      // Create data entry with experiment_id and session_id
      // Extract actual data payload (for network topics, data is nested)
      final dataPayload = data.containsKey('data')
          ? data['data'] as Map<String, dynamic>
          : data; // For internal topics, data is already the payload

      final entry = DataEntry(
        timestamp: data['timestamp'] as int,
        topicName: actualTopicName,
        experimentId: _activeExperiment!.id!,
        sessionId: _currentSession?.id,
        data: dataPayload,
      );

      // Insert into database (with retry logic for database locks)
      await _repository.insertDataEntry(entry);
      _sessionEntriesCount++;
      final payload = entry.toJson();

      // ส่งต่อไป API
      try {
        if (sendToApiEnabled) {
          final res = await http.post(
            Uri.parse('https://mctrl.kmutt.ac.th/ken-api/api/stat/add'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          );

          if (res.statusCode == 201) {
            print('✅ ส่งข้อมูลไป API สำเร็จ');
          } else {
            print('⚠️ ส่ง API ไม่สำเร็จ: ${res.statusCode} ${res.body}');
          }
        } else {
          print(
            '⚠️ Sending to API disabled, stored locally: ${entry.topicName}',
          );
        }
      } catch (e) {
        print('❌ Error sending to API: $e');
      }
      // Update latest entries (keep max 5 per topic)
      if (!_latestEntries.containsKey(topicName)) {
        _latestEntries[topicName] = Queue<DataEntry>();
      }

      final queue = _latestEntries[topicName]!;
      queue.add(entry);
      if (queue.length > 5) {
        queue.removeFirst();
      }

      // Update session-specific counters (every entry for real-time updates)
      _sessionEntriesController.add(_sessionEntriesCount);
      _sessionStorageController.add(_sessionEntriesCount * 500); // Estimate

      // Update total entries count (every 10 entries to reduce DB queries)
      if (_sessionEntriesCount % 10 == 0 || _sessionEntriesCount == 1) {
        final totalCount = await _repository.getTotalDataEntriesCount();
        _totalEntriesController.add(totalCount);

        // Update storage size estimation
        final storageSize = await _repository.getStorageSizeEstimate();
        _storageSizeController.add(storageSize);

        // Update session-specific storage if we have session ID
        if (_currentSession?.id != null) {
          final sessionStorage = await _repository.getSessionStorageSize(
            _currentSession!.id!,
          );
          _sessionStorageController.add(sessionStorage);
        }
      }

      // Emit latest entries
      final latestEntriesMap = Map<String, List<DataEntry>>.fromEntries(
        _latestEntries.entries.map(
          (e) => MapEntry(
            e.key,
            e.value.toList().reversed.toList(), // Most recent first
          ),
        ),
      );
      _latestEntriesController.add(latestEntriesMap);
    } catch (e) {
      print('Error handling publisher data for $topicName: $e');
      // Don't rethrow - continue recording even if one entry fails
    }
  }

  bool sendToApiEnabled = true;

  /// Method to toggle
  void toggleSendToApi(bool value) {
    sendToApiEnabled = value;
    print('Send to API: ${sendToApiEnabled ? "ENABLED" : "DISABLED"}');
  }

  /// Get latest entries for a topic
  List<DataEntry> getLatestEntries(String topicName) {
    return _latestEntries[topicName]?.toList().reversed.toList() ?? [];
  }

  /// Get all latest entries
  Map<String, List<DataEntry>> getAllLatestEntries() {
    return Map<String, List<DataEntry>>.fromEntries(
      _latestEntries.entries.map(
        (e) => MapEntry(
          e.key,
          e.value.toList().reversed.toList(), // Most recent first
        ),
      ),
    );
  }

  /// Get publisher status (from PublisherManager)
  Map<String, bool> getPublisherStatus() {
    return _publisherManager.getPublisherStatus();
  }

  /// Get unavailable topics (configured but not available)
  /// Returns map of topic name -> reason (e.g., "Client disconnected", "Publisher disabled")
  /// Always returns a non-null map, even if recording is not active
  Map<String, String> getUnavailableTopics() {
    try {
      final unavailable = <String, String>{};

      if (!_isRecording || _enabledTopics == null) {
        return unavailable;
      }

      for (var topic in _enabledTopics!) {
        // Check if topic is active
        if (_activePublishers.containsKey(topic.name)) {
          // Topic is active, check if it's a network topic and client is disconnected
          if (_isNetworkTopic(topic.name)) {
            final parts = topic.name.split('/');
            if (parts.isNotEmpty) {
              final clientName = parts[0];
              final webSocketServer = _publisherManager.webSocketServer;
              if (webSocketServer != null) {
                final client = webSocketServer.getClient(clientName);
                if (client == null || !client.isConnected) {
                  unavailable[topic.name] = 'Client $clientName disconnected';
                }
              } else {
                unavailable[topic.name] = 'WebSocket server not initialized';
              }
            }
          }
        } else {
          // Topic is not active - check why
          String publisherName;
          if (topic.name.startsWith('gps/')) {
            publisherName = 'gps';
          } else if (topic.name.startsWith('imu/')) {
            publisherName = 'imu';
          } else if (_isNetworkTopic(topic.name)) {
            publisherName = 'external';
            // Check if client exists
            final parts = topic.name.split('/');
            if (parts.isNotEmpty) {
              final clientName = parts[0];
              final webSocketServer = _publisherManager.webSocketServer;
              if (webSocketServer != null) {
                final client = webSocketServer.getClient(clientName);
                if (client == null) {
                  unavailable[topic.name] = 'Client $clientName not found';
                } else if (!client.isConnected) {
                  unavailable[topic.name] = 'Client $clientName disconnected';
                } else {
                  unavailable[topic.name] = 'Publisher not enabled';
                }
              } else {
                unavailable[topic.name] = 'WebSocket server not initialized';
              }
            } else {
              unavailable[topic.name] = 'Publisher not enabled';
            }
          } else {
            publisherName = 'unknown';
            unavailable[topic.name] = 'Publisher not enabled';
          }

          // Check if publisher is enabled
          if (publisherName != 'unknown' &&
              !_publisherManager.isPublisherEnabled(publisherName)) {
            unavailable[topic.name] = 'Publisher $publisherName disabled';
          }
        }
      }

      return unavailable;
    } catch (e) {
      print('Error in getUnavailableTopics: $e');
      return <String, String>{};
    }
  }

  /// Get current total entries count
  Future<int> getCurrentTotalEntries() async {
    return await _repository.getTotalDataEntriesCount();
  }

  /// Get current storage size
  Future<int> getCurrentStorageSize() async {
    return await _repository.getStorageSizeEstimate();
  }

  /// Dispose resources
  void dispose() {
    stopRecording();

    // Cancel all enabled state subscriptions
    for (var subscription in _enabledStateSubscriptions.values) {
      subscription.cancel();
    }
    _enabledStateSubscriptions.clear();

    _latestEntriesController.close();
    _totalEntriesController.close();
    _storageSizeController.close();
    _sessionEntriesController.close();
    _sessionStorageController.close();
    // Note: Publishers are disposed by PublisherManager
  }

  /// Check if a topic is a network topic (format: client_name/topic_tree)
  bool _isNetworkTopic(String topicName) {
    // Network topics are not internal topics (gps/imu) and contain at least one '/'
    if (topicName.startsWith('gps/') || topicName.startsWith('imu/')) {
      return false;
    }
    // Check if it's a network topic by checking if client exists
    // Format: client_name/topic_tree
    if (!topicName.contains('/')) return false;

    final parts = topicName.split('/');
    if (parts.length < 2) return false;

    // Check if first part is a known client name
    final webSocketServer = _publisherManager.webSocketServer;
    if (webSocketServer != null) {
      final client = webSocketServer.getClient(parts[0]);
      return client != null;
    }

    return false;
  }
}
