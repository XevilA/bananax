import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:avatar_glow/avatar_glow.dart';

// =====================================================
// Configuration & Constants
// =====================================================

class AppConfig {
  static const String geminiApiKey = "AIzaSyC-iSyQeROeHB6XbDPdIDd4TbpFDNAnB2g";
  static const String geminiModel = "gemini-2.5-flash";
  static const String geminiBaseUrl =
      "https://generativelanguage.googleapis.com/v1beta/models";

  // App Settings
  static const int maxImageSize = 4 * 1024 * 1024;
  static const int minImageDimension = 200;
  static const int maxImageDimension = 2048;
  static const double imageQuality = 85;
  
  // Voice Settings
  static const String aiName = "น้องกรีน";
  static const double speechRate = 0.5;
  static const double pitch = 1.0;
  static const double volume = 1.0;
}

// =====================================================
// Main App
// =====================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const LeafDoctorApp());
}

class LeafDoctorApp extends StatelessWidget {
  const LeafDoctorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Leaf Doctor AI - น้องกรีน',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ),
        fontFamily: 'Kanit',
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// =====================================================
// Models
// =====================================================

class ChatMessage {
  final String id;
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final String? imagePath;
  final MessageType type;

  ChatMessage({
    String? id,
    required this.text,
    required this.isUser,
    DateTime? timestamp,
    this.imagePath,
    this.type = MessageType.text,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'isUser': isUser,
      'timestamp': timestamp.toIso8601String(),
      'imagePath': imagePath,
      'type': type.toString(),
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'],
      text: json['text'],
      isUser: json['isUser'],
      timestamp: DateTime.parse(json['timestamp']),
      imagePath: json['imagePath'],
      type: MessageType.values.firstWhere(
        (e) => e.toString() == json['type'],
        orElse: () => MessageType.text,
      ),
    );
  }
}

enum MessageType { text, voice, image, diagnosis }

class Diagnosis {
  final String id;
  final String plant;
  final String part;
  final String disease;
  final String severity;
  final String recommendation;
  final double confidence;
  final List<String> careSteps;
  final DateTime timestamp;
  final String? imagePath;

  Diagnosis({
    String? id,
    required this.plant,
    required this.part,
    required this.disease,
    required this.confidence,
    required this.severity,
    required this.recommendation,
    required this.careSteps,
    DateTime? timestamp,
    this.imagePath,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp = timestamp ?? DateTime.now();

  factory Diagnosis.fromJson(Map<String, dynamic> json) {
    return Diagnosis(
      id: json['id']?.toString(),
      plant: json['plant']?.toString() ?? 'ไม่ทราบ',
      part: json['part']?.toString() ?? 'ใบ',
      disease: json['disease']?.toString() ?? 'ไม่ทราบ',
      confidence: _parseDouble(json['confidence']),
      severity: json['severity']?.toString() ?? 'ไม่ทราบ',
      recommendation: json['recommendation']?.toString() ?? 'ไม่มีคำแนะนำ',
      careSteps: _parseCareSteps(json['careSteps']),
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'])
          : DateTime.now(),
      imagePath: json['imagePath'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'plant': plant,
      'part': part,
      'disease': disease,
      'confidence': confidence,
      'severity': severity,
      'recommendation': recommendation,
      'careSteps': careSteps,
      'timestamp': timestamp.toIso8601String(),
      'imagePath': imagePath,
    };
  }

  static double _parseDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      return parsed ?? 0.0;
    }
    return 0.0;
  }

  static List<String> _parseCareSteps(dynamic value) {
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return <String>[];
  }
}

// =====================================================
// Services
// =====================================================

class VoiceService {
  static final stt.SpeechToText _speech = stt.SpeechToText();
  static final FlutterTts _tts = FlutterTts();
  static bool _isInitialized = false;

  static Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      // Request microphone permission
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        throw Exception('ไม่ได้รับอนุญาตให้เข้าถึงไมโครโฟน');
      }

      // Initialize speech recognition
      _isInitialized = await _speech.initialize(
        onError: (error) => debugPrint('Speech error: $error'),
        onStatus: (status) => debugPrint('Speech status: $status'),
      );

      // Configure TTS
      await _tts.setLanguage('th-TH');
      await _tts.setSpeechRate(AppConfig.speechRate);
      await _tts.setPitch(AppConfig.pitch);
      await _tts.setVolume(AppConfig.volume);

