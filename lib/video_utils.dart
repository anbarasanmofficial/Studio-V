import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:path_provider/path_provider.dart';

class VideoUtils {
  static Future<void> mergeVideos(List<File> videos, String outputPath) async {
    if (videos.isEmpty) {
      throw Exception('No videos provided for merging');
    }
    
    // Validate all input files exist
    for (final video in videos) {
      if (!video.existsSync()) {
        throw Exception('Video file not found: ${video.path}');
      }
    }
    
    final tmpDir = await getTemporaryDirectory();
    final listFile = File('${tmpDir.path}/ffmpeg_concat_${DateTime.now().millisecondsSinceEpoch}.txt');
    
    try {
      final buffer = StringBuffer();
      for (final f in videos) {
        final normalized = f.path.replaceAll('\\', '/');
        buffer.writeln("file '$normalized'");
      }
      await listFile.writeAsString(buffer.toString(), flush: true);

      final command = "-f concat -safe 0 -i \"${listFile.path}\" -c copy \"$outputPath\"";
      final result = await FFmpegKit.execute(command);
      final returnCode = await result.getReturnCode();
      
      if (returnCode?.isValueSuccess() != true) {
        final logs = await result.getLogsAsString();
        throw Exception('FFmpeg merge failed: $logs');
      }
    } finally {
      if (await listFile.exists()) {
        try { 
          await listFile.delete(); 
        } catch (_) {}
      }
    }
  }

  static Future<void> trimVideo(
      File file, String outputPath, int start, int duration) async {
    if (!file.existsSync()) {
      throw Exception('Input video file not found: ${file.path}');
    }
    
    if (start < 0 || duration <= 0) {
      throw Exception('Invalid trim parameters: start=$start, duration=$duration');
    }
    
    final command = "-ss $start -i \"${file.path}\" -t $duration -c copy \"$outputPath\"";
    final result = await FFmpegKit.execute(command);
    final returnCode = await result.getReturnCode();
    
    if (returnCode?.isValueSuccess() != true) {
      final logs = await result.getLogsAsString();
      throw Exception('FFmpeg trim failed: $logs');
    }
  }

  // More robust trim that re-encodes to avoid keyframe boundary issues
  static Future<void> reencodeTrim(
      File file, String outputPath, int start, int duration) async {
    if (!file.existsSync()) {
      throw Exception('Input video file not found: ${file.path}');
    }
    
    if (start < 0 || duration <= 0) {
      throw Exception('Invalid trim parameters: start=$start, duration=$duration');
    }
    
    final command = "-ss $start -i \"${file.path}\" -t $duration -c:v libx264 -preset veryfast -crf 23 -c:a aac -b:a 192k \"$outputPath\"";
    final result = await FFmpegKit.execute(command);
    final returnCode = await result.getReturnCode();
    
    if (returnCode?.isValueSuccess() != true) {
      final logs = await result.getLogsAsString();
      throw Exception('FFmpeg re-encode trim failed: $logs');
    }
  }

  // Split a file at 'atSeconds' into two outputs
  static Future<List<File>> splitAt(File file, int atSeconds) async {
    if (!file.existsSync()) {
      throw Exception('Input video file not found: ${file.path}');
    }
    
    if (atSeconds <= 0) {
      throw Exception('Invalid split position: $atSeconds');
    }
    
    final tmp = await getTemporaryDirectory();
    final left = File('${tmp.path}/split_left_${DateTime.now().millisecondsSinceEpoch}.mp4');
    final right = File('${tmp.path}/split_right_${DateTime.now().millisecondsSinceEpoch}.mp4');

    try {
      // Left: from 0 to atSeconds
      await trimVideo(file, left.path, 0, atSeconds);
      // Right: from atSeconds to end; use re-encode for safety
      await reencodeTrim(file, right.path, atSeconds, 999999);

      return [left, right];
    } catch (e) {
      // Clean up partial files on error
      try {
        if (await left.exists()) await left.delete();
        if (await right.exists()) await right.delete();
      } catch (_) {}
      rethrow;
    }
  }

  // Extract a specific range from a file
  static Future<File> extractRange(File file, int start, int duration) async {
    if (!file.existsSync()) {
      throw Exception('Input video file not found: ${file.path}');
    }
    
    if (start < 0 || duration <= 0) {
      throw Exception('Invalid range parameters: start=$start, duration=$duration');
    }
    
    final tmp = await getTemporaryDirectory();
    final out = File('${tmp.path}/range_${DateTime.now().millisecondsSinceEpoch}.mp4');
    
    try {
      await reencodeTrim(file, out.path, start, duration);
      return out;
    } catch (e) {
      // Clean up partial file on error
      try {
        if (await out.exists()) await out.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
