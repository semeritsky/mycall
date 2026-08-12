import 'package:flutter/material.dart';

import 'family.dart';
import 'signaling.dart';
import 'theme.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.link, required this.peer});
  final Signaling link;
  final String peer;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.link.markRead(widget.peer);
    widget.link.addListener(_onUpdate);
  }

  void _onUpdate() {
    widget.link.markRead(widget.peer);
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    widget.link.sendText(widget.peer, text);
    _input.clear();
  }

  @override
  void dispose() {
    widget.link.removeListener(_onUpdate);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.link.messagesWith(widget.peer);
    final isOnline = widget.link.online.contains(widget.peer);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: ink,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(displayName(widget.peer),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(
              isOnline ? 'в сети' : 'не в сети',
              style: TextStyle(fontSize: 12, color: isOnline ? live : muted),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text('Сообщений пока нет',
                        style: TextStyle(color: muted)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    itemCount: messages.length,
                    itemBuilder: (context, i) => _Bubble(message: messages[i]),
                  ),
          ),
          Container(
            color: surface,
            padding: EdgeInsets.only(
              left: 12,
              right: 8,
              top: 8,
              bottom: 8 + MediaQuery.of(context).viewPadding.bottom,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(color: textColor),
                    decoration: const InputDecoration(
                      hintText: 'Сообщение',
                      fillColor: surfaceHigh,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(
                  onPressed: _send,
                  icon: const Icon(Icons.arrow_upward_rounded, color: amber),
                  tooltip: 'Отправить',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final mine = message.outgoing;
    final time =
        '${message.ts.hour.toString().padLeft(2, '0')}:${message.ts.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.76),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF2A2F3A) : surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(message.text, style: const TextStyle(color: textColor, height: 1.35)),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(time, style: const TextStyle(color: muted, fontSize: 11)),
                if (mine) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.delivered ? Icons.done_all : Icons.schedule,
                    size: 12,
                    color: message.delivered ? live : muted,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
