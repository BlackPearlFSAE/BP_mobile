import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../main.dart';
import '../../models/history_session.dart';
import '../../providers/experiment_provider.dart';
import '../../providers/recording_provider.dart';
import '../../repositories/experiment_repository.dart';
import '../experiments/experiment_list_screen.dart';
import '../publishers/publishers_view_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/network_settings_screen.dart';
import '../settings/client_management_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int _selectedIndex = 0;
  Future<Map<String, dynamic>>? _dashboardDataFuture;
  Timer? _refreshTimer;

  // --- STATE ---
  bool _isMarking = false;
  final TextEditingController _driverController = TextEditingController(
    text: "Driver",
  );
  List<String> _liveLogs = [];
  List<HistorySession> _historyList = [];
  int _currentSessionNum = 1;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _driverController.dispose();
    super.dispose();
  }

  // --- PERSISTENCE LOGIC ---
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('mark_history_data');
    if (data != null) {
      final List<dynamic> decoded = json.decode(data);
      setState(() {
        _historyList = decoded
            .map((item) => HistorySession.fromJson(item))
            .toList();
      });
    }
  }

  Future<void> _persistHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = json.encode(
      _historyList.map((s) => s.toJson()).toList(),
    );
    await prefs.setString('mark_history_data', encoded);
  }

  // --- AUTO-INCREMENT LOGIC BY DRIVER NAME ---
  int _calculateNextNumber(String driverName) {
    if (_historyList.isEmpty) return 1;
    final sameDriverSessions = _historyList.where((s) {
      return s.driverName.trim().toLowerCase() ==
          driverName.trim().toLowerCase();
    }).toList();

    if (sameDriverSessions.isEmpty) return 1;

    int maxNum = 0;
    for (var s in sameDriverSessions) {
      if (s.sessionNumber > maxNum) maxNum = s.sessionNumber;
    }
    return maxNum + 1;
  }

  void _toggleMarking() {
    final recordingState = ref.read(recordingStateProvider);
    final activeExp = recordingState.activeExperiment;

    setState(() {
      if (_isMarking) {
        if (_liveLogs.isNotEmpty) {
          final expId = activeExp?.id;
          final String generatedRunId =
              "${_driverController.text} - ${_currentSessionNum.toString().padLeft(2, '0')} - ${expId ?? 'NoExp'}";

          final newSession = HistorySession(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            driverName: _driverController.text,
            runId: generatedRunId,
            sessionNumber: _currentSessionNum,
            experimentId: expId,
            date: DateTime.now(),
            logs: List.from(_liveLogs),
          );
          _historyList.insert(0, newSession);
          _persistHistory();
        }
        _isMarking = false;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Marker Session Saved')));
      } else {
        _currentSessionNum = _calculateNextNumber(_driverController.text);
        final expInfo = activeExp != null
            ? "EXP ID: ${activeExp.id}"
            : "Manual Run";
        final header =
            "${_driverController.text.toUpperCase()} | RUN #${_currentSessionNum.toString().padLeft(2, '0')} | $expInfo";
        _liveLogs = [header];
        _isMarking = true;
      }
    });
  }

  void _addMarkLog(String category, String eventName) {
    if (!_isMarking) return;
    final String timestamp = DateFormat(
      'yyyy.MM.dd HH:mm:ss',
    ).format(DateTime.now());

    // Format: CATEGORY: event
    final String formattedEntry = "$category: $eventName";

    setState(() => _liveLogs.insert(1, "$timestamp | $formattedEntry"));
  }

  // --- CUSTOM LOG DIALOG ---
  void _showCustomLogDialog() {
    if (!_isMarking) return;
    final TextEditingController customController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Custom Log"),
        content: TextField(
          controller: customController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "Enter your message...",
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCEL"),
          ),
          ElevatedButton(
            onPressed: () {
              if (customController.text.trim().isNotEmpty) {
                _addMarkLog("CUSTOM", customController.text.trim());
              }
              Navigator.pop(context);
            },
            child: const Text("SAVE"),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENTS ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BP Mobile'),
        backgroundColor: AppColors.main,
        foregroundColor: Colors.white,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: _buildDrawer(context),
      body: _buildBody(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        selectedItemColor: AppColors.main,
        unselectedItemColor: AppColors.textSecondary,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.science),
            label: 'Experiments',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.sensors),
            label: 'Publishers',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.edit_note), label: 'Marker'),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_selectedIndex) {
      case 0:
        return _buildDashboardView();
      case 1:
        return const ExperimentListScreen();
      case 2:
        return const PublishersViewScreen();
      case 3:
        return _buildMarkView();
      default:
        return _buildDashboardView();
    }
  }

  Widget _buildMarkView() {
    final activeExp = ref.watch(recordingStateProvider).activeExperiment;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _driverController,
                  decoration: const InputDecoration(
                    labelText: 'Driver Name',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "LINKING EXP:",
                      style: TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                    Text(
                      activeExp != null ? "ID: ${activeExp.id}" : "MANUAL MODE",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: activeExp != null ? Colors.blue : Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 45,
            child: ElevatedButton.icon(
              onPressed: _toggleMarking,
              icon: Icon(_isMarking ? Icons.stop : Icons.play_arrow),
              label: Text(_isMarking ? "STOP MARKING" : "START MARKING"),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isMarking ? Colors.red : Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 160,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[800]!),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _liveLogs.length,
              itemBuilder: (context, index) => Text(
                _liveLogs[index],
                style: TextStyle(
                  color: index == 0 ? Colors.yellowAccent : Colors.greenAccent,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: index == 0 ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          _buildMarkGridSection(
            "DRIVER ACTION",
            ["PIT IN", "PIT OUT", "OFF-TRACK", "TURN", "CRASH", "OVERTAKE"],
            Colors.blueGrey,
            "DRIVER ACTION",
          ),

          _buildMarkGridSection(
            "CAR REACTION",
            ["FAILURE", "ISSUE", "CUSTOM"],
            Colors.blue,
            "CAR REACTION",
          ),

          const Text(
            "FLAGS",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                "🟡",
                "🔴",
                "⚫",
                "🔵",
                "🟢",
                "🏁",
              ].map((f) => _flagIcon(f)).toList(),
            ),
          ),
          const SizedBox(height: 24),

          // --- ADDED RACE MODE SECTION ---
          _buildMarkGridSection(
            "VEHICLE SETUP",
            ["ENDURANCE", "AUTOCROSS", "SKIDPAD", "ACCELERATION", "CUSTOM"],
            Colors.deepPurple,
            "RACE MODE",
          ),

          const Divider(height: 30),
          Center(
            child: TextButton.icon(
              onPressed: _showHistorySheet,
              icon: const Icon(Icons.history),
              label: const Text("VIEW HISTORY"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarkGridSection(
    String title,
    List<String> items,
    Color color,
    String category,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 2.2,
          ),
          itemBuilder: (context, index) {
            final itemName = items[index];
            return ElevatedButton(
              onPressed: _isMarking
                  ? () {
                      if (itemName == "CUSTOM") {
                        _showCustomLogDialog();
                      } else {
                        _addMarkLog(category, itemName);
                      }
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: Text(
                itemName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize:
                      11, // Adjusted slightly for longer text like ACCELERATION
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _flagIcon(String emoji) {
    return InkWell(
      onTap: _isMarking
          ? () {
              // Convert Emoji to English Text for the log
              String textLabel;
              switch (emoji) {
                case "🟡":
                  textLabel = "YELLOW FLAG";
                  break;
                case "🔴":
                  textLabel = "RED FLAG";
                  break;
                case "⚫":
                  textLabel = "BLACK FLAG";
                  break;
                case "🔵":
                  textLabel = "BLUE FLAG";
                  break;
                case "🟢":
                  textLabel = "GREEN FLAG";
                  break;
                case "🏁":
                  textLabel = "CHECKERED FLAG";
                  break;
                default:
                  textLabel = "UNKNOWN FLAG";
              }
              _addMarkLog("FLAG", textLabel);
            }
          : null,
      child: Container(
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _isMarking ? Colors.white : Colors.grey[300],
          shape: BoxShape.circle,
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 22)),
      ),
    );
  }

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          Map<int?, List<HistorySession>> grouped = {};
          for (var s in _historyList) {
            grouped.putIfAbsent(s.experimentId, () => []).add(s);
          }

          return Container(
            height: MediaQuery.of(context).size.height * 0.75,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text(
                  "SESSION HISTORY",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Divider(),
                Expanded(
                  child: grouped.isEmpty
                      ? const Center(child: Text("No records found"))
                      : ListView(
                          children: grouped.entries.map((entry) {
                            return ExpansionTile(
                              initiallyExpanded: true,
                              title: Text(
                                entry.key != null
                                    ? "Experiment ID: ${entry.key}"
                                    : "Manual Runs (No Exp)",
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue,
                                ),
                              ),
                              children: entry.value
                                  .map(
                                    (session) => ListTile(
                                      dense: true,
                                      title: Text(
                                        session.runId,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      subtitle: Text(
                                        DateFormat(
                                          'yyyy.MM.dd HH:mm',
                                        ).format(session.date),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(
                                              Icons.share,
                                              size: 20,
                                            ),
                                            onPressed: () =>
                                                _exportLogs(session),
                                          ),
                                          IconButton(
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              size: 20,
                                              color: Colors.redAccent,
                                            ),
                                            onPressed: () {
                                              setState(() {
                                                _historyList.removeWhere(
                                                  (s) => s.id == session.id,
                                                );
                                              });
                                              setModalState(() {});
                                              _persistHistory();
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                  .toList(),
                            );
                          }).toList(),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // --- DASHBOARD DATA & REFRESH ---
  void _refreshDashboardData(WidgetRef ref) {
    final repository = ref.read(experimentRepositoryProvider);
    _dashboardDataFuture = _getDashboardData(repository);
  }

  Future<Map<String, dynamic>> _getDashboardData(
    ExperimentRepository repository,
  ) async {
    await repository.cleanupOrphanedEntries();
    final totalStorage = await repository.getStorageSizeEstimate();
    final totalEntries = await repository.getTotalDataEntriesCount();
    final experiments = await repository.getAllExperiments();
    return {
      'totalStorage': totalStorage,
      'totalEntries': totalEntries,
      'totalExperiments': experiments.length,
    };
  }

  Widget _buildDashboardView() {
    final recordingState = ref.watch(recordingStateProvider);
    if (_dashboardDataFuture == null) _refreshDashboardData(ref);
    return FutureBuilder<Map<String, dynamic>>(
      future: _dashboardDataFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        final data = snapshot.data ?? {};
        return RefreshIndicator(
          onRefresh: () async {
            _refreshDashboardData(ref);
            setState(() {});
          },
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.access_time, color: AppColors.accent),
                            SizedBox(width: 8),
                            Text(
                              'System Time',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        StreamBuilder<DateTime>(
                          stream: Stream.periodic(
                            const Duration(seconds: 1),
                            (_) => DateTime.now(),
                          ),
                          builder: (context, snapshot) {
                            final now = snapshot.data ?? DateTime.now();
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  DateFormat('yyyy-MM-dd').format(now),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  DateFormat('HH:mm:ss').format(now),
                                  style: const TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildQuickStat(
                          'Experiments',
                          (data['totalExperiments'] ?? 0).toString(),
                          Icons.science,
                        ),
                        _buildQuickStat(
                          'Entries',
                          (recordingState.isRecording
                                  ? recordingState.totalEntries
                                  : (data['totalEntries'] ?? 0))
                              .toString(),
                          Icons.data_object,
                        ),
                        _buildQuickStat(
                          'Storage',
                          _formatBytesShort(
                            recordingState.isRecording
                                ? recordingState.storageSizeBytes
                                : (data['totalStorage'] ?? 0),
                          ),
                          Icons.storage,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildQuickStat(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: AppColors.accent, size: 32),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  String _formatBytesShort(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
  }

  Future<void> _exportLogs(HistorySession session) async {
    final String content =
        "Driver: ${session.driverName}\nRun: ${session.runId}\nDate: ${session.date}\n\nLogs:\n${session.logs.join('\n')}";
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/${session.runId.replaceAll(" ", "_")}.txt',
    );
    await file.writeAsString(content);
    await Share.shareXFiles([
      XFile(file.path),
    ], text: 'Log Export: ${session.runId}');
  }

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: AppColors.main),
            child: Text(
              'BP Mobile',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: const Text('Network Settings'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const NetworkSettingsScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('General Settings'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
