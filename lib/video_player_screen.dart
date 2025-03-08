import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart'; // تأكد من وجود هذا الاستيراد
import 'package:google_mobile_ads/google_mobile_ads.dart';

enum VideoSize {
  fullScreen, // Use device's full screen size
  ratio16_9, // 16:9 aspect ratio
  ratio4_3, // 4:3 aspect ratio
  ratio1_1, // 1:1 aspect ratio
}

class VideoPlayerScreen extends StatefulWidget {
  final String initialUrl;
  final List<Map<String, dynamic>> streamLinks;
  final Color progressBarColor;
  final Color progressBarBufferedColor;
  final Duration controlsHideDelay;
  final Duration playbackTimeoutDuration;
  final int maxRetries;
  final Duration streamSwitchDelay;

  const VideoPlayerScreen({
    super.key,
    required this.initialUrl,
    required this.streamLinks,
    this.progressBarColor = Colors.red,
    this.progressBarBufferedColor = Colors.grey,
    this.controlsHideDelay = const Duration(seconds: 5),
    this.playbackTimeoutDuration = const Duration(seconds: 10),
    this.maxRetries = 5,
    this.streamSwitchDelay = const Duration(seconds: 3),
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;
  late AnimationController _animationController;
  late Animation<double> _opacityAnimation;

  bool _isLoading = true;
  bool _hasError = false;
  bool _isControlsVisible = true;
  String? _currentUrl = "";
  bool _isLive = false;
  int _selectedQualityIndex = 0;
  bool _isTryingNextStream = false;
  VideoSize _currentVideoSize = VideoSize.ratio16_9; // Start with 16:9
  double? _initialAspectRatio; // Store initial aspect ratio

  // AdMob variables
  InterstitialAd? _interstitialAd;
  bool _isAdLoading = false;
  final String _adUnitId = 'ca-app-pub-2393153600924393/4147344165';

  Timer? _hideControlsTimer;
  Timer? _playbackTimeoutTimer;
  Timer? _bufferingTimer;
  StreamSubscription<ConnectivityResult>?
      _connectivitySubscription; // التصحيح هنا

  void _loadAd() {
    _isAdLoading = true;
    InterstitialAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (InterstitialAd ad) {
          _interstitialAd = ad;
          _isAdLoading = false;
        },
        onAdFailedToLoad: (LoadAdError error) {
          print('InterstitialAd failed to load: $error');
          _isAdLoading = false;
          _showError('Failed to load ad.');
        },
      ),
    );
  }

