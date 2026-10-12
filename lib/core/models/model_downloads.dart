// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'model_catalog.dart';
import 'model_downloader.dart';

/// What the UI and the Gemma engine need from a model downloader. Linux uses
/// the in-process [ModelDownloader]; Android hands the transfer to the system
/// DownloadManager so it survives the app going away.
abstract interface class ModelDownloads {
  /// Whether [pause] keeps the partial file for [start] to resume. When false,
  /// [pause] is a cancel and the UI should only offer "Cancel".
  bool get supportsPause;

  Stream<DownloadStatus> watch(GemmaVariant v);
  DownloadStatus statusOf(GemmaVariant v);

  /// Reads the real state (disk, and the system downloader if any). Call at
  /// startup so a download that finished while the app was closed is verified.
  Future<DownloadStatus> refresh(GemmaVariant v);

  bool isActive(GemmaVariant v);

  /// Starts or resumes; progress is reported through [watch].
  Future<DownloadStatus> start(GemmaVariant v);
  Future<void> pause(GemmaVariant v);
  Future<void> delete(GemmaVariant v);

  File finalFile(GemmaVariant v);
}
