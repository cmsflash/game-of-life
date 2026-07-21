import 'package:flutter/material.dart';

class AsyncMessage extends StatelessWidget {
  const AsyncMessage({super.key, this.error, this.notice});

  final String? error;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final text = error ?? notice;
    if (text == null) return const SizedBox.shrink();
    final isError = error != null;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 20,
            color: isError
                ? scheme.onErrorContainer
                : scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
