import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel signalSocket(Uri uri, String token) =>
    IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