      return _isInitialized;
    } catch (e) {
      debugPrint('Voice initialization error: $e');
      return false;
    }
  }

  static Future<void> startListening({
    required Function(String) onResult,
    required Function() onListening,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_speech.isAvailable) {
      onListening();
      await _speech.listen(
        onResult: (result) {
          if (result.finalResult) {
            onResult(result.recognizedWords);
          }
        },
        localeId: 'th_TH',
        listenMode: stt.ListenMode.confirmation,
      );
    }
  }

  static Future<void> stopListening() async {
    await _speech.stop();
  }

  static Future<void> speak(String text) async {
    await _tts.speak(text);
  }

  static Future<void> stop() async {
    await _tts.stop();
  }

  static bool get isListening => _speech.isListening;
}

class GeminiService {
  static const String _baseUrl = AppConfig.geminiBaseUrl;
  static const String _model = AppConfig.geminiModel;
  static const String _apiKey = AppConfig.geminiApiKey;

  // Image Analysis (original functionality)
  static Future<Diagnosis> analyzePlantImage(File imageFile) async {
    try {
      if (_apiKey.isEmpty || _apiKey == "YOUR_GEMINI_API_KEY_HERE") {
        throw Exception('กรุณาใส่ Gemini API Key ในไฟล์');
      }

      final bytes = await imageFile.readAsBytes();
      final base64Image = base64Encode(bytes);
      final url = Uri.parse('$_baseUrl/$_model:generateContent?key=$_apiKey');

      final requestBody = {
        "contents": [
          {
            "parts": [
              {"text": _getDiagnosisPrompt()},
              {
                "inline_data": {
                  "mime_type": _getMimeType(imageFile.path),
                  "data": base64Image,
                },
              },
            ],
          },
        ],
        "generationConfig": {
          "temperature": 0.1,
          "topK": 32,
          "topP": 1,
          "maxOutputTokens": 2048,
        },
      };

      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: json.encode(requestBody),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorBody = json.decode(response.body);
        throw Exception(
          'API Error: ${errorBody['error']?['message'] ?? 'Unknown error'}',
        );
      }

      final responseData = json.decode(response.body);
      final candidates = responseData['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        throw Exception('ไม่ได้รับคำตอบจาก AI');
      }

      final content = candidates[0]['content'];
      final parts = content['parts'] as List?;
      if (parts == null || parts.isEmpty) {
        throw Exception('ไม่มีเนื้อหาในคำตอบ');
      }

      final text = parts[0]['text'] as String?;
      if (text == null || text.isEmpty) {
        throw Exception('ไม่มีข้อความในคำตอบ');
      }

      final jsonString = _extractJsonFromResponse(text);
      final diagnosisData = json.decode(jsonString);
      final savedImagePath = await _saveImage(imageFile);
      diagnosisData['imagePath'] = savedImagePath;

      return Diagnosis.fromJson(diagnosisData);
    } catch (e) {
      rethrow;
    }
  }

  // Text Chat (new functionality)
  static Future<String> chatWithAI(
    String message, {
    List<ChatMessage>? conversationHistory,
    File? imageFile,
  }) async {
    try {
      if (_apiKey.isEmpty) {
        throw Exception('กรุณาใส่ Gemini API Key');
      }

      final url = Uri.parse('$_baseUrl/$_model:generateContent?key=$_apiKey');

      // Build conversation context
      final List<Map<String, dynamic>> contents = [];

      // Add system prompt
      contents.add({
        "parts": [
          {"text": _getChatPrompt()},
        ],
      });

      // Add conversation history
      if (conversationHistory != null && conversationHistory.isNotEmpty) {
        for (var msg in conversationHistory.take(10)) {
          // Last 10 messages
          contents.add({
            "parts": [
              {"text": msg.text},
            ],
            "role": msg.isUser ? "user" : "model",
          });
        }
      }

      // Add current message
      final currentParts = <Map<String, dynamic>>[];
      currentParts.add({"text": message});

      // Add image if present
      if (imageFile != null) {
        final bytes = await imageFile.readAsBytes();
        final base64Image = base64Encode(bytes);
        currentParts.add({
          "inline_data": {
            "mime_type": _getMimeType(imageFile.path),
            "data": base64Image,
          },
        });
      }

      contents.add({
        "parts": currentParts,
        "role": "user",
      });

      final requestBody = {
        "contents": contents,
        "generationConfig": {
          "temperature": 0.7,
          "topK": 40,
          "topP": 0.95,
          "maxOutputTokens": 1024,
        },
      };

      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: json.encode(requestBody),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorBody = json.decode(response.body);
        throw Exception(
          'API Error: ${errorBody['error']?['message'] ?? 'Unknown error'}',
        );
      }

      final responseData = json.decode(response.body);
      final candidates = responseData['candidates'] as List?;
      
      if (candidates == null || candidates.isEmpty) {
        throw Exception('ไม่ได้รับคำตอบจาก AI');
      }

      final content = candidates[0]['content'];
      final parts = content['parts'] as List?;
      
      if (parts == null || parts.isEmpty) {
        throw Exception('ไม่มีเนื้อหาในคำตอบ');
      }

      final text = parts[0]['text'] as String? ?? '';
      return text.trim();
    } catch (e) {
      throw Exception('เกิดข้อผิดพลาดในการสนทนา: $e');
    }
  }

  static String _getMimeType(String filePath) {
    final extension = filePath.toLowerCase().split('.').last;
    switch (extension) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }

  static String _extractJsonFromResponse(String response) {
    String cleaned = response.replaceAll('```json', '').replaceAll('```', '').trim();
    final startIndex = cleaned.indexOf('{');
    final endIndex = cleaned.lastIndexOf('}');

    if (startIndex >= 0 && endIndex > startIndex) {
      return cleaned.substring(startIndex, endIndex + 1);
    }

    throw FormatException('ไม่พบ JSON ที่ถูกต้องในคำตอบ');
  }

  static Future<String> _saveImage(File imageFile) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fileName = 'image_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedFile = await imageFile.copy('${directory.path}/$fileName');
      return savedFile.path;
    } catch (e) {
      return imageFile.path;
    }
  }

  static String _getDiagnosisPrompt() {
    return '''
คุณเป็นผู้เชี่ยวชาญด้านโรคพืชและการเกษตร ชื่อ "${AppConfig.aiName}" มีความเชี่ยวชาญพิเศษในการวินิจฉัยโรคพืชจากภาพถ่าย

วิเคราะห์ภาพที่ให้มาอย่างละเอียด และส่งคืนผลการวินิจฉัยในรูปแบบ JSON ที่เข้มงวด

**รูปแบบ JSON Output:**
{
  "plant": "ชื่อพืช",
  "part": "ส่วนของพืช",
  "disease": "ชื่อโรคหรืออาการ",
  "confidence": 0.85,
  "severity": "ระดับความรุนแรง",
  "recommendation": "คำแนะนำการรักษา",
  "careSteps": [
    "ขั้นตอนที่ 1",
    "ขั้นตอนที่ 2",
    "ขั้นตอนที่ 3"
  ]
}

**กฎสำคัญ:**
- ส่งคืนเฉพาะ JSON object เท่านั้น
- confidence ต้องเป็นตัวเลข 0.0-1.0
- ใช้ภาษาไทยในทุกฟิลด์
''';
  }

  static String _getChatPrompt() {
    return '''
คุณคือ "${AppConfig.aiName}" ผู้ช่วยผู้เชี่ยวชาญด้านโรคพืชและการเกษตร มีบุคลิกเป็นมิตร อบอุ่น และพร้อมช่วยเหลือ

**บทบาทและหน้าที่:**
- ตอบคำถามเกี่ยวกับโรคพืช การดูแลรักษาพืช และเทคนิคการเกษตร
- ให้คำแนะนำด้านการป้องกันและกำจัดศัตรูพืช
- แนะนำการใช้ปุ๋ยและสารเคมีที่เหมาะสม
- ช่วยแก้ปัญหาที่เกี่ยวข้องกับการปลูกพืช
- สนทนาได้ทั้งภาษาไทยและภาษาอังกฤษ

**ลักษณะการตอบ:**
- ใช้ภาษาที่เข้าใจง่าย เป็นมิตร
- ตอบอย่างละเอียดแต่กระชับ
- ให้ข้อมูลที่ถูกต้องและเป็นประโยชน์
- หากไม่แน่ใจ ให้บอกตรงๆ และแนะนำให้ปรึกษาผู้เชี่ยวชาญ
- สามารถวิเคราะห์รูปภาพพืชที่ผู้ใช้ส่งมา

จงตอบคำถามด้วยความเป็นมิตรและเป็นประโยชน์สูงสุด
''';
  }
}

