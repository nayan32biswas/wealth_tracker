import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';

/// How long typing must pause before notes are looked up.
const noteLookupDelay = Duration(milliseconds: 150);

/// Notes used before, shown as a row of chips under a text field while it
/// has focus. Looked up once per pause in typing, never watched, so a closed
/// or idle field costs nothing.
class NoteSuggestions extends ConsumerStatefulWidget {
  const NoteSuggestions({
    super.key,
    required this.controller,
    required this.focusNode,
    this.categoryId,
    this.whenEmpty = true,
    this.onPicked,
    this.padding = EdgeInsets.zero,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Notes used with this category come first.
  final int? categoryId;

  /// Whether an empty field offers the most used notes.
  final bool whenEmpty;
  final ValueChanged<String>? onPicked;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<NoteSuggestions> createState() => _NoteSuggestionsState();
}

class _NoteSuggestionsState extends ConsumerState<NoteSuggestions> with WidgetsBindingObserver {
  List<String> _notes = const [];
  String? _lookedUp;
  Timer? _wait;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    widget.focusNode.addListener(_changed);
  }

  @override
  void didUpdateWidget(NoteSuggestions old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
    if (old.categoryId != widget.categoryId) {
      _lookedUp = null;
      _changed();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  // The controller also fires when only the cursor moves; that needs no new
  // lookup.
  void _changed() {
    final text = widget.controller.text.trim();
    if (!widget.focusNode.hasFocus || (text.isEmpty && !widget.whenEmpty)) {
      _wait?.cancel();
      _request++;
      _lookedUp = null;
      if (_notes.isNotEmpty) setState(() => _notes = const []);
      return;
    }
    if (text == _lookedUp) return;
    _lookedUp = text;
    _wait?.cancel();
    _wait = Timer(noteLookupDelay, () => _lookUp(text));
  }

  Future<void> _lookUp(String text) async {
    final request = ++_request;
    final today = ref.read(clockProvider)();
    final notes = await ref
        .read(repositoriesProvider)
        .transactions
        .noteSuggestions(
          text: text,
          categoryId: widget.categoryId,
          since: DateTime(today.year - 1, today.month, today.day),
        );
    if (!mounted || request != _request) return;
    setState(() => _notes = notes);
    _reveal();
  }

  // The keyboard covers the lower half of the screen and often finishes
  // opening after the notes arrive, so lift the row into view again each
  // time the screen size changes.
  @override
  void didChangeMetrics() => _reveal();

  void _reveal() {
    if (_notes.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _notes.isNotEmpty) {
        Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      }
    });
  }

  void _pick(String note) {
    widget.controller.value = TextEditingValue(
      text: note,
      selection: TextSelection.collapsed(offset: note.length),
    );
    widget.focusNode.unfocus();
    widget.onPicked?.call(note);
  }

  @override
  Widget build(BuildContext context) {
    if (_notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: widget.padding,
      // One row that scrolls sideways keeps every suggestion above the keyboard.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: 8,
          children: [for (final n in _notes) ActionChip(label: Text(n), onPressed: () => _pick(n))],
        ),
      ),
    );
  }
}
