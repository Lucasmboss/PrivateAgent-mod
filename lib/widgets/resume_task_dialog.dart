import 'package:flutter/material.dart';

import '../models/task_record.dart';
import '../services/task_progress_summary.dart';

class ResumeTaskDialog extends StatefulWidget {
  const ResumeTaskDialog({super.key, required this.record});

  final TaskRecord record;

  static Future<String?> show(BuildContext context, TaskRecord record) =>
      showDialog<String>(
        context: context,
        builder: (_) => ResumeTaskDialog(record: record),
      );

  @override
  State<ResumeTaskDialog> createState() => _ResumeTaskDialogState();
}

class _ResumeTaskDialogState extends State<ResumeTaskDialog> {
  final TextEditingController _contextController = TextEditingController();

  @override
  void dispose() {
    _contextController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Continue saved task?'),
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(TaskProgressSummary.describe(widget.record)),
          const SizedBox(height: 16),
          TextField(
            controller: _contextController,
            maxLength: 600,
            maxLines: 3,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What context or approach should change?',
              hintText: 'Optional',
              border: OutlineInputBorder(),
            ),
          ),
          const Text(
            'This context is used for this resume only. It does not replace '
            'the original goal or change the task’s safety rules.',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _contextController.text.trim(),
        ),
        child: const Text('Continue'),
      ),
    ],
  );
}