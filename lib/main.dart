import 'dart:async';
import 'dart:convert'; // 用于JSON转换
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 本地存储
import 'package:intl/intl.dart'; // 时间格式化

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '智能坐姿管家',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.indigo, useMaterial3: true),
      home: const ConnectionPage(),
    );
  }
}

// ==================== 1. 连接页面 ====================
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final TextEditingController _ipController = TextEditingController(text: "192.168.");
  final TextEditingController _portController = TextEditingController(text: "5000");

  void _connect() {
    String ip = _ipController.text.trim();
    String port = _portController.text.trim();
    if (ip.isEmpty || port.isEmpty) return;
    String fullUrl = "http://$ip:$port";
    Navigator.push(context, MaterialPageRoute(builder: (context) => PostureHomePage(serverUrl: fullUrl)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("连接设备")),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            TextField(controller: _ipController, decoration: const InputDecoration(labelText: "IP 地址", border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _portController, decoration: const InputDecoration(labelText: "端口", border: OutlineInputBorder())),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _connect, child: const Text("开始连接")),
          ],
        ),
      ),
    );
  }
}

// ==================== 2. 主页面 (实时数据) ====================
class PostureHomePage extends StatefulWidget {
  final String serverUrl;
  const PostureHomePage({super.key, required this.serverUrl});
  @override
  State<PostureHomePage> createState() => _PostureHomePageState();
}

class _PostureHomePageState extends State<PostureHomePage> {
  late IO.Socket socket;
  String connectionStatus = "连接中...";
  
  // 实时数据
  String postureText = "等待数据...";
  bool isBadPosture = false;
  int sitTimeSeconds = 0;
  List<double> pressureData = [0.0, 0.0, 0.0, 0.0];

  // 记录控制
  DateTime lastLogTime = DateTime.now(); // 上次记录的时间
  final int logInterval = 5; // 每隔 5 秒记录一次 (防止存储爆炸)

  @override
  void initState() {
    super.initState();
    initSocket();
  }

  void initSocket() {
    socket = IO.io(widget.serverUrl, IO.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build());
    socket.connect();

    socket.onConnect((_) => setState(() => connectionStatus = "已连接"));
    socket.onDisconnect((_) => setState(() => connectionStatus = "已断开"));

    socket.on('server_update', (data) {
      if (!mounted) return;
      
      setState(() {
        postureText = data['posture_text'] ?? "未知";
        isBadPosture = data['is_bad'] ?? false;
        sitTimeSeconds = data['sit_time'] ?? 0;
        if (data['pressure_data'] != null) {
          pressureData = List<double>.from(data['pressure_data']);
        }
      });

      // --- 核心修改：在手机端记录数据 ---
       // 1. 保存历史记录
      _saveLogLocally(postureText, isBadPosture);
      
      // 2. 检查是否需要震动 (加上这一行！)
      checkAndVibrate(); 
    });
  }
  DateTime lastVibrateTime = DateTime.now(); // 补上这行
  final int vibrateCooldown = 10;            // 补上这行
  final int sedentaryLimit = 45 * 60;        // 补上这行

  // 补上这个核心震动函数
  Future<void> checkAndVibrate() async {
    // 检查是否有震动硬件
    if (await Vibration.hasVibrator() != true) return;

    DateTime now = DateTime.now();
    // 冷却时间检查
    if (now.difference(lastVibrateTime).inSeconds < vibrateCooldown) {
      return;
    }

    // 震动逻辑
    if (sitTimeSeconds > sedentaryLimit) {
      Vibration.vibrate(pattern: [0, 1000, 500, 1000]); // 久坐长震
      lastVibrateTime = now;
    } else if (isBadPosture) {
      Vibration.vibrate(pattern: [0, 100, 100, 100]);   // 姿势坏短震
      lastVibrateTime = now;
    }
  }
  // 保存日志到手机本地
  Future<void> _saveLogLocally(String status, bool isBad) async {
    DateTime now = DateTime.now();
    // 只有当距离上次保存超过 5 秒，或者状态突然变坏时，才保存
    if (now.difference(lastLogTime).inSeconds < logInterval && !isBad) {
      return; 
    }

    final prefs = await SharedPreferences.getInstance();
    List<String> logs = prefs.getStringList('posture_logs') ?? [];

    // 构建一条记录 (JSON格式字符串)
    String logEntry = jsonEncode({
      "time": DateFormat('HH:mm:ss').format(now), // 14:30:05
      "date": DateFormat('yyyy-MM-dd').format(now),
      "status": status,
      "isBad": isBad,
    });

    logs.insert(0, logEntry); // 插到最前面
    
    // 限制只保存最近 200 条，防止手机卡顿
    if (logs.length > 200) {
      logs = logs.sublist(0, 200);
    }

    await prefs.setStringList('posture_logs', logs);
    lastLogTime = now;
  }

  @override
  void dispose() {
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color primaryColor = isBadPosture ? Colors.red : Colors.indigo;
    
    return Scaffold(
      backgroundColor: isBadPosture ? Colors.red.shade50 : Colors.indigo.shade50,
      appBar: AppBar(
        title: const Text("实时监控", style: TextStyle(color: Colors.white)),
        backgroundColor: primaryColor,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          // --- 新增：历史记录按钮 ---
          IconButton(
            icon: const Icon(Icons.history, size: 30),
            tooltip: "查看历史记录",
            onPressed: () {
              // 跳转到历史页面
              Navigator.push(context, MaterialPageRoute(builder: (context) => const HistoryPage()));
            },
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // 状态大卡片
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]
              ),
              child: Column(
                children: [
                  Text(postureText, 
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: primaryColor),
                    textAlign: TextAlign.center),
                  const SizedBox(height: 10),
                  Text("本次坚持: ${sitTimeSeconds}秒", style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // 这里简单显示四个压力值
            Text("连接状态: $connectionStatus", style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

// ==================== 3. 历史记录页面 (新增) ====================
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Map<String, dynamic>> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> rawLogs = prefs.getStringList('posture_logs') ?? [];
    
    setState(() {
      _logs = rawLogs.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
    });
  }

  Future<void> _clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('posture_logs');
    _loadLogs(); // 刷新
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("历史记录"),
        actions: [
          IconButton(icon: const Icon(Icons.delete_forever), onPressed: _clearLogs)
        ],
      ),
      body: _logs.isEmpty 
        ? const Center(child: Text("暂无数据，请连接设备坐一会儿")) 
        : ListView.separated(
            itemCount: _logs.length,
            separatorBuilder: (c, i) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final log = _logs[index];
              bool isBad = log['isBad'] ?? false;
              
              return ListTile(
                leading: Icon(
                  isBad ? Icons.warning : Icons.check_circle,
                  color: isBad ? Colors.red : Colors.green,
                ),
                title: Text(log['status'] ?? ""),
                subtitle: Text("${log['date']} ${log['time']}"),
                trailing: isBad ? const Text("不良", style: TextStyle(color: Colors.red)) : null,
              );
            },
          ),
    );
  }
}