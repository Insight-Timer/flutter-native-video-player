class NativeVideoPlayerMediaInfo {
  const NativeVideoPlayerMediaInfo({
    this.title,
    this.subtitle,
    this.album,
    this.artworkUrl,
    this.showSkipControls,
  });

  final String? title;
  final String? subtitle;
  final String? album;
  final String? artworkUrl;
  final bool? showSkipControls;

  Map<String, dynamic> toMap() => <String, dynamic>{
    if (title != null) 'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (album != null) 'album': album,
    if (artworkUrl != null) 'artworkUrl': artworkUrl,
    if (showSkipControls != null) 'showSkipControls': showSkipControls,
  };
}
