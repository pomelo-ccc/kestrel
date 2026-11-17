import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:bao_markdown/bao_markdown.dart';

import '../../kernel/agent_kernel.dart';
import '../../kernel/kernel_types.dart';
import '../../kernel/prompt_suggestions.dart';
import '../../keybindings/chat_keybindings.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show WorkbenchColors, themeColors;
import '../chat_keys.dart';
import '../chat_models.dart';
import '../chat_session.dart';
import '../open_editor.dart';
import '../stop_confirmation.dart';
import '../floating/floating_layer.dart';
import '../floating/floating_placement.dart';
import '../floating/floating_registry.dart';
import '../../diagnostics/input_lag.dart';
import '../../workspace/window_controls.dart';
import '../widgets/context_meter.dart';
import '../widgets/hover_builder.dart';
import 'composer_caret.dart';
import 'composer_controller.dart';
import 'composer_draft.dart';
import 'composer_embeds.dart';
import 'composer_files.dart';
import 'composer_images.dart';
import 'composer_mock_data.dart';
import 'composer_picker.dart';
import 'composer_polish.dart';
import 'pickers_row.dart';
import 'session_model_picker.dart';
import 'kernel_option_text.dart';
import 'file_drop.dart';
import 'suggestion_menu.dart';
import '../../ide/ide_hover.dart';
import '../../ide/ide_spinning.dart';
import '../../theme/codicons.dart';
import '../../ide/file_service.dart'
    show IdeFileService, TransferCancelledException;
import '../../ide/ide_notifications.dart';
import '../../ide/transfer_progress.dart';
import 'remote_drops.dart';

/// An open query: a /command's (a slash starting a word), or a mention's
/// (an @ starting a word: a file, a folder or a conversation);
/// [query] is the text between it and the caret.
class _Trigger {
  const _Trigger(this.kind, this.start, this.query);

  /// [SuggestionKind.command], or [SuggestionKind.file] for a mention.
  final SuggestionKind kind;

  /// Where the slash or the @ is.
  final int start;
  final String query;

  bool sameAnchor(_Trigger? other) =>
      other != null && other.kind == kind && other.start == start;
}

/// The chat input: an editor of plain text (bao_markdown's, see
/// [ComposerController]) with tags in it.
///
/// The dock's composer sends to [session]. With [onSubmit] it edits instead
/// (e.g. a sent message reopened in the history): it starts from
/// [initialText], shows no stop button or context ring, and Esc calls
/// [onCancel].
///
/// Its keys are keybindings (see [ChatCommandIds]): Enter sends, ↑ at its
/// start shows the messages sent before, the / menu's keys…
///
/// Files come in as tags of their paths (images as images, where the
/// conversation takes them): dragged onto it from other apps or from the
/// IDE, pasted after a copy, or picked (Add Context…). Code copied from the
/// IDE's editor pastes as a tag of its lines (see [CopiedCode]), and text
/// too long to lay out as a tag of it (see [PastedText]).
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.session,
    this.contextPanelOpen = false,
    this.onToggleContextPanel,
    this.initialText,
    this.initialImages = const [],
    this.onSubmit,
    this.onIntercept,
    this.onCancel,
    this.tapRegionGroupId,
    this.draft,
    this.openEditor,
    this.hostFiles,
  });

  final ChatSession session;
  final bool contextPanelOpen;
  final VoidCallback? onToggleContextPanel;

  /// Text to start from; `@paths`, `[path:lines]` and a leading `/command`
  /// in it become tags again.
  final String? initialText;

  /// Images to start from (the message being edited had them).
  final List<ImageAttachment> initialImages;
  final ValueChanged<ComposerMessage>? onSubmit;

  /// Takes a message the app handles itself, never the agent's (a side
  /// question, say): true when it was, and what is typed is gone.
  final bool Function(ComposerMessage message)? onIntercept;
  final VoidCallback? onCancel;

  /// Group of a [TapRegion] around this composer: its menus, which open in
  /// the overlay, count as inside it.
  final Object? tapRegionGroupId;

  /// Where what is typed is kept while the composer is gone; once saved,
  /// it starts from there rather than [initialText] and [initialImages].
  final ComposerDraft? draft;

  /// The file open in the editor beside the chat (see [ChatSession.send]).
  final OpenEditor? Function()? openEditor;

  /// A remote project's host's files, where files of this machine's put
  /// in (let go from another app, pasted, picked) are copied first, for its
  /// agent to read (see [RemoteDrops]); null for a local project.
  final IdeFileService? hostFiles;

  @override
  State<ChatComposer> createState() => ChatComposerState();
}

