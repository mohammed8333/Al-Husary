import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:just_audio/just_audio.dart';
import 'package:xml/xml.dart' as xml;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const QuranApp());
}

class QuranApp extends StatefulWidget {
  const QuranApp({super.key});

  static void toggleTheme(BuildContext context) {
    _QuranAppState? state = context.findAncestorStateOfType<_QuranAppState>();
    state?.toggleTheme();
  }

  static bool isDarkMode(BuildContext context) {
    _QuranAppState? state = context.findAncestorStateOfType<_QuranAppState>();
    return state?._themeMode == ThemeMode.dark;
  }

  @override
  State<QuranApp> createState() => _QuranAppState();
}

class _QuranAppState extends State<QuranApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('isDarkMode') ?? true;
    setState(() {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    });
  }

  void toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
    await prefs.setBool('isDarkMode', _themeMode == ThemeMode.dark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'القرآن الكريم بصوت الحصري',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF4F7F5),
        primaryColor: const Color(0xFFD1E5DB),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFD48C00),
          secondary: Color(0xFFB87600),
          surface: Color(0xFFE3EDE8),
        ),
        fontFamily: 'Cairo',
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF06110D),
        primaryColor: const Color(0xFF1E4637),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFF2AF29),
          secondary: Color(0xFFD4AF37),
          surface: Color(0xFF0D221A),
        ),
        fontFamily: 'Cairo',
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: QuranHomePage(),
      ),
    );
  }
}

// Data Models
class Ayah {
  final int index;
  final String text;
  bool isRevealed = true; // For Memorization Mode

  Ayah({required this.index, required this.text});
}

class Surah {
  final int index;
  final String name;
  final List<Ayah> ayahs;

  Surah({required this.index, required this.name, required this.ayahs});
}

class QuranHomePage extends StatefulWidget {
  const QuranHomePage({super.key});

  @override
  State<QuranHomePage> createState() => _QuranHomePageState();
}

class _QuranHomePageState extends State<QuranHomePage> {
  // Quran Data
  List<Surah> _surahs = [];
  bool _isLoading = true;
  int _selectedSurahIndex = 1; // Default: Al-Fatihah
  String _searchQuery = "";

  // Screen Routing State
  String _currentScreen = 'menu'; // 'menu', 'full', 'range', 'starred', 'search'

  // Playback States
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  String _playbackMode = 'ayah'; // 'ayah', 'surah', 'starred', 'starred-single'
  int? _activeAyahIndex; // 1-indexed currently playing ayah
  
  // Ranges
  int _rangeFrom = 1;
  int _rangeTo = 7;

  // Repetition Counters
  int _ayahRepCount = 1;
  int _rangeRepCount = 1;
  int _currentAyahPlayCount = 0;
  int _currentRangePlayCount = 0;
  int _activeQueueIndex = 1;

  // Helpers
  bool _delayActive = false; // Wait for recitation pause
  bool _hideTextMode = false;
  Set<String> _starredAyahs = {}; // Format: "surahIndex_ayahIndex"
  
  // Offline Downloader
  bool _isDownloading = false;
  String _downloadStatus = "";
  double _downloadProgress = 0.0;
  String _downloadProgressText = "";
  Set<String> _localAyahs = {}; // Track files that are offline
  Set<int> _localSurahs = {}; // Track full Surah continuous files

