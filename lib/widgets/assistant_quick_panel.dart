import 'package:flutter/material.dart';

class AssistantQuickPanel extends StatelessWidget {
  final bool isDark;
  final bool isListening;
  final bool isPressed;
  final bool isLoading;
  final String transcript;
  final String response;
  final String? error;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  final VoidCallback onExpand;
  final VoidCallback onDismiss;

  const AssistantQuickPanel({
    super.key,
    required this.isDark,
    required this.isListening,
    required this.isPressed,
    required this.isLoading,
    required this.transcript,
    required this.response,
    required this.error,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onExpand,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final surface = isDark ? const Color(0xFF171827) : Colors.white;
    final textColor = isDark
        ? const Color(0xFFF8FAFC)
        : const Color(0xFF172033);
    final mutedColor = isDark
        ? const Color(0xFFA8ADC0)
        : const Color(0xFF697386);
    final accent = Theme.of(context).colorScheme.primary;
    final voiceActive = isListening || isPressed;
    final status = isLoading
        ? 'Trabajando…'
        : isPressed
        ? 'Escuchando · suelta para enviar'
        : isListening
        ? 'Preparando la solicitud…'
        : 'Mantén pulsado para hablar';
    final showTranscript =
        (isPressed || isListening || isLoading) && transcript.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Material(
        color: surface,
        elevation: 22,
        shadowColor: Colors.black.withOpacity(0.28),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(
            color: isDark
                ? Colors.white.withOpacity(0.09)
                : const Color(0xFFE7EAF2),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: accent.withOpacity(isDark ? 0.24 : 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.auto_awesome_rounded, color: accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'PrivateAgent',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onExpand,
                    tooltip: 'Abrir chat completo',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.open_in_full_rounded,
                      color: mutedColor,
                      size: 20,
                    ),
                  ),
                  IconButton(
                    onPressed: onDismiss,
                    tooltip: 'Cerrar asistente',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded, color: mutedColor),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: 62, maxHeight: 92),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF202235)
                      : const Color(0xFFF5F6FA),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    showTranscript
                        ? transcript
                        : response.isNotEmpty
                        ? response
                        : '¿Qué necesitas?',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: showTranscript || response.isNotEmpty
                          ? textColor
                          : mutedColor,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (error != null && error!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              Text(
                status,
                style: TextStyle(
                  color: voiceActive ? accent : mutedColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                button: true,
                label: 'Mantener pulsado para hablar',
                hint: 'Suelta el botón cuando termines de hablar.',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: isLoading ? null : (_) => onHoldStart(),
                  onTapUp: isLoading ? null : (_) => onHoldEnd(),
                  onTapCancel: isLoading ? null : onHoldEnd,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 66,
                    height: 66,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: voiceActive
                          ? accent
                          : (isDark
                                ? const Color(0xFF252B42)
                                : const Color(0xFFEEF0FF)),
                      boxShadow: voiceActive
                          ? [
                              BoxShadow(
                                color: accent.withOpacity(0.36),
                                blurRadius: 22,
                                spreadRadius: 3,
                              ),
                            ]
                          : null,
                      border: Border.all(
                        color: accent.withOpacity(voiceActive ? 0.9 : 0.18),
                        width: 1.5,
                      ),
                    ),
                    child: Icon(
                      voiceActive
                          ? Icons.graphic_eq_rounded
                          : Icons.mic_rounded,
                      color: voiceActive
                          ? Colors.white
                          : Theme.of(context).colorScheme.primary,
                      size: 27,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
