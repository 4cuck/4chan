import 'package:chan/models/thread.dart';

/// Generates KurobaEx-compatible HTML for a [Thread] so exported ZIPs are self-contained.
///
/// The output can be parsed back by [parseKurobaThreadHtml] in kuroba_import.dart.
String generateThreadHtml(Thread thread) {
  final buf = StringBuffer();
  buf.writeln('<!DOCTYPE html>');
  buf.writeln('<head>');
  buf.writeln('  <link rel="stylesheet" title="switch" href="tomorrow.css">');
  buf.writeln('  <meta charset="utf-8">');
  buf.writeln('<body class="is_thread">');
  buf.writeln('  <form name="delform" id="delform">');
  buf.writeln('    <div class="board">');
  buf.writeln('      <div class="thread">');

  for (final post in thread.posts_) {
    final isOp = post.id == thread.id;
    final containerClass =
        isOp ? 'postContainer opContainer' : 'postContainer replyContainer';
    buf.writeln('        <div class="$containerClass" id="pc${post.id}">');
    buf.writeln(
        '          <div id="p${post.id}" class="post ${isOp ? 'op' : 'reply'}">');

    // Attachments
    if (post.attachments_.isNotEmpty) {
      buf.writeln('            <div class="files_container">');
      for (final att in post.attachments_) {
        final cdnFilename = '${att.id}${att.ext}';
        final thumbFilename = '${att.id}s.jpg';
        final size = _formatSize(att.sizeInBytes);
        final dims = (att.width != null && att.height != null)
            ? '${att.width}x${att.height}'
            : '';
        final parts = [
          att.filename,
          if (size != null) size,
          if (dims.isNotEmpty) dims
        ];
        final linkText = parts.join(', ');
        buf.writeln('              <div class="file" id="f${post.id}">');
        buf.writeln(
            '                <div class="fileText" id="fT${post.id}">File:');
        buf.writeln(
            '                  <a href="$cdnFilename" target="_blank">$linkText</a>');
        buf.writeln('                </div>');
        buf.writeln(
            '                <a class="fileThumb" href="$cdnFilename" target="_blank">');
        buf.writeln(
            '                  <img src="$thumbFilename" alt="${size ?? ''}" loading="lazy">');
        buf.writeln('                </a>');
        buf.writeln('              </div>');
      }
      buf.writeln('            </div>');
    }

    // Post info
    buf.writeln('            <div class="postInfo desktop" id="pi${post.id}">');
    if (isOp && (thread.title?.isNotEmpty ?? false)) {
      buf.writeln(
          '              <span class="subject">${_escapeHtml(thread.title!)}</span>');
    } else {
      buf.writeln('              <span class="subject"></span>');
    }
    buf.writeln('              <span class="nameBlock">');
    buf.writeln(
        '                <span class="name">${_escapeHtml(post.name ?? '')}</span>');
    buf.writeln('              </span>');
    buf.writeln(
        '              <span class="dateTime">${_formatDateTime(post.time)} No. ${post.id}</span>');
    buf.writeln('            </div>');

    // Post message
    buf.writeln(
        '            <blockquote class="postMessage" id="m${post.id}">${post.text}</blockquote>');

    buf.writeln('          </div>');
    buf.writeln('        </div>');
  }

  buf.writeln('      </div>');
  buf.writeln('    </div>');
  buf.writeln('  </form>');
  buf.writeln('</body>');
  return buf.toString();
}

String _formatDateTime(DateTime? dt) {
  if (dt == null) return '';
  final y = dt.year.toString().padLeft(4, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final mi = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi:$s';
}

String _escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String? _formatSize(int? bytes) {
  if (bytes == null) return null;
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024)
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
