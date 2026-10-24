import 'package:flutter/material.dart';

import '../../../domain/services/security.dart';

/// "PIN" or "password"; both when the keystore could not say which.
String secretName(SecretKind? kind) => switch (kind) {
  SecretKind.pin => 'PIN',
  SecretKind.password => 'password',
  null => 'PIN or password',
};

/// What to tell the user after a try that did not open the lock.
String? wrongSecretMessage(UnlockResult result, SecretKind? kind, DateTime now) {
  if (result.ok) return null;
  if (result.unreadable) return "Couldn't check your ${secretName(kind)} just now. Try again.";
  if (result.waitUntil case final until?) {
    return 'Too many wrong tries. Try again in ${_waitText(until.difference(now))}.';
  }
  final wrong = 'Wrong ${secretName(kind)}';
  final left = result.triesLeft;
  return left > 0 && left <= 3 ? '$wrong. $left ${left == 1 ? 'try' : 'tries'} left before a wait.' : wrong;
}

String _waitText(Duration wait) {
  final minutes = (wait.inSeconds / 60).ceil().clamp(1, 1 << 30);
  String unit(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
  if (minutes < 60) return unit(minutes, 'minute');
  final hours = unit(minutes ~/ 60, 'hour');
  return minutes % 60 == 0 ? hours : '$hours ${unit(minutes % 60, 'minute')}';
}

/// A PIN pad or a password field, whichever the lock uses. A password field
/// when [kind] is unknown, as it takes a PIN too. [onSubmit] returns whether
/// the secret was accepted; the entry is cleared either way.
class SecretInput extends StatefulWidget {
  const SecretInput({
    super.key,
    required this.kind,
    required this.title,
    required this.onSubmit,
    this.submitLabel = 'OK',
    this.hint,
    this.error,
    this.extraKey,
  });

  final SecretKind? kind;
  final String title;

  /// A short line under the title, such as how long the PIN may be.
  final String? hint;
  final String submitLabel;
  final String? error;
  final Widget? extraKey;
  final Future<bool> Function(String secret) onSubmit;

  @override
  State<SecretInput> createState() => _SecretInputState();
}

class _SecretInputState extends State<SecretInput> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  bool _shown = false;
  String _pin = '';

  bool get _isPin => widget.kind == SecretKind.pin;
  bool get _valid => _isPin ? isValidPin(_pin) : isValidPassword(_password.text);

  // Not autofocus: that does nothing while another field holds the focus,
  // as one behind the lock screen can.
  void _focusPassword() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !_isPin) _focus.requestFocus();
  });

  @override
  void initState() {
    super.initState();
    _focusPassword();
  }

  @override
  void didUpdateWidget(SecretInput old) {
    super.didUpdateWidget(old);
    if (old.kind == widget.kind) return;
    _pin = '';
    _password.clear();
    _focusPassword();
  }

  @override
  void dispose() {
    _password.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_valid) return;
    final secret = _isPin ? _pin : _password.text;
    setState(() {
      _pin = '';
      _password.clear();
    });
    if (!await widget.onSubmit(secret) && mounted && !_isPin) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
          if (widget.hint != null) ...[const SizedBox(height: 8), Text(widget.hint!)],
          const SizedBox(height: 24),
          if (_isPin)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 12,
              children: [
                for (var i = 0; i < 8; i++)
                  if (i < _pin.length || i < 4)
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _pin.length ? scheme.primary : null,
                        border: Border.all(color: scheme.outline),
                      ),
                    ),
              ],
            )
          else
            TextField(
              controller: _password,
              focusNode: _focus,
              obscureText: !_shown,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  tooltip: _shown ? 'Hide password' : 'Show password',
                  icon: Icon(_shown ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _shown = !_shown),
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          const SizedBox(height: 16),
          SizedBox(
            height: 24,
            child: widget.error == null ? null : Text(widget.error!, style: TextStyle(color: scheme.error)),
          ),
          if (_isPin) ...[
            const Spacer(),
            PinPad(
              extraKey: widget.extraKey,
              onDigit: (d) => setState(() => _pin = _pin.length < 8 ? '$_pin$d' : _pin),
              onBackspace: () => setState(() => _pin = _pin.isEmpty ? _pin : _pin.substring(0, _pin.length - 1)),
            ),
            const SizedBox(height: 16),
          ] else ...[
            ?widget.extraKey,
            const Spacer(),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _valid ? _submit : null, child: Text(widget.submitLabel)),
          ),
        ],
      ),
    );
  }
}

class PinPad extends StatelessWidget {
  const PinPad({super.key, required this.onDigit, required this.onBackspace, this.extraKey});

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final Widget? extraKey;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.headlineSmall;
    Widget digit(String d) => Expanded(
      child: TextButton(
        onPressed: () => onDigit(d),
        child: Text(d, style: style),
      ),
    );
    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(children: [for (final d in row) digit(d)]),
        Row(
          children: [
            Expanded(child: extraKey ?? const SizedBox()),
            digit('0'),
            Expanded(
              child: IconButton(
                tooltip: 'Delete digit',
                icon: const Icon(Icons.backspace_outlined),
                onPressed: onBackspace,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
