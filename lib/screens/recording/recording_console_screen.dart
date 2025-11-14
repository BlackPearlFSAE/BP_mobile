import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../main.dart';
import '../../models/data_entry.dart';
import '../../providers/recording_provider.dart';

class RecordingConsoleScreen extends ConsumerStatefulWidget {
  final int experimentId;

  const RecordingConsoleScreen({super.key, required this.experimentId});

  @override
  ConsumerState<RecordingConsoleScreen> createState() =>
      _RecordingConsoleScreenState();
}

class _RecordingConsoleScreenState
    extends ConsumerState<RecordingConsoleScreen> {
  @override
  // Toggle for sending data to API
  bool _sendToApiEnabled = true; // default true
  void initState() {
    super.initState();
    // Refresh state when screen is opened
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshState();
    });
  }

  void _refreshState() {
    // Force refresh of recording state when screen opens
    // This ensures state is synced even if navigation was interrupted
    ref.read(recordingStateProvider);
  }

  @override
  Widget build(BuildContext context) {
    final recordingState = ref.watch(recordingStateProvider);

    // Check if actually recording for this experiment
    // Use recordingState which is kept in sync via streams
    final isActuallyRecording =
        recordingState.isRecording &&
        recordingState.activeExperiment?.id == widget.experimentId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recording Console'),
        backgroundColor: AppColors.main,
        foregroundColor: Colors.white,
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: AppColors.main,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Session ${recordingState.sessionNumber}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Statistics section
          _buildStatisticsSection(context, recordingState),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Send data to API',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                Switch(
                  value: _sendToApiEnabled,
                  onChanged: (value) {
                    setState(() {
                      _sendToApiEnabled = value;
                    });

                    // Update service toggle
                    final service = ref.read(recordingServiceProvider);
                    service.toggleSendToApi(value);

                    // Optional: feedback
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          value
                              ? 'Sending to API enabled'
                              : 'Sending to API disabled',
                        ),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          const Divider(),

          // Publisher status indicators
          _buildPublisherStatusSection(context, recordingState),

          const Divider(),

          // Data log console
          Expanded(child: _buildDataLogConsole(context, recordingState)),

          // Stop button
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: isActuallyRecording
                    ? () => _stopRecording(context, ref)
                    : () {
                        // If not recording, navigate back
                        Navigator.pop(context);
                      },
                icon: Icon(isActuallyRecording ? Icons.stop : Icons.close),
                label: Text(
                  isActuallyRecording ? 'Stop Recording' : 'Recording Stopped',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isActuallyRecording
                      ? AppColors.main
                      : AppColors.textSecondary,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatisticsSection(BuildContext context, RecordingState state) {
    String formatBytes(int bytes) {
      if (bytes < 1024) return '$bytes B';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      if (bytes < 1024 * 1024 * 1024) {
        return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
      }
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }

    return Container(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          // Session-specific stats
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  const Text(
                    'Session Entries',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${state.sessionEntries}',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              Container(width: 1, height: 40, color: AppColors.textTertiary),
              Column(
                children: [
                  const Text(
                    'Session Storage',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatBytes(state.sessionStorageBytes),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 12),
          // Global stats (smaller)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  const Text(
                    'Total Entries',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${state.totalEntries}',
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              Container(width: 1, height: 30, color: AppColors.textTertiary),
              Column(
                children: [
                  const Text(
                    'Total Storage',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatBytes(state.storageSizeBytes),
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPublisherStatusSection(
    BuildContext context,
    RecordingState state,
  ) {
    if (state.publisherStatus.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Text('No active publishers'),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16.0),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: state.publisherStatus.entries.map((entry) {
          final isActive = entry.value;
          return Chip(
            avatar: CircleAvatar(
              backgroundColor: isActive
                  ? AppColors.accent
                  : AppColors.textSecondary,
              radius: 8,
            ),
            label: Text(
              entry.key,
              style: TextStyle(
                color: isActive ? AppColors.accent : AppColors.textSecondary,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: isActive
                ? AppColors.accent.withValues(alpha: 0.1)
                : AppColors.surface,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDataLogConsole(BuildContext context, RecordingState state) {
    if (state.latestEntries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.code, size: 64, color: AppColors.textTertiary),
            const SizedBox(height: 16),
            const Text(
              'Waiting for data...',
              style: TextStyle(fontSize: 18, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: state.latestEntries.length,
      itemBuilder: (context, index) {
        final topicName = state.latestEntries.keys.elementAt(index);
        final entries = state.latestEntries[topicName] ?? [];

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ExpansionTile(
            title: Text(
              topicName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('${entries.length} entries (last 5)'),
            leading: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: state.publisherStatus[topicName] == true
                    ? AppColors.accent
                    : AppColors.textSecondary,
                shape: BoxShape.circle,
              ),
            ),
            children: entries.isEmpty
                ? [const ListTile(title: Text('No data yet'))]
                : entries
                      .map((entry) => _buildDataEntryTile(context, entry))
                      .toList(),
          ),
        );
      },
    );
  }

  Widget _buildDataEntryTile(BuildContext context, DataEntry entry) {
    final timestamp = DateTime.fromMillisecondsSinceEpoch(entry.timestamp);
    final timeString = DateFormat('HH:mm:ss.SSS').format(timestamp);

    // Preview data (show first few fields)
    final dataPreview = entry.data.entries
        .take(3)
        .map((e) {
          final value = e.value;
          String valueStr;
          if (value is double) {
            valueStr = value.toStringAsFixed(2);
          } else if (value is int) {
            valueStr = value.toString();
          } else {
            valueStr = value.toString();
          }
          return '${e.key}: $valueStr';
        })
        .join(', ');

    return ListTile(
      dense: true,
      leading: const Icon(Icons.circle, size: 8),
      title: Text(
        timeString,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      ),
      subtitle: Text(
        dataPreview,
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.visibility, size: 16),
        onPressed: () => _showDataDetails(context, entry),
      ),
    );
  }

  void _showDataDetails(BuildContext context, DataEntry entry) {
    final timestamp = DateTime.fromMillisecondsSinceEpoch(entry.timestamp);
    final timeString = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(timestamp);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.topicName),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Timestamp: $timeString'),
              const SizedBox(height: 16),
              const Text(
                'Data:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...entry.data.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Text('${e.key}: ${e.value}'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _stopRecording(BuildContext context, WidgetRef ref) async {
    // Always allow stopping - check both provider and service state
    final recordingState = ref.read(recordingStateProvider);
    final service = ref.read(recordingServiceProvider);

    // If already stopped, just navigate back
    if (!recordingState.isRecording && !service.isRecording) {
      if (context.mounted) {
        Navigator.pop(context);
      }
      return;
    }

    // Stop immediately without confirmation for faster response
    try {
      // Stop via provider first
      await ref.read(recordingStateProvider.notifier).stopRecording();
    } catch (e) {
      // If provider fails, stop service directly as fallback
      print('Error stopping via provider, trying service directly: $e');
      try {
        await service.stopRecording();
      } catch (e2) {
        print('Error stopping service directly: $e2');
      }
    }

    // Invalidate provider to force state update
    ref.invalidate(recordingStateProvider);

    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recording stopped'),
          backgroundColor: AppColors.accent,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }
}