  // New App Features States
  String _selectedReciter = 'husary'; // 'husary', 'minshawy', 'alafasy'
  double _playbackSpeed = 1.0;
  List<Map<String, int>> _starredQueue = [];
  int _starredQueueIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadQuranData();
    _loadPreferences();
    _setupAudioPlayerListeners();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  // Load Quran XML from assets
  Future<void> _loadQuranData() async {
    try {
      final xmlString = await rootBundle.loadString('assets/quran-simple.xml');
      final document = xml.XmlDocument.parse(xmlString);
      final suraElements = document.findAllElements('sura');
      
      final List<Surah> loadedSurahs = [];
      for (var sura in suraElements) {
        final int index = int.parse(sura.getAttribute('index')!);
        final String name = sura.getAttribute('name')!;
        
        final List<Ayah> loadedAyahs = [];
        final ayaElements = sura.findElements('aya');
        for (var aya in ayaElements) {
          final int ayaIndex = int.parse(aya.getAttribute('index')!);
          final String text = aya.getAttribute('text')!;
          loadedAyahs.add(Ayah(index: ayaIndex, text: text));
        }
        
        loadedSurahs.add(Surah(index: index, name: name, ayahs: loadedAyahs));
      }

      setState(() {
        _surahs = loadedSurahs;
        _isLoading = false;
        _rangeTo = _surahs[0].ayahs.length;
      });
      _checkLocalAudioFiles();
    } catch (e) {
      debugPrint("Error loading XML: $e");
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Load preferences (bookmarks, repetitions)
  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _starredAyahs = (prefs.getStringList('starredAyahs') ?? []).toSet();
      _ayahRepCount = prefs.getInt('ayahRepCount') ?? 1;
      _rangeRepCount = prefs.getInt('rangeRepCount') ?? 1;
      _selectedReciter = prefs.getString('selectedReciter') ?? 'husary';
      _playbackSpeed = prefs.getDouble('playbackSpeed') ?? 1.0;
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('starredAyahs', _starredAyahs.toList());
    await prefs.setInt('ayahRepCount', _ayahRepCount);
    await prefs.setInt('rangeRepCount', _rangeRepCount);
    await prefs.setString('selectedReciter', _selectedReciter);
    await prefs.setDouble('playbackSpeed', _playbackSpeed);
  }

  String get _reciterVbyvPath {
    return _selectedReciter == 'husary' ? '000_versebyverse' : '000_versebyverse/$_selectedReciter';
  }

  String get _reciterSurahPath {
    return _selectedReciter == 'husary' ? 'Al-Husaree_Almoalim' : 'Al-Husaree_Almoalim/$_selectedReciter';
  }

  String get _reciterVbyvOnlineUrl {
    if (_selectedReciter == 'minshawy') {
      return 'https://everyayah.com/data/Minshawy_Teacher_128kbps/';
    } else if (_selectedReciter == 'alafasy') {
      return 'https://everyayah.com/data/Alafasy_128kbps/';
    }
    return 'https://everyayah.com/data/Husary_Muallim_128kbps/';
  }

  String get _reciterSurahOnlineUrl {
    if (_selectedReciter == 'minshawy') {
      return 'https://server11.mp3quran.net/minsh/';
    } else if (_selectedReciter == 'alafasy') {
      return 'https://server8.mp3quran.net/afs/';
    }
    return 'https://server13.mp3quran.net/husr/';
  }

  // Check what files are downloaded to local storage
  Future<void> _checkLocalAudioFiles() async {
    final docsDir = await getApplicationDocumentsDirectory();
    
    // Check local verses
    final verseDir = Directory('${docsDir.path}/$_reciterVbyvPath');
    final Set<String> localFiles = {};
    if (await verseDir.exists()) {
      final List<FileSystemEntity> files = verseDir.listSync();
      for (var file in files) {
        if (file is File) {
          if (await file.length() > 0) {
            localFiles.add(file.uri.pathSegments.last); // e.g. "001001.mp3"
          } else {
            try { await file.delete(); } catch (_) {}
          }
        }
      }
    }

    // Check local full Surahs
    final surahDir = Directory('${docsDir.path}/$_reciterSurahPath');
    final Set<int> localSurahIndexes = {};
    if (await surahDir.exists()) {
      final List<FileSystemEntity> files = surahDir.listSync();
      for (var file in files) {
        if (file is File) {
          final filename = file.uri.pathSegments.last;
          if (filename.endsWith('.mp3')) {
            if (await file.length() > 0) {
              final idxStr = filename.replaceAll('.mp3', '');
              final int? idx = int.tryParse(idxStr);
              if (idx != null) {
                localSurahIndexes.add(idx);
              }
            } else {
              try { await file.delete(); } catch (_) {}
            }
          }
        }
      }
    }

    setState(() {
      _localAyahs = localFiles;
      _localSurahs = localSurahIndexes;
    });
  }

  // Playback ending/looping scheduling logic
  void _setupAudioPlayerListeners() {
    _audioPlayer.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        if (_playbackMode == 'surah') {
          _stopPlayback();
          return;
        }

        if (singlePlayMode) {
          _currentAyahPlayCount++;
          if (_currentAyahPlayCount < _ayahRepCount) {
            if (_playbackMode == 'starred-single') {
              _playStarredSingle(_selectedSurahIndex, _activeAyahIndex!);
            } else {
              _playSingleAyahInLoop();
            }
          } else {
            _stopPlayback();
          }
          return;
        }

        if (_playbackMode == 'starred') {
          _currentAyahPlayCount++;
          if (_currentAyahPlayCount < _ayahRepCount) {
            _playStarredInQueue();
          } else {
            _currentAyahPlayCount = 0;
            _advanceStarredQueue();
          }
          return;
        }

        // Ayah Repetition Logic
        _currentAyahPlayCount++;
        if (_currentAyahPlayCount < _ayahRepCount) {
          _playAyahInQueue();
        } else {
          // Finished repetitions for this ayah
          _currentAyahPlayCount = 0;
          
          if (_delayActive) {
            // Wait for recitation: pause equal to duration of the ayah played
            final duration = _audioPlayer.duration ?? const Duration(seconds: 3);
            setState(() {
              _isPlaying = false; // Show pause state on UI
            });
            
            await Future.delayed(duration);
            if (!_isPlaying && _activeAyahIndex != null) {
              _isPlaying = true;
              _advanceQueue();
            }
          } else {
            _advanceQueue();
          }
        }
      }
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
        });
      }
    });
  }

  // Advance to next verse in the range
  void _advanceQueue() {
    if (_activeQueueIndex < _rangeTo) {
      _activeQueueIndex++;
      _playAyahInQueue();
    } else {
      // Reached end of range
      _currentRangePlayCount++;
      if (_currentRangePlayCount < _rangeRepCount) {
        // Repeat range
        _activeQueueIndex = _rangeFrom;
        _playAyahInQueue();
      } else {
        // Fully finished
        _stopPlayback();
      }
    }
  }

  // Single play card states
  bool singlePlayMode = false;
  int? _singlePlayAyahIndex;

  Future<void> playSingleAyah(int index) async {
    _stopPlayback();
    setState(() {
      _isPlaying = true;
      _activeAyahIndex = index;
    });

    singlePlayMode = true;
    _singlePlayAyahIndex = index;
    _currentAyahPlayCount = 0;

    _playSingleAyahInLoop();
  }

  Future<void> _playSingleAyahInLoop() async {
    if (!_isPlaying || _singlePlayAyahIndex == null) return;
    
    final String surahPad = _selectedSurahIndex.toString().padLeft(3, '0');
    final String ayahPad = _singlePlayAyahIndex!.toString().padLeft(3, '0');
    final String filename = "$surahPad$ayahPad.mp3";
    
    final docsDir = await getApplicationDocumentsDirectory();
    final localFile = File('${docsDir.path}/$_reciterVbyvPath/$filename');

    final String sourcePath = (await localFile.exists() && await localFile.length() > 0)
        ? localFile.path
        : '$_reciterVbyvOnlineUrl$filename';

    try {
      await _audioPlayer.setAudioSource(
        sourcePath.startsWith('/')
            ? AudioSource.file(sourcePath)
            : AudioSource.uri(Uri.parse(sourcePath)),
      );
      await _audioPlayer.setSpeed(_playbackSpeed);
      _audioPlayer.play();
    } catch (e) {
      _stopPlayback();
    }
  }

  // Start Playback
  Future<void> _startPlayback() async {
    singlePlayMode = false;
    
    if (_playbackMode == 'surah') {
      final String surahPad = _selectedSurahIndex.toString().padLeft(3, '0');
      final docsDir = await getApplicationDocumentsDirectory();
      final localFile = File('${docsDir.path}/$_reciterSurahPath/$surahPad.mp3');
      
      final String url = (await localFile.exists() && await localFile.length() > 0)
          ? localFile.path
          : '$_reciterSurahOnlineUrl$surahPad.mp3';
      
      try {
        await _audioPlayer.setAudioSource(
          url.startsWith('/') ? AudioSource.file(url) : AudioSource.uri(Uri.parse(url)),
        );
        await _audioPlayer.setSpeed(_playbackSpeed);
        _audioPlayer.play();
      } catch (e) {
        _showErrorDialog("فشل تشغيل السورة. تأكد من الاتصال بالإنترنت.");
      }
    } else {
      // Ayah Mode
      _currentAyahPlayCount = 0;
      _currentRangePlayCount = 0;
      _activeQueueIndex = _rangeFrom;
      _playAyahInQueue();
    }
  }

  // Play current ayah in range queue
  Future<void> _playAyahInQueue() async {
    setState(() {
      _activeAyahIndex = _activeQueueIndex;
    });

    final String surahPad = _selectedSurahIndex.toString().padLeft(3, '0');
    final String ayahPad = _activeQueueIndex.toString().padLeft(3, '0');
    final String filename = "$surahPad$ayahPad.mp3";
    
    final docsDir = await getApplicationDocumentsDirectory();
    final localFile = File('${docsDir.path}/$_reciterVbyvPath/$filename');

    final String sourcePath = (await localFile.exists() && await localFile.length() > 0)
        ? localFile.path
        : '$_reciterVbyvOnlineUrl$filename';

    try {
      await _audioPlayer.setAudioSource(
        sourcePath.startsWith('/')
            ? AudioSource.file(sourcePath)
            : AudioSource.uri(Uri.parse(sourcePath)),
      );
      await _audioPlayer.setSpeed(_playbackSpeed);
      _audioPlayer.play();
      
      // Auto cache check
      if (!sourcePath.startsWith('/')) {
        _autoCacheFile(_selectedSurahIndex, _activeQueueIndex);
      }
    } catch (e) {
      _showErrorDialog("فشل تشغيل الآية. تأكد من الاتصال بالإنترنت أو تحميل السورة.");
      _stopPlayback();
    }
  }

  void _stopPlayback() {
    _audioPlayer.stop();
    setState(() {
      _isPlaying = false;
      _activeAyahIndex = null;
      singlePlayMode = false;
      _singlePlayAyahIndex = null;
    });
  }

  void _showErrorDialog(String msg) {
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('عذراً', textAlign: TextAlign.right),
          content: Text(msg, textAlign: TextAlign.right),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('حسناً'),
            )
          ],
        ),
      ),
    );
  }

  // Download continuous Surah from Grid
  Future<void> _downloadFullSurahFromGrid(int index) async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadProgressText = "بدء التحميل...";
      _downloadStatus = "جاري تحميل السورة كاملة للتشغيل دون اتصال...";
    });

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final surahDir = Directory('${docsDir.path}/$_reciterSurahPath');
      await surahDir.create(recursive: true);

      final String surahPad = index.toString().padLeft(3, '0');
      final File localSurahFile = File('${surahDir.path}/$surahPad.mp3');
      
      if (!await localSurahFile.exists() || await localSurahFile.length() == 0) {
        final url = '$_reciterSurahOnlineUrl$surahPad.mp3';
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          await localSurahFile.writeAsBytes(response.bodyBytes);
        }
      }

      setState(() {
        _isDownloading = false;
        _downloadStatus = "تم تحميل السورة بنجاح!";
      });
      _checkLocalAudioFiles();
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadStatus = "فشل تحميل السورة";
      });
    }
  }

  // Download Selected range of ayahs only
  Future<void> _downloadSelectedRange() async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadProgressText = "بدء التحميل...";
    });

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final verseDir = Directory('${docsDir.path}/$_reciterVbyvPath');
      await verseDir.create(recursive: true);

      final List<Ayah> rangeAyahs = _currentSurah.ayahs
          .where((a) => a.index >= _rangeFrom && a.index <= _rangeTo)
          .toList();
      final int total = rangeAyahs.length;

      int count = 0;
      for (var ayah in rangeAyahs) {
        if (!_isDownloading) return;

        final String surahPad = _selectedSurahIndex.toString().padLeft(3, '0');
        final String ayahPad = ayah.index.toString().padLeft(3, '0');
        final String filename = "$surahPad$ayahPad.mp3";
        
        final File localFile = File('${verseDir.path}/$filename');
        if (!await localFile.exists() || await localFile.length() == 0) {
          setState(() {
            _downloadStatus = "جاري تحميل الآية ${ayah.index} من $_rangeTo";
            _downloadProgress = count / total;
            _downloadProgressText = "$count / $total";
          });

          final url = '$_reciterVbyvOnlineUrl$filename';
          final response = await http.get(Uri.parse(url));
          if (response.statusCode == 200) {
            await localFile.writeAsBytes(response.bodyBytes);
          }
        }
        count++;
      }

      setState(() {
        _isDownloading = false;
        _downloadStatus = "تم تحميل النطاق بنجاح!";
      });
      _checkLocalAudioFiles();
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadStatus = "فشل تحميل الآيات";
      });
    }
  }

  // --- UI Helpers ---

  Surah get _currentSurah => _surahs.isEmpty
      ? Surah(index: 1, name: 'الفاتحة', ayahs: [])
      : _surahs.firstWhere((s) => s.index == _selectedSurahIndex);

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  String _toArabicIndicNumbers(int number) {
    const english = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    String input = number.toString();
    for (int i = 0; i < english.length; i++) {
      input = input.replaceAll(english[i], arabic[i]);
    }
    return input;
  }

  List<Surah> get _filteredSurahs {
    if (_searchQuery.isEmpty) return _surahs;
    return _surahs.where((s) =>
        s.name.contains(_searchQuery) ||
        s.index.toString() == _searchQuery).toList();
  }

  bool _isAyahLocal(int index) {
    final String surahPad = _selectedSurahIndex.toString().padLeft(3, '0');
    final String ayahPad = index.toString().padLeft(3, '0');
    return _localAyahs.contains("$surahPad$ayahPad.mp3");
  }

  bool get _isCurrentSelectionLocal {
    if (_playbackMode == 'surah') {
      return _localSurahs.contains(_selectedSurahIndex);
    }
    return _isAyahLocal(_rangeFrom);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFFF2AF29)),
              SizedBox(height: 20),
              Text('جاري تحميل المصحف الشريف...', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );
    }

    return PopScope(
      canPop: _currentScreen == 'menu',
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentScreen != 'menu') {
          setState(() {
            _currentScreen = 'menu';
          });
          _stopPlayback();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: _buildCurrentScreen(),
              ),
              _buildAdaptivePlayer(),
            ],
          ),
        ),
      ),
    );
  }

  // Choose sub-screen view
  Widget _buildCurrentScreen() {
    switch (_currentScreen) {
      case 'menu':
        return _buildMenuScreen();
      case 'full':
        return _buildFullSurahScreen();
      case 'range':
        return _buildSpecificVersesScreen();
      case 'starred':
        return _buildStarredScreen();
      case 'search':
        return _buildSearchScreen();
      default:
        return _buildMenuScreen();
    }
  }

  // 1. Menu Screen
  Widget _buildMenuScreen() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Stack(
      children: [
        Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: isDark 
                  ? [const Color(0xFF143C2D), const Color(0xFF06110D)]
                  : [const Color(0xFFE2EFE7), const Color(0xFFF4F7F5)],
              center: Alignment.center,
              radius: 1.0,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 20),
                Icon(
                  Icons.menu_book_outlined,
                  size: 90,
                  color: isDark ? const Color(0xFFF2AF29) : const Color(0xFFB87600),
                ),
                const SizedBox(height: 20),
                Text(
                  'القرآن الكريم التفاعلي',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: isDark ? const Color(0xFFF2AF29) : const Color(0xFFB87600),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'تطبيق تفاعلي مخصص لمساعدة الأطفال والطلاب على حفظ وتلاوة كتاب الله',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? const Color(0xFF9BB8AC) : const Color(0xFF5A786C),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'يدعم التكرار، سرعة القراءة، والتشغيل دون اتصال بالقراء المتعددين',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xCCF2AF29) : const Color(0xCCB87600),
                  ),
                ),
                const SizedBox(height: 40),
                
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 550),
                  child: Column(
                    children: [
                      _buildMenuCard(
                        title: 'الاستماع للسورة كاملة',
                        desc: 'تشغيل متواصل للسورة كاملة من البداية للنهاية مع إمكانية التحميل والاستماع بدون إنترنت.',
                        icon: Icons.play_circle_filled,
                        iconBgColor: const Color(0xFF3EC37A).withOpacity(0.15),
                        iconColor: const Color(0xFF3EC37A),
                        onTap: () {
                          setState(() {
                            _currentScreen = 'full';
                            _playbackMode = 'surah';
                          });
                          _checkLocalAudioFiles();
                        },
                      ),
                      const SizedBox(height: 20),
                      _buildMenuCard(
                        title: 'الاستماع لآيات محددة',
                        desc: 'تحديد نطاق معين من الآيات، تكرار الآية الواحدة، وتكرار المجموعة لتسهيل الحفظ والترديد.',
                        icon: Icons.tune_rounded,
                        iconBgColor: const Color(0xFFF2AF29).withOpacity(0.15),
                        iconColor: const Color(0xFFF2AF29),
                        onTap: () {
                          setState(() {
                            _currentScreen = 'range';
                            _playbackMode = 'ayah';
                          });
                          _checkLocalAudioFiles();
                        },
                      ),
                      const SizedBox(height: 20),
                      _buildMenuCard(
                        title: 'الآيات المفضلة والمراجعة',
                        desc: 'استعراض ومراجعة كافة الآيات التي قمت بتمييزها بنجمة لتسهيل مراجعتها وتثبيتها بشكل متتابع.',
                        icon: Icons.star_rounded,
                        iconBgColor: const Color(0xFF3EC37A).withOpacity(0.15),
                        iconColor: const Color(0xFF3EC37A),
                        onTap: () {
                          setState(() {
                            _currentScreen = 'starred';
                            _playbackMode = 'starred';
                          });
                          _checkLocalAudioFiles();
                        },
                      ),
                      const SizedBox(height: 20),
                      _buildMenuCard(
                        title: 'البحث في المصحف الشريف',
                        desc: 'ابحث عن أي آية أو كلمة في القرآن الكريم فورياً، وانتقل إلى مكانها في السورة لبدء الحفظ والتلاوة.',
                        icon: Icons.search_rounded,
                        iconBgColor: const Color(0xFFF2AF29).withOpacity(0.15),
                        iconColor: const Color(0xFFF2AF29),
                        onTap: () {
                          setState(() {
                            _currentScreen = 'search';
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 16,
          left: 16,
          child: IconButton(
            icon: Icon(
              isDark ? Icons.wb_sunny_outlined : Icons.nightlight_round,
              color: isDark ? const Color(0xFFF2AF29) : const Color(0xFFB87600),
            ),
            onPressed: () {
              QuranApp.toggleTheme(context);
            },
            tooltip: 'تبديل المظهر',
          ),
        ),
      ],
    );
  }

  Widget _buildMenuCard({
    required String title,
    required String desc,
    required IconData icon,
    required Color iconBgColor,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Card(
      color: const Color(0xFF0D221A),
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFF1E4637)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: iconBgColor,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, color: iconColor, size: 28),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      desc,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9BB8AC),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_left_rounded,
                color: Color(0xFF9BB8AC),
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 2. Full Surah screen
  Widget _buildFullSurahScreen() {
    return Column(
      children: [
        _buildScreenHeader(
          title: 'الاستماع للسورة كاملة',
          onBack: () {
            setState(() {
              _currentScreen = 'menu';
            });
            _stopPlayback();
          },
        ),
        
        // Search Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: TextField(
            onChanged: (val) => setState(() => _searchQuery = val),
            style: const TextStyle(fontFamily: 'Cairo'),
            decoration: InputDecoration(
              hintText: 'ابحث عن السورة بالاسم أو الرقم...',
              prefixIcon: const Icon(Icons.search, color: Color(0xFFF2AF29)),
              filled: true,
              fillColor: const Color(0xFF0D221A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: const BorderSide(color: Color(0xFF1E4637)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: const BorderSide(color: Color(0xFFF2AF29)),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        
        // Surah Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 320,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 2.8,
            ),
            itemCount: _filteredSurahs.length,
            itemBuilder: (ctx, idx) {
              final surah = _filteredSurahs[idx];
              final isSelected = surah.index == _selectedSurahIndex;
              final isLocal = _localSurahs.contains(surah.index);
              
              return Card(
                color: isSelected ? const Color(0xFF1E4637) : const Color(0xFF0D221A).withOpacity(0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: isSelected ? const Color(0xFFF2AF29) : const Color(0xFFD4AF37).withOpacity(0.15),
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    setState(() {
                      _selectedSurahIndex = surah.index;
                    });
                    _stopPlayback();
                    _startPlayback();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFFF2AF29) : Colors.black26,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              surah.index.toString(),
                              style: TextStyle(
                                color: isSelected ? Colors.black : const Color(0xFFF2AF29),
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                surah.name,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${surah.ayahs.length} آية',
                                style: const TextStyle(fontSize: 11, color: Colors.white54),
                              ),
                            ],
                          ),
                        ),
                        
                        _buildSurahCardStatusAndAction(surah.index, isLocal),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSurahCardStatusAndAction(int surahIndex, bool isLocal) {
    if (isLocal) {
      return const Icon(
        Icons.check_circle_outline,
        color: Colors.green,
        size: 22,
      );
    }
    
    return IconButton(
      icon: const Icon(
        Icons.download_for_offline_outlined,
        color: Color(0xFFF2AF29),
        size: 22,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () {
        _downloadFullSurahFromGrid(surahIndex);
      },
      tooltip: 'تحميل السورة للتشغيل دون اتصال',
    );
  }

  // 3. Specific Verses screen
  Widget _buildSpecificVersesScreen() {
    return Column(
      children: [
        _buildSpecificVersesHeader(),
        _buildMemorizationControlPanel(),
        
        if (_isDownloading)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF0D221A),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_downloadStatus, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    Text(_downloadProgressText, style: const TextStyle(fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: _downloadProgress,
                  backgroundColor: Colors.white10,
                  color: const Color(0xFFF2AF29),
                  minHeight: 4,
                ),
              ],
            ),
          ),
        
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.1)),
            ),
            child: _currentSurah.ayahs.isEmpty
                ? const Center(child: Text('لا يوجد آيات متوفرة.'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _getAyahListCount(),
                    itemBuilder: (ctx, idx) {
                      return _buildAyahListItem(idx);
                    },
                  ),
          ),
        ),
      ],
    );
  }

  int _getAyahListCount() {
    int count = _rangeTo - _rangeFrom + 1;
    if (_rangeFrom == 1 && _selectedSurahIndex != 1 && _selectedSurahIndex != 9) {
      return count + 1;
    }
    return count;
  }

  Widget _buildAyahListItem(int idx) {
    final bool hasBismillah = _rangeFrom == 1 && _selectedSurahIndex != 1 && _selectedSurahIndex != 9;
    
    if (hasBismillah && idx == 0) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16.0),
        child: Text(
          'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Amiri',
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: Color(0xFFF2AF29),
          ),
        ),
      );
    }
    
    final int arrayIndex = _rangeFrom - 1 + (hasBismillah ? idx - 1 : idx);
    final ayah = _currentSurah.ayahs[arrayIndex];
    
    final isPlayingThis = _activeAyahIndex == ayah.index;
    final starKey = "${_selectedSurahIndex}_${ayah.index}";
    final isStarred = _starredAyahs.contains(starKey);
    final showBlurred = _hideTextMode && !ayah.isRevealed;
    final isLocal = _isAyahLocal(ayah.index);
    
    return Card(
      color: isPlayingThis
          ? const Color(0xFF1E4637).withOpacity(0.6)
          : const Color(0xFF0D221A).withOpacity(0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isPlayingThis ? const Color(0xFFF2AF29) : const Color(0xFFD4AF37).withOpacity(0.15),
        ),
      ),
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          if (showBlurred) {
            setState(() {
              ayah.isRevealed = true;
            });
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top box: centered Arabic text followed immediately by its index in Quranic brackets
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: ayah.text,
                      style: TextStyle(
                        fontFamily: 'Amiri',
                        fontSize: 24,
                        height: 2.0,
                        color: showBlurred ? Colors.transparent : Colors.white,
                        shadows: showBlurred
                            ? const [
                                Shadow(
                                  color: Colors.white38,
                                  blurRadius: 10,
                                )
                              ]
                            : null,
                      ),
                    ),
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: '\u200e\uFD3F${_toArabicIndicNumbers(ayah.index)}\uFD3E',
                      style: const TextStyle(
                        fontFamily: 'Amiri',
                        fontSize: 22,
                        color: Color(0xFFF2AF29),
                      ),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              
              // Bottom row: three circular controls
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Left: Star icon (bookmark toggle)
                  InkWell(
                    onTap: () {
                      setState(() {
                        if (isStarred) {
                          _starredAyahs.remove(starKey);
                        } else {
                          _starredAyahs.add(starKey);
                        }
                      });
                      _savePreferences();
                    },
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isStarred 
                            ? const Color(0xFFF2AF29).withOpacity(0.2) 
                            : Colors.white.withOpacity(0.05),
                        border: Border.all(
                          color: isStarred 
                              ? const Color(0xFFF2AF29) 
                              : const Color(0xFFD4AF37).withOpacity(0.15),
                        ),
                      ),
                      child: Icon(
                        isStarred ? Icons.star : Icons.star_border,
                        color: isStarred ? const Color(0xFFF2AF29) : Colors.white60,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  
                  // Middle: Play/Pause action
                  InkWell(
                    onTap: () {
                      if (isPlayingThis && _isPlaying) {
                        _audioPlayer.pause();
                      } else {
                        playSingleAyah(ayah.index);
                      }
                    },
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFFF2AF29),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          )
                        ],
                      ),
                      child: Icon(
                        (isPlayingThis && _isPlaying) ? Icons.pause : Icons.play_arrow,
                        color: Colors.black,
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  
                  // Right: Download status indicator (Local green checkmark or Wifi icon)
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isLocal 
                          ? Colors.green.withOpacity(0.15) 
                          : const Color(0xFFF2AF29).withOpacity(0.1),
                      border: Border.all(
                        color: isLocal ? Colors.green : const Color(0xFFF2AF29),
                      ),
                    ),
                    child: Icon(
                      isLocal ? Icons.check_circle : Icons.wifi,
                      color: isLocal ? Colors.green : const Color(0xFFF2AF29),
                      size: 20,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpecificVersesHeader() {
    return Container(
      color: const Color(0xFF0D221A),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: () {
              setState(() {
                _currentScreen = 'menu';
              });
              _stopPlayback();
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _currentSurah.name,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  'سورة رقم $_selectedSurahIndex • ${_currentSurah.ayahs.length} آيات',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
          
          // Surah selection dropdown directly in header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF06110D),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.2)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _selectedSurahIndex,
                dropdownColor: const Color(0xFF0D221A),
                items: _surahs.map((surah) {
                  return DropdownMenuItem<int>(
                    value: surah.index,
                    child: Text(
                      surah.name,
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _selectedSurahIndex = val;
                      _rangeFrom = 1;
                      _rangeTo = _surahs[val - 1].ayahs.length;
                    });
                    _stopPlayback();
                    _checkLocalAudioFiles();
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemorizationControlPanel() {
    if (_currentSurah.ayahs.isEmpty) return const SizedBox.shrink();
    
    return Container(
      padding: const EdgeInsets.all(16.0),
      color: const Color(0xFF0D221A).withOpacity(0.3),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('نطاق الحفظ:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70)),
              Row(
                children: [
                  DropdownButton<int>(
                    value: _rangeFrom,
                    dropdownColor: const Color(0xFF0D221A),
                    items: List.generate(_currentSurah.ayahs.length, (index) => index + 1)
                        .map((val) => DropdownMenuItem(value: val, child: Text('من آية $val'))).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _rangeFrom = val;
                          if (_rangeTo < val) _rangeTo = val;
                        });
                        _stopPlayback();
                      }
                    },
                  ),
                  const SizedBox(width: 16),
                  DropdownButton<int>(
                    value: _rangeTo,
                    dropdownColor: const Color(0xFF0D221A),
                    items: List.generate(_currentSurah.ayahs.length, (index) => index + 1)
                        .where((val) => val >= _rangeFrom)
                        .map((val) => DropdownMenuItem(value: val, child: Text('إلى آية $val'))).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _rangeTo = val;
                        });
                        _stopPlayback();
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('تكرار الآية:  ', style: TextStyle(fontSize: 12, color: Colors.white60)),
                      _buildCounter(
                        val: _ayahRepCount,
                        onDec: () {
                          if (_ayahRepCount > 1) {
                            setState(() => _ayahRepCount--);
                            _savePreferences();
                          }
                        },
                        onInc: () {
                          if (_ayahRepCount < 20) {
                            setState(() => _ayahRepCount++);
                            _savePreferences();
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('تكرار الكل:  ', style: TextStyle(fontSize: 12, color: Colors.white60)),
                      _buildCounter(
                        val: _rangeRepCount,
                        onDec: () {
                          if (_rangeRepCount > 1) {
                            setState(() => _rangeRepCount--);
                            _savePreferences();
                          }
                        },
                        onInc: () {
                          if (_rangeRepCount < 20) {
                            setState(() => _rangeRepCount++);
                            _savePreferences();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
              
              Column(
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.cloud_download, size: 16),
                    label: const Text('تحميل النطاق', style: TextStyle(fontSize: 12, fontFamily: 'Cairo')),
                    onPressed: _isDownloading ? null : _downloadSelectedRange,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF2AF29),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _hideTextMode = !_hideTextMode;
                        for (var a in _currentSurah.ayahs) {
                          a.isRevealed = !_hideTextMode;
                        }
                      });
                    },
                    icon: Icon(_hideTextMode ? Icons.visibility : Icons.visibility_off, size: 16),
                    label: Text(_hideTextMode ? 'إظهار الآيات' : 'إخفاء الآيات', style: const TextStyle(fontSize: 12, fontFamily: 'Cairo')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _hideTextMode ? const Color(0xFF1E4637) : const Color(0xFF0D221A),
                      foregroundColor: _hideTextMode ? Colors.greenAccent : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: const Color(0xFFD4AF37).withOpacity(0.15)),
                      ),
                    ),
                  ),
                ],
              )
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Colors.white12),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Text('القارئ: ', style: TextStyle(fontSize: 12, color: Colors.white60)),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedReciter,
                      dropdownColor: const Color(0xFF0D221A),
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFF2AF29)),
                      items: const [
                        DropdownMenuItem(value: 'husary', child: Text('الحصري (المعلم)')),
                        DropdownMenuItem(value: 'minshawy', child: Text('المنشاوي (المعلم)')),
                        DropdownMenuItem(value: 'alafasy', child: Text('العفاسي')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _selectedReciter = val;
                          });
                          _stopPlayback();
                          _checkLocalAudioFiles();
                          _savePreferences();
                        }
                      },
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text('السرعة: ', style: TextStyle(fontSize: 12, color: Colors.white60)),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<double>(
                      value: _playbackSpeed,
                      dropdownColor: const Color(0xFF0D221A),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFF2AF29)),
                      items: const [
                        DropdownMenuItem(value: 0.75, child: Text('0.75x')),
                        DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                        DropdownMenuItem(value: 1.25, child: Text('1.25x')),
                        DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                        DropdownMenuItem(value: 2.0, child: Text('2.0x')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _playbackSpeed = val;
                          });
                          _audioPlayer.setSpeed(val);
                          _savePreferences();
                        }
                      },
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

  // Header helpers
  Widget _buildScreenHeader({required String title, required VoidCallback onBack}) {
    return Container(
      color: const Color(0xFF0D221A),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: onBack,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // 4. Adaptive player bar
  Widget _buildAdaptivePlayer() {
    if (_currentScreen == 'menu') return const SizedBox.shrink();
    
    final isRangeMode = _currentScreen == 'range';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF0D221A),
        border: Border(top: BorderSide(color: const Color(0xFFD4AF37).withOpacity(0.2))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<Duration>(
            stream: _audioPlayer.positionStream,
            builder: (context, snapshot) {
              final position = snapshot.data ?? Duration.zero;
              final duration = _audioPlayer.duration ?? Duration.zero;
              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: const Color(0xFFF2AF29),
                      inactiveTrackColor: Colors.white12,
                      thumbColor: const Color(0xFFF2AF29),
                      overlayColor: const Color(0xFFF2AF29).withOpacity(0.2),
                      trackShape: const RectangularSliderTrackShape(),
                    ),
                    child: Slider(
                      value: position.inMilliseconds.toDouble().clamp(
                        0.0, 
                        duration.inMilliseconds.toDouble() > 0 
                            ? duration.inMilliseconds.toDouble() 
                            : 1.0
                      ),
                      min: 0.0,
                      max: duration.inMilliseconds.toDouble() > 0 
                          ? duration.inMilliseconds.toDouble() 
                          : 1.0,
                      onChanged: (val) {
                        _audioPlayer.seek(Duration(milliseconds: val.toInt()));
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(position),
                          style: const TextStyle(fontSize: 10, color: Colors.white60, fontFamily: 'Cairo'),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: const TextStyle(fontSize: 10, color: Colors.white60, fontFamily: 'Cairo'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Info details (Right in RTL)
              Row(
                children: [
                  Text(
                    _currentSurah.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFFF2AF29)),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isCurrentSelectionLocal ? 'محلي' : 'أونلاين',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _isCurrentSelectionLocal ? Icons.check_circle : Icons.wifi,
                    color: _isCurrentSelectionLocal ? Colors.green : const Color(0xFFF2AF29),
                    size: 16,
                  ),
                ],
              ),
              
              // Control Actions (Center)
              Row(
                children: [
                  if (isRangeMode) ...[
                    IconButton(
                      icon: const Icon(Icons.skip_previous, size: 28),
                      onPressed: () {
                        if (_activeAyahIndex != null && _activeAyahIndex! > _rangeFrom) {
                          _activeQueueIndex = _activeAyahIndex! - 1;
                          _playAyahInQueue();
                        }
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                  GestureDetector(
                    onTap: () {
                      if (_isPlaying) {
                        _audioPlayer.pause();
                      } else {
                        if (_audioPlayer.audioSource == null || _activeAyahIndex == null) {
                          _startPlayback();
                        } else {
                          _audioPlayer.play();
                        }
                      }
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF2AF29),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.black,
                        size: 28,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (isRangeMode) ...[
                    IconButton(
                      icon: const Icon(Icons.skip_next, size: 28),
                      onPressed: () {
                        if (_activeAyahIndex != null && _activeAyahIndex! < _rangeTo) {
                          _activeQueueIndex = _activeAyahIndex! + 1;
                          _playAyahInQueue();
                        }
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                  IconButton(
                    icon: const Icon(Icons.stop, size: 26, color: Colors.white60),
                    onPressed: _stopPlayback,
                  ),
                ],
              ),
              
              // Recitation delay toggle (Left in RTL)
              if (isRangeMode)
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _delayActive = !_delayActive;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _delayActive ? const Color(0xFF1E4637) : Colors.black12,
                    foregroundColor: _delayActive ? Colors.greenAccent : Colors.white70,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: const Color(0xFFD4AF37).withOpacity(0.15)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                  child: Row(
                    children: [
                      Icon(_delayActive ? Icons.mic : Icons.mic_off, size: 12),
                      const SizedBox(width: 4),
                      const Text('ترديد', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
                    ],
                  ),
                )
              else
                const SizedBox(width: 60), // spacer balance
            ],
          ),
        ],
      ),
    );
  }

  // Kid friendly counter widget
  Widget _buildCounter({required int val, required VoidCallback onDec, required VoidCallback onInc}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onDec,
            child: const CircleAvatar(
              radius: 12,
              backgroundColor: Colors.transparent,
              child: Text('-', style: TextStyle(color: Color(0xFFF2AF29), fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10.0),
            child: Text(
              val.toString(),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          GestureDetector(
            onTap: onInc,
            child: const CircleAvatar(
              radius: 12,
              backgroundColor: Colors.transparent,
              child: Text('+', style: TextStyle(color: Color(0xFFF2AF29), fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  // --- New Features Helpers & Screens ---

  Future<void> _autoCacheFile(int surahIndex, int ayahIndex) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final verseDir = Directory('${docsDir.path}/$_reciterVbyvPath');
      await verseDir.create(recursive: true);
      
      final String surahPad = surahIndex.toString().padLeft(3, '0');
      final String ayahPad = ayahIndex.toString().padLeft(3, '0');
      final String filename = "$surahPad$ayahPad.mp3";
      final File localFile = File('${verseDir.path}/$filename');
      
      if (!await localFile.exists() || await localFile.length() == 0) {
        final url = '$_reciterVbyvOnlineUrl$filename';
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          await localFile.writeAsBytes(response.bodyBytes);
          _checkLocalAudioFiles();
        }
      }
    } catch (_) {}
  }

  Future<void> _playStarredSingle(int surahIndex, int ayahIndex) async {
    _stopPlayback();
    setState(() {
      _isPlaying = true;
      _activeAyahIndex = ayahIndex;
      _selectedSurahIndex = surahIndex;
    });
    
    singlePlayMode = true;
    _playbackMode = 'starred-single';
    _singlePlayAyahIndex = ayahIndex;
    _currentAyahPlayCount = 0;
    
    final String surahPad = surahIndex.toString().padLeft(3, '0');
    final String ayahPad = ayahIndex.toString().padLeft(3, '0');
    final String filename = "$surahPad$ayahPad.mp3";
    
    final docsDir = await getApplicationDocumentsDirectory();
    final localFile = File('${docsDir.path}/$_reciterVbyvPath/$filename');

    final String sourcePath = (await localFile.exists() && await localFile.length() > 0)
        ? localFile.path
        : '$_reciterVbyvOnlineUrl$filename';

    try {
      await _audioPlayer.setAudioSource(
        sourcePath.startsWith('/')
            ? AudioSource.file(sourcePath)
            : AudioSource.uri(Uri.parse(sourcePath)),
      );
      await _audioPlayer.setSpeed(_playbackSpeed);
      _audioPlayer.play();
      
      if (!sourcePath.startsWith('/')) {
        _autoCacheFile(surahIndex, ayahIndex);
      }
    } catch (e) {
      _stopPlayback();
    }
  }

  Future<void> _playStarredInQueue() async {
    if (_starredQueue.isEmpty || _starredQueueIndex >= _starredQueue.length) {
      _stopPlayback();
      return;
    }
    
    final currentItem = _starredQueue[_starredQueueIndex];
    final int surahIndex = currentItem['surah']!;
    final int ayahIndex = currentItem['ayah']!;
    
    setState(() {
      _selectedSurahIndex = surahIndex;
      _activeAyahIndex = ayahIndex;
    });
    
    final String surahPad = surahIndex.toString().padLeft(3, '0');
    final String ayahPad = ayahIndex.toString().padLeft(3, '0');
    final String filename = "$surahPad$ayahPad.mp3";
    
    final docsDir = await getApplicationDocumentsDirectory();
    final localFile = File('${docsDir.path}/$_reciterVbyvPath/$filename');

    final String sourcePath = (await localFile.exists() && await localFile.length() > 0)
        ? localFile.path
        : '$_reciterVbyvOnlineUrl$filename';

    try {
      await _audioPlayer.setAudioSource(
        sourcePath.startsWith('/')
            ? AudioSource.file(sourcePath)
            : AudioSource.uri(Uri.parse(sourcePath)),
      );
      await _audioPlayer.setSpeed(_playbackSpeed);
      _audioPlayer.play();
      
      if (!sourcePath.startsWith('/')) {
        _autoCacheFile(surahIndex, ayahIndex);
      }
    } catch (e) {
      _stopPlayback();
    }
  }

  void _advanceStarredQueue() {
    if (_starredQueueIndex < _starredQueue.length - 1) {
      _starredQueueIndex++;
      _playStarredInQueue();
    } else {
      _stopPlayback();
    }
  }

  void _startStarredPlayback() {
    _stopPlayback();
    _starredQueue.clear();
    for (var key in _starredAyahs) {
      final parts = key.split('_');
      if (parts.length == 2) {
        final int sIdx = int.parse(parts[0]);
        final int aIdx = int.parse(parts[1]);
        _starredQueue.add({'surah': sIdx, 'ayah': aIdx});
      }
    }
    
    _starredQueue.sort((a, b) {
      if (a['surah'] != b['surah']) {
        return a['surah']!.compareTo(b['surah']!);
      }
      return a['ayah']!.compareTo(b['ayah']!);
    });
    
    if (_starredQueue.isEmpty) {
      _showErrorDialog("لا توجد آيات مفضلة للتشغيل.");
      return;
    }
    
    setState(() {
      _isPlaying = true;
      _playbackMode = 'starred';
      _starredQueueIndex = 0;
      _currentAyahPlayCount = 0;
    });
    
    _playStarredInQueue();
  }

  Widget _buildStarredScreen() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final Map<int, List<int>> grouped = {};
    for (var key in _starredAyahs) {
      final parts = key.split('_');
      if (parts.length == 2) {
        final sIdx = int.parse(parts[0]);
        final aIdx = int.parse(parts[1]);
        grouped.putIfAbsent(sIdx, () => []).add(aIdx);
      }
    }
    
    final sortedSurahIndexes = grouped.keys.toList()..sort();
    for (var sIdx in sortedSurahIndexes) {
      grouped[sIdx]!.sort();
    }
    
    return Column(
      children: [
        _buildScreenHeader(
          title: 'الآيات المفضلة والمراجعة',
          onBack: () {
            setState(() {
              _currentScreen = 'menu';
            });
            _stopPlayback();
          },
        ),
        
        if (_starredAyahs.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.star_outline_rounded, size: 70, color: Colors.grey.withOpacity(0.5)),
                  const SizedBox(height: 16),
                  const Text('قائمتك المفضلة فارغة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
                  const SizedBox(height: 8),
                  const Text('قم بتمييز الآيات بنجمة أثناء القراءة لتظهر هنا', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          )
        else ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: isDark ? const Color(0xFF0D221A).withOpacity(0.5) : const Color(0xFFE3EDE8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'عدد الآيات المفضلة: ${_starredAyahs.length}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                ElevatedButton.icon(
                  onPressed: _startStarredPlayback,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('تشغيل الكل متتالياً', style: TextStyle(fontSize: 12, fontFamily: 'Cairo')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF2AF29),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
          
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: sortedSurahIndexes.length,
              itemBuilder: (context, index) {
                final sIdx = sortedSurahIndexes[index];
                final surahName = _surahs.isEmpty ? 'سورة $sIdx' : _surahs[sIdx - 1].name;
                final ayahs = grouped[sIdx]!;
                
                return Card(
                  color: isDark ? const Color(0xFF0D221A) : Colors.white,
                  margin: const EdgeInsets.only(bottom: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: const Color(0xFFD4AF37).withOpacity(0.15)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.bookmark, color: Color(0xFFF2AF29), size: 20),
                            const SizedBox(width: 8),
                            Text(
                              surahName,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFFF2AF29)),
                            ),
                          ],
                        ),
                        const Divider(color: Colors.white10, height: 16),
                        ...ayahs.map((aIdx) {
                          final ayahText = _surahs.isEmpty ? '' : _surahs[sIdx - 1].ayahs[aIdx - 1].text;
                          final isLocal = _localAyahs.contains("${sIdx.toString().padLeft(3, '0')}${aIdx.toString().padLeft(3, '0')}.mp3");
                          final isPlayingThis = _playbackMode == 'starred-single' && _selectedSurahIndex == sIdx && _activeAyahIndex == aIdx;
                          
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 12,
                                  backgroundColor: const Color(0xFFF2AF29).withOpacity(0.15),
                                  child: Text(
                                    _toArabicIndicNumbers(aIdx),
                                    style: const TextStyle(fontSize: 10, color: Color(0xFFF2AF29), fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        ayahText,
                                        style: const TextStyle(fontSize: 15, height: 1.6, fontFamily: 'Cairo'),
                                      ),
                                    ],
                                  ),
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: Icon(isPlayingThis && _isPlaying ? Icons.pause_circle : Icons.play_circle, color: const Color(0xFF3EC37A)),
                                      onPressed: () {
                                        if (isPlayingThis && _isPlaying) {
                                          _audioPlayer.pause();
                                        } else {
                                          _playStarredSingle(sIdx, aIdx);
                                        }
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                      onPressed: () {
                                        setState(() {
                                          _starredAyahs.remove("${sIdx}_$aIdx");
                                          _savePreferences();
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  String _normalizeArabic(String text) {
    final Map<String, String> diacritics = {
      'َ': '', 'ُ': '', 'ِ': '', 'ْ': '', 'ّ': '', 'ً': '', 'ٌ': '', 'ٍ': '',
      'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ى': 'ي', 'ة': 'ه'
    };
    String result = text;
    diacritics.forEach((key, value) {
      result = result.replaceAll(key, value);
    });
    return result;
  }

  Widget _buildSearchScreen() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final List<Map<String, dynamic>> results = [];
    if (_searchQuery.trim().length >= 2) {
      final normalizedQuery = _normalizeArabic(_searchQuery.trim());
      for (var surah in _surahs) {
        for (var ayah in surah.ayahs) {
          final normalizedAyah = _normalizeArabic(ayah.text);
          if (normalizedAyah.contains(normalizedQuery)) {
            results.add({
              'surahIndex': surah.index,
              'surahName': surah.name,
              'ayahIndex': ayah.index,
              'text': ayah.text,
            });
          }
        }
      }
    }
    
    return Column(
      children: [
        _buildScreenHeader(
          title: 'البحث في الآيات',
          onBack: () {
            setState(() {
              _currentScreen = 'menu';
              _searchQuery = "";
            });
            _stopPlayback();
          },
        ),
        
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: TextField(
            autofocus: true,
            style: const TextStyle(fontFamily: 'Cairo'),
            decoration: InputDecoration(
              hintText: 'ابحث عن آية أو كلمة (مثال: رحمن)...',
              prefixIcon: const Icon(Icons.search, color: Color(0xFFF2AF29)),
              suffixIcon: _searchQuery.isNotEmpty 
                  ? IconButton(
                      icon: const Icon(Icons.clear), 
                      onPressed: () => setState(() => _searchQuery = ""),
                    )
                  : null,
              filled: true,
              fillColor: isDark ? const Color(0xFF0D221A) : Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: const Color(0xFFD4AF37).withOpacity(0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: Color(0xFFF2AF29), width: 2),
              ),
            ),
            onChanged: (val) {
              setState(() {
                _searchQuery = val;
              });
            },
          ),
        ),
        
        Expanded(
          child: _searchQuery.trim().length < 2
              ? const Center(
                  child: Text('اكتب حرفين على الأقل لبدء البحث...', style: TextStyle(color: Colors.grey, fontSize: 13)),
                )
              : results.isEmpty
                  ? const Center(
                      child: Text('لم يتم العثور على نتائج تطابق بحثك', style: TextStyle(color: Colors.grey, fontSize: 13)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final res = results[index];
                        final int sIdx = res['surahIndex'];
                        final int aIdx = res['ayahIndex'];
                        
                        return Card(
                          color: isDark ? const Color(0xFF0D221A) : Colors.white,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(color: const Color(0xFFD4AF37).withOpacity(0.1)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      "${res['surName'] ?? res['surahName']} - الآية ${aIdx}",
                                      style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFF2AF29), fontSize: 12),
                                    ),
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        setState(() {
                                          _selectedSurahIndex = sIdx;
                                          _rangeFrom = aIdx;
                                          _rangeTo = _surahs[sIdx - 1].ayahs.length;
                                          _currentScreen = 'range';
                                          _playbackMode = 'ayah';
                                          _searchQuery = "";
                                        });
                                        _stopPlayback();
                                        _checkLocalAudioFiles();
                                      },
                                      icon: const Icon(Icons.arrow_back, size: 14),
                                      label: const Text('انتقال للآية', style: TextStyle(fontSize: 11, fontFamily: 'Cairo')),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF1E4637),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  res['text'],
                                  style: const TextStyle(fontSize: 15, height: 1.6),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
