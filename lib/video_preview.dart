import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPreview extends StatelessWidget {
  final VideoPlayerController playerController;
  const VideoPreview({super.key, required this.playerController});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: playerController.value.aspectRatio,
      child: VideoPlayer(playerController),
    );
  }
}
