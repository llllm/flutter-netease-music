import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../repository/app_dir.dart';
import '../log.dart';
import 'key_value_cache.dart';

@immutable
class CachedImage extends ImageProvider<CachedImage> implements CacheKey {
  const CachedImage(this.url, {this.scale = 1.0, this.headers});

  const CachedImage._internal(
    this.url, {
    this.scale = 1.0,
    this.headers,
  });

  final String url;

  final double scale;

  final Map<String, String>? headers;

  String get id => url.isEmpty ? '' : url.substring(url.lastIndexOf('/') + 1);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedImage &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          scale == other.scale;

  @override
  int get hashCode => Object.hash(id, scale);

  @override
  ImageStreamCompleter loadImage(CachedImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
    );
  }

  static final _dio = Dio();

  static Future<Uint8List> _loadDataFromNetwork(
    String url, {
    Map<String, String>? headers,
  }) async {
    final response = await _dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          // FIXME: 使用真实的UA
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 10; Redmi K30 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Mobile Safari/537.36',
          if (headers != null) ...headers,
        },
      ),
    );
    return Uint8List.fromList(response.data!);
  }

  Future<ui.Codec> _loadAsync(
    CachedImage key,
    ImageDecoderCallback decode,
  ) async {
    final image = await ImageFileCache.instance.get(key);
    if (image != null) {
      return decode(
        await ui.ImmutableBuffer.fromUint8List(image),
      );
    }

    logger.d('load image from network: $url $id');

    if (key.url.isEmpty) {
      throw Exception('image url is empty.');
    }

    //request network source
    final bytes = await _loadDataFromNetwork(url, headers: headers);

    //save image to cache
    await ImageFileCache.instance.update(key, bytes);

    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  Future<CachedImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CachedImage>(
      CachedImage(
        url,
        scale: scale,
        headers: headers,
      ),
    );
  }

  @override
  String toString() {
    return 'NeteaseImage{url: $url, scale: $scale}';
  }

  @override
  String getKey() {
    return id;
  }
}

class ImageFileCache implements Cache<Uint8List?> {
  ImageFileCache._internal()
      : provider = FileCacheProvider(
          p.join(cacheDir.path, 'image'),
          maxSize: 600 * 1024 * 1024 /* 600 Mb*/,
        );

  static final ImageFileCache instance = ImageFileCache._internal();

  final FileCacheProvider provider;

  @override
  Future<Uint8List?> get(CacheKey key) async {
    final file = provider.getFile(key);
    if (await file.exists()) {
      provider.touchFile(file);
      return Uint8List.fromList(await file.readAsBytes());
    }
    return null;
  }

  @override
  Future<bool> update(CacheKey key, Uint8List? t) async {
    var file = provider.getFile(key);
    if (await file.exists()) {
      await file.delete();
    }
    file = await file.create(recursive: true);
    await file.writeAsBytes(t!);
    try {
      return await file.exists();
    } finally {
      provider.checkSize();
    }
  }
}

class IsolateImageCacheLoader {
  IsolateImageCacheLoader(this.sendPort, this.imageUrl);

  final SendPort sendPort;
  final String imageUrl;
}

const _kImageCacheLoaderPortName = 'image_cache_loader_send_port';

final _receiverPort = ReceivePort('image_cache_provider');

void registerImageCacheProvider() {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return;
  }
  _receiverPort.listen((message) async {
    if (message is IsolateImageCacheLoader) {
      logger.d(
          'IsolateImageCacheLoader: ${message.imageUrl} ${Isolate.current.debugName}');
      final image = ResizeImage(
        CachedImage(message.imageUrl),
        width: 200,
        height: 200,
      );
      final stream = image.resolve(
        ImageConfiguration(
          devicePixelRatio:
              PlatformDispatcher.instance.views.first.devicePixelRatio,
          locale: PlatformDispatcher.instance.locale,
          platform: defaultTargetPlatform,
        ),
      );
      final completer = Completer<Uint8List?>();
      ImageStreamListener? listener;
      listener = ImageStreamListener(
        (ImageInfo? image, bool sync) {
          if (!completer.isCompleted) {
            completer.complete(
              image?.image
                  .toByteData(format: ImageByteFormat.png)
                  .then((value) => value?.buffer.asUint8List()),
            );
          }
          // Give callers until at least the end of the frame to subscribe to the
          // image stream.
          // See ImageCache._liveImages
          SchedulerBinding.instance.addPostFrameCallback((Duration timeStamp) {
            stream.removeListener(listener!);
          });
        },
        onError: (Object exception, StackTrace? stackTrace) {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
          stream.removeListener(listener!);
          logger.e('failed to load image: $exception $stackTrace');
        },
      );
      stream.addListener(listener);
      message.sendPort.send(await completer.future);
    }
  });
  ui.IsolateNameServer.removePortNameMapping(_kImageCacheLoaderPortName);
  ui.IsolateNameServer.registerPortWithName(
    _receiverPort.sendPort,
    _kImageCacheLoaderPortName,
  );
}

Future<Uint8List?> loadImageFromOtherIsolate(String? imageUrl) async {
  if (imageUrl == null || imageUrl.isEmpty) {
    return null;
  }
  final imageCachePort = ui.IsolateNameServer.lookupPortByName(
    _kImageCacheLoaderPortName,
  );
  if (imageCachePort == null) {
    logger.e(
        'can not get imageCachePort in isolate: ${Isolate.current.debugName}');
    return null;
  }
  final receivePort = ReceivePort();
  imageCachePort.send(IsolateImageCacheLoader(receivePort.sendPort, imageUrl));
  final bytes = await receivePort.first;
  receivePort.close();
  return bytes;
}