  void _showAd({required VoidCallback onAdDismissed}) {
    if (_interstitialAd != null) {
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (InterstitialAd ad) =>
            print('%ad onAdShowedFullScreenContent.'),
        onAdDismissedFullScreenContent: (InterstitialAd ad) {
          print('$ad onAdDismissedFullScreenContent.');
          ad.dispose();
          onAdDismissed();
        },
        onAdFailedToShowFullScreenContent: (InterstitialAd ad, AdError error) {
          print('$ad onAdFailedToShowFullScreenContent: $error');
          ad.dispose();
          onAdDismissed();
        },
        onAdImpression: (InterstitialAd ad) =>
            print('$ad impression occurred.'),
      );
      _interstitialAd!.show();
    } else {
      onAdDismissed();
    }
  }

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _opacityAnimation =
        Tween<double>(begin: 1.0, end: 0.0).animate(_animationController);

    if (widget.streamLinks.isNotEmpty) {
      _currentUrl = widget.streamLinks[0]['url'];
      _selectedQualityIndex = 0;
    } else {
      _currentUrl = widget.initialUrl;
      _selectedQualityIndex = _findInitialStreamIndex();
    }
    _loadAd();

    _enableFullscreenMode();
    _startHideControlsTimer();

    // **تغيير الترتيب:** تهيئة _connectivitySubscription *قبل* _checkIfLive()
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen(_handleConnectivityChange); // التصحيح هنا
    _checkIfLive();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialUrl != oldWidget.initialUrl ||
        widget.streamLinks != oldWidget.streamLinks) {
      _cancelAllTimers();
      _videoPlayerController?.removeListener(_videoPlayerListener);
      if (widget.streamLinks.isNotEmpty) {
        _changeStream(widget.streamLinks[0]['url'], 0);
      } else {
        _changeStream(widget.initialUrl, _findInitialStreamIndex());
      }
    }
  }

  @override
  dispose() {
    print("dispose: Disposing VideoPlayerScreenState");
    _cancelAllTimers();
    _videoPlayerController?.removeListener(_videoPlayerListener);
    _releaseControllers();
    _disableFullscreenMode();
    _animationController.dispose();
    _interstitialAd?.dispose();
    _connectivitySubscription?.cancel(); // ✅ إلغاء الاشتراك

    super.dispose();
  }

  int _findInitialStreamIndex() {
    final index = widget.streamLinks
        .indexWhere((link) => link['url'] == widget.initialUrl);
    return index != -1 ? index : 0;
  }

  void _checkIfLive() {
    _isLive = widget.streamLinks.any((link) =>
        link['url'] == _currentUrl &&
        link.containsKey('isLive') &&
        link['isLive'] == true);
  }

  void _enableFullscreenMode() {
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _disableFullscreenMode() {
    WakelockPlus.disable();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([]);
    });
  }

  void _cancelAllTimers() {
    _hideControlsTimer?.cancel();
    _playbackTimeoutTimer?.cancel();
    _bufferingTimer?.cancel();
  }

  void _releaseControllers() {
    print("_releaseControllers: Releasing controllers");
    _videoPlayerController?.pause();
    _videoPlayerController?.dispose();
    _chewieController?.pause();
    _chewieController?.dispose();
  }

  void _handleConnectivityChange(ConnectivityResult result) {
    // التصحيح هنا
    if (!mounted) return;

    if (result == ConnectivityResult.none) {
      _showNetworkError();
      _chewieController?.pause(); // Pause, don't dispose
    } else {
      // Connection restored.  Try to re-initialize.
      if (mounted) {
        // ✅ فحص mounted مهم
        _initializePlayer(_currentUrl!);
      }
    }
  }

  Future<void> _initializePlayer(String url) async {
    if (!mounted) return;
    print("_initializePlayer: START for url: $url");

    // No need to check connectivity *here* anymore. The listener handles it.

    _showAd(onAdDismissed: () async {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });

      if (_videoPlayerController != null) {
        _videoPlayerController!.removeListener(_videoPlayerListener);
        await _videoPlayerController!.dispose();
        _videoPlayerController = null;
      }
      if (_chewieController != null) {
        _chewieController!.pause();
        _chewieController!.dispose();
        _chewieController = null;
      }

      _videoPlayerController = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: {
          'Accept':
              'application/vnd.apple.mpegurl,application/x-mpegurl,video/mp4,application/mp4,video/MP2T,*/*',
          'User-Agent': 'MyFlutterApp/1.0',
        },
      );

      _videoPlayerController!.addListener(_videoPlayerListener);

      try {
        await _videoPlayerController!.initialize();

        _initialAspectRatio = _videoPlayerController!.value.aspectRatio;

        _chewieController = ChewieController(
          videoPlayerController: _videoPlayerController!,
          autoPlay: true,
          looping: false,
          aspectRatio: _getAspectRatioForSize(_currentVideoSize),
          showControls: false,
          showOptions: false,
          errorBuilder: (context, errorMessage) =>
              _buildErrorWidget(errorMessage),
          autoInitialize: true,
        );

        _startPlaybackTimeoutTimer();
        _startBufferingTimer();

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        print("_initializePlayer: SUCCESS for url: $url");
      } catch (e) {
        print("Error initializing player: $e for url: $url");
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        _tryNextStream();
      }
    });
  }

  void _startPlaybackTimeoutTimer() {
    _playbackTimeoutTimer?.cancel();
    _playbackTimeoutTimer = Timer(widget.playbackTimeoutDuration, () {
      if (!mounted) return;
      if (_videoPlayerController != null &&
          !_videoPlayerController!.value.isPlaying &&
          !_videoPlayerController!.value.isBuffering &&
          _videoPlayerController!.value.position.inSeconds == 0) {
        _tryNextStream();
      }
    });
  }

  void _startBufferingTimer() {
    _bufferingTimer?.cancel();
    _bufferingTimer = Timer.periodic(const Duration(seconds: 7), (timer) {
      if (!mounted) return;
      if (_videoPlayerController?.value.isBuffering ?? false) {
        print("Buffering timer triggered retry");
        _tryNextStream();
      }
    });
  }

  void _videoPlayerListener() {
    if (!mounted || _videoPlayerController == null) return;

    if (_videoPlayerController!.value.isPlaying) {
      _playbackTimeoutTimer?.cancel();
      _bufferingTimer?.cancel();
      _isTryingNextStream = false;
    }

    if (_videoPlayerController!.value.hasError) {
      if (mounted && !_isTryingNextStream) {
        setState(() {
          _isLoading = false;
        });
        _tryNextStream();
      }
      return;
    }

    if (_videoPlayerController!.value.isBuffering != _isLoading) {
      if (mounted) {
        setState(() {
          _isLoading = _videoPlayerController!.value.isBuffering;
        });
      }
    }
  }

  Future<void> _tryNextStream() async {
    if (_isTryingNextStream) {
      print("_tryNextStream: Already trying next stream, exiting");
      return;
    }
    _isTryingNextStream = true;

    print(
        "_tryNextStream: Attempting to find next stream. Current index: $_selectedQualityIndex");
    final nextIndex = _findNextViableStreamIndex();

    if (nextIndex != -1 && nextIndex != _selectedQualityIndex) {
      final nextUrl = widget.streamLinks[nextIndex]['url'];
      if (nextUrl != null && nextUrl.isNotEmpty) {
        print(
            "_tryNextStream: Changing stream to index: $nextIndex, URL: $nextUrl after delay");
        await Future.delayed(widget.streamSwitchDelay);
        if (!mounted) return;
        _changeStream(nextUrl, nextIndex);
      } else {
        print(
            "_tryNextStream: Next stream URL is empty or null at index: $nextIndex");
        _handleNoMoreStreams();
      }
    } else {
      print("_tryNextStream: No next viable stream found or same index.");
      _handleNoMoreStreams();
    }
  }

  void _handleNoMoreStreams() {
    if (mounted) {
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
      _showError("No other streams available.");
    }
  }

  int _findNextViableStreamIndex() {
    print(
        "_findNextViableStreamIndex: Searching from index: $_selectedQualityIndex");
    for (int i = _selectedQualityIndex + 1;
        i < widget.streamLinks.length;
        i++) {
      if (widget.streamLinks[i]['url'] != null &&
          widget.streamLinks[i]['url'].isNotEmpty) {
        print(
            "_findNextViableStreamIndex: Found forward, index: $i, URL: ${widget.streamLinks[i]['url']}");
        return i;
      }
    }
    print("_findNextViableStreamIndex: No viable stream found.");
    return -1;
  }

  Future<void> _changeStream(String url, int index) async {
    if (url == _currentUrl || url.isEmpty) return;
    print("_changeStream: START to URL: $url, index: $index");

    setState(() {
      _hasError = false;
      _isLoading = true;
      _selectedQualityIndex = index;
      _currentUrl = url;
    });

    await _videoPlayerController?.pause();
    await _chewieController?.pause();
    _videoPlayerController?.removeListener(_videoPlayerListener);
    await _videoPlayerController?.dispose();
    _chewieController?.dispose();

    _videoPlayerController = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: {
        'Accept':
            'application/vnd.apple.mpegurl,application/x-mpegurl,video/mp4,application/mp4,video/MP2T,*/*',
        'User-Agent': 'MyFlutterApp/1.0',
      },
    );
    _videoPlayerController!.addListener(_videoPlayerListener);

    try {
      await _videoPlayerController!.initialize();

      _initialAspectRatio = _videoPlayerController!.value.aspectRatio;

      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController!,
        autoPlay: true,
        looping: false,
        aspectRatio: _getAspectRatioForSize(_currentVideoSize),
        showControls: false,
        showOptions: false,
        errorBuilder: (context, errorMessage) =>
            _buildErrorWidget(errorMessage),
        autoInitialize: true,
      );

      _startPlaybackTimeoutTimer();
      _startBufferingTimer();

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      print("_changeStream: SUCCESS for url: $url");
    } catch (e) {
      print("Error initializing player: $e for url: $url");
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      _tryNextStream();
    }
  }

  void _startHideControlsTimer() {
    _setControlsVisibility(true);
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(widget.controlsHideDelay, () {
      _hideControls(animate: true);
    });
  }

  void _setControlsVisibility(bool visible) {
    if (mounted) {
      setState(() {
        _isControlsVisible = visible;
        if (visible) {
          _animationController.reverse();
        } else {
          _animationController.forward();
        }
      });
    }
  }

  void _hideControls({bool animate = true}) {
    _setControlsVisibility(false);
  }

  void _onTap() {
    if (_isControlsVisible) {
      _hideControls();
    } else {
      _startHideControlsTimer();
    }
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return "00:00";
    String twoDigits(int n) => n.toString().padLeft(2, '0');

    if (duration.inHours > 0) {
      String twoDigitHours = twoDigits(duration.inHours);
      String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
      String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
      return "$twoDigitHours:$twoDigitMinutes:$twoDigitSeconds";
    } else {
      String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
      String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
      return "$twoDigitMinutes:$twoDigitSeconds";
    }
  }

  Widget _buildStreamSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(25),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: widget.streamLinks.asMap().entries.map<Widget>((entry) {
            final index = entry.key;
            final link = entry.value;
            final streamName = link['name'] ?? 'Stream ${index + 1}';
            final streamUrl = link['url'];
            final isActive = index == _selectedQualityIndex;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: InkWell(
                onTap: () {
                  if (streamUrl != null && streamUrl.isNotEmpty) {
                    _changeStream(streamUrl, index);
                  }
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  decoration: BoxDecoration(
                    color: isActive
                        ? widget.progressBarColor
                        : Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: isActive
                        ? Border.all(color: Colors.white, width: 2)
                        : null,
                  ),
                  child: Text(
                    streamName,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white70,
                      fontWeight:
                          isActive ? FontWeight.bold : FontWeight.normal,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildErrorWidget(String message) {
    return Center(
      child: SizedBox(
        width: 300,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.white70,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _initializePlayer(_currentUrl!),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white70,
                foregroundColor: Colors.black,
              ),
              child: const Text("Retry"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAspectRatioButton() {
    return InkWell(
      onTap: () {
        if (!mounted) return;

        final wasPlaying = _videoPlayerController?.value.isPlaying ?? false;

        setState(() {
          // Cycle through the available VideoSize options, updated order.
          switch (_currentVideoSize) {
            case VideoSize.fullScreen:
              _currentVideoSize = VideoSize.ratio16_9;
              break;
            case VideoSize.ratio16_9:
              _currentVideoSize = VideoSize.ratio4_3;
              break;
            case VideoSize.ratio4_3:
              _currentVideoSize = VideoSize.ratio1_1;
              break;
            case VideoSize.ratio1_1:
              _currentVideoSize = VideoSize.fullScreen;
              break;
          }
        });

        _rebuildChewieController(wasPlaying); // Rebuild with new aspect ratio
      },
      child: Container(
        padding: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.4),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/maximize.png', // Ensure this asset exists
              width: 24,
              height: 24,
              color: Colors.white,
            ),
            const SizedBox(width: 4),
            Text(
              _getSizeName(_currentVideoSize), // Display size name
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  void _rebuildChewieController(bool wasPlaying) {
    if (!mounted) return;

    _chewieController?.dispose();
    _chewieController = ChewieController(
      videoPlayerController: _videoPlayerController!,
      autoPlay: wasPlaying,
      looping: false,
      aspectRatio: _getAspectRatioForSize(_currentVideoSize),
      showControls: false,
      showOptions: false,
      errorBuilder: (context, errorMessage) => _buildErrorWidget(errorMessage),
      autoInitialize: true,
    );

    _startHideControlsTimer();
  }

  double? _getAspectRatioForSize(VideoSize size) {
    switch (size) {
      case VideoSize.fullScreen:
        final size = MediaQuery.of(context).size;
        return size.width / size.height;
      case VideoSize.ratio16_9:
        return 16 / 9;
      case VideoSize.ratio4_3:
        return 4 / 3;
      case VideoSize.ratio1_1:
        return 1;
      default:
        return 16 / 9; // Default to 16:9
    }
  }

  String _getSizeName(VideoSize size) {
    switch (size) {
      case VideoSize.fullScreen:
        return "Full";
      case VideoSize.ratio16_9:
        return "16:9";
      case VideoSize.ratio4_3:
        return "4:3";
      case VideoSize.ratio1_1:
        return "1:1";
      default:
        return "16:9"; // Default
    }
  }

  Widget _buildControls(BuildContext context) {
    return Stack(
      children: [
        FadeTransition(
          opacity: _opacityAnimation,
          child: IgnorePointer(
            ignoring: !_isControlsVisible,
            child: Stack(
              children: [
                Positioned(
                  top: MediaQuery.of(context).padding.top + 10,
                  left: 0,
                  right: 0,
                  child: Center(child: _buildStreamSelector()),
                ),
                Center(
                  child: _isLoading && !_hasError
                      ? CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                              widget.progressBarColor),
                        )
                      : IconButton(
                          icon: Icon(
                            _videoPlayerController?.value.isPlaying ?? false
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                            color: Colors.white,
                            size: 64,
                          ),
                          onPressed: () {
                            if (!mounted) return;
                            if (_videoPlayerController?.value.isPlaying ??
                                false) {
                              _videoPlayerController?.pause();
                            } else {
                              _videoPlayerController?.play();
                            }
                            _startHideControlsTimer();
                          },
                        ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _buildBottomControls(context),
                ),
              ],
            ),
          ),
        ),
        if (_hasError)
          Positioned.fill(
            child: _buildErrorWidget("Error loading video"),
          ),
      ],
    );
  }

  Widget _buildBottomControls(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.7), Colors.transparent],
          stops: const [0.0, 1.0],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.replay_10, color: Colors.white),
                onPressed: () {
                  if (!mounted) return;
                  if (_videoPlayerController != null && !_isLive) {
                    final currentPosition =
                        _videoPlayerController!.value.position;
                    _videoPlayerController!
                        .seekTo(currentPosition - const Duration(seconds: 10));
                  }
                  _startHideControlsTimer();
                },
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (!mounted) return;
                    if (_videoPlayerController != null) {
                      if (_videoPlayerController!.value.isPlaying) {
                        _videoPlayerController!.pause();
                      } else {
                        _videoPlayerController!.play();
                      }
                    }
                    _startHideControlsTimer();
                  },
                  onHorizontalDragUpdate: !_isLive &&
                          _videoPlayerController != null
                      ? (details) {
                          if (!mounted) return;
                          final duration =
                              _videoPlayerController!.value.duration;
                          final position =
                              _videoPlayerController!.value.position;

                          final dragDistance = details.primaryDelta ?? 0;
                          final dragPercentage =
                              dragDistance / context.size!.width;
                          final durationOffset =
                              duration.inMilliseconds * dragPercentage;

                          final newPosition = position +
                              Duration(milliseconds: durationOffset.toInt());
                          if (newPosition <= duration &&
                              newPosition >= Duration.zero) {
                            _videoPlayerController!.seekTo(newPosition);
                          }

                          _startHideControlsTimer();
                        }
                      : null,
                  child: _isLive
                      ? Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              "LIVE",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        )
                      : _videoPlayerController != null
                          ? VideoProgressIndicator(
                              _videoPlayerController!,
                              allowScrubbing: true,
                              colors: VideoProgressColors(
                                playedColor: widget.progressBarColor,
                                bufferedColor: widget.progressBarBufferedColor,
                                backgroundColor: Colors.white30,
                              ),
                            )
                          : const SizedBox.shrink(),
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.forward_10, color: Colors.white),
                onPressed: () {
                  if (!mounted) return;
                  if (_videoPlayerController != null && !_isLive) {
                    final currentPosition =
                        _videoPlayerController!.value.position;
                    _videoPlayerController!
                        .seekTo(currentPosition + const Duration(seconds: 10));
                  }
                  _startHideControlsTimer();
                },
              ),
              _buildAspectRatioButton(),
            ],
          ),
          if (!_isLive && _videoPlayerController != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 46),
                  child: Text(
                    _formatDuration(_videoPlayerController!.value.position),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 46),
                  child: Text(
                    _formatDuration(_videoPlayerController!.value.duration),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildVideoPlayer() {
    if (_isLoading && !_hasError) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
        ),
      );
    }

    if (_hasError || _chewieController == null) {
      return const SizedBox.shrink();
    }

    return Chewie(
      key: ValueKey("$_currentUrl$_currentVideoSize"),
      controller: _chewieController!,
    );
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _showNetworkError() {
    _showError("No internet connection. Please check your network settings.");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            _buildVideoPlayer(),
            _buildControls(context),
          ],
        ),
      ),
    );
  }
}