// =====================================================
// Storage Service
// =====================================================

class StorageService {
  static const String _historyKey = 'diagnosis_history';
  static const String _chatKey = 'chat_history';
  static const int _maxHistoryItems = 50;
  static const int _maxChatMessages = 100;

  static Future<List<Diagnosis>> getHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getStringList(_historyKey) ?? [];

      return historyJson
          .map((json) => Diagnosis.fromJson(jsonDecode(json)))
          .toList()
          .reversed
          .toList();
    } catch (e) {
      debugPrint('Error loading history: $e');
      return [];
    }
  }

  static Future<void> saveToHistory(Diagnosis diagnosis) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getStringList(_historyKey) ?? [];

      historyJson.add(jsonEncode(diagnosis.toJson()));

      if (historyJson.length > _maxHistoryItems) {
        historyJson.removeRange(0, historyJson.length - _maxHistoryItems);
      }

      await prefs.setStringList(_historyKey, historyJson);
    } catch (e) {
      debugPrint('Error saving to history: $e');
    }
  }

  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  static Future<void> deleteFromHistory(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getStringList(_historyKey) ?? [];

      historyJson.removeWhere((json) {
        final item = jsonDecode(json);
        return item['id'] == id;
      });

      await prefs.setStringList(_historyKey, historyJson);
    } catch (e) {
      debugPrint('Error deleting from history: $e');
    }
  }

  // Chat History
  static Future<List<ChatMessage>> getChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final chatJson = prefs.getStringList(_chatKey) ?? [];

      return chatJson.map((json) => ChatMessage.fromJson(jsonDecode(json))).toList();
    } catch (e) {
      debugPrint('Error loading chat: $e');
      return [];
    }
  }

  static Future<void> saveChatMessage(ChatMessage message) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final chatJson = prefs.getStringList(_chatKey) ?? [];

      chatJson.add(jsonEncode(message.toJson()));

      if (chatJson.length > _maxChatMessages) {
        chatJson.removeRange(0, chatJson.length - _maxChatMessages);
      }

      await prefs.setStringList(_chatKey, chatJson);
    } catch (e) {
      debugPrint('Error saving chat: $e');
    }
  }

  static Future<void> clearChat() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_chatKey);
  }
}

