import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:video_editor/video_editor.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'export_screen.dart';
import 'video_preview.dart';
import 'video_utils.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class EnhancedEditorScreen extends StatefulWidget {
  final File file;
  final List<File>? clips;
  final String? projectName;
  final String? projectDescription;
  const EnhancedEditorScreen({super.key, required this.file, this.clips, this.projectName, this.projectDescription});

  @override
  State<EnhancedEditorScreen> createState() => _EnhancedEditorScreenState();
}

class _EnhancedEditorScreenState extends State<EnhancedEditorScreen> {
  VideoEditorController? _controller;
  VideoPlayerController? _playerController;
  bool _isInitializing = true;
  String? _errorMessage;
  late File _currentFile;
  List<File> _clips = <File>[];
  int _selectedClipIndex = -1;

  // Panel visibility states
  bool showCrop = false;
  bool showTrim = false;
  bool showTransform = false; // Rotate
  bool showFilters = false;
  bool showText = false;
  bool showAudioOverlay = false;
  bool showTimeline = false;

  // Transform states
  double scale = 1.0;
  double previousScale = 1.0;
  int rotationTurns = 0;
  double brightness = 0.0;
  double contrast = 1.0;

  // Text overlay states
  List<TextOverlay> textOverlays = [];
  int selectedTextIndex = -1;
  bool _isDragging = false;
  bool _isApplyingEdits = false;
  bool _lastApplyIncludedCrop = false;

  // Filter states
  String selectedFilter = 'None';
  List<String> filters = [
    'None',
    'Vintage',
    'Black & White',
    'Sepia',
    'Cool',
    'Warm',
    'Dramatic',
    'Fade',
  ];

  // Crop states
  bool isCropping = false;

  // Trim states
  Duration trimStart = Duration.zero;
  Duration trimEnd = Duration.zero;
  bool isTrimming = false;