class ChatComposerState extends State<ChatComposer>
    with ChatKeyTarget
    implements FileDropDelegate {
  static const _fontSize = 13.5;
  static TextStyle get _textStyle => TextStyle(
    color: AppColors.textPrimary,
    fontSize: _fontSize,
    height: 1.5,
    // Center glyphs in the line box so the custom caret lines up with them.
    leadingDistribution: TextLeadingDistribution.even,
  );
  static const _lineHeight = _fontSize * 1.5;

  /// Resting height of the text area: balanced and well-proportioned above
  /// the control deck.
  static const _minEditorHeight = _lineHeight + 22;
  static const _maxEditorLines = 10;

  late final ComposerController _controller = _createController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'Composer');
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<MarkdownEditorState> _editorKey = GlobalKey();

  /// Keys and edits, timed to the frame that shows them: typing fast
  /// stuck for seconds on an Intel Mac with no frame or hang written
  /// (E0A7T8YQ).
  late final InputLag _lag = InputLag(
    'chat input',
    describe: () => [
      'text ${_controller.length} chars, '
          '${_controller.lines.lineCount} lines',
      if (_pool.isNotEmpty) '${_pool.length} images',
    ].join('; '),
  );
  final GlobalKey _boxKey = GlobalKey();
  final GlobalKey<ComposerPickerState> _modePickerKey = GlobalKey();
  final GlobalKey<ComposerPickerState> _modelPickerKey = GlobalKey();

  bool _hasContent = false;

  /// Polish asked, its answer awaited (see [_polish]).
  bool _polishing = false;

  /// Every image put in, by number, kept until sent: the text's references
  /// pick which go (see [_images]), so one taken out and brought back by
  /// undo is still there. Replaced, not changed, for the references
  /// showing them to see it.
  late Map<int, ImageAttachment> _pool = _initialPool();

  /// The images that go: those the text refers to, in its order, once
  /// each. Derived from the text alone, as it changes.
  List<ImageAttachment> _images = const [];
  _Trigger? _trigger;
  _Trigger? _dismissedTrigger;
  List<SuggestionMatch> _matches = const [];

  /// The conversations the open @ offers, as they were when it was typed.
  List<Suggestion> _sessions = const [];

  /// The stashes the open @ offers, after the files, as they were when it
  /// was typed.
  List<Suggestion> _stashes = const [];

  /// What an @ offers besides files: stashes, then conversations.
  List<SuggestionMatch> _rankOthers(String query) => [
    ...rankGroupedSuggestions(_stashes, query),
    ...rankGroupedSuggestions(_sessions, query),
  ];

  /// Whether the menu lists a mention's files and conversations or the
  /// commands: kept as it closes, for it to fade out as it was.
  SuggestionKind _menuKind = SuggestionKind.command;
  int _highlighted = 0;
  double _menuX = 0;

  Map<int, ImageAttachment> _initialPool() {
    if (widget.draft case final draft? when draft.saved) {
      return {for (final image in draft.images) ?image.number: image};
    }
    final pool = <int, ImageAttachment>{};
    var next = widget.session.lastImageNumber + 1;
    for (final image in widget.initialImages) {
      if (image.number case final number?) {
        pool[number] = image;
        next = math.max(next, number + 1);
      }
    }
    // Sent before images were numbered: numbered now.
    for (final image in widget.initialImages) {
      if (image.number != null) continue;
      pool[next] = image.withNumber(next);
      next++;
    }
    return pool;
  }

  ComposerController _createController() {
    if (widget.draft case final draft? when draft.saved) {
      final content = draft.content!;
      final end = content.length;
      return ComposerController(
        text: content,
        selection: TextSelection(
          baseOffset: draft.selection.baseOffset.clamp(0, end),
          extentOffset: draft.selection.extentOffset.clamp(0, end),
        ),
      );
    }
    var text = widget.initialText ?? '';
    final numbers = _pool.keys.toSet();
    // Every image referred to: those the text does not, at its start.
    final referred = {
      for (final match in imageReferencePattern.allMatches(text))
        int.parse(match[1]!),
    };
    final unreferred = numbers.where((n) => !referred.contains(n)).toList();
    if (unreferred.isNotEmpty) {
      text = [unreferred.map(imageReference).join(' '), text].join(' ');
    }
    if (text.isEmpty) return ComposerController();
    final content = composerContentFromText(
      text,
      ComposerVocabulary.read(context),
      images: numbers,
    );
    return ComposerController(
      text: content,
      selection: TextSelection.collapsed(offset: content.length),
    );
  }

  /// Pastes what the clipboard holds: copied files as tags of their paths
  /// (images as images), code the IDE's editor copied as a tag of its lines,
  /// a picture (a screenshot), or else its plain text, with its `@paths`
  /// (and a leading /command) as tags, as the message will show once sent:
  /// copied from the history or from elsewhere alike. (What this editor
  /// copied itself, its tags and all, the editor pastes back as it was.)
  /// Returns false for nothing to paste. With `raw` (⇧⌘V / Ctrl+Shift+V),
  /// its text goes in as it is, past the long-paste tag; files and images
  /// still come in as such.
  Future<bool> _paste({bool raw = false}) async {
    final files = await WindowControls.readPasteboardFiles();
    if (!mounted) return false;
    if (files.isNotEmpty) {
      await insertFiles(files, here: true);
      return true;
    }
    final text = await WindowControls.readPasteboardText();
    if (!mounted) return false;
    if (text != null && !raw) {
      if (CopiedCode.matching(text) case final code?) {
        _insertTags([
          ComposerCodeEmbed.of(
            code.withPath(displayPath(code.path, widget.session.root)),
          ),
        ]);
        return true;
      }
    }
    if (widget.session.acceptsImages) {
      final images = await WindowControls.readPasteboardImages();
      if (images.isNotEmpty) {
        await _addImages(images);
        return true;
      }
    }
    if (text == null || !mounted) return false;
    var plain = MdAtoms.strip(text.replaceAll('\r\n', '\n'));
    if (widget.session.acceptsImages) {
      plain = await _picturesIn(plain);
      if (!mounted) return false;
    }
    // Pasted raw, the text goes in as it is, whatever its length: no paste
    // tag (the shortcut is for exactly that), and no attachment offload,
    // which happens as the message is sent (see PasteStore.offload).
    if (!raw && PastedText.isLong(plain)) {
      _insertTags([
        ComposerPastedTextEmbed.of(
          PastedText(number: _nextPastedNumber(), text: plain),
        ),
      ]);
      return true;
    }
    final selection = _controller.selection;
    final start = selection.isValid ? selection.start : _controller.length;
    final end = selection.isValid ? selection.end : start;
    final content = raw
        ? plain
        : composerContentFromPaste(
            plain,
            ComposerVocabulary.read(context),
            atStart: start == 0,
            images: _pool.keys.toSet(),
          );
    _controller
      ..breakUndo()
      ..replace(start, end, content)
      ..breakUndo();
    return true;
  }

  /// The number for a long paste: one past the highest the text has.
  int _nextPastedNumber() {
    var highest = 0;
    for (final (:embed, start: _, end: _) in _controller.embeds) {
      if (embed.type == ComposerPastedTextEmbed.type) {
        highest = math.max(
          highest,
          ComposerPastedTextEmbed.decode(embed.data).number,
        );
      }
    }
    return highest + 1;
  }

  @override
  void initState() {
    super.initState();
    _padTrailingTokens();
    _images = _referredImages();
    _hasContent = _controller.text.trim().isNotEmpty;
    _controller.addListener(_handleEditorChanged);
    _focusNode.addListener(_handleFocusChanged);
    widget.draft?.addListener(_handleDraftChanged);
    ComposerPolishSetting.changes?.addListener(_handleSettingsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _takeDraftFiles();
      _takeDraftCode();
      _takeDraftMessage();
    });
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.draft, widget.draft)) {
      oldWidget.draft?.removeListener(_handleDraftChanged);
      widget.draft?.addListener(_handleDraftChanged);
    }
  }

  /// Settings → General's Polish button, turned on or off.
  void _handleSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.draft?.removeListener(_handleDraftChanged);
    ComposerPolishSetting.changes?.removeListener(_handleSettingsChanged);
    FloatingRegistry.closePopover(_menuOwner);
    _clickWindow?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void focus() => _focusNode.requestFocus();

  // --- Images --------------------------------------------------------------

  /// At most this many per message: the API takes 100 a request on its
  /// 200K-context models (600 on the others), each made small enough
  /// ([prepareImage]) for its limit on requests of over 20.
  static const _maxImages = 100;

  /// The numbers of the images the text refers to, in its order, with
  /// where each reference is.
  Iterable<({int number, int offset})> _references() sync* {
    for (final (:embed, :start, end: _) in _controller.embeds) {
      if (embed.type == ComposerImageEmbed.type) {
        yield (number: ComposerImageEmbed.decode(embed.data), offset: start);
      }
    }
  }

  List<ImageAttachment> _referredImages() => [
    for (final number in {for (final r in _references()) r.number})
      ?_pool[number],
  ];

  /// Puts [images] in at [at] (in place of the selection when null), each
  /// as a reference in the text, numbered on from the conversation's last.
  Future<void> _addImages(List<ImageAttachment> images, {int? at}) async {
    final added = (await _numbered(images)).nonNulls;
    if (!mounted || added.isEmpty) return;
    _insertTags([
      for (final image in added) ComposerImageEmbed.of(image.number!),
    ], at: at);
  }

  /// [images] made ready to send (see [prepareImage]), numbered on from the
  /// conversation's last and put in the pool, in their places: null for
  /// those that are no images, or past the most a message takes.
  Future<List<ImageAttachment?>> _numbered(
    List<ImageAttachment?> images,
  ) async {
    final prepared = await Future.wait([
      for (final image in images)
        image == null ? Future<ImageAttachment?>.value() : prepareImage(image),
    ]);
    if (!mounted) return [for (final _ in images) null];
    var next =
        math.max(widget.session.lastImageNumber, _pool.keys.fold(0, math.max)) +
        1;
    var room = _maxImages - _images.length;
    final numbered = [
      for (final image in prepared)
        image != null && room-- > 0 ? image.withNumber(next++) : null,
    ];
    _pool = {
      ..._pool,
      for (final image in numbered.nonNulls) image.number!: image,
    };
    return numbered;
  }

  /// Puts [files] in at [at] (in place of the selection when null), in
  /// their order: each a tag of its path, from the project's root when it
  /// is in it, or, for an image the conversation takes, the image. [here],
  /// they are this machine's: a remote project's agent is given copies on
  /// its host ([ChatComposer.hostFiles]), those that could not be copied
  /// left out.
  Future<void> insertFiles(
    List<ComposerFile> files, {
    int? at,
    bool here = false,
  }) async {
    if (files.isEmpty) return;
    var images = <ImageAttachment?>[for (final _ in files) null];
    if (widget.session.acceptsImages) {
      images = await _numbered(
        await Future.wait([
          for (final file in files)
            file.maybeImage
                ? WindowControls.readImageFile(file.path)
                : Future<ImageAttachment?>.value(),
        ]),
      );
    }
    if (!mounted) return;
    // The pictures go with the message as they are; the rest are copied.
    final List<ComposerFile?> paths = [
      for (final (index, file) in files.indexed)
        images[index] == null ? file : null,
    ];
    if (here && widget.hostFiles != null && paths.nonNulls.isNotEmpty) {
      final copies = await _copyToHost(paths.nonNulls.toList());
      if (!mounted) return;
      final copied = copies?.iterator;
      for (var i = 0; i < paths.length; i++) {
        if (paths[i] == null) continue;
        paths[i] = copied != null && copied.moveNext() ? copied.current : null;
      }
    }
    final root = widget.session.root;
    _insertTags([
      for (final (index, file) in files.indexed)
        if (images[index] case final image?)
          ComposerImageEmbed.of(image.number!)
        else if (paths[index] case final path?)
          ComposerTokenEmbed.file(
            displayPath(path.path, root),
            directory: file.directory,
          ),
    ], at: at);
  }

  /// [files], this machine's, copied onto the remote project's host, how
  /// far told in a notification once it takes a moment; null when they
  /// could not be, as a notification says.
  Future<List<ComposerFile>?> _copyToHost(List<ComposerFile> files) async {
    final notifications = IdeNotificationsScope.maybeOf(context);
    final l10n = context.l10n;
    try {
      return await withTransferProgress(
        context,
        l10n.explorerUploading,
        (transfer) => RemoteDrops.copy(
          widget.hostFiles!,
          files,
          onProgress: transfer.onProgress,
          onFile: transfer.onFile,
          cancel: transfer.cancel,
        ),
        cancellable: true,
      );
    } on TransferCancelledException {
      return null;
    } on Object catch (error) {
      notifications?.notify(
        IdeSeverity.error,
        l10n.composerCopyToHostFailed('$error'),
      );
      return null;
    }
  }

  /// [text]'s `@paths` of pictures that go in as such ([pastedAsPicture]:
  /// copied out of a stash) as the pictures: read, numbered, and referred
  /// to as `[Image #N]`, which the paste makes their tags.
  Future<String> _picturesIn(String text) async {
    final found = <(int, int, String)>[];
    for (var i = 0; i < text.length; i++) {
      if (text[i] != '@' || (i > 0 && text[i - 1].trim().isNotEmpty)) continue;
      if (parseFileReference(text, i)
          case (:final path, directory: false, :final end)
          when pastedAsPicture(path)) {
        found.add((i, end, path));
        i = end - 1;
      }
    }
    if (found.isEmpty) return text;
    final images = await _numbered(
      await Future.wait([
        for (final (_, _, path) in found) WindowControls.readImageFile(path),
      ]),
    );
    final out = StringBuffer();
    var at = 0;
    for (final (i, (start, end, _)) in found.indexed) {
      final image = images[i];
      if (image == null) continue;
      out
        ..write(text.substring(at, start))
        ..write(imageReference(image.number!));
      at = end;
    }
    out.write(text.substring(at));
    return out.toString();
  }

  /// Puts [tags] in at [at] (in place of the selection when null), apart
  /// from a word before them, each followed by a space, so that none is
  /// the last thing on its line (see [_padTrailingTokens]); the caret after
  /// them. One edit, undone as one.
  void _insertTags(List<ComposerEmbed> tags, {int? at}) {
    if (tags.isEmpty) return;
    final selection = _controller.selection;
    final end = _controller.length;
    final start = (at ?? (selection.isValid ? selection.start : end)).clamp(
      0,
      end,
    );
    final replaced = at == null && selection.isValid
        ? math.max(0, selection.end - start)
        : 0;
    final text = _controller.text;
    final content = StringBuffer();
    if (start > 0 && text[start - 1].trim().isNotEmpty) content.write(' ');
    for (final tag in tags) {
      content
        ..write(tag.atom)
        ..write(' ');
    }
    _controller
      ..breakUndo()
      ..replace(start, start + replaced, content.toString())
      ..breakUndo();
    _focusNode.requestFocus();
  }

  bool get _canSend => _hasContent || _images.isNotEmpty;

  // --- Suggested prompt & Predictive input ---------------------------------

  static final bool _isFlutterTest =
      Platform.environment['FLUTTER_TEST'] == 'true';

  /// The first of what the agent suggests sending next, shown over an empty
  /// dock composer (see ReplySuggestionBar); Tab takes it.
  String? _suggestion;

  /// Contextual next-step suggestions for the empty dock composer.
  List<String> _emptySuggestions = const [];

  /// Real-time inline completion prediction while the user is typing.
  String? _inlinePrediction;

  /// Key of the turn whose empty-state suggestion shelf was dismissed by `×`.
  String? _dismissedSuggestionTurnKey;

  String get _suggestionTurnKey =>
      '${widget.session.sessionId ?? 'new'}:${widget.session.itemCount}:${widget.session.promptSuggestion ?? ''}';

  /// The key that takes it, as the keybindings have it now: shown after
  /// it; none when unbound.
  String? _suggestionKey;

  /// The context keys where the suggested prompt's key applies.
  static const _suggestionKeyContext = {
    ChatContextKeys.inChatInput: true,
    ChatContextKeys.hasPromptSuggestion: true,
    ChatContextKeys.inputHasText: false,
  };

  void _acceptSuggestion([String? chosen]) {
    final suggestion = MdAtoms.strip(chosen ?? _suggestion ?? '');
    if (suggestion.isEmpty) return;
    _controller
      ..breakUndo()
      ..replace(
        0,
        _controller.length,
        suggestion,
        selection: TextSelection.collapsed(offset: suggestion.length),
      )
      ..breakUndo();
    _focusNode.requestFocus();
  }

  void _acceptInlinePrediction() {
    final prediction = _inlinePrediction;
    if (prediction == null || prediction.isEmpty) return;
    _controller
      ..breakUndo()
      ..replace(
        0,
        _controller.length,
        prediction,
        selection: TextSelection.collapsed(offset: prediction.length),
      )
      ..breakUndo();
    _focusNode.requestFocus();
  }

  /// Extracts the most recently modified or read filename from the session.
  String? _recentSessionFile() {
    final session = widget.session;
    final count = session.itemCount;
    for (var i = count - 1; i >= math.max(0, count - 30); i--) {
      final item = session.itemAt(i);
      if (item case CodeDiffItem(:final fileName) when fileName.isNotEmpty) {
        return fileName.split(RegExp(r'[/\\]')).last;
      }
      if (item case ToolCallItem(
        kind: ToolKind.edit || ToolKind.read,
        :final target,
      ) when target.isNotEmpty) {
        return target.split(RegExp(r'[/\\]')).last;
      }
    }
    return null;
  }

  /// Contextual next-step prompt suggestions when the input box is empty.
  List<String> _computeEmptySuggestions() {
    if (widget.onSubmit != null) return const [];
    final session = widget.session;
    if (session.isStreaming || session.pendingInteraction != null) {
      return const [];
    }
    if (!PromptSuggestions.current()) return const [];
    final fromKernel = session.promptSuggestion?.trim();
    if (_isFlutterTest) {
      return [if (fromKernel != null && fromKernel.isNotEmpty) fromKernel];
    }
    final results = <String>[];
    void addUnique(String value) {
      final cleaned = value.trim();
      if (cleaned.isNotEmpty && !results.contains(cleaned)) {
        results.add(cleaned);
      }
    }

    if (fromKernel != null && fromKernel.isNotEmpty) {
      addUnique(fromKernel);
    }

    final count = session.itemCount;
    String? recentFile;
    bool hadFailedCommand = false;
    bool askedQuestion = false;
    for (var i = count - 1; i >= math.max(0, count - 25); i--) {
      final item = session.itemAt(i);
      if (recentFile == null &&
          item is CodeDiffItem &&
          item.fileName.isNotEmpty) {
        recentFile = item.fileName.split(RegExp(r'[/\\]')).last;
      }
      if (item is TerminalItem && item.status == CommandStatus.failed) {
        hadFailedCommand = true;
      }
      if (item is AssistantTextItem && i >= count - 3) {
        final t = item.text.trimRight();
        if (t.endsWith('?') || t.endsWith('？')) {
          askedQuestion = true;
        }
      }
    }

    if (hadFailedCommand) {
      addUnique('分析刚才报错的原因并修复问题');
      addUnique('重新运行命令验证修复结果');
    }
    if (askedQuestion) {
      addUnique('好的，请按这个方案继续执行');
    }
    if (recentFile != null) {
      addUnique('检查 $recentFile 的改动并验证是否有编译警告');
      addUnique('继续优化 $recentFile 的交互与细节');
    }
    if (count > 0) {
      addUnique('继续完成下一步并验证效果');
      addUnique('总结一下刚才所做的修改');
    } else {
      addUnique('帮我分析当前项目的核心结构与模块划分');
      addUnique('检查最近的 git 改动并排查潜在问题');
    }
    return results.take(3).toList(growable: false);
  }

  /// Real-time inline predictive completion while typing in the composer.
  String? _computeInlinePrediction(String rawText) {
    if (_isFlutterTest ||
        widget.onSubmit != null ||
        _trigger != null ||
        !PromptSuggestions.current()) {
      return null;
    }
    if (rawText.contains(MdAtoms.open) ||
        rawText.contains('\n') ||
        RegExp(r'[*_`#>\[\]]').hasMatch(rawText)) {
      return null;
    }
    final trimmed = rawText.trimLeft();
    if (trimmed.isEmpty || trimmed.length > 60) return null;
    final lower = trimmed.toLowerCase();

    // 1. Match previously sent prompts in this session (most recent first).
    for (final sent in _sentPrompts().reversed) {
      final clean = sent.trim();
      if (!clean.contains('\n') &&
          clean.length <= 80 &&
          clean.length > trimmed.length + 1 &&
          clean.toLowerCase().startsWith(lower)) {
        return clean;
      }
    }

    // 2. Match contextual empty-state suggestions.
    for (final suggestion in _computeEmptySuggestions()) {
      if (suggestion.length > trimmed.length + 1 &&
          suggestion.toLowerCase().startsWith(lower)) {
        return suggestion;
      }
    }

    // 3. Match context-aware developer templates.
    final recentFile = _recentSessionFile();
    final fileTarget = recentFile ?? '当前代码';
    final templates = <String>[
      '帮我检查 $fileTarget 的逻辑并修复潜在问题',
      '帮我优化这里的界面交互与视觉细节',
      '帮我分析一下为什么会出现这个问题',
      '请帮我检查并修复这个问题',
      '为什么这里没有生效？请帮我排查原因',
      '怎么修复这个问题并确保测试通过？',
      '如何优化这里的实现让体验更流畅？',
      '修复这个问题并重新构建应用验证',
      '看看 $fileTarget 这里为什么有问题',
      '检查一下修改后的代码是否有分析警告或错误',
      '运行测试并确认所有用例通过',
      '测试一下刚才改动的功能是否正常',
      '继续完成剩下的步骤并验证效果',
      '优化一下这里的性能与动画流畅度',
      '重构这部分代码，保持结构清晰简洁',
      '提交当前的改动并生成清晰的 commit message',
      '解释一下这段代码的实现原理与调用流程',
      '排查一下最近改动引发的异常原因',
      '分析一下哪里耗时较长或存在性能瓶颈',
      '把刚才的修改应用并重新打开应用验证',
      '加一个更直观的交互提示和状态反馈',
      '修改这里的样式，使其更贴合整体暖色主题',
      '还是有这个问题，请深入排查根本原因',
      '再检查一下边界情况和异常分支处理',
      '对比一下修改前后的差异并确认无误',
      '总结一下刚才所做的改动和影响范围',
      'Run tests and verify the changes in $fileTarget',
      'Fix the issue and check for any analyzer warnings',
      'Explain how this works and why it behaves this way',
      'Check $fileTarget for edge cases and potential bugs',
      'Continue with the next step and verify',
      'Refactor this code to make it cleaner and more maintainable',
    ];
    for (final template in templates) {
      if (template.length > trimmed.length + 1 &&
          template.toLowerCase().startsWith(lower)) {
        return template;
      }
    }

    // 4. Smart suffix completion for arbitrary phrases as the user types.
    final rightTrimmed = trimmed.trimRight();
    if (rightTrimmed.length >= 2 &&
        rightTrimmed.length <= 28 &&
        !RegExp(r'[，。！？,.!?：:]$').hasMatch(rightTrimmed)) {
      if (rightTrimmed.startsWith('帮我') || rightTrimmed.startsWith('请帮我')) {
        return rightTrimmed.length < 5
            ? '$rightTrimmed检查 $fileTarget 并优化实现细节'
            : '$rightTrimmed，并验证修改后的效果';
      }
      if (rightTrimmed.startsWith('为什么') ||
          rightTrimmed.startsWith('怎么') ||
          rightTrimmed.startsWith('如何')) {
        return '$rightTrimmed？请帮我排查原因并给出修复方案';
      }
      if (rightTrimmed.startsWith('修复') ||
          rightTrimmed.startsWith('解决') ||
          rightTrimmed.startsWith('排查')) {
        return '$rightTrimmed，并确认没有引入新的问题';
      }
      if (rightTrimmed.startsWith('优化') ||
          rightTrimmed.startsWith('调整') ||
          rightTrimmed.startsWith('修改') ||
          rightTrimmed.startsWith('把')) {
        return '$rightTrimmed，让交互体验更加自然顺畅';
      }
      if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(rightTrimmed) &&
          rightTrimmed.length <= 16) {
        return '$rightTrimmed — 请帮我检查并完善这部分功能';
      }
    }
    return null;
  }

  /// The text area's own scroll position (it scrolls past its maximum
  /// height), or null before it is laid out.
  ScrollPosition? get editorScrollPosition =>
      _scrollController.hasClients ? _scrollController.position : null;

  /// The editor subtree, built once and reused so that keystrokes (which
  /// rebuild this state for the menu and send button) do not build it
  /// again. Rebuilt only when an inherited dependency (theme, window size),
  /// the color theme or the placeholder changes.
  Widget? _editor;

  /// [_shownOfText] when the box was last built.
  _ShownOfText? _shownBuilt;

  /// The color theme's colors [_editor] was built with.
  WorkbenchColors? _editorColors;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editor = null;
  }

  // --- Editor state --------------------------------------------------------

  /// An input method is composing text: a composition not empty. A macOS
  /// one may leave an empty one (its letters deleted, or after a commit)
  /// until its next: not composing, or the keys (Tab, Enter) went to the
  /// editor (#143).
  bool get _isComposing => _controller.isComposing;

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      _closeMenu();
    } else {
      // Focused, the caret in view: an edit's opens scrolled to its end.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final selection = _controller.selection;
        if (mounted && _focusNode.hasFocus && selection.isValid) {
          _editorKey.currentState?.ensureVisible(selection.extentOffset);
        }
      });
    }
    setState(() {});
  }

  /// The files put in the draft from outside (see
  /// [ComposerDraft.insertFiles]), as if pasted.
  void _takeDraftFiles() {
    final files = widget.draft?.takeFiles() ?? const <ComposerFile>[];
    if (files.isNotEmpty) unawaited(insertFiles(files));
  }

  /// The lines of code put in the draft from outside (see
  /// [ComposerDraft.insertCode]): tags of them after what is typed, as the
  /// IDE's lines pasted are.
  void _takeDraftCode() {
    final code = widget.draft?.takeCode() ?? const <CodeReference>[];
    final root = widget.session.root;
    _insertTags([
      for (final lines in code)
        ComposerCodeEmbed.of(lines.withPath(displayPath(lines.path, root))),
    ], at: _controller.length);
  }

  /// The message put back in the draft to be edited (see
  /// [ComposerDraft.restore]): after what is typed, the caret at its end.
  void _takeDraftMessage() {
    final message = widget.draft?.takeMessage();
    if (message == null) return;
    _pool = {
      for (final image in message.images) ?image.number: image,
      ..._pool,
    };
    var text = message.text;
    final referred = {
      for (final match in imageReferencePattern.allMatches(text))
        int.parse(match[1]!),
    };
    final unreferred = [
      for (final image in message.images)
        if (image.number case final number? when !referred.contains(number))
          number,
    ];
    if (unreferred.isNotEmpty) {
      text = [unreferred.map(imageReference).join(' '), text].join(' ');
    }
    final content = composerContentFromText(
      text,
      ComposerVocabulary.read(context),
      images: _pool.keys.toSet(),
    );
    final end = _controller.length;
    _controller
      ..breakUndo()
      ..replace(
        end,
        end,
        content,
        selection: TextSelection.collapsed(offset: end + content.length),
      )
      ..breakUndo();
    _focusNode.requestFocus();
  }

  /// Keeps what is typed, and where the caret is, in the draft.
  void _saveDraft() {
    if (_takingDraft) return;
    widget.draft?.save(
      _controller.text,
      _controller.selection,
      _pool.values.toList(),
      by: this,
    );
  }

  /// Taking up [_handleDraftChanged]'s text: not the user's edit.
  bool _takingDraft = false;

  /// The draft typed in by another composer (the same agent's, in another
  /// window): its text here too, the caret kept where it was.
  void _handleDraftChanged() {
    final draft = widget.draft;
    if (draft != null && draft.pendingFiles.isNotEmpty) _takeDraftFiles();
    if (draft != null && draft.pendingCode.isNotEmpty) _takeDraftCode();
    if (draft?.pendingMessage != null) _takeDraftMessage();
    if (draft == null || identical(draft.savedBy, this) || !draft.saved) {
      return;
    }
    final current = _controller.text;
    final content = draft.content!;
    if (current == content) return;
    _pool = {..._pool, for (final image in draft.images) ?image.number: image};
    // Only what differs replaced, the caret moved along.
    var start = 0;
    final shorter = math.min(current.length, content.length);
    while (start < shorter &&
        current.codeUnitAt(start) == content.codeUnitAt(start)) {
      start++;
    }
    var end = 0;
    while (end < shorter - start &&
        current.codeUnitAt(current.length - 1 - end) ==
            content.codeUnitAt(content.length - 1 - end)) {
      end++;
    }
    // Not into an atom: one changed is replaced whole.
    while (start > 0 && _inAtom(current, start)) {
      start--;
    }
    while (end > 0 && _inAtom(current, current.length - end)) {
      end--;
    }
    _takingDraft = true;
    try {
      // Not this composer's edit to undo, and its steps no longer the
      // text's.
      _controller
        ..forgetUndo()
        ..replaceUnrecorded(
          start,
          current.length - end,
          content.substring(start, content.length - end),
        );
    } finally {
      _takingDraft = false;
    }
  }

  /// Whether [offset] of [text] is inside an atom (after its opening mark,
  /// before or at its closing one).
  static bool _inAtom(String text, int offset) {
    if (offset <= 0 || offset > text.length) return false;
    final open = text.lastIndexOf(MdAtoms.open, offset - 1);
    if (open < 0) return false;
    final close = text.lastIndexOf(MdAtoms.close, offset - 1);
    return close < open;
  }

  /// What the box shows that follows the text, besides the text (which
  /// the editor shows itself): the menu, the images, whether the message
  /// can be sent and polished. A key typed that changes none of it since
  /// the box was built ([_shownBuilt]) does not build it again (its
  /// pickers, its buttons).
  _ShownOfText _shownOfText() => (
    menu: (_trigger != null, _menuX, _menuKind, _matches, _highlighted),
    pool: _pool,
    canSend: _canSend,
    polishable: ComposerPolishSetting.current() && _hasWords(),
    inlinePrediction: _inlinePrediction,
  );

  /// Whether the text has words to polish: read again only once it
  /// changed, not each time the session builds the box.
  bool _hasWords() {
    final version = _controller.textVersion;
    if (version != _wordsVersion) {
      _wordsVersion = version;
      _words = _polishText().hasWords;
    }
    return _words;
  }

  int? _wordsVersion;
  bool _words = false;

  void _handleEditorChanged() => _lag.time('edit', _editorChanged);

  void _editorChanged() {
    // The placeholder of a drag coming and going: not the user's edit.
    if (_ghosting) return;
    if (_padTrailingTokens()) return; // Re-entered with the fixed text.
    _images = _referredImages();
    _lag.time('draft', _saveDraft);
    final text = _controller.text;
    // Edited, a message recalled from the history is the one typed.
    if (_historyAt != null && !_recalling && text != _historyShown) {
      _leaveHistory();
    }
    final hasContent = text.trim().isNotEmpty;
    final trigger = _findTrigger(text);

    if (trigger == null || !trigger.sameAnchor(_dismissedTrigger)) {
      _dismissedTrigger = null;
    }
    var visible = trigger != null && _dismissedTrigger == null;
    final vocabulary = ComposerVocabulary.read(context);
    // An @ with no file to look up and no other conversation to refer to
    // stays text.
    if (visible && trigger.kind == SuggestionKind.file) {
      if (!trigger.sameAnchor(_trigger)) {
        _sessions = vocabulary.sessions?.call() ?? [];
        _stashes = vocabulary.stashes?.call() ?? [];
      }
      visible =
          vocabulary.suggestFiles != null ||
          _sessions.isNotEmpty ||
          _stashes.isNotEmpty;
    }
    // A / within the message that starts no command's name (e.g. a path's)
    // stays text.
    List<SuggestionMatch>? commands;
    if (visible &&
        trigger != null &&
        trigger.kind == SuggestionKind.command &&
        trigger.start > 0) {
      commands = rankSuggestions(vocabulary.commands, trigger.query);
      visible = commands.isNotEmpty;
    }

    if (visible) {
      final queryChanged =
          !trigger!.sameAnchor(_trigger) || trigger.query != _trigger!.query;
      if (queryChanged) {
        if (trigger.kind == SuggestionKind.file) {
          _matches = _rankOthers(trigger.query);
          if (vocabulary.suggestFiles case final suggest?) {
            unawaited(_lookUpFiles(trigger, suggest));
          }
        } else {
          _matches =
              commands ?? rankSuggestions(vocabulary.commands, trigger.query);
        }
        _highlighted = 0;
      }
      _menuKind = trigger.kind;
      _highlighted = _highlighted.clamp(0, math.max(0, _matches.length - 1));
      _menuX = _caretX(trigger.start);
    }
    _trigger = visible ? trigger : null;
    _syncMenuRegistration();
    _hasContent = hasContent;
    _inlinePrediction = hasContent ? _computeInlinePrediction(text) : null;
    if (_shownOfText() != _shownBuilt) setState(() {});
  }

  int _lookups = 0;

  /// Asks the kernel for files matching [trigger], and shows them ahead of
  /// the conversations. Answers to older queries are dropped.
  Future<void> _lookUpFiles(
    _Trigger trigger,
    Future<List<Suggestion>> Function(String query) suggest,
  ) async {
    final lookup = ++_lookups;
    final List<Suggestion> files;
    try {
      files = await suggest(trigger.query);
    } on Object {
      return;
    }
    final current = _trigger;
    if (!mounted ||
        lookup != _lookups ||
        current == null ||
        !current.sameAnchor(trigger) ||
        current.query != trigger.query) {
      return;
    }
    setState(() {
      _matches = [
        for (final suggestion in files)
          SuggestionMatch(
            suggestion,
            fuzzyMatch(suggestion.label, trigger.query)?.indexes ?? const [],
          ),
        ..._rankOthers(trigger.query),
      ];
      _highlighted = _highlighted.clamp(0, math.max(0, _matches.length - 1));
    });
    _syncMenuRegistration();
  }

  /// Flutter lays out a line whose only content is an inline widget taller
  /// than a line with text, so a token must never end a line: when it does
  /// (e.g. the space after it was deleted), add a space after it, part of
  /// the edit that left it there, and leave the caret where it was. Sending
  /// trims it. Returns true if it edited.
  bool _padTrailingTokens() {
    final text = _controller.text;
    for (final run in MdAtoms.parse(text).reversed) {
      final end = run.end;
      if (end < text.length && text[end] != '\n') continue;
      _controller.amend(end, end, ' ');
      return true;
    }
    return false;
  }

  _Trigger? _findTrigger(String text) {
    final selection = _controller.selection;
    if (!selection.isCollapsed || selection.baseOffset < 1) return null;
    final caret = math.min(selection.baseOffset, text.length);

    // A space, a line's end, or a tag's either end.
    bool isBoundary(String char) =>
        char.trim().isEmpty || char == MdAtoms.open || char == MdAtoms.close;
    // Only at the end of a query: a caret moved into existing text (e.g.
    // `/re|view`) is not typing one.
    if (caret < text.length && !isBoundary(text[caret])) return null;
    // A / or an @ starting the word the caret ends: a command, or a file or
    // a conversation to refer to.
    final vocabulary = ComposerVocabulary.read(context);
    final mentions =
        vocabulary.sessions != null ||
        vocabulary.suggestFiles != null ||
        vocabulary.stashes != null;
    for (var i = caret - 1; i >= 0; i--) {
      final char = text[i];
      if (isBoundary(char)) return null;
      if (i > 0 && !isBoundary(text[i - 1])) continue;
      final query = text.substring(i + 1, caret);
      if (char == '/') return _Trigger(SuggestionKind.command, i, query);
      if (char == '@' && mentions) {
        return _Trigger(SuggestionKind.file, i, query);
      }
    }
    return null;
  }

  /// Horizontal caret position of [offset] relative to the composer box.
  double _caretX(int offset) {
    final caret = _editorKey.currentState?.caretRect(offset);
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (caret == null || box == null || !box.attached) return 12;
    final x = box.globalToLocal(caret.topLeft).dx - 8;
    return x.clamp(0, math.max(0, box.size.width - SuggestionMenu.width));
  }

  // --- Suggestions ---------------------------------------------------------

  void _closeMenu() {
    if (_trigger != null) _dismissedTrigger = _trigger;
    _trigger = null;
    _syncMenuRegistration();
  }

  /// Identifies the suggestion menu to [FloatingRegistry].
  final Object _menuOwner = Object();
  bool _menuRegistered = false;

  void _syncMenuRegistration() {
    final open = _trigger != null;
    if (open == _menuRegistered) return;
    _menuRegistered = open;
    if (open) {
      FloatingRegistry.openPopover(_menuOwner, () {
        if (mounted) setState(_closeMenu);
      });
    } else {
      FloatingRegistry.closePopover(_menuOwner);
    }
  }

  void _moveHighlight(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _highlighted = (_highlighted + delta) % _matches.length;
    });
  }

  void _accept(int index) {
    final trigger = _trigger;
    if (trigger == null || index >= _matches.length) return;
    final suggestion = _matches[index].suggestion;
    final caret = _controller.selection.baseOffset;
    final ComposerEmbed token;
    if (suggestion.kind == SuggestionKind.stash) {
      final stash = ComposerVocabulary.read(context).stash
          ?.call(int.parse(suggestion.id));
      if (stash == null) return;
      token = ComposerStashEmbed.of(stash);
    } else if (suggestion.kind == SuggestionKind.file ||
        suggestion.kind == SuggestionKind.folder) {
      token = ComposerTokenEmbed.file(
        suggestion.value,
        directory: suggestion.kind == SuggestionKind.folder,
      );
    } else {
      token = ComposerTokenEmbed.fromSuggestion(suggestion);
    }
    // The token and a space after it, so the token is never the last thing
    // on its line (see [_padTrailingTokens]).
    final tag = '${token.atom} ';
    _controller
      ..breakUndo()
      ..replace(
        trigger.start,
        caret,
        tag,
        selection: TextSelection.collapsed(offset: trigger.start + tag.length),
      )
      ..breakUndo();
    _focusNode.requestFocus();
  }

  // --- Keyboard ------------------------------------------------------------

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyUpEvent) _lag.begin('key');
    if (event is KeyUpEvent || _isComposing) return KeyEventResult.ignored;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyE &&
        HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      unawaited(_polish());
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        _trigger == null) {
      if (_hasContent && _inlinePrediction != null) {
        _acceptInlinePrediction();
        return KeyEventResult.handled;
      }
      if (!_hasContent && _suggestion != null) {
        _acceptSuggestion();
        return KeyEventResult.handled;
      }
    }
    // Run by the window's keybindings (it sees keys first).
    if (ChatKeys.isHandled(event)) return KeyEventResult.handled;
    // An open picker menu (or tooltip) takes arrows, Enter and Esc first.
    if (FloatingRegistry.handleKey(event) case final result?) return result;
    // Then the keybindings: Enter sends, the menu's keys…
    return ChatKeys.dispatch(event) ?? KeyEventResult.ignored;
  }

  bool get _caretAtStart {
    final selection = _controller.selection;
    return selection.isCollapsed && selection.baseOffset <= 0;
  }

  bool get _caretAtEnd {
    final selection = _controller.selection;
    return selection.isCollapsed && selection.baseOffset >= _controller.length;
  }

  @override
  Object? chatContextKey(String key) => switch (key) {
    ChatContextKeys.inChatInput ||
    'inputFocus' ||
    'textInputFocus' => _focusNode.hasFocus,
    ChatContextKeys.inputHasText => _hasContent,
    // As upstream: at the very start, and the very end.
    ChatContextKeys.cursorAtTop => _caretAtStart,
    ChatContextKeys.cursorAtBottom => _caretAtEnd,
    ChatContextKeys.suggestWidgetVisible => _trigger != null,
    ChatContextKeys.hasPromptSuggestion => _suggestion != null,
    ChatContextKeys.currentlyEditing => widget.onSubmit != null,
    _ => null,
  };

  @override
  Map<String, VoidCallback> get chatCommands {
    final menu = _trigger != null;
    final history = widget.onSubmit == null;
    return {
      // Always: with nothing to send, Enter does nothing (no new line).
      ChatCommandIds.submit: _submit,
      // Paste the clipboard as plain text, past the long-paste tag.
      ChatCommandIds.pasteRaw: () => unawaited(_paste(raw: true)),
      ChatCommandIds.cancelEdit: ?widget.onCancel,
      if (history && (_historyAt ?? _sentPrompts().length) > 0)
        ChatCommandIds.showPreviousPrompt: () => _showPrompt(-1),
      if (history && _historyAt != null)
        ChatCommandIds.showNextPrompt: () => _showPrompt(1),
      if (_suggestion != null)
        ChatCommandIds.acceptPromptSuggestion: _acceptSuggestion,
      if (_modePickerKey.currentState case final picker?)
        ChatCommandIds.openModePicker: picker.toggle,
      if (widget.session.modes case final modes?)
        ChatCommandIds.nextMode: () => _nextMode(modes),
      if (_modelPickerKey.currentState case final picker?)
        ChatCommandIds.openModelPicker: picker.toggle,
      if (WindowControls.canPickFiles)
        ChatCommandIds.attachContext: _attachContext,
      if (menu) ...{
        ChatCommandIds.selectNextSuggestion: () => _moveHighlight(1),
        ChatCommandIds.selectPrevSuggestion: () => _moveHighlight(-1),
        if (_matches.isNotEmpty)
          ChatCommandIds.acceptSelectedSuggestion: () => _accept(_highlighted),
        ChatCommandIds.hideSuggestWidget: () => setState(_closeMenu),
      },
    };
  }

  @override
  bool get chatComposing => _isComposing;

  /// Picks the mode after the one picked, back to the first after the
  /// last.
  void _nextMode(KernelChoice modes) {
    final options = modes.options;
    final at = options.indexWhere((o) => o.id == modes.selected.id);
    modes.onSelected(options[(at + 1) % options.length]);
  }

  /// Asks for files (the system's open panel) and puts them in at the
  /// caret (upstream's Add Context… picks them in a picker of its own).
  Future<void> _attachContext() async {
    final files = await WindowControls.pickFiles();
    if (!mounted) return;
    await insertFiles(files, here: true);
    _focusNode.requestFocus();
  }

  // --- Drag and drop -----------------------------------------------------
  //
  // Files dragged over the composer, from other apps (see [FileDrops]) or
  // from the IDE ([FileDragData]), show where they would go: their tags,
  // faint, in the text at the pointer, the text making room for them. Let
  // go, the tags take their place.

  /// Where the placeholder is in the text, while a drag is over it.
  int? _ghostAt;

  /// The placeholder and the space after it, as they are in the text.
  String _ghost = '';

  /// What the placeholder shows.
  List<ComposerFile> _ghostFiles = const [];

  /// The placeholder is being put in or taken out: no edit of the user's
  /// (see [_handleEditorChanged]), and nothing to undo.
  bool _ghosting = false;

  /// Where in the text [position] (the window's) would put what is let go
  /// there: an offset in the text without the placeholder. Below or
  /// beside the text (the toolbar, the pictures), its end.
  int _dropOffset(Offset position) {
    final end = _controller.length - (_ghostAt == null ? 0 : _ghost.length);
    final editor = _editorKey.currentState;
    final area = editor?.viewportRect;
    if (editor == null || area == null || !area.contains(position)) {
      return end;
    }
    var offset = editor.offsetAt(position) ?? end;
    if (_ghostAt case final ghost? when offset > ghost) {
      offset = math.max(ghost, offset - _ghost.length);
    }
    return offset.clamp(0, end);
  }

  /// Stashes dragged from their page, let go at [position]: their tags
  /// where the text is there.
  void _dropStashes(Offset position, List<StashReference> stashes) {
    if (!mounted) return;
    final at = _dropOffset(position);
    final tags = [
      for (final stash in stashes) '${ComposerStashEmbed.of(stash).atom} ',
    ].join();
    _controller
      ..breakUndo()
      ..replace(
        at,
        at,
        tags,
        selection: TextSelection.collapsed(offset: at + tags.length),
      )
      ..breakUndo();
    _focusNode.requestFocus();
  }

  void _showGhost(Offset position, List<ComposerFile> files) {
    if (!mounted) return;
    final at = _dropOffset(position);
    if (at == _ghostAt && listEquals(files, _ghostFiles)) return;
    final shown = _ghostAt != null;
    _editGhost(() {
      _removeGhost();
      final ghost = '${ComposerGhostEmbed.of(files).atom} ';
      _controller.replaceUnrecorded(at, at, ghost);
      _ghostAt = at;
      _ghost = ghost;
      _ghostFiles = files;
    });
    // The border shows it.
    if (!shown) setState(() {});
  }

  void _hideGhost() {
    if (!mounted || _ghostAt == null) return;
    _editGhost(_removeGhost);
    setState(() {});
  }

  void _removeGhost() {
    final at = _ghostAt;
    if (at == null) return;
    final length = _ghost.length;
    _ghostAt = null;
    _ghost = '';
    _ghostFiles = const [];
    _controller.replaceUnrecorded(at, at + length, '');
  }

  void _editGhost(VoidCallback edit) {
    _ghosting = true;
    try {
      edit();
    } finally {
      _ghosting = false;
    }
  }

  @override
  void fileDragOver(Offset position, List<ComposerFile> files) => _showGhost(
    position,
    // Files an app is still to write (a mail's attachment) have no names
    // yet.
    files.isEmpty ? const [ComposerFile('…')] : files,
  );

  @override
  void fileDragLeave() => _hideGhost();

  /// From another app: this machine's files.
  @override
  void fileDrop(Offset position, List<ComposerFile> files) =>
      _dropFiles(position, files, here: true);

  /// [files] let go at [position]; [here], this machine's (else the
  /// project's, dragged from the IDE).
  void _dropFiles(
    Offset position,
    List<ComposerFile> files, {
    required bool here,
  }) {
    if (!mounted) return;
    final at = _ghostAt ?? _dropOffset(position);
    _hideGhost();
    unawaited(insertFiles(files, at: at, here: here));
  }

  // --- Prompt history ------------------------------------------------------
  //
  // As upstream's chat input history: ↑ at the start of the input shows
  // the message sent before, ↓ at its end the one after, and past the last,
  // what was being typed.

  /// Where in [_sentPrompts] the history shows (their count: what was
  /// being typed); null when it does not.
  int? _historyAt;

  /// What was being typed when the history was opened.
  String? _historyDraft;

  /// The text the history put in: once it is edited, it is the message
  /// typed, and the history closes.
  String? _historyShown;
  bool _recalling = false;

  /// The messages sent in this conversation, oldest first, a message sent
  /// again in a row once.
  List<String> _sentPrompts() {
    final session = widget.session;
    final prompts = <String>[];
    for (var i = 0; i < session.itemCount; i++) {
      if (session.itemAt(i) case UserMessageItem(:final text, fromAgent: null)
          when text.trim().isNotEmpty &&
              (prompts.isEmpty || prompts.last != text)) {
        prompts.add(text);
      }
    }
    return prompts;
  }

  void _leaveHistory() {
    _historyAt = null;
    _historyDraft = null;
    _historyShown = null;
  }

  /// Shows the message [step] from the one shown (-1: the one before).
  void _showPrompt(int step) {
    final prompts = _sentPrompts();
    final from = _historyAt ?? prompts.length;
    final at = from + step;
    if (at < 0 || at > prompts.length) return;
    _historyDraft ??= _controller.text;
    final String content;
    if (at == prompts.length) {
      content = _historyDraft!;
    } else {
      content = composerContentFromPaste(
        prompts[at],
        ComposerVocabulary.read(context),
        atStart: true,
      );
    }
    _recalling = true;
    try {
      // Going back, at the start: ↑ goes on back; going on, at the end.
      _controller
        ..breakUndo()
        ..replace(
          0,
          _controller.length,
          content,
          selection: TextSelection.collapsed(
            offset: step < 0 ? 0 : content.length,
          ),
        )
        ..breakUndo();
    } finally {
      _recalling = false;
    }
    if (at == prompts.length) {
      _leaveHistory();
    } else {
      _historyAt = at;
      _historyShown = _controller.text;
    }
  }

  // --- Polish --------------------------------------------------------------

  /// The text as the model is given it to polish (see [composerPolishText]).
  ComposerPolishText _polishText() => composerPolishText(_controller.text);

  /// Has the auxiliary model polish the text into a clearer, more specific
  /// prompt (Enhance prompt), its tags, images, code and links kept as they
  /// are, the agent's last turn told to know what it answers; put in its place as one change (⌘Z takes it back), unless the
  /// text changed meanwhile. Why not, in a notification.
  Future<void> _polish() async {
    if (_polishing) return;
    final asked = _polishText();
    if (!asked.hasWords) return;
    final before = _controller.text;
    final notifications = IdeNotificationsScope.maybeOf(context);
    final l10n = context.l10n;
    setState(() => _polishing = true);
    try {
      final String polished;
      try {
        polished = await polishComposerText(
          asked,
          reply: widget.session.lastTurnReply,
          model: widget.session.selected(KernelChoiceKind.model),
          location: widget.session.kernelContext.cwd,
        );
      } on ComposerPolishException catch (error) {
        notifications?.notify(
          IdeSeverity.error,
          l10n.composerPolishFailed(error.message ?? l10n.stashAiNoAnswer),
        );
        return;
      }
      if (!mounted || _controller.text != before) return;
      // One change of its own to undo: not merged with what was typed just
      // before it, nor with what is typed next.
      _controller
        ..breakUndo()
        ..replace(
          0,
          _controller.length,
          polished,
          selection: TextSelection.collapsed(offset: polished.length),
        )
        ..breakUndo();
      _focusNode.requestFocus();
    } finally {
      if (mounted) setState(() => _polishing = false);
    }
  }

  /// Inserts external selected text grabbed via global hotkey (`⌃⇧S`) into
  /// the composer and focuses the input.
  void insertGrabbedSelection(String selectedText) {
    final trimmed = selectedText.trim();
    if (trimmed.isEmpty || !mounted) return;
    final quoted = trimmed
        .split('\n')
        .map((line) => '> $line')
        .join('\n');
    final prefix = _controller.text.isEmpty || _controller.text.endsWith('\n')
        ? ''
        : '\n';
    final insertion = '$prefix$quoted\n\n请帮我分析或解释以上内容：';
    final end = _controller.length;
    _controller
      ..breakUndo()
      ..replace(
        end,
        end,
        insertion,
        selection: TextSelection.collapsed(offset: end + insertion.length),
      )
      ..breakUndo();
    _saveDraft();
    _focusNode.requestFocus();
  }

  void _updateImage(int number, ImageAttachment updated) {
    if (!mounted) return;
    setState(() {
      _pool = {..._pool, number: updated};
    });
    _saveDraft();
  }

  // --- Submit --------------------------------------------------------------

  ComposerMessage _buildMessage() {
    final text = StringBuffer();
    final mentions = <String>[];
    final code = <String, AppendedText>{};
    for (final piece in composerPieces(_controller.text)) {
      switch (piece) {
        case final String data:
          text.write(data);
        case ComposerEmbed(type: ComposerImageEmbed.type, :final data):
          text.write(ComposerImageEmbed.plainText(data));
        case ComposerEmbed(type: ComposerCodeEmbed.type, :final data):
          final reference = ComposerCodeEmbed.decode(data);
          text.write(reference.reference);
          code.putIfAbsent(reference.reference, () => reference);
        case ComposerEmbed(type: ComposerPastedTextEmbed.type, :final data):
          final pasted = ComposerPastedTextEmbed.decode(data);
          text.write(pasted.reference);
          code.putIfAbsent(pasted.reference, () => pasted);
        case ComposerEmbed(type: ComposerStashEmbed.type, :final data):
          final stash = ComposerStashEmbed.decode(data);
          text.write(stash.reference);
          code.putIfAbsent(stash.reference, () => stash);
        case ComposerEmbed(type: ComposerTokenEmbed.type, :final data):
          text.write(ComposerTokenEmbed.plainText(data));
          final token = ComposerTokenEmbed.decode(data);
          if ((token.kind == SuggestionKind.file ||
                  token.kind == SuggestionKind.folder) &&
              !mentions.contains(token.value)) {
            mentions.add(token.value);
          }
      }
    }
    return ComposerMessage(
      // The lines it refers to after it.
      text: text.toString().trim() + codeAppendix(code.values),
      mentions: mentions,
      images: [..._images],
    );
  }

  /// The dock's composer shows a stop button while a turn runs; an editing
  /// composer can always submit (resending stops the running turn).
  bool get _showsStop =>
      widget.onSubmit == null &&
      widget.session.isStreaming &&
      !(widget.session.canQueue && _canSend);

  void _submit() {
    // Empty while a turn runs, messages queued behind it: the first of them
    // taken up now, as its Send Now.
    if (widget.onSubmit == null && widget.session.isStreaming && !_canSend) {
      if (widget.session.queued.firstOrNull case (final id, _)) {
        widget.session.sendQueuedNow(id);
      }
      return;
    }
    if (_showsStop) return;
    final message = _buildMessage();
    if (message.text.isEmpty && message.images.isEmpty) return;
    if (widget.onIntercept case final intercept? when intercept(message)) {
      _pool = {};
      _controller.clear();
      _leaveHistory();
      _saveDraft();
      _dismissedTrigger = null;
      return;
    }
    if (widget.onSubmit case final onSubmit?) {
      onSubmit(message);
      return;
    }
    widget.session.send(
      message,
      editor: widget.openEditor,
      from: UserPlace.computer,
    );
    _pool = {};
    _controller.clear();
    _leaveHistory();
    _saveDraft();
    _dismissedTrigger = null;
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _shownBuilt = _shownOfText();
    final focused = _focusNode.hasFocus;
    final emptySuggestions = _computeEmptySuggestions();
    _emptySuggestions = emptySuggestions;
    final suggestion = widget.onSubmit == null
        ? (widget.session.promptSuggestion ?? emptySuggestions.firstOrNull)
        : null;
    // In tests, the editor placeholder shows `suggestion    Tab`; in the live
    // desktop UI, suggestions show as floating tactile chips above the card so
    // the editor placeholder stays calm and never duplicates text.
    final placeholderSuggestion = _isFlutterTest && widget.onSubmit == null
        ? widget.session.promptSuggestion
        : null;
    final suggestionKey = placeholderSuggestion == null
        ? null
        : ChatKeys.keyLabel(
            ChatCommandIds.acceptPromptSuggestion,
            _suggestionKeyContext,
          );
    if (suggestion != _suggestion || suggestionKey != _suggestionKey) {
      final placeholderChanged =
          (_isFlutterTest && suggestion != _suggestion) ||
          suggestionKey != _suggestionKey;
      _suggestion = suggestion;
      _suggestionKey = suggestionKey;
      if (placeholderChanged) {
        _editor = null; // The placeholder shows them in tests.
      }
    }
    final colors = themeColors;
    if (!identical(colors, _editorColors)) {
      _editorColors = colors;
      _editor = null;
    }
    // Before what is built is told by it (see [_buildInputs]).
    _editor ??= _buildEditor(context);
    final inputs = _buildInputs();
    if (_built case final built? when listEquals(inputs, _builtFrom)) {
      return built;
    }
    _builtFrom = inputs;
    return _built = FloatingLayer(
      visible: _trigger != null,
      // Above the composer at the trigger character; below it when there
      // is no room above.
      placement: (side: FloatingSide.top, align: FloatingAlign.start),
      anchorRect: (box) =>
          Rect.fromLTWH(box.left + _menuX, box.top, 1, box.height),
      // Clicks in the menu are not outside the editor.
      tapRegionGroupId: _focusNode,
      outerTapRegionGroupId: widget.tapRegionGroupId,
      builder: _buildMenu,
      child: FileDropRegion(
        delegate: this,
        child: DragTarget<StashDragData>(
          onWillAcceptWithDetails: (details) =>
              details.data.references.isNotEmpty,
          onAcceptWithDetails: (details) =>
              _dropStashes(details.offset, details.data.references),
          builder: (context, stashes, _) => DragTarget<FileDragData>(
            onWillAcceptWithDetails: (details) => details.data.files.isNotEmpty,
            onMove: (details) => _showGhost(details.offset, details.data.files),
            onLeave: (_) => _hideGhost(),
            onAcceptWithDetails: (details) =>
                _dropFiles(details.offset, details.data.files, here: false),
            builder: (context, candidates, rejected) => _buildBox(
              focused: focused || _ghostAt != null || stashes.isNotEmpty,
            ),
          ),
        ),
      ),
    );
  }

  /// What [build] made, and of what ([_buildInputs]): the same again
  /// while none of it changed, so that the session's every change (an
  /// answer's each word, streaming) does not build the box again, its
  /// pickers and buttons.
  Widget? _built;
  List<Object?>? _builtFrom;

  /// The hovers of the toolbar's mode and model pickers and its context
  /// ring, with the keys that do the same in the input.
  late ({String mode, String model, String ring}) _hovers;

  /// All that [build] reads, as it is now: the widget's, the state's, and
  /// the session's that the toolbar shows. A kernel's options are the same
  /// list while they do not change; the kernel among these, the picks'
  /// callbacks built with it stay its.
  List<Object?> _buildInputs() {
    final session = widget.session;
    final l10n = context.l10n;
    const input = {ChatContextKeys.inChatInput: true};
    _hovers = (
      mode: ChatKeys.titleWithKey(
        l10n.composerSetMode,
        ChatCommandIds.openModePicker,
        input,
      ),
      model: ChatKeys.titleWithKey(
        l10n.composerPickModel,
        ChatCommandIds.openModelPicker,
        input,
      ),
      ring: ChatKeys.titleWithKey(
        l10n.composerContextUsage,
        ChatCommandIds.toggleContextPanel,
        const {...input, ChatContextKeys.inChat: true},
      ),
    );
    final model = session.models;
    return [
      session,
      widget.onSubmit == null,
      widget.tapRegionGroupId,
      widget.contextPanelOpen,
      widget.onToggleContextPanel,
      _focusNode.hasFocus,
      _ghostAt != null,
      _shownBuilt,
      _editor,
      _polishing,
      _emptySuggestions.join('\n'),
      _dismissedSuggestionTurnKey,
      ComposerPolishSetting.current(),
      l10n,
      themeColors,
      _hovers,
      session.kernel,
      _showsStop,
      session.health.noModel,
      session.context?.fraction,
      for (final choice in [
        session.kernelChoice,
        session.modes,
        session.permissions,
        model,
      ]) ...[choice?.options, choice?.selected],
      // What the model's label says of its settings (see
      // SessionModelPicker): their lists are made anew each time.
      if (model != null)
        for (final setting in session.modelSettings(model.selected.id)) ...[
          setting.kind,
          setting.selected,
          setting.options.firstOrNull,
        ],
    ];
  }

  Color _cardSurfaceColor({required bool dark, required bool focused}) {
    if (dark) {
      return Color.lerp(
        AppColors.bubbleFill,
        Colors.white,
        focused ? 0.038 : 0.018,
      )!;
    }
    return Color.lerp(
      AppColors.bubbleFill,
      Colors.white,
      focused ? 0.62 : 0.44,
    )!;
  }

  Widget _buildBox({required bool focused}) {
    final dark = themeColors.dark;
    final cardSurface = _cardSurfaceColor(dark: dark, focused: focused);
    final shelf = _buildEmptySuggestionShelf(dark: dark);
    final box = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _focusNode.requestFocus,
      child: AnimatedContainer(
        key: _boxKey,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        clipBehavior: Clip.antiAlias,
        decoration: ShapeDecoration(
          color: cardSurface,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: AppColors.bubbleBorder(focused: focused),
              width: focused ? 1.15 : 1.0,
            ),
          ),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: focused ? (dark ? 0.30 : 0.075) : (dark ? 0.18 : 0.045),
              ),
              blurRadius: focused ? 18 : 10,
              offset: Offset(0, focused ? 5 : 2.5),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.12 : 0.02),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
            if (focused)
              BoxShadow(
                color: AppColors.accent.withValues(alpha: dark ? 0.13 : 0.09),
                blurRadius: 8,
                spreadRadius: 0.5,
              ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ComposerImages(
              images: _pool,
              onUpdateImage: _updateImage,
              child: _editor!,
            ),
            _buildToolbar(),
          ],
        ),
      ),
    );
    if (shelf == null) return box;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        shelf,
        const SizedBox(height: 6),
        box,
      ],
    );
  }

  /// Floating warm-parchment quick-suggestion pills shown above the composer
  /// card when the input is empty. Zero text duplication inside the editor!
  Widget? _buildEmptySuggestionShelf({required bool dark}) {
    if (_isFlutterTest ||
        widget.onSubmit != null ||
        _hasContent ||
        _images.isNotEmpty ||
        !PromptSuggestions.current() ||
        widget.session.isStreaming ||
        widget.session.pendingInteraction != null ||
        _emptySuggestions.isEmpty ||
        _dismissedSuggestionTurnKey == _suggestionTurnKey) {
      return null;
    }
    final chipSurface = _cardSurfaceColor(dark: dark, focused: false);
    return SizedBox(
      height: 27,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _emptySuggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final item = _emptySuggestions[index];
                final isPrimary = index == 0;
                return HoverBuilder(
                  cursor: SystemMouseCursors.click,
                  builder: (context, hovered) => GestureDetector(
                    onTapDown: (_) {},
                    onTap: () => _acceptSuggestion(item),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 130),
                      padding: EdgeInsets.only(
                        left: isPrimary ? 9 : 10,
                        right: isPrimary ? 6.5 : 10,
                      ),
                      decoration: BoxDecoration(
                        color: hovered
                            ? Color.lerp(
                                chipSurface,
                                AppColors.accent,
                                dark ? 0.14 : 0.07,
                              )
                            : chipSurface.withValues(
                                alpha: isPrimary ? 1.0 : (dark ? 0.82 : 0.86),
                              ),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: hovered
                              ? AppColors.accent.withValues(
                                  alpha: dark ? 0.45 : 0.35,
                                )
                              : isPrimary
                              ? AppColors.accent.withValues(
                                  alpha: dark ? 0.25 : 0.20,
                                )
                              : AppColors.bubbleBorder(),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: dark ? 0.14 : 0.03,
                            ),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isPrimary) ...[
                            Icon(
                              Codicons.sparkle,
                              size: 11.5,
                              color: AppColors.accent,
                            ),
                            const SizedBox(width: 5),
                          ],
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 270),
                            child: Text(
                              item,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: isPrimary
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                                color: hovered || isPrimary
                                    ? AppColors.text
                                    : AppColors.textMuted,
                              ),
                            ),
                          ),
                          if (isPrimary) ...[
                            const SizedBox(width: 6),
                            _KeycapBadge(label: 'Tab', dark: dark),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 4),
          IdeHover(
            message: '隐藏当前预测建议',
            child: HoverBuilder(
              cursor: SystemMouseCursors.click,
              builder: (context, hovered) => GestureDetector(
                onTapDown: (_) {},
                onTap: () => setState(() {
                  _dismissedSuggestionTurnKey = _suggestionTurnKey;
                }),
                child: Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: hovered
                        ? AppColors.textFaint.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 12.5,
                    color: hovered ? AppColors.textMuted : AppColors.textFaint,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    return SuggestionMenu(
      title: _menuKind == SuggestionKind.file
          ? context.l10n.composerMentions
          : context.l10n.composerCommands,
      matches: _matches,
      highlighted: _highlighted,
      onHighlight: (index) => setState(() => _highlighted = index),
      onSelect: _accept,
    );
  }

  Widget _buildEditor(BuildContext context) {
    // Slim overlay scrollbar for when the text exceeds the max height.
    return ScrollbarTheme(
      data: ScrollbarTheme.of(context).copyWith(
        thickness: const WidgetStatePropertyAll(4),
        crossAxisMargin: 3,
      ),
      child: Scrollbar(
        controller: _scrollController,
        // Desktop scroll behavior would add a second, default scrollbar to
        // the editor's scroll view.
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: _buildEditorBody(context),
        ),
      ),
    );
  }

  Widget _buildEditorBody(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final base = DefaultTextStyle.of(context).style.merge(_textStyle);
    final placeholderColor = colors['agentsChatInput.placeholderForeground'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 6),
      child: ClipRect(
        child: ComposerCaret(
          editorKey: _editorKey,
          child: Listener(
            onPointerDown: _handleClickDown,
            onPointerUp: _handleClickUp,
            onPointerCancel: (_) => _clickDownAt = null,
            child: Listener(
              onPointerDown: _handleMenuPointerDown,
              onPointerUp: _handleMenuPointerUp,
              onPointerCancel: (_) => _menuPressAt = null,
              child: Stack(
                children: [
                  _buildMarkdownEditor(context),
                  if (!_isFlutterTest && widget.onSubmit == null)
                    Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: ListenableBuilder(
                          listenable: _controller,
                          builder: (context, _) {
                            if (_isComposing || !_caretAtEnd) {
                              return const SizedBox.shrink();
                            }
                            if (_scrollController.hasClients &&
                                _scrollController.offset > 0.5) {
                              return const SizedBox.shrink();
                            }
                            final raw = _controller.text;
                            if (raw.trim().isEmpty) {
                              return const SizedBox.shrink();
                            }
                            final prediction = _computeInlinePrediction(raw);
                            if (prediction == null) {
                              return const SizedBox.shrink();
                            }
                            final trimmedLeft = raw.trimLeft();
                            if (!prediction
                                    .toLowerCase()
                                    .startsWith(trimmedLeft.toLowerCase()) ||
                                prediction.length <= trimmedLeft.length) {
                              return const SizedBox.shrink();
                            }
                            final suffix = prediction.substring(
                              trimmedLeft.length,
                            );
                            return Text.rich(
                              TextSpan(
                                style: base,
                                children: [
                                  TextSpan(
                                    text: raw,
                                    style: base.copyWith(
                                      color: Colors.transparent,
                                    ),
                                  ),
                                  TextSpan(
                                    text: suffix,
                                    style: base.copyWith(
                                      color: placeholderColor.withValues(
                                        alpha: dark ? 0.68 : 0.78,
                                      ),
                                    ),
                                  ),
                                  const TextSpan(text: '  '),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: _KeycapBadge(
                                      label: 'Tab',
                                      dark: dark,
                                    ),
                                  ),
                                ],
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Context menu -------------------------------------------------------
  //
  // A right click opens the system's menu, the caret first put at the
  // click, unless the click is on a selection.

  /// Where a right click went down; null for other presses.
  Offset? _menuPressAt;

  void _handleMenuPointerDown(PointerDownEvent event) {
    _menuPressAt =
        event.kind == PointerDeviceKind.mouse &&
            event.buttons == kSecondaryMouseButton
        ? event.position
        : null;
  }

  void _handleMenuPointerUp(PointerUpEvent event) {
    final down = _menuPressAt;
    _menuPressAt = null;
    if (down == null || (event.position - down).distance > kTouchSlop) return;
    final selection = _controller.selection;
    if (_editorKey.currentState?.offsetAt(event.position) case final at?
        when selection.isCollapsed ||
            at < selection.start ||
            at > selection.end) {
      _controller.selection = TextSelection.collapsed(offset: at);
    }
    _focusNode.requestFocus();
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _showContextMenu(event.position))
      ..scheduleFrame();
  }

  Future<void> _showContextMenu(Offset position) async {
    if (!mounted || !WindowControls.hasNativeMenus) return;
    final selected = !_controller.selection.isCollapsed;
    final canPaste = await WindowControls.canPaste();
    if (!mounted) return;
    final l10n = context.l10n;
    final chosen = await WindowControls.showContextMenu(position, [
      NativeMenuItem('cut', l10n.commonCut, key: 'x', enabled: selected),
      NativeMenuItem('copy', l10n.commonCopy, key: 'c', enabled: selected),
      NativeMenuItem('paste', l10n.commonPaste, key: 'v', enabled: canPaste),
      const NativeMenuItem.separator(),
      NativeMenuItem(
        'selectAll',
        l10n.commonSelectAll,
        key: 'a',
        enabled: _controller.length > 0,
      ),
    ]);
    final editor = _editorKey.currentState;
    if (!mounted || editor == null) return;
    _focusNode.requestFocus();
    // As their shortcuts do: the selection stays where it is.
    switch (chosen) {
      case 'cut':
        await editor.copy(cut: true);
      case 'copy':
        await editor.copy();
      case 'paste':
        await editor.paste();
      case 'selectAll':
        _selectAll();
    }
  }

  void _selectAll() => _controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: _controller.length,
  );

  // --- Double-click -------------------------------------------------------
  //
  // A double-click with nothing selected selects everything; with text
  // selected it selects a word, as the editor does. Told apart here rather
  // than by the editor: a real click often moves the pointer a pixel or
  // two, past where a drag starts, and then it sees no double-click at all.

  /// How far a press may move and still be a click.
  static const _clickSlop = 6.0;

  /// Where the current plain press came down; null for other presses.
  Offset? _clickDownAt;

  /// Open from a click's up while a press near it is that click's double.
  Timer? _clickWindow;
  Offset? _clickUpAt;

  /// Whether text was selected when the last first click came down.
  bool _clickOnSelection = false;

  /// Whether the current press is a double-click's second.
  bool _secondClick = false;

  void _handleClickDown(PointerDownEvent event) {
    final plainPress =
        event.kind == PointerDeviceKind.mouse &&
        event.buttons == kPrimaryMouseButton &&
        !HardwareKeyboard.instance.isShiftPressed;
    final upAt = _clickUpAt;
    _clickDownAt = plainPress ? event.position : null;
    _secondClick =
        plainPress &&
        _clickWindow?.isActive == true &&
        upAt != null &&
        (event.position - upAt).distance <= kDoubleTapSlop;
    _clickWindow?.cancel();
    _clickWindow = null;
    // The first click puts any selection away, so ask before it.
    if (!_secondClick) _clickOnSelection = !_controller.selection.isCollapsed;
  }

  void _handleClickUp(PointerUpEvent event) {
    final downAt = _clickDownAt;
    _clickDownAt = null;
    if (downAt == null || (event.position - downAt).distance > _clickSlop) {
      return;
    }
    // A third click is a click again (no window after a second).
    if (_secondClick) {
      if (_clickOnSelection) return;
      // After the editor's handling of the up, which comes after this:
      // whatever it made of the press (a word, a caret, a drag of a pixel).
      scheduleMicrotask(() {
        if (mounted) _selectAll();
      });
      return;
    }
    _clickUpAt = event.position;
    _clickWindow = Timer(kDoubleTapTimeout, () => _clickWindow = null);
  }

  /// Grows with content up to 10 lines, or a third of the window on short
  /// windows, then scrolls internally.
  double _maxEditorHeight(BuildContext context) {
    final byWindow = MediaQuery.sizeOf(context).height / 3;
    return math.max(
      _minEditorHeight,
      math.min(_lineHeight * _maxEditorLines, byWindow),
    );
  }

  Widget _buildMarkdownEditor(BuildContext context) {
    final colors = themeColors;
    final base = DefaultTextStyle.of(context).style.merge(_textStyle);
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: _minEditorHeight,
        maxHeight: _maxEditorHeight(context),
      ),
      child: MarkdownEditor(
        key: _editorKey,
        controller: _controller,
        focusNode: _focusNode,
        scrollController: _scrollController,
        shrinkWrap: true,
        embeds: const ComposerChips(),
        // A suggested prompt, then the key that takes it as the keybindings
        // label it (`Tab`); alone when it has none. On one line.
        placeholder: switch ((
          _isFlutterTest ? _suggestion : null,
          _isFlutterTest ? _suggestionKey : null,
        )) {
          (final suggestion?, final key?) => '$suggestion    $key',
          (final suggestion?, null) => suggestion,
          (null, _) => context.l10n.composerPlaceholder,
        }.replaceAll(RegExp(r'[\x00-\x1f]+'), ' '),
        onKey: _handleKey,
        onPaste: _paste,
        onPasteCopy: (markdown) =>
            renumberPastes(markdown, from: _nextPastedNumber()),
        style: MarkdownEditorStyle(
          text: base,
          selection: AppColors.textSelection,
          caret: colors['editorCursor.foreground'],
          placeholder: TextStyle(
            color: colors['agentsChatInput.placeholderForeground'],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final session = widget.session;
    // Only the dock's composer picks the kernel, and only until it starts.
    final kernel = widget.onSubmit == null ? session.kernelChoice : null;
    final mode = session.modes;
    final permission = session.permissions;
    final model = session.models;
    final context = session.context;
    final l10n = this.context.l10n;
    KernelOption localized(KernelOption option) => localizedKernelOption(
      l10n,
      session.kernel.id,
      KernelChoiceKind.permission,
      option,
    );
    final dark = themeColors.dark;
    final hasModel = model != null || session.health.noModel;
    final hasLeadingPickers = kernel != null || mode != null || permission != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? 0.015 : 0.016,
        ),
        border: Border(
          top: BorderSide(
            color: AppColors.partBorder.withValues(alpha: dark ? 0.35 : 0.42),
            width: 0.75,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 5.5, 8, 6),
        child: Row(
          children: [
            // Takes the room left, so the actions sit at the far end; the
            // model's label cut short to fit, scrolls when even that does not.
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: PickersRow(
                    maxWidth: constraints.maxWidth,
                    children: [
                      if (kernel != null) ...[
                        ComposerPicker(
                          options: kernel.options,
                          selected: kernel.selected,
                          tapRegionGroupId: widget.tapRegionGroupId,
                          focusNode: _focusNode,
                          onSelected: kernel.onSelected,
                        ),
                        const SizedBox(width: 3),
                      ],
                      if (mode != null) ...[
                        ComposerPicker(
                          key: _modePickerKey,
                          options: mode.options,
                          selected: mode.selected,
                          emphasized: true,
                          tooltip: _hovers.mode,
                          tapRegionGroupId: widget.tapRegionGroupId,
                          focusNode: _focusNode,
                          onSelected: mode.onSelected,
                        ),
                        const SizedBox(width: 3),
                      ],
                      if (permission != null) ...[
                        ComposerPicker(
                          options: [
                            for (final option in permission.options)
                              localized(option),
                          ],
                          selected: localized(permission.selected),
                          // `context` is the session's here.
                          title: l10n.composerApprovalTitle(
                            session.kernel.label,
                          ),
                          menuWidth: 290,
                          tapRegionGroupId: widget.tapRegionGroupId,
                          focusNode: _focusNode,
                          onSelected: permission.onSelected,
                        ),
                      ],
                      if (hasLeadingPickers && hasModel) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          child: Container(
                            width: 1,
                            height: 11,
                            color: AppColors.partBorder.withValues(
                              alpha: dark ? 0.55 : 0.65,
                            ),
                          ),
                        ),
                      ],
                      // With none to pick, one to set up.
                      if (hasModel)
                        SessionModelPicker(
                          session: session,
                          pickerKey: _modelPickerKey,
                          tooltip: _hovers.model,
                          tapRegionGroupId: widget.tapRegionGroupId,
                          focusNode: _focusNode,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (ComposerPolishSetting.current()) ...[
              _PolishButton(
                busy: _polishing,
                enabled: _polishing || _shownBuilt!.polishable,
                onTap: () => unawaited(_polish()),
              ),
              const SizedBox(width: 2),
            ],
            if ((widget.onToggleContextPanel, context) case (
              final onToggle?,
              final usage?,
            )) ...[
              ContextMeter(
                usage: usage,
                active: widget.contextPanelOpen,
                // Toggle Context Panel's, which has none by default.
                tooltip: _hovers.ring,
                onTap: onToggle,
              ),
              const SizedBox(width: 2),
            ],
            const SizedBox(width: 3),
            _SendButton(
              streaming: _showsStop,
              enabled: _canSend,
              onSend: _submit,
              onStop: () => stopTurn(this.context, session),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tactile 3D keycap badge (e.g. `Tab`) matching macOS / studio workbench keycaps.
class _KeycapBadge extends StatelessWidget {
  const _KeycapBadge({required this.label, required this.dark});

  final String label;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.09)
            : Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4.5),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.14)
              : Colors.black.withValues(alpha: 0.11),
          width: 0.75,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.06),
            offset: const Offset(0, 1),
            blurRadius: 0,
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          height: 1.15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.15,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}

/// Polish, Enhance prompt as it says (see [ChatComposerState._polish]): a
/// sparkle, spinning while the model answers; faint with no words to polish,
/// yet still responsive on hover with a circular highlight and status tooltip.
class _PolishButton extends StatelessWidget {
  const _PolishButton({
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dark = themeColors.dark;
    final active = enabled && !busy;
    final isZh = l10n.localeName.startsWith('zh');
    final hoverBase = active
        ? Color.lerp(
            dark ? Colors.white : Colors.black,
            AppColors.accent,
            0.42,
          )!
        : (dark ? Colors.white : Colors.black);
    final hoverAlpha = active ? (dark ? 0.19 : 0.13) : (dark ? 0.13 : 0.09);

    return IdeHover(
      position: IdeHoverPosition.above,
      message: busy ? l10n.composerPolishing : l10n.composerPolishHint,
      content: busy
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${l10n.composerPolish} (⌘E)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    enabled
                        ? (isZh
                              ? '用辅助模型将草稿改写得更清晰具体（⌘Z 可撤销）'
                              : l10n.composerPolishHint)
                        : (isZh
                              ? '输入内容后点击可一键润色增强提示词'
                              : 'Type a prompt first to enhance it'),
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
      child: HoverBuilder(
        cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
        builder: (context, hovered) {
          final iconColor = busy
              ? AppColors.accent
              : active
              ? (hovered ? AppColors.accent : AppColors.textMuted)
              : (hovered ? AppColors.textMuted : AppColors.textFaint);
          final icon = Icon(
            busy ? Codicons.loading : Codicons.sparkle,
            size: 14,
            color: iconColor,
          );
          return GestureDetector(
            // Keeps the editor's focus.
            onTapDown: (_) {},
            onTap: active ? onTap : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hovered
                    ? hoverBase.withValues(alpha: hoverAlpha)
                    : hoverBase.withValues(alpha: 0),
                shape: BoxShape.circle,
                border: Border.all(
                  color: active && hovered
                      ? AppColors.accent.withValues(alpha: dark ? 0.36 : 0.28)
                      : AppColors.accent.withValues(alpha: 0),
                  width: 0.85,
                ),
              ),
              child: busy ? IdeSpinning(icon) : icon,
            ),
          );
        },
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.streaming,
    required this.enabled,
    required this.onSend,
    required this.onStop,
  });

  final bool streaming;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final active = streaming || enabled;
    final colors = themeColors;
    // As upstream's submit button: the primary button's colors; disabled,
    // none but the disabled icon.
    final foreground = colors['button.foreground'];
    // With the keys that do the same, as the keybindings have them.
    const input = {ChatContextKeys.inChatInput: true};
    return IdeHover(
      message: streaming
          ? ChatKeys.titleWithKey(
              context.l10n.composerStop,
              ChatCommandIds.cancel,
              {...input, ChatContextKeys.requestInProgress: true},
            )
          : ChatKeys.titleWithKey(
              context.l10n.cmdChatSubmit,
              ChatCommandIds.submit,
              input,
            ),
      child: HoverBuilder(
        cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
        builder: (context, hovered) => GestureDetector(
          onTap: streaming ? onStop : (enabled ? onSend : null),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 27,
            height: 27,
            decoration: BoxDecoration(
              color: !active
                  ? AppColors.textFaint.withValues(alpha: 0.12)
                  : hovered
                  ? colors['button.hoverBackground']
                  : colors['button.background'],
              shape: BoxShape.circle,
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: colors['button.background'].withValues(
                          alpha: 0.30,
                        ),
                        blurRadius: 7,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: streaming
                  ? Container(
                      key: const ValueKey('stop'),
                      width: 8.5,
                      height: 8.5,
                      decoration: BoxDecoration(
                        color: foreground,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    )
                  : Icon(
                      key: const ValueKey('send'),
                      Icons.arrow_upward_rounded,
                      size: 15.5,
                      color: active ? foreground : AppColors.textFaint,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

typedef _ShownOfText = ({
  Object menu,
  Map<int, ImageAttachment> pool,
  bool canSend,
  bool polishable,
  String? inlinePrediction,
});