// =====================================================
// Image Service
// =====================================================

class ImageService {
  static final ImagePicker _picker = ImagePicker();

  static Future<File?> pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        imageQuality: AppConfig.imageQuality.toInt(),
        maxWidth: AppConfig.maxImageDimension.toDouble(),
        maxHeight: AppConfig.maxImageDimension.toDouble(),
      );

      if (pickedFile != null) {
        final file = File(pickedFile.path);

        if (!await validateImage(file)) {
          throw Exception('รูปภาพไม่ผ่านการตรวจสอบ');
        }

        return file;
      }
      return null;
    } catch (e) {
      throw Exception('เกิดข้อผิดพลาดในการเลือกรูปภาพ: $e');
    }
  }

  static Future<bool> validateImage(File image) async {
    try {
      final bytes = await image.readAsBytes();

      if (bytes.length > AppConfig.maxImageSize) {
        throw Exception(
          'ขนาดไฟล์ใหญ่เกินไป (สูงสุด ${AppConfig.maxImageSize ~/ 1024 ~/ 1024} MB)',
        );
      }

      final decodedImage = await decodeImageFromList(bytes);

      if (decodedImage.width < AppConfig.minImageDimension ||
          decodedImage.height < AppConfig.minImageDimension) {
        throw Exception(
          'รูปภาพมีความละเอียดต่ำเกินไป',
        );
      }

      return true;
    } catch (e) {
      rethrow;
    }
  }
}