  // Preview sizing used to map overlay positions back to video coordinates
  double _previewRenderWidth = 0;
  double _previewRenderHeight = 0;
  // Timeline states
  int _timelineQuantity = 12; // density of markers/thumbnails
  bool _isScrubbingTimeline = false;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
    _clips = (widget.clips != null && widget.clips!.isNotEmpty) ? List<File>.from(widget.clips!) : <File>[widget.file];
    // Ensure a clip is selected by default
    final idx = _clips.indexWhere((f) => f.path == _currentFile.path);
    _selectedClipIndex = idx >= 0 ? idx : (_clips.isNotEmpty ? 0 : -1);
    _initializeControllers();
  }

  // Returns null if crop is effectively full-frame or controller not available
  String? _computeCropFilter() {
    try {
      final ctl = _controller;
      final player = _playerController;
      if (ctl == null || player == null) return null;
      final Size sz = player.value.size;
      if (sz.width <= 0 || sz.height <= 0) return null;

      // VideoEditorController exposes crop bounds as normalized Offsets (0..1)
      final Offset min = ctl.minCrop;
      final Offset max = ctl.maxCrop;

      // Guard: values should be sane
      if (min.dx.isNaN || min.dy.isNaN || max.dx.isNaN || max.dy.isNaN) return null;

      // Compute pixel crop rect
      double left = (min.dx * sz.width).clamp(0.0, sz.width);
      double top = (min.dy * sz.height).clamp(0.0, sz.height);
      double right = (max.dx * sz.width).clamp(0.0, sz.width);
      double bottom = (max.dy * sz.height).clamp(0.0, sz.height);

      double w = (right - left).abs();
      double h = (bottom - top).abs();

      // Treat near-full-frame as no crop
      const double tol = 1e-2; // ~1%
      if (w >= sz.width * (1 - tol) && h >= sz.height * (1 - tol)) return null;

      // Even dimensions for codecs like H.264
      int toEven(num v) => ((v.floor()) >> 1) << 1;
      final int iw = toEven(w);
      final int ih = toEven(h);
      final int ix = toEven(left);
      final int iy = toEven(top);

      if (iw <= 0 || ih <= 0) return null;
      return 'crop=${iw}:${ih}:${ix}:${iy}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _initializeControllers() async {
    if (!mounted) return;
    
    try {
      setState(() {
        _isInitializing = true;
        _errorMessage = null;
      });

      // Dispose existing controllers if they exist
      await _disposeControllers();

      // Check if file exists
      if (!_currentFile.existsSync()) {
        throw Exception('Video file not found: ${_currentFile.path}');
      }

      _controller = VideoEditorController.file(
        _currentFile,
        minDuration: const Duration(seconds: 1),
        maxDuration: const Duration(seconds: 300),
      );
      
      await _controller!.initialize();
      
      _playerController = _controller!.video;
      if (_playerController == null) {
        throw Exception('Failed to initialize video player');
      }
      
      _playerController!.setLooping(true);
      
      // Add listeners only after successful initialization
      _controller!.addListener(_onControllerChanged);
      _playerController!.addListener(_onVideoTick);
      
      trimStart = _controller!.startTrim;
      trimEnd = _controller!.endTrim;
      
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Failed to initialize video: $e';
        });
      }
      // Clean up any partially initialized controllers
      await _disposeControllers();
    }
  }

  Future<void> _disposeControllers() async {
    try {
      _playerController?.removeListener(_onVideoTick);
      _controller?.removeListener(_onControllerChanged);
    } catch (_) {}
    
    try {
      await _playerController?.dispose();
      _playerController = null;
    } catch (_) {}
    
    try {
      _controller?.dispose();
      _controller = null;
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void goToExportScreen() {
    if (_controller == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(milliseconds: 500), content: const Text('Video controller not available')),
      );
      return;
    }
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExportScreen(controller: _controller!, clips: _clips),
      ),
    );
  }

  void addTextOverlay() {
    setState(() {
      textOverlays.add(TextOverlay(
        text: 'Sample Text',
        position: const Offset(100, 100),
        fontSize: 24,
        color: Colors.white,
        backgroundColor: Colors.black54,
      ));
      selectedTextIndex = textOverlays.length - 1;
    });
  }

  void updateTextOverlay(int index, TextOverlay overlay) {
    setState(() {
      textOverlays[index] = overlay;
    });
  }

  void removeTextOverlay(int index) {
    setState(() {
      textOverlays.removeAt(index);
      if (selectedTextIndex == index) {
        selectedTextIndex = -1;
      } else if (selectedTextIndex > index) {
        selectedTextIndex--;
      }
    });
  }

  void applyFilter(String filter) {
    setState(() {
      selectedFilter = filter;
      switch (filter) {
        case 'Vintage':
          brightness = -0.1;
          contrast = 1.2;
          break;
        case 'Black & White':
          // handled via ColorFiltered matrix choice
          break;
        case 'Sepia':
          brightness = 0.1;
          contrast = 1.1;
          break;
        case 'Cool':
          brightness = 0.05;
          contrast = 1.1;
          break;
        case 'Warm':
          brightness = 0.1;
          contrast = 1.2;
          break;
        case 'Dramatic':
          brightness = -0.2;
          contrast = 1.5;
          break;
        case 'Fade':
          brightness = 0.0;
          contrast = 1.0;
          break;
        default:
          brightness = 0.0;
          contrast = 1.0;
      }
    });
  }

  // (removed) applyEffect – effects not used

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                'Initializing Video Editor...',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isInitializing = true;
                    _errorMessage = null;
                  });
                  _initializeControllers();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_controller == null || _playerController == null || !_controller!.initialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              const Text(
                'Video not ready',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isInitializing = true;
                    _errorMessage = null;
                  });
                  _initializeControllers();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final media = MediaQuery.of(context);
    final size = media.size;
    final bool isLandscape = media.orientation == Orientation.landscape;
    final double toolbarHeight = isLandscape ? 56.0 : size.height * 0.08;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.projectName ?? 'Editor'),
        actions: [
          IconButton(
            tooltip: 'Export',
            icon: const Icon(Icons.ios_share),
            onPressed: goToExportScreen,
          )
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Video Preview with Effects
              Expanded(
                child: Container(
                  margin: EdgeInsets.symmetric(
                    horizontal: isLandscape ? 0 : 8,
                    vertical: 8,
                  ),
                  child: GestureDetector(
                    onTap: () {
                      if (_playerController != null) {
                        setState(() {
                          _playerController!.value.isPlaying
                              ? _playerController!.pause()
                              : _playerController!.play();
                        });
                      }
                    },
                    onScaleStart: (details) {
                      previousScale = scale;
                    },
                    onScaleUpdate: (details) {
                      setState(() {
                        scale = previousScale * details.scale;
                        if (scale < 0.5) scale = 0.5;
                        if (scale > 3.0) scale = 3.0;
                      });
                    },
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        if (_playerController == null) {
                          return const Center(
                            child: Text(
                              'Video not available',
                              style: TextStyle(color: Colors.white),
                            ),
                          );
                        }
                        
                        final double videoAspect =
                            _playerController!.value.aspectRatio == 0
                                ? 16 / 9
                                : _playerController!.value.aspectRatio;
                        final bool rotated = rotationTurns % 2 != 0;
                        final double effectiveAspect =
                            rotated ? (1 / videoAspect) : videoAspect;

                        final double maxW = constraints.maxWidth;
                        final double maxH = constraints.maxHeight;
                        double childW;
                        double childH;
                        if (maxW / maxH > effectiveAspect) {
                          childH = maxH;
                          childW = childH * effectiveAspect;
                        } else {
                          childW = maxW;
                          childH = childW / effectiveAspect;
                        }

                        // Track current render size for text overlay mapping
                        _previewRenderWidth = childW;
                        _previewRenderHeight = childH;
                        return Center(
                          child: SizedBox(
                            width: childW,
                            height: childH,
                            child: ClipRect(
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Video with effects
                                  if (_controller != null)
                                    Transform.rotate(
                                      angle: rotationTurns * 3.14159265 / 2,
                                      child: Transform.scale(
                                        scale: scale,
                                        child: ColorFiltered(
                                          colorFilter: ColorFilter.matrix(
                                              _buildColorMatrix()),
                                          child: CropGridViewer.preview(
                                              controller: _controller!),
                                        ),
                                      ),
                                    ),

                                  // Text overlays
                                  ...textOverlays.asMap().entries.map((entry) {
                                    final int index = entry.key;
                                    final TextOverlay overlay = entry.value;
                                    return DraggableTextOverlay(
                                      key: ValueKey('overlay_$index'),
                                      initialPosition: overlay.position,
                                      text: overlay.text,
                                      fontSize: overlay.fontSize,
                                      textColor: overlay.color,
                                      backgroundColor: overlay.backgroundColor,
                                      selected: selectedTextIndex == index,
                                      onTap: () {
                                        setState(() {
                                          selectedTextIndex = index;
                                        });
                                        _showTextEditorDialog(index, overlay);
                                      },
                                      onDragStart: () {
                                        setState(() {
                                          _isDragging = true;
                                        });
                                      },
                                      onDragEnd: (newPos) {
                                        // Commit final position to the model; single parent rebuild
                                        updateTextOverlay(
                                          index,
                                          TextOverlay(
                                            text: overlay.text,
                                            position: newPos,
                                            fontSize: overlay.fontSize,
                                            color: overlay.color,
                                            backgroundColor: overlay.backgroundColor,
                                          ),
                                        );
                                        setState(() {
                                          _isDragging = false;
                                        });
                                      },
                                    );
                                  }).toList(),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),

              // Scrub bar and big timeline slider
              if (_playerController != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      VideoProgressIndicator(
                        _playerController!,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.red,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '-10s',
                            icon: const Icon(Icons.replay_10, color: Colors.white70),
                            onPressed: () {
                              if (_playerController == null) return;
                              final pos = _playerController!.value.position - const Duration(seconds: 10);
                              _playerController!.seekTo(pos);
                            },
                          ),
                          const SizedBox(width: 8),
                          AnimatedBuilder(
                            animation: _playerController!,
                            builder: (context, _) {
                              final isPlaying = _playerController!.value.isPlaying;
                              return ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
                                onPressed: () {
                                  final ctl = _playerController;
                                  if (ctl == null) return;
                                  if (ctl.value.isPlaying) {
                                    ctl.pause();
                                  } else {
                                    ctl.play();
                                  }
                                },
                                icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                                label: Text(isPlaying ? 'Pause' : 'Play'),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: '+10s',
                            icon: const Icon(Icons.forward_10, color: Colors.white70),
                            onPressed: () {
                              if (_playerController == null) return;
                              final pos = _playerController!.value.position + const Duration(seconds: 10);
                              _playerController!.seekTo(pos);
                            },
                          ),
                        ],
                      )
                    ],
                  ),
                ),

              // Enhanced Bottom Toolbar
              Container(
                color: Colors.black87,
                height: toolbarHeight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildToolbarButton(
                        icon: Icons.timeline,
                        label: 'Timeline',
                        isActive: showTimeline,
                        onPressed: () {
                          setState(() {
                            final wasActive = showTimeline;
                            _hideOtherPanels();
                            if (!wasActive) showTimeline = true;
                          });
                        },
                      ),
                      _buildToolbarButton(
                        icon: Icons.crop,
                        label: 'Crop',
                        isActive: showCrop,
                        onPressed: () {
                          setState(() {
                            final wasActive = showCrop;
                            _hideOtherPanels();
                            if (!wasActive) showCrop = true;
                          });
                        },
                      ),
                      _buildToolbarButton(
                        icon: Icons.content_cut,
                        label: 'Trim',
                        isActive: showTrim,
                        onPressed: () {
                          setState(() {
                            final wasActive = showTrim;
                            _hideOtherPanels();
                            if (!wasActive) showTrim = true;
                          });
                        },
                      ),
                      _buildToolbarButton(
                        icon: Icons.rotate_90_degrees_ccw,
                        label: 'Rotate',
                        isActive: showTransform,
                        onPressed: () {
                          setState(() {
                            final wasActive = showTransform;
                            _hideOtherPanels();
                            if (!wasActive) showTransform = true;
                          });
                        },
                      ),
                      
                      _buildToolbarButton(
                        icon: Icons.filter,
                        label: 'Filters',
                        isActive: showFilters,
                        onPressed: () {
                          setState(() {
                            final wasActive = showFilters;
                            _hideOtherPanels();
                            if (!wasActive) showFilters = true;
                          });
                        },
                      ),
                      _buildToolbarButton(
                        icon: Icons.text_fields,
                        label: 'Text',
                        isActive: showText,
                        onPressed: () {
                          setState(() {
                            final wasActive = showText;
                            _hideOtherPanels();
                            if (!wasActive) showText = true;
                          });
                        },
                      ),
                      _buildToolbarButton(
                        icon: Icons.library_music,
                        label: 'Audio',
                        isActive: showAudioOverlay,
                        onPressed: () {
                          setState(() {
                            final wasActive = showAudioOverlay;
                            _hideOtherPanels();
                            if (!wasActive) showAudioOverlay = true;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Enhanced Panels
          if (showCrop) _buildCropPanel(toolbarHeight, size),
          if (showTrim) _buildTrimPanel(toolbarHeight, size),
          if (showTransform) _buildTransformPanel(toolbarHeight, size),
          if (showFilters)
            _buildFiltersPanel(toolbarHeight, size, isLandscape: isLandscape),
          if (showText) _buildTextPanel(toolbarHeight, size),
          if (showAudioOverlay) _buildAudioOverlayPanel(toolbarHeight, size),
          if (showTimeline) _buildTimelinePanel(toolbarHeight, size),

          // Fullscreen loading overlay while applying edits (e.g., crop)
          if (_isApplyingEdits)
            Positioned.fill(
              child: AbsorbPointer(
                absorbing: true,
                child: Container(
                  color: Colors.black54,
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 12),
                        Text(
                          'Applying edits...',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // nothing overlays
        ],
      ),
    );
  }

  // Keep trim time labels in sync with controller while dragging
  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {
      trimStart = _controller!.startTrim;
      trimEnd = _controller!.endTrim;
    });
  }

  // Loop playback within the selected trim range for real-time preview
  void _onVideoTick() {
    final controller = _playerController;
    if (controller == null) return;
    final pos = controller.value.position;
    final start = _controller!.startTrim;
    final end = _controller!.endTrim == Duration.zero
        ? _controller!.videoDuration
        : _controller!.endTrim;
    if (end > start) {
      if (pos < start) {
        controller.seekTo(start);
      } else if (pos >= end) {
        controller.seekTo(start);
      }
    }
    // Force UI update to ensure play/pause button reflects current state
    if (mounted) {
      setState(() {});
    }
  }

  // Compose a color matrix for current filter/brightness/contrast
  List<double> _buildColorMatrix() {
    final double c = contrast;
    final double b = brightness * 255.0;

    if (selectedFilter == 'Black & White') {
      const double r = 0.2126;
      const double g = 0.7152;
      const double bl = 0.0722;
      return [
        r * c,
        g * c,
        bl * c,
        0,
        b,
        r * c,
        g * c,
        bl * c,
        0,
        b,
        r * c,
        g * c,
        bl * c,
        0,
        b,
        0,
        0,
        0,
        1,
        0,
      ];
    }

    if (selectedFilter == 'Sepia') {
      return [
        0.393 * c,
        0.769 * c,
        0.189 * c,
        0,
        b,
        0.349 * c,
        0.686 * c,
        0.168 * c,
        0,
        b,
        0.272 * c,
        0.534 * c,
        0.131 * c,
        0,
        b,
        0,
        0,
        0,
        1,
        0,
      ];
    }

    // Default brightness/contrast matrix; other filters currently map to these adjustments
    return [
      c,
      0,
      0,
      0,
      b,
      0,
      c,
      0,
      0,
      b,
      0,
      0,
      c,
      0,
      b,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  // Bake current controller edits (crop/trim/rotate) into a new file
  Future<void> _applyEditsUsingController() async {
    try {
      final oldSize = _playerController?.value.size;
      // Let the library build the correct ffmpeg command (with trim/crop ordering)
      final exec = await VideoFFmpegVideoEditorConfig(_controller!).getExecuteConfig();
      // Detect whether crop is included in the config command
      final cmdString = exec.command;
      _lastApplyIncludedCrop = cmdString.contains('crop=') || cmdString.contains('crop=');
      
      // Execute the FFmpeg command and check for success
      final session = await FFmpegKit.execute(exec.command);
      final returnCode = await session.getReturnCode();
      
      if (returnCode == null || !returnCode.isValueSuccess()) {
        final logs = await session.getAllLogsAsString();
        throw Exception('FFmpeg failed with return code: ${returnCode?.getValue() ?? 'unknown'}. Logs: $logs');
      }

      // Check if output file was created
      final outputFile = File(exec.outputPath);
      if (!outputFile.existsSync()) {
        throw Exception('Output file was not created: ${exec.outputPath}');
      }

      // Start from the library's produced output
      String finalPath = exec.outputPath;

      // If the generated command did not include crop, but the crop grid is adjusted,
      // run an explicit crop pass now based on controller's crop bounds.
      if (!_lastApplyIncludedCrop) {
        final cropFilter = _computeCropFilter();
        if (cropFilter != null) {
          final cropOut = await _createOutputPath('crop');
          final cropCmd = "-i \"$finalPath\" -vf \"$cropFilter\" -c:a copy \"$cropOut\"";
          final cropSession = await FFmpegKit.execute(cropCmd);
          final cropRC = await cropSession.getReturnCode();
          if (cropRC == null || !cropRC.isValueSuccess()) {
            final cropLogs = await cropSession.getAllLogsAsString();
            throw Exception('Crop FFmpeg failed with return code: ${cropRC?.getValue() ?? 'unknown'}. Logs: $cropLogs');
          }
          if (!File(cropOut).existsSync()) {
            throw Exception('Crop output file was not created: $cropOut');
          }
          finalPath = cropOut;
          _lastApplyIncludedCrop = true; // We applied crop explicitly
        }
      }
      
      // Apply rotation as a separate pass to avoid merging filters with config.command
      final int turns = ((rotationTurns % 4) + 4) % 4;
      if (turns != 0) {
        final rotOut = await _createOutputPath('rot');
        String vf;
        if (turns == 1) {
          vf = 'transpose=1'; // 90° clockwise
        } else if (turns == 2) {
          vf = 'transpose=1,transpose=1'; // 180°
        } else {
          vf = 'transpose=2'; // 270° clockwise (90° CCW)
        }
        final rotCmd = "-i \"$finalPath\" -vf \"$vf\" -c:a copy \"$rotOut\"";
        final rotSession = await FFmpegKit.execute(rotCmd);
        final rotReturnCode = await rotSession.getReturnCode();
        
        if (rotReturnCode == null || !rotReturnCode.isValueSuccess()) {
          final rotLogs = await rotSession.getAllLogsAsString();
          throw Exception('Rotation FFmpeg failed with return code: ${rotReturnCode?.getValue() ?? 'unknown'}. Logs: $rotLogs');
        }
        
        if (!File(rotOut).existsSync()) {
          throw Exception('Rotation output file was not created: $rotOut');
        }
        
        finalPath = rotOut;
      }

      await _reloadWithFile(File(finalPath));
      setState(() {
        rotationTurns = 0;
        scale = 1.0;
        isCropping = false;
        isTrimming = false;
      });

      // Post-apply diagnostics: if crop requested but dimensions unchanged, inform user
      final newSize = _playerController?.value.size;
      if (_lastApplyIncludedCrop && oldSize != null && newSize != null) {
        if (oldSize.width == newSize.width && oldSize.height == newSize.height) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(duration: Duration(milliseconds: 500), content: Text('Crop executed but output size unchanged. Try adjusting the crop area more.')),
            );
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(milliseconds: 500), content: Text('Failed to apply edits: $e')),
      );
    }
  }

  String _escapeDrawtext(String text) {
    return text
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll(':', '\\:')
        .replaceAll(',', '\\,')
        .replaceAll('\n', '\\n');
  }

  String _colorToFFmpeg(Color c) {
    final r = c.red.toRadixString(16).padLeft(2, '0');
    final g = c.green.toRadixString(16).padLeft(2, '0');
    final b = c.blue.toRadixString(16).padLeft(2, '0');
    final a = (c.opacity).clamp(0.0, 1.0);
    final aStr = a.toStringAsFixed(2);
    return "#${r}${g}${b}@${aStr}";
  }

  Future<void> _applyTextOverlays() async {
    if (_isApplyingEdits) return; // avoid concurrent apply
    if (textOverlays.isEmpty) return;
    if (_playerController == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(milliseconds: 500), content: const Text('Video player not available')),
      );
      return;
    }
    
    try {
      final vidW = _playerController!.value.size.width;
      final vidH = _playerController!.value.size.height;
      if (vidW == 0 || vidH == 0 || _previewRenderWidth == 0 || _previewRenderHeight == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(milliseconds: 500), content: const Text('Preview not ready. Please wait a moment and try again.')),
        );
        return;
      }

      // Select a default font file path for drawtext (FFmpeg often requires explicit fontfile)
      String? fontFile;
      if (Platform.isAndroid) {
        fontFile = '/system/fonts/Roboto-Regular.ttf';
      } else if (Platform.isIOS) {
        // Common iOS core font family; actual path can vary by iOS version
        fontFile = '/System/Library/Fonts/Core/Helvetica.ttc';
      } else if (Platform.isMacOS) {
        fontFile = '/Library/Fonts/Arial.ttf';
      } else if (Platform.isWindows) {
        fontFile = 'C:/Windows/Fonts/arial.ttf';
      } else if (Platform.isLinux) {
        fontFile = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';
      }
      // Only use fontfile if it actually exists on the device
      if (fontFile != null && !File(fontFile).existsSync()) {
        fontFile = null;
      }

      final filters = <String>[];
      for (final overlay in textOverlays) {
        final x = (overlay.position.dx / _previewRenderWidth) * vidW;
        final y = (overlay.position.dy / _previewRenderHeight) * vidH;
        final text = _escapeDrawtext(overlay.text);
        final color = _colorToFFmpeg(overlay.color);
        final boxColor = _colorToFFmpeg(overlay.backgroundColor);
        final sizePx = overlay.fontSize;
        final fontArg = (fontFile != null) ? ":fontfile='${_escapeDrawtext(fontFile)}'" : '';
        filters.add("drawtext=text='${text}'${fontArg}:x=${x.toStringAsFixed(0)}:y=${y.toStringAsFixed(0)}:fontsize=${sizePx.toStringAsFixed(0)}:fontcolor=${color}:box=1:boxcolor=${boxColor}:boxborderw=8");
      }
      final vf = filters.join(',');
      final outPath = await _createOutputPath('text');
      // Re-encode to Android-friendly H.264 baseline + yuv420p and move moov atom to the front
      // Also re-encode audio to AAC LC for wide compatibility
      final cmd = "-y -i \"${_currentFile.path}\" -vf \"$vf\" -c:v libx264 -preset veryfast -crf 20 -profile:v baseline -level 3.0 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart \"$outPath\"";
      // Debug (optional): print command and output path to help diagnose playback issues
      // ignore: avoid_print
      print('FFmpeg text cmd: ' + cmd);
      // ignore: avoid_print
      print('Text output: ' + outPath);
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (rc == null || !rc.isValueSuccess()) {
        final logs = await session.getAllLogsAsString() ?? '';
        final firstErrLine = logs.split('\n').firstWhere(
          (l) => l.toLowerCase().contains('error') || l.toLowerCase().contains('failed'),
          orElse: () => '',
        );
        throw 'FFmpeg failed (code: ${rc?.getValue() ?? 'unknown'}) ${firstErrLine.isNotEmpty ? '- ' + firstErrLine : ''}';
      }
      await _reloadWithFile(File(outPath));
      setState(() {
        textOverlays.clear();
        selectedTextIndex = -1;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(milliseconds: 500), content: Text('Failed to apply text overlays: $e')),
      );
    }
  }

  void _hideOtherPanels() {
    showCrop = false;
    showTrim = false;
    showTransform = false;
    showFilters = false;
    showText = false;
    showAudioOverlay = false;
    showTimeline = false;
    // speed panel removed
  }

  Widget _buildToolbarButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onPressed,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: onPressed,
            icon: Icon(
              icon,
              color: isActive ? Colors.blue : Colors.white54,
              size: 20,
            ),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(
              minWidth: 32,
              minHeight: 32,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.blue : Colors.white54,
              fontSize: 9,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildCropPanel(double toolbarHeight, Size size) {
    return Positioned(
      bottom: toolbarHeight,
      left: 0,
      right: 0,
      child: Container(
        height: size.height * 0.35,
        color: Colors.black87,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text(
                'Crop Video',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _controller != null
                  ? CropGridViewer.edit(
                      controller: _controller!,
                      rotateCropArea: true,
                    )
                  : const Center(
                      child: Text(
                        'Video controller not available',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        isCropping = false;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(duration: const Duration(milliseconds: 500), content: const Text('Crop cancelled!')),
                      );
                    },
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[600],
                      foregroundColor: Colors.white,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () async {
                      setState(() {
                        _isApplyingEdits = true;
                        isCropping = true;
                      });
                      try {
                        if (_playerController?.value.isPlaying == true) {
                          await _playerController!.pause();
                        }
                        await _applyEditsUsingController();
                        if (!mounted) return;
                        setState(() {
                          showCrop = false;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(duration: const Duration(milliseconds: 500), content: Text(_lastApplyIncludedCrop ? 'Crop applied successfully!' : 'No crop detected. Adjust the crop area and try again.')),
                        );
                      } finally {
                        if (mounted) {
                          setState(() {
                            _isApplyingEdits = false;
                          });
                        }
                      }
                    },
                    icon: const Icon(Icons.crop),
                    label: const Text('Apply Crop'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // (removed) aspect ratio buttons – not supported in current widget API

  Widget _buildTrimPanel(double toolbarHeight, Size size) {
    return Positioned(
      bottom: toolbarHeight,
      left: 0,
      right: 0,
      child: Container(
        height: size.height * 0.3,
        color: Colors.black87,
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            const Text(
              'Trim Video',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            // Time Display
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Start: ${_formatDuration(trimStart)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Text(
                  'End: ${_formatDuration(trimEnd)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _controller != null
                  ? TrimSlider(
                      controller: _controller!,
                    )
                  : const Center(
                      child: Text(
                        'Video controller not available',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      // Reset to full range
                      _controller!.updateTrim(0, 1);
                      trimStart = Duration.zero;
                      trimEnd = _controller!.videoDuration;
                      isTrimming = false;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(duration: const Duration(milliseconds: 500), content: const Text("Trim reset!")),
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text("Reset"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[600],
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    setState(() {
                      _isApplyingEdits = true;
                      isTrimming = true;
                      trimStart = _controller!.startTrim;
                      trimEnd = _controller!.endTrim;
                    });
                    try {
                      if (_playerController?.value.isPlaying == true) {
                        await _playerController!.pause();
                      }
                      await _applyEditsUsingController();
                      if (!mounted) return;
                      setState(() {
                        showTrim = false; // hide trim panel after applying
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(duration: const Duration(milliseconds: 500), content: Text("Video trimmed from ${_formatDuration(trimStart)} to ${_formatDuration(trimEnd)}")),
                      );
                    } finally {
                      if (mounted) {
                        setState(() {
                          _isApplyingEdits = false;
                        });
                      }
                    }
                  },
                  icon: const Icon(Icons.cut),
                  label: const Text("Apply Trim"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigitMinutes}:${twoDigitSeconds}";
  }

  Widget _buildTransformPanel(double toolbarHeight, Size size) {
    return Positioned(
      bottom: toolbarHeight,
      left: 0,
      right: 0,
      child: Container(
        height: size.height * 0.25,
        color: Colors.black87,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'Transform Video',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  // Rotation Controls
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Rotate',
                          style: TextStyle(color: Colors.white54)),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.rotate_left,
                                color: Colors.white),
                            onPressed: () {
                              setState(() {
                                rotationTurns = (rotationTurns - 1) % 4;
                              });
                            },
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.grey[800],
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${rotationTurns * 90}°',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.rotate_right,
                                color: Colors.white),
                            onPressed: () {
                              setState(() {
                                rotationTurns = (rotationTurns + 1) % 4;
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  // Scale Controls
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Scale',
                          style: TextStyle(color: Colors.white54)),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey[800],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${scale.toStringAsFixed(1)}x',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          IconButton(
                            icon:
                                const Icon(Icons.zoom_out, color: Colors.white),
                            onPressed: () {
                              setState(() {
                                scale = (scale - 0.1).clamp(0.5, 3.0);
                              });
                            },
                          ),
                          IconButton(
                            icon:
                                const Icon(Icons.zoom_in, color: Colors.white),
                            onPressed: () {
                              setState(() {
                                scale = (scale + 0.1).clamp(0.5, 3.0);
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      scale = 1.0;
                      rotationTurns = 0;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(duration: const Duration(milliseconds: 500), content: const Text("Transform reset!")),
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text("Reset"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[600],
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    await _applyEditsUsingController();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(duration: const Duration(milliseconds: 500), content: Text("Transform applied! Scale: ${scale.toStringAsFixed(1)}x, Rotation: ${rotationTurns * 90}°")),
                      );
                    }
                  },
                  icon: const Icon(Icons.check),
                  label: const Text("Apply"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFiltersPanel(double toolbarHeight, Size size,
      {bool isLandscape = false}) {
    return Positioned(
      bottom: toolbarHeight,
      left: 0,
      right: 0,
      child: Container(
        height: size.height * 0.3,
        color: Colors.black87,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'Video Filters',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: isLandscape ? 6 : 4,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: isLandscape ? 1.4 : 1.2,
                ),
                itemCount: filters.length,
                itemBuilder: (context, index) {
                  final filter = filters[index];
                  final isSelected = selectedFilter == filter;
                  return GestureDetector(
                    onTap: () => applyFilter(filter),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.blue : Colors.grey[800],
                        borderRadius: BorderRadius.circular(8),
                        border: isSelected
                            ? Border.all(color: Colors.blue, width: 2)
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _getFilterIcon(filter),
                            color: isSelected ? Colors.white : Colors.white70,
                            size: 24,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            filter,
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.white70,
                              fontSize: 10,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      selectedFilter = 'None';
                      brightness = 0.0;
                      contrast = 1.0;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(duration: const Duration(milliseconds: 500), content: const Text("Filters reset!")),
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text("Reset"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[600],
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(duration: const Duration(milliseconds: 500), content: Text("Filter '$selectedFilter' applied!")),
                    );
                  },
                  icon: const Icon(Icons.check),
                  label: const Text("Apply"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getFilterIcon(String filter) {
    switch (filter) {
      case 'Vintage':
        return Icons.filter_vintage;
      case 'Black & White':
        return Icons.filter_b_and_w;
      case 'Sepia':
        return Icons.filter_drama;
      case 'Cool':
        return Icons.ac_unit;
      case 'Warm':
        return Icons.wb_sunny;
      case 'Dramatic':
        return Icons.flash_on;
      case 'Fade':
        return Icons.blur_on;
      default:
        return Icons.filter_none;
    }
  }

  // (removed) Effects panel – not part of focused feature set

  Widget _buildTextPanel(double toolbarHeight, Size size) {
    return Positioned(
      bottom: toolbarHeight,
      left: 0,
      right: 0,
      child: Container(
        height: size.height * 0.35,
        color: Colors.black87,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Text Overlays',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _showTextStyleDialog(),
                      icon: const Icon(Icons.style),
                      label: const Text('Style'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: addTextOverlay,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Text'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: textOverlays.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.text_fields,
                              color: Colors.white54, size: 48),
                          SizedBox(height: 16),
                          Text(
                            'No text overlays added yet.\nTap "Add Text" to get started!',
                            style: TextStyle(color: Colors.white54),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: textOverlays.length,
                      itemBuilder: (context, index) {
                        final overlay = textOverlays[index];
                        final isSelected = selectedTextIndex == index;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.blue.withOpacity(0.2)
                                : Colors.grey[800],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListTile(
                            title: Text(
                              overlay.text,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            subtitle: Text(
                              'Font: ${overlay.fontSize.toInt()}px | Color: ${_getColorName(overlay.color)}',
                              style: const TextStyle(color: Colors.white54),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit,
                                      color: Colors.white),
                                  onPressed: () =>
                                      _showTextEditorDialog(index, overlay),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete,
                                      color: Colors.red),
                                  onPressed: () => removeTextOverlay(index),
                                ),
                              ],
                            ),
                            onTap: () {
                              setState(() {
                                selectedTextIndex = index;
                              });
                            },
                          ),
                        );
                      },
                    ),
            ),
            if (textOverlays.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          textOverlays.clear();
                          selectedTextIndex = -1;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(duration: const Duration(milliseconds: 500), content: const Text("All text overlays removed!")),
                        );
                      },
                      icon: const Icon(Icons.clear_all),
                      label: const Text("Clear All"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final count = textOverlays.length;
                        if (count == 0) return;
                        setState(() { _isApplyingEdits = true; });
                        try {
                          if (_playerController?.value.isPlaying == true) {
                            await _playerController!.pause();
                          }
                          await _applyTextOverlays();
                          if (!mounted) return;
                          setState(() { showText = false; });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(duration: const Duration(milliseconds: 500), content: Text("$count text overlay${count > 1 ? 's' : ''} applied and saved!")),
                          );
                        } finally {
                          if (mounted) {
                            setState(() { _isApplyingEdits = false; });
                          }
                        }
                      },
                      icon: const Icon(Icons.check),
                      label: const Text("Apply"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _getColorName(Color color) {
    if (color == Colors.white) return 'White';
    if (color == Colors.black) return 'Black';
    if (color == Colors.red) return 'Red';
    if (color == Colors.green) return 'Green';
    if (color == Colors.blue) return 'Blue';
    if (color == Colors.yellow) return 'Yellow';
    return 'Custom';
  }

  void _showTextStyleDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Text Style Presets',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStylePreset('Title', Colors.white, 32, Colors.black54),
            _buildStylePreset('Subtitle', Colors.white70, 24, Colors.black54),
            _buildStylePreset('Caption', Colors.white54, 18, Colors.black54),
            _buildStylePreset('Highlight', Colors.yellow, 20, Colors.black54),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _buildStylePreset(
      String name, Color color, double fontSize, Color bgColor) {
    return ListTile(
      title: Text(
        name,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      onTap: () {
        addTextOverlay();
        if (textOverlays.isNotEmpty) {
          final lastIndex = textOverlays.length - 1;
          updateTextOverlay(
              lastIndex,
              TextOverlay(
                text: 'Sample $name',
                position: const Offset(100, 100),
                fontSize: fontSize,
                color: color,
                backgroundColor: bgColor,
              ));
        }
        Navigator.pop(context);
      },
    );
  }

  // (removed) audio playback controls – using audio overlay panel instead

  // (removed) playback speed – not part of focused feature set

  void _showTextEditorDialog(int index, TextOverlay overlay) {
    final textController = TextEditingController(text: overlay.text);
    final fontSizeController =
        TextEditingController(text: overlay.fontSize.toInt().toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Edit Text', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: textController,
              decoration: const InputDecoration(
                labelText: 'Text',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white30)),
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.blue)),
              ),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: fontSizeController,
              decoration: const InputDecoration(
                labelText: 'Font Size',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white30)),
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.blue)),
              ),
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () {
              final newText = textController.text;
              final newFontSize =
                  double.tryParse(fontSizeController.text) ?? overlay.fontSize;

              updateTextOverlay(
                  index,
                  TextOverlay(
                    text: newText,
                    position: overlay.position,
                    fontSize: newFontSize,
                    color: overlay.color,
                    backgroundColor: overlay.backgroundColor,
                  ));

              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<String> _createOutputPath(String suffix) async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}/edit_${ts}_$suffix.mp4';
  }

  Future<void> _reloadWithFile(File newFile) async {
    if (!mounted) return;
    
    setState(() => _isInitializing = true);
    try {
      // Check if new file exists
      if (!newFile.existsSync()) {
        throw Exception('New video file not found: ${newFile.path}');
      }
      
      await _disposeControllers();
      _currentFile = newFile;
      // Keep selection in sync with current file
      final idx = _clips.indexWhere((f) => f.path == _currentFile.path);
      _selectedClipIndex = idx >= 0 ? idx : (_clips.isNotEmpty ? 0 : -1);
      await _initializeControllers();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Failed to reload: $e';
        });
      }
    }
  }

  double _currentPanelHeight(Size size) {
    double factor = 0.0;
    if (showCrop)
      factor = 0.35;
    else if (showTrim)
      factor = 0.3;
    else if (showTransform)
      factor = 0.25;
    else if (showFilters)
      factor = 0.3;
    else if (showText)
      factor = 0.35;
    else if (showAudioOverlay) factor = 0.24;
    else if (showTimeline) factor = 0.26;
    if (factor == 0.0) return 0.0;
    return math.min(size.height * factor, size.height * 0.45);
  }

  Future<File> _savePlatformFileToTemp(PlatformFile pf) async {
    final dir = await getTemporaryDirectory();
    final ext = (pf.extension != null && pf.extension!.isNotEmpty)
        ? '.${pf.extension}'
        : '';
    final path =
        '${dir.path}/pick_${DateTime.now().millisecondsSinceEpoch}$ext';
    if (pf.path != null) {
      return File(pf.path!);
    }
    throw Exception('No data available for picked file');
  }

  Future<List<File>> _savePickedFilesToTemp(List<PlatformFile> pfs) async {
    final result = <File>[];
    for (final pf in pfs) {
      result.add(await _savePlatformFileToTemp(pf));
    }
    return result;
  }

  

  Widget _buildAudioOverlayPanel(double toolbarHeight, Size size) {
    final maxH = _currentPanelHeight(size);
    return Positioned(
      bottom: toolbarHeight,
      left: 0,
      right: 0,
      child: Container(
        constraints:
            BoxConstraints(maxHeight: maxH > 0 ? maxH : size.height * 0.24),
        color: Colors.black87,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Audio Overlay',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      final result = await FilePicker.platform
                          .pickFiles(type: FileType.audio, withData: false);
                      if (result == null || result.files.isEmpty) return;
                      final audioFile =
                          await _savePlatformFileToTemp(result.files.first);
                      final outPath = await _createOutputPath('audio_overlay');
                      final cmd =
                          "-i \"${_currentFile.path}\" -i \"${audioFile.path}\" -map 0:v:0 -map 1:a:0 -c:v copy -shortest \"$outPath\"";
                      await FFmpegKit.execute(cmd);
                      await _reloadWithFile(File(outPath));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                duration: const Duration(milliseconds: 500),
                                content: const Text('Audio overlay applied')));
                      }
                    },
                    icon: const Icon(Icons.library_music),
                    label: const Text('Pick & Overlay Audio'),
                  ),
                  ElevatedButton.icon(
                    onPressed: () async {
                      final outPath = await _createOutputPath('mute');
                      final cmd =
                          "-i \"${_currentFile.path}\" -an -c:v copy \"$outPath\"";
                      await FFmpegKit.execute(cmd);
                      await _reloadWithFile(File(outPath));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                duration: const Duration(milliseconds: 500),
                                content: const Text('Removed all audio tracks')));
                      }
                    },
                    icon: const Icon(Icons.volume_off),
                    label: const Text('Remove Audio'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                  'Note: Audio is replaced by the picked track; use Remove Audio to mute.',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimelinePanel(double toolbarHeight, Size size) {
    return Positioned(
      bottom: toolbarHeight,
      left: 0,
      right: 0,
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        bottom: true,
        child: Container(
          height: math.min(size.height * 0.36, 260),
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text('Timeline', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Text('(${_clips.length} clips)', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(width: 12),
                    IconButton(
                      tooltip: 'Zoom out',
                      onPressed: () {
                        setState(() {
                          _timelineQuantity = (_timelineQuantity - 4).clamp(4, 60);
                        });
                      },
                      icon: const Icon(Icons.zoom_out, color: Colors.white70),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      onPressed: () {
                        setState(() {
                          _timelineQuantity = (_timelineQuantity + 4).clamp(4, 60);
                        });
                      },
                      icon: const Icon(Icons.zoom_in, color: Colors.white70),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Add clips',
                      onPressed: () async {
                        final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.video, withData: false);
                        if (result == null || result.files.isEmpty) return;
                        final added = await _savePickedFilesToTemp(result.files);
                        setState(() {
                          _clips.addAll(added);
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(duration: const Duration(milliseconds: 500), content: const Text('Clips added to timeline')),
                        );
                      },
                      icon: const Icon(Icons.add, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // Visible list of clips as chips for quick selection
              SizedBox(
                height: 36,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _clips.length,
                  itemBuilder: (context, i) {
                    final f = _clips[i];
                    final name = f.path.split(Platform.pathSeparator).last;
                    final isSelected = i == _selectedClipIndex;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: ChoiceChip(
                        selected: isSelected,
                        label: Text(
                          '${i + 1}: ' + (name.length > 18 ? name.substring(0, 15) + '…' : name),
                          style: TextStyle(color: isSelected ? Colors.black : Colors.white),
                        ),
                        selectedColor: Colors.amber,
                        backgroundColor: Colors.grey.shade800,
                        onSelected: (_) async {
                          if (_selectedClipIndex == i) return;
                          setState(() => _selectedClipIndex = i);
                          await _reloadWithFile(_clips[i]);
                        },
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Ensure controllers are ready before drawing timeline
                    if (_controller == null || _playerController == null || !_playerController!.value.isInitialized) {
                      return Center(
                        child: Text('Preparing timeline…', style: TextStyle(color: Colors.white54)),
                      );
                    }
                    final duration = _controller!.videoDuration;
                    final pos = _playerController!.value.position;
                    final fraction = (duration.inMilliseconds == 0)
                        ? 0.0
                        : (pos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0) as double;

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanDown: (d) {
                        setState(() => _isScrubbingTimeline = true);
                        final rel = (d.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0) as double;
                        final target = Duration(milliseconds: (duration.inMilliseconds * rel).round());
                        _playerController!.seekTo(target);
                      },
                      onPanUpdate: (d) {
                        final w = constraints.maxWidth;
                        double dx = d.localPosition.dx;
                        if (dx < 0) dx = 0;
                        if (dx > w) dx = w;
                        final rel = (dx / w).clamp(0.0, 1.0) as double;
                        final target = Duration(milliseconds: (duration.inMilliseconds * rel).round());
                        _playerController!.seekTo(target);
                      },
                      onPanEnd: (_) => setState(() => _isScrubbingTimeline = false),
                      onTapDown: (d) {
                        final rel = (d.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0) as double;
                        final target = Duration(milliseconds: (duration.inMilliseconds * rel).round());
                        _playerController!.seekTo(target);
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: TrimTimeline(
                              controller: _controller!,
                              quantity: _timelineQuantity,
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                            ),
                          ),
                          Positioned(
                            left: math.max(8.0, math.min(8.0 + fraction * (constraints.maxWidth - 16.0), constraints.maxWidth - 8.0)),
                            top: 0,
                            bottom: 0,
                            child: Container(
                              width: 2,
                              color: _isScrubbingTimeline ? Colors.amber : Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () async {
                        if (_clips.length <= 1) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add more clips to merge timeline')));
                          return;
                        }
                        final outPath = await _createOutputPath('timeline_merge');
                        await VideoUtils.mergeVideos(_clips, outPath);
                        await _reloadWithFile(File(outPath));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Timeline merged into a single clip')));
                      },
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), minimumSize: const Size(0, 36)),
                      icon: const Icon(Icons.merge_type, size: 18),
                      label: const Text('Merge Timeline'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () async {
                        if (_selectedClipIndex < 0) {
                          // Auto-select current clip or first clip
                          final idx = _clips.indexWhere((f) => f.path == _currentFile.path);
                          setState(() {
                            _selectedClipIndex = idx >= 0 ? idx : (_clips.isNotEmpty ? 0 : -1);
                          });
                          if (_selectedClipIndex < 0) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No clips in timeline')));
                            return;
                          }
                        }
                        if (_playerController == null) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Video player not available')));
                          return;
                        }
                        final playPos = _playerController!.value.position;
                        final secs = playPos.inSeconds;
                        if (secs <= 0) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Move playhead to where you want to split')));
                          return;
                        }
                        final current = _clips[_selectedClipIndex];
                        final parts = await VideoUtils.splitAt(current, secs);
                        setState(() {
                          _clips.removeAt(_selectedClipIndex);
                          _clips.insertAll(_selectedClipIndex, parts);
                          _selectedClipIndex = _selectedClipIndex + 1;
                        });
                        await _reloadWithFile(parts.first);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clip split at playhead')));
                      },
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), minimumSize: const Size(0, 36)),
                      icon: const Icon(Icons.call_split, size: 18),
                      label: const Text('Split at Playhead'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () async {
                        if (_selectedClipIndex < 0) {
                          final idx = _clips.indexWhere((f) => f.path == _currentFile.path);
                          setState(() {
                            _selectedClipIndex = idx >= 0 ? idx : (_clips.isNotEmpty ? 0 : -1);
                          });
                          if (_selectedClipIndex < 0) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No clips in timeline')));
                            return;
                          }
                        }
                        if (_controller == null) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Video controller not available')));
                          return;
                        }
                        final start = _controller!.startTrim.inSeconds;
                        final end = (_controller!.endTrim == Duration.zero ? _controller!.videoDuration : _controller!.endTrim).inSeconds;
                        final duration = (end - start);
                        if (duration <= 0) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select a valid trim range')));
                          return;
                        }
                        final range = await VideoUtils.extractRange(_clips[_selectedClipIndex], start, duration);
                        setState(() {
                          _clips[_selectedClipIndex] = range;
                        });
                        await _reloadWithFile(range);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Replaced clip with trimmed range')));
                      },
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), minimumSize: const Size(0, 36)),
                      icon: const Icon(Icons.crop_7_5, size: 18),
                      label: const Text('Replace with Range'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () async {
                        if (_selectedClipIndex < 0) {
                          final idx = _clips.indexWhere((f) => f.path == _currentFile.path);
                          setState(() {
                            _selectedClipIndex = idx >= 0 ? idx : (_clips.isNotEmpty ? 0 : -1);
                          });
                        }
                        if (_selectedClipIndex < 0 || _clips.length < 2) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select clip(s) to merge')));
                          return;
                        }
                        final idx = _selectedClipIndex;
                        if (idx >= _clips.length - 1) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select a non-last clip to merge with next')));
                          return;
                        }
                        final out = await _createOutputPath('merge_pair');
                        await VideoUtils.mergeVideos([_clips[idx], _clips[idx + 1]], out);
                        setState(() {
                          _clips.removeAt(idx + 1);
                          _clips[idx] = File(out);
                        });
                        await _reloadWithFile(File(out));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clips merged')));
                      },
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), minimumSize: const Size(0, 36)),
                      icon: const Icon(Icons.merge, size: 18),
                      label: const Text('Merge With Next'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TextOverlay {
  final String text;
  final Offset position;
  final double fontSize;
  final Color color;
  final Color backgroundColor;

  TextOverlay({
    required this.text,
    required this.position,
    required this.fontSize,
    required this.color,
    required this.backgroundColor,
  });
}

class DraggableTextOverlay extends StatefulWidget {
  final Offset initialPosition;
  final String text;
  final double fontSize;
  final Color textColor;
  final Color backgroundColor;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDragEnd;

  const DraggableTextOverlay({
    super.key,
    required this.initialPosition,
    required this.text,
    required this.fontSize,
    required this.textColor,
    required this.backgroundColor,
    this.selected = false,
    this.onTap,
    this.onDragStart,
    this.onDragEnd,
  });

  @override
  State<DraggableTextOverlay> createState() => _DraggableTextOverlayState();
}

class _DraggableTextOverlayState extends State<DraggableTextOverlay> {
  late Offset _pos;

  @override
  void initState() {
    super.initState();
    _pos = widget.initialPosition;
  }

  @override
  void didUpdateWidget(covariant DraggableTextOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If model changed externally (e.g., undo/redo), sync position
    if (oldWidget.initialPosition != widget.initialPosition) {
      _pos = widget.initialPosition;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      child: GestureDetector
        (
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          if (widget.onDragStart != null) widget.onDragStart!();
        },
        onPanUpdate: (details) {
          setState(() {
            _pos = Offset(_pos.dx + details.delta.dx, _pos.dy + details.delta.dy);
          });
        },
        onPanEnd: (_) {
          if (widget.onDragEnd != null) widget.onDragEnd!(_pos);
        },
        onTap: widget.onTap,
        child: Transform.scale(
          scale: widget.selected ? 1.08 : 1.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: widget.selected
                  ? widget.backgroundColor.withOpacity(0.8)
                  : widget.backgroundColor,
              borderRadius: BorderRadius.circular(4),
              boxShadow: widget.selected
                  ? [
                      BoxShadow(
                        color: Colors.blue.withOpacity(0.3),
                        blurRadius: 8,
                        spreadRadius: 2,
                      )
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 2,
                        spreadRadius: 1,
                      )
                    ],
            ),
            child: Text(
              widget.text,
              style: TextStyle(
                color: widget.textColor,
                fontSize: widget.fontSize,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipThumb extends StatefulWidget {
  final File file;
  const _ClipThumb({required this.file});

  @override
  State<_ClipThumb> createState() => _ClipThumbState();
}

class _ClipThumbState extends State<_ClipThumb> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    try {
      // Check if file exists before generating thumbnail
      if (!widget.file.existsSync()) {
        throw Exception('File not found: ${widget.file.path}');
      }
      
      final bytes = await VideoThumbnail.thumbnailData(
        video: widget.file.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 256,
        quality: 50,
      );
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // Log error for debugging but don't crash
        print('Thumbnail generation failed: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(color: Colors.grey[800]);
    }
    if (_bytes == null || _bytes!.isEmpty) {
      return Container(color: Colors.grey[800], child: const Icon(Icons.movie, color: Colors.white38));
    }
    return Image.memory(_bytes!, fit: BoxFit.cover);
  }
}