// =====================================================
// Main UI
// =====================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  File? _imageFile;
  bool _loading = false;
  Diagnosis? _currentDiagnosis;
  String? _error;
  List<Diagnosis> _history = [];
  int _selectedIndex = 0;

  late TabController _tabController;
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _loadHistory();
    _initializeVoice();
  }

  Future<void> _initializeVoice() async {
    await VoiceService.initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _animationController.dispose();
    VoiceService.stop();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await StorageService.getHistory();
    if (mounted) {
      setState(() {
        _history = history;
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final file = await ImageService.pickImage(source);
      if (file != null && mounted) {
        setState(() {
          _imageFile = file;
          _currentDiagnosis = null;
          _error = null;
        });
      }
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _diagnose() async {
    if (_imageFile == null) {
      _showError('กรุณาเลือกรูปภาพก่อนทำการวินิจฉัย');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _currentDiagnosis = null;
    });

    try {
      final diagnosis = await GeminiService.analyzePlantImage(_imageFile!);

      await StorageService.saveToHistory(diagnosis);
      await _loadHistory();

      if (mounted) {
        setState(() {
          _currentDiagnosis = diagnosis;
          _loading = false;
        });

        _showSuccess('วินิจฉัยเสร็จสมบูรณ์');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _loading = false;
        });
        _showError(_error!);
      }
    }
  }

  void _reset() {
    setState(() {
      _imageFile = null;
      _currentDiagnosis = null;
      _error = null;
      _loading = false;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red.shade600,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.white),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        backgroundColor: Colors.green.shade600,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
              Theme.of(context).colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildTabs(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildDiagnosisTab(),
                    const ChatScreen(),
                    _buildHistoryTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.primaryContainer,
                ],
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(Icons.eco, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Leaf Doctor AI',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                Text(
                  'ผู้ช่วย ${AppConfig.aiName}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _showAboutDialog(),
            icon: const Icon(Icons.info_outline),
            tooltip: 'เกี่ยวกับแอป',
          ),
        ],
      ),
    ).animate().fadeIn(duration: 500.ms).slideX(begin: -0.2, end: 0);
  }

  Widget _buildTabs() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TabBar(
        controller: _tabController,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        indicator: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.primary,
        ),
        labelColor: Colors.white,
        unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
        tabs: [
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.camera_alt, size: 18),
                SizedBox(width: 6),
                Text('วินิจฉัย', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.chat_bubble, size: 18),
                SizedBox(width: 6),
                Text('สนทนา', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.history, size: 18),
                const SizedBox(width: 6),
                Text('ประวัติ (${_history.length})',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosisTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildImagePicker(),
          const SizedBox(height: 16),
          _buildActionButtons(),
          const SizedBox(height: 20),
          if (_loading) _buildLoadingIndicator(),
          if (_error != null) _buildErrorWidget(),
          if (_currentDiagnosis != null) _buildDiagnosisResult(),
        ],
      ),
    );
  }

  Widget _buildImagePicker() {
    return Container(
      height: 300,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: _imageFile != null
          ? Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Image.file(
                    _imageFile!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: CircleAvatar(
                    backgroundColor: Colors.black54,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => setState(() => _imageFile = null),
                    ),
                  ),
                ),
              ],
            ).animate().fadeIn().scale(begin: const Offset(0.9, 0.9))
          : InkWell(
              onTap: () => _showImageSourceDialog(),
              borderRadius: BorderRadius.circular(18),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 72,
                    color:
                        Theme.of(context).colorScheme.primary.withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'แตะเพื่อเลือกรูปภาพ',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'ถ่ายรูปหรือเลือกจากแกลเลอรี่',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant
                              .withOpacity(0.7),
                        ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: _buildButton(
            icon: Icons.camera_alt,
            label: 'ถ่ายรูป',
            onPressed: _loading ? null : () => _pickImage(ImageSource.camera),
            isPrimary: false,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildButton(
            icon: Icons.photo_library,
            label: 'เลือกรูป',
            onPressed: _loading ? null : () => _pickImage(ImageSource.gallery),
            isPrimary: false,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildButton(
            icon: Icons.biotech,
            label: _loading ? 'กำลังวิเคราะห์' : 'วินิจฉัย',
            onPressed: (_imageFile != null && !_loading) ? _diagnose : null,
            isPrimary: true,
          ),
        ),
      ],
    );
  }

  Widget _buildButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required bool isPrimary,
  }) {
    final enabled = onPressed != null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: isPrimary
              ? (enabled
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.primary.withOpacity(0.3))
              : Theme.of(context).colorScheme.surfaceVariant,
          foregroundColor: isPrimary
              ? Colors.white
              : Theme.of(context).colorScheme.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(
              Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'กำลังวิเคราะห์ด้วย AI...',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'อาจใช้เวลาสักครู่',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    ).animate(onPlay: (controller) => controller.repeat()).shimmer(
          duration: 1500.ms,
        );
  }

  Widget _buildErrorWidget() {
    return Container(
      padding: const EdgeInsets.all(24),
      margin: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Column(
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
          const SizedBox(height: 16),
          Text(
            'เกิดข้อผิดพลาด',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.red.shade600),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.refresh),
            label: const Text('ลองใหม่'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosisResult() {
    final diagnosis = _currentDiagnosis!;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.medical_services,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'ผลการวินิจฉัย',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              _buildSeverityChip(diagnosis.severity),
            ],
          ),
          const SizedBox(height: 20),
          _buildInfoRow('พืช', diagnosis.plant, Icons.local_florist),
          _buildInfoRow('ส่วน', diagnosis.part, Icons.grass),
          _buildInfoRow('โรค/อาการ', diagnosis.disease, Icons.coronavirus),
          _buildInfoRow(
            'ความเชื่อมั่น',
            '${(diagnosis.confidence * 100).toStringAsFixed(0)}%',
            Icons.analytics,
          ),
          const Divider(height: 32),
          _buildRecommendationSection(diagnosis),
          if (diagnosis.careSteps.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildCareStepsSection(diagnosis),
          ],
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.1, end: 0);
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeverityChip(String severity) {
    Color backgroundColor;
    Color textColor;
    IconData icon;

    switch (severity.toLowerCase()) {
      case 'เบา':
        backgroundColor = Colors.green.shade100;
        textColor = Colors.green.shade700;
        icon = Icons.check_circle_outline;
        break;
      case 'ปานกลาง':
        backgroundColor = Colors.orange.shade100;
        textColor = Colors.orange.shade700;
        icon = Icons.warning_amber;
        break;
      case 'รุนแรง':
      case 'วิกฤต':
        backgroundColor = Colors.red.shade100;
        textColor = Colors.red.shade700;
        icon = Icons.error_outline;
        break;
      case 'สุขภาพดี':
        backgroundColor = Colors.teal.shade100;
        textColor = Colors.teal.shade700;
        icon = Icons.favorite;
        break;
      default:
        backgroundColor = Colors.grey.shade100;
        textColor = Colors.grey.shade700;
        icon = Icons.help_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: textColor),
          const SizedBox(width: 4),
          Text(
            severity,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendationSection(Diagnosis diagnosis) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.lightbulb_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              'คำแนะนำ',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .primaryContainer
                .withOpacity(0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
            ),
          ),
          child: Text(
            diagnosis.recommendation,
            style: const TextStyle(height: 1.5),
          ),
        ),
      ],
    );
  }

  Widget _buildCareStepsSection(Diagnosis diagnosis) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.checklist, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'ขั้นตอนการดูแลรักษา',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...diagnosis.careSteps.asMap().entries.map((entry) {
          final index = entry.key;
          final step = entry.value;

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(step, style: const TextStyle(height: 1.4)),
                ),
              ],
            ),
          );
        }).toList(),
      ],
    );
  }

  Widget _buildHistoryTab() {
    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history,
              size: 64,
              color: Theme.of(context)
                  .colorScheme
                  .onSurfaceVariant
                  .withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'ยังไม่มีประวัติการวินิจฉัย',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _history.length,
      itemBuilder: (context, index) {
        final item = _history[index];
        return _buildHistoryItem(item);
      },
    );
  }

  Widget _buildHistoryItem(Diagnosis diagnosis) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showHistoryDetail(diagnosis),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (diagnosis.imagePath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(diagnosis.imagePath!),
                    width: 60,
                    height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 60,
                        height: 60,
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.broken_image),
                      );
                    },
                  ),
                )
              else
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.eco,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      diagnosis.plant,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      diagnosis.disease,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DateFormat('dd MMM yyyy HH:mm').format(
                        diagnosis.timestamp,
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              _buildSeverityChip(diagnosis.severity),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(diagnosis),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHistoryDetail(Diagnosis diagnosis) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (diagnosis.imagePath != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.file(
                      File(diagnosis.imagePath!),
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                const SizedBox(height: 20),
                _buildDiagnosisDetails(diagnosis),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiagnosisDetails(Diagnosis diagnosis) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'ผลการวินิจฉัย',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            _buildSeverityChip(diagnosis.severity),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoRow('พืช', diagnosis.plant, Icons.local_florist),
        _buildInfoRow('ส่วน', diagnosis.part, Icons.grass),
        _buildInfoRow('โรค/อาการ', diagnosis.disease, Icons.coronavirus),
        _buildInfoRow(
          'ความเชื่อมั่น',
          '${(diagnosis.confidence * 100).toStringAsFixed(0)}%',
          Icons.analytics,
        ),
        _buildInfoRow(
          'วันที่',
          DateFormat('dd MMMM yyyy HH:mm').format(diagnosis.timestamp),
          Icons.calendar_today,
        ),
        const Divider(height: 32),
        _buildRecommendationSection(diagnosis),
        if (diagnosis.careSteps.isNotEmpty) ...[
          const SizedBox(height: 20),
          _buildCareStepsSection(diagnosis),
        ],
      ],
    );
  }

  void _confirmDelete(Diagnosis diagnosis) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ยืนยันการลบ'),
        content: const Text('คุณต้องการลบประวัติการวินิจฉัยนี้หรือไม่?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ยกเลิก'),
          ),
          TextButton(
            onPressed: () async {
              await StorageService.deleteFromHistory(diagnosis.id);
              await _loadHistory();
              if (mounted) {
                Navigator.pop(context);
                _showSuccess('ลบประวัติสำเร็จ');
              }
            },
            child: const Text('ลบ', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'เลือกแหล่งที่มาของรูปภาพ',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('ถ่ายรูป'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('เลือกจากแกลเลอรี่'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.eco, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            const Text('ระบบตรวจโรคพืชด้วย AI'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'เวอร์ชัน 3.0.0 - Advanced Edition',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('แอปพลิเคชันวินิจฉัยโรคพืชด้วย AI'),
            const SizedBox(height: 16),
            Text(
              'ผู้ช่วย AI: ${AppConfig.aiName}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text('คุณสมบัติ:'),
            const Text('• วิเคราะห์โรคพืชจากภาพถ่าย'),
            const Text('• สนทนาด้วยเสียงแบบ Real-time'),
            const Text('• แชทข้อความกับ AI'),
            const Text('• ให้คำแนะนำการรักษา'),
            const Text('• บันทึกประวัติการวินิจฉัย'),
            const SizedBox(height: 16),
            const Text(
              'Powered by Gemini AI',
              style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ปิด'),
          ),
        ],
      ),
    );
  }
}

// =====================================================
// Chat Screen (NEW FEATURE)
// =====================================================

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isListening = false;
  File? _selectedImage;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _addWelcomeMessage();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    VoiceService.stop();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    final messages = await StorageService.getChatHistory();
    if (mounted) {
      setState(() {
        _messages = messages;
      });
      _scrollToBottom();
    }
  }

  void _addWelcomeMessage() {
    if (_messages.isEmpty) {
      final welcomeMessage = ChatMessage(
        text:
            'สวัสดีค่ะ! ฉันชื่อ${AppConfig.aiName} 🌿\n\nฉันพร้อมช่วยเหลือคุณในเรื่องการดูแลพืชและการเกษตรค่ะ คุณสามารถ:\n\n• ถามคำถามเกี่ยวกับโรคพืช\n• ส่งรูปภาพพืชมาให้ฉันดู\n• สนทนาด้วยเสียง\n\nมีอะไรให้ช่วยไหมคะ?',
        isUser: false,
        type: MessageType.text,
      );
      setState(() {
        _messages.add(welcomeMessage);
      });
      StorageService.saveChatMessage(welcomeMessage);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage({String? text}) async {
    final messageText = text ?? _messageController.text.trim();

    if (messageText.isEmpty && _selectedImage == null) return;

    final userMessage = ChatMessage(
      text: messageText.isEmpty ? '[ส่งรูปภาพ]' : messageText,
      isUser: true,
      imagePath: _selectedImage?.path,
      type: _selectedImage != null ? MessageType.image : MessageType.text,
    );

    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
    });

    await StorageService.saveChatMessage(userMessage);
    _messageController.clear();
    _scrollToBottom();

    try {
      // Get AI response
      final response = await GeminiService.chatWithAI(
        messageText.isEmpty ? 'วิเคราะห์รูปภาพนี้' : messageText,
        conversationHistory: _messages.length > 20
            ? _messages.sublist(_messages.length - 20)
            : _messages,
        imageFile: _selectedImage,
      );

      final aiMessage = ChatMessage(
        text: response,
        isUser: false,
        type: MessageType.text,
      );

      if (mounted) {
        setState(() {
          _messages.add(aiMessage);
          _isLoading = false;
          _selectedImage = null;
        });

        await StorageService.saveChatMessage(aiMessage);
        _scrollToBottom();

        // Speak the response
        await VoiceService.speak(response);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _selectedImage = null;
        });
        _showError(e.toString());
      }
    }
  }

  Future<void> _startVoiceInput() async {
    try {
      await VoiceService.startListening(
        onResult: (text) {
          if (mounted) {
            setState(() {
              _isListening = false;
            });
            _messageController.text = text;
            _sendMessage();
          }
        },
        onListening: () {
          if (mounted) {
            setState(() {
              _isListening = true;
            });
          }
        },
      );
    } catch (e) {
      _showError('ไม่สามารถเริ่มการฟังเสียงได้: $e');
    }
  }

  Future<void> _stopVoiceInput() async {
    await VoiceService.stopListening();
    if (mounted) {
      setState(() {
        _isListening = false;
      });
    }
  }

  Future<void> _pickImageForChat() async {
    try {
      final file = await ImageService.pickImage(ImageSource.gallery);
      if (file != null && mounted) {
        setState(() {
          _selectedImage = file;
        });
      }
    } catch (e) {
      _showError(e.toString());
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade600,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _clearChat() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ล้างประวัติการสนทนา'),
        content: const Text('คุณต้องการลบประวัติการสนทนาทั้งหมดหรือไม่?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ยกเลิก'),
          ),
          TextButton(
            onPressed: () async {
              await StorageService.clearChat();
              setState(() {
                _messages.clear();
              });
              _addWelcomeMessage();
              Navigator.pop(context);
            },
            child: const Text('ลบ', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header with clear button
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: const Icon(Icons.eco, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppConfig.aiName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      'ผู้ช่วยด้านโรคพืช',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _clearChat,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'ล้างประวัติการสนทนา',
              ),
            ],
          ),
        ),

        // Messages list
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 64,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withOpacity(0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'เริ่มการสนทนา',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    return _buildMessageBubble(_messages[index]);
                  },
                ),
        ),

        // Loading indicator
        if (_isLoading)
          Container(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: const Icon(Icons.eco, color: Colors.white, size: 16),
                ),
                const SizedBox(width: 8),
                Text(
                  '${AppConfig.aiName} กำลังพิมพ์...',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Selected image preview
        if (_selectedImage != null)
          Container(
            margin: const EdgeInsets.all(8),
            height: 100,
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    _selectedImage!,
                    width: 100,
                    height: 100,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: CircleAvatar(
                    radius: 12,
                    backgroundColor: Colors.black54,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => setState(() => _selectedImage = null),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Input area
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SafeArea(
            child: Row(
              children: [
                // Image button
                IconButton(
                  onPressed: _pickImageForChat,
                  icon: const Icon(Icons.image),
                  color: Theme.of(context).colorScheme.primary,
                  tooltip: 'แนบรูปภาพ',
                ),

                // Text input
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceVariant
                          .withOpacity(0.5),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: 'พิมพ์ข้อความ...',
                        border: InputBorder.none,
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // Voice button
                _isListening
                    ? AvatarGlow(
                        glowColor: Theme.of(context).colorScheme.primary,
                        child: CircleAvatar(
                          radius: 24,
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          child: IconButton(
                            onPressed: _stopVoiceInput,
                            icon: const Icon(Icons.stop, color: Colors.white),
                            tooltip: 'หยุดฟัง',
                          ),
                        ),
                      )
                    : CircleAvatar(
                        radius: 24,
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: IconButton(
                          onPressed: _startVoiceInput,
                          icon: const Icon(Icons.mic, color: Colors.white),
                          tooltip: 'พูด',
                        ),
                      ),

                const SizedBox(width: 4),

                // Send button
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: IconButton(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send, color: Colors.white),
                    tooltip: 'ส่ง',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!message.isUser) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: const Icon(Icons.eco, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: message.isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: message.isUser
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (message.imagePath != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(message.imagePath!),
                            width: 200,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        message.text,
                        style: TextStyle(
                          color: message.isUser
                              ? Colors.white
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('HH:mm').format(message.timestamp),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (message.isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: Theme.of(context).colorScheme.secondary,
              child: const Icon(Icons.person, color: Colors.white, size: 18),
            ),
          ],
        ],
      ),
    ).animate().fadeIn().slideX(
          begin: message.isUser ? 0.2 : -0.2,
          end: 0,
        );
  }
}

// =====================================================
// Required Dependencies in pubspec.yaml:
// =====================================================
/*
dependencies:
  flutter:
    sdk: flutter
  flutter_animate: ^4.5.0
  image_picker: ^1.0.7
  http: ^1.2.0
  path_provider: ^2.1.2
  shared_preferences: ^2.2.2
  intl: ^0.19.0
  speech_to_text: ^6.6.0
  flutter_tts: ^4.0.2
  permission_handler: ^11.3.0
  avatar_glow: ^3.0.1
*/
